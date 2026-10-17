// hehehehehe "ts"
const PACKET: usize = 188;
const SYNC: u8 = 0x47;
const AUDIO_TYPES: [u8; 3] = [0x0f, 0x03, 0x04];

pub fn is_ts(data: &[u8]) -> bool {
    data.len() >= PACKET && data[0] == SYNC && (data.len() < PACKET * 2 || data[PACKET] == SYNC)
}

pub fn demux(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut pmt = None;
    let mut audio = None;
    let mut output = Vec::with_capacity(data.len());
    for packet in data.chunks_exact(PACKET) {
        if packet[0] != SYNC {
            continue;
        }
        let start = packet[1] & 0x40 != 0;
        let pid = (u16::from(packet[1] & 0x1f) << 8) | u16::from(packet[2]);
        let control = (packet[3] >> 4) & 3;
        if control & 1 == 0 {
            continue;
        }
        let at = if control == 3 { 5 + packet[4] as usize } else { 4 };
        if at >= PACKET {
            continue;
        }
        let payload = &packet[at..];
        if pid == 0 && start {
            pmt = program_map(payload);
        } else if Some(pid) == pmt && start && audio.is_none() {
            audio = audio_stream(payload);
        } else if Some(pid) == audio {
            if !start {
                output.extend_from_slice(payload);
            } else if payload.len() >= 9 && payload[..3] == [0, 0, 1] {
                let body = 9 + payload[8] as usize;
                if body <= payload.len() {
                    output.extend_from_slice(&payload[body..]);
                }
            }
        }
    }
    match audio {
        Some(_) => Ok(output),
        None => Err("the stream segment has no supported audio".into()),
    }
}

fn section(payload: &[u8], table: u8) -> Option<&[u8]> {
    let pointer = *payload.first()? as usize;
    let data = payload.get(1 + pointer..)?;
    if *data.first()? != table || data.len() < 3 {
        return None;
    }
    let length = (usize::from(data[1] & 0x0f) << 8) | usize::from(data[2]);
    data.get(..(3 + length).saturating_sub(4))
}

fn program_map(payload: &[u8]) -> Option<u16> {
    let data = section(payload, 0x00)?;
    data.get(8..)?.chunks_exact(4).find_map(|entry| {
        let program = u16::from_be_bytes([entry[0], entry[1]]);
        (program != 0).then(|| (u16::from(entry[2] & 0x1f) << 8) | u16::from(entry[3]))
    })
}

fn audio_stream(payload: &[u8]) -> Option<u16> {
    let data = section(payload, 0x02)?;
    let info = (usize::from(*data.get(10)? & 0x0f) << 8) | usize::from(*data.get(11)?);
    let mut at = 12 + info;
    while at + 5 <= data.len() {
        let kind = data[at];
        let pid = (u16::from(data[at + 1] & 0x1f) << 8) | u16::from(data[at + 2]);
        if AUDIO_TYPES.contains(&kind) {
            return Some(pid);
        }
        at += 5 + ((usize::from(data[at + 3] & 0x0f) << 8) | usize::from(data[at + 4]));
    }
    None
}

#[cfg(test)]
pub mod tests {
    use super::*;

    fn packet(pid: u16, start: bool, payload: &[u8]) -> Vec<u8> {
        let mut packet = vec![SYNC, (if start { 0x40 } else { 0 }) | (pid >> 8) as u8, pid as u8];
        let room = PACKET - 4;
        if payload.len() >= room {
            packet.push(0x10);
            packet.extend_from_slice(&payload[..room]);
        } else {
            let stuffing = room - payload.len() - 1;
            packet.push(0x30);
            packet.push(stuffing as u8);
            if stuffing > 0 {
                packet.push(0);
                packet.extend(std::iter::repeat_n(0xff, stuffing - 1));
            }
            packet.extend_from_slice(payload);
        }
        packet
    }

    pub fn wrap(audio: &[u8]) -> Vec<u8> {
        let pat = [0, 0x00, 0xb0, 13, 0, 1, 0xc1, 0, 0, 0, 1, 0xe1, 0x00, 0, 0, 0, 0];
        let pmt = [0, 0x02, 0xb0, 18, 0, 1, 0xc1, 0, 0, 0xe1, 0x01, 0xf0, 0, 0x0f, 0xe1, 0x01, 0xf0, 0, 0, 0, 0, 0];
        let mut data = packet(0, true, &pat);
        data.extend(packet(0x100, true, &pmt));
        let mut pes = vec![0, 0, 1, 0xc0, 0, 0, 0x80, 0x80, 5, 0x21, 0, 1, 0, 1];
        pes.extend_from_slice(audio);
        let mut first = true;
        for chunk in pes.chunks(PACKET - 4) {
            data.extend(packet(0x101, first, chunk));
            first = false;
        }
        data
    }

    #[test]
    fn pulls_the_audio_out_of_transport_streams() {
        let audio: Vec<u8> = (0..1000u32).map(|value| (value % 251) as u8).collect();
        let data = wrap(&audio);
        assert!(is_ts(&data));
        assert_eq!(demux(&data).unwrap(), audio);
        assert!(!is_ts(b"ID3 not a transport stream at all, just some bytes"));
        assert!(demux(&data[PACKET * 2..]).is_err());
    }
}
