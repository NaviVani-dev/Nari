use rustysynth::{MidiFile, MidiFileSequencer, SoundFont, Synthesizer, SynthesizerSettings};
use std::ffi::{c_char, c_int, c_void, CStr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use xmrs::prelude::Module;
use xmrsplayer::xmrsplayer::XmrsPlayer;

use crate::library::meta::Metadata;

const CHUNK: usize = 1024;
const MIDI: [&str; 3] = ["mid", "midi", "kar"];
pub const MODULES: [&str; 23] = [
    "mod", "xm", "s3m", "it", "mptm", "669", "amf", "ams", "dbm", "dmf", "dsm", "far", "mdl", "med", "mo3", "mt2", "mtm", "okt", "psm", "ptm", "stm",
    "ult", "umx",
];
const SID: &str = "sid";
const OVERRUN_SECONDS: f64 = 2.0;
const LOOP_FADE_SECONDS: f64 = 10.0;
const LOOP_TAIL_RMS: f32 = 0.005;
pub const NO_SOUNDFONT: &str = "Choose a SoundFont in Settings → Playback to play MIDI";

static MODULE_ENDING: AtomicBool = AtomicBool::new(true);
static SOUNDFONT: Mutex<String> = Mutex::new(String::new());
static LOADED: Mutex<Option<(String, Arc<SoundFont>)>> = Mutex::new(None);

pub trait Generator: Send {
    fn render(&mut self) -> Option<Vec<f32>>;
    fn seek(&mut self, position_ms: u64);
}

pub fn set_soundfont(path: &str) {
    *SOUNDFONT.lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = path.to_owned();
}

pub fn set_module_ending(enabled: bool) {
    MODULE_ENDING.store(enabled, Ordering::Relaxed);
}

pub fn handles(name: &str) -> bool {
    let extension = crate::storage::extension(name);
    MIDI.contains(&extension.as_str()) || MODULES.contains(&extension.as_str()) || extension == SID
}

pub fn open(bytes: &[u8], name: &str, rate: u32) -> Result<Box<dyn Generator>, String> {
    if MIDI.contains(&crate::storage::extension(name).as_str()) {
        let file = Arc::new(MidiFile::new(&mut &bytes[..]).map_err(|error| error.to_string())?);
        let settings = SynthesizerSettings::new(rate as i32);
        let synthesizer = Synthesizer::new(&soundfont()?, &settings).map_err(|error| error.to_string())?;
        let mut sequencer = MidiFileSequencer::new(synthesizer);
        sequencer.play(&file, false);
        return Ok(Box::new(Midi { sequencer, file, left: vec![0.0; CHUNK], right: vec![0.0; CHUNK] }));
    }
    if crate::storage::extension(name) != SID {
        return Ok(Box::new(Openmpt::load(bytes, rate)?));
    }
    let module = Box::new(Module::load(bytes).map_err(|error| format!("{error:?}"))?);
    let player = XmrsPlayer::new(unsafe { &*(module.as_ref() as *const Module) }, rate, 0);
    let mut tracker = Tracker { player, _module: module, rate, rendered: 0, limit: 0 };
    tracker.player.set_max_loop_count(1);
    tracker.limit = ((tracker.player.duration_seconds() + OVERRUN_SECONDS) * f64::from(rate)) as u64;
    Ok(Box::new(tracker))
}

pub fn metadata(uri: &str, name: &str) -> Option<Metadata> {
    let mut bytes = Vec::new();
    std::io::Read::read_to_end(&mut crate::storage::open(uri).ok()?, &mut bytes).ok()?;
    let stem = name.rsplit_once('.').map_or(name, |(stem, _)| stem).to_owned();
    let extension = crate::storage::extension(name);
    let (title, seconds) = if MIDI.contains(&extension.as_str()) {
        (stem, MidiFile::new(&mut &bytes[..]).ok()?.get_length())
    } else if extension != SID {
        let module = Openmpt::load(&bytes, 44100).ok()?;
        let title = module.text(c"title");
        let artist = module.text(c"artist");
        return Some(Metadata {
            title: if title.is_empty() { stem } else { title },
            artists: if artist.is_empty() { Vec::new() } else { vec![artist] },
            duration: (module.seconds() * 1000.0) as i64,
            ..Metadata::default()
        });
    } else {
        let module = Module::load(&bytes).ok()?;
        let seconds = XmrsPlayer::new(&module, 44100, 0).duration_seconds();
        let title = module.name.trim().to_owned();
        (if title.is_empty() { stem } else { title }, seconds)
    };
    Some(Metadata { title, duration: (seconds * 1000.0) as i64, ..Metadata::default() })
}

fn soundfont() -> Result<Arc<SoundFont>, String> {
    let path = SOUNDFONT.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).clone();
    if path.is_empty() {
        return Err(NO_SOUNDFONT.into());
    }
    let mut loaded = LOADED.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some((_, font)) = loaded.as_ref().filter(|(cached, _)| *cached == path) {
        return Ok(font.clone());
    }
    let mut file = std::fs::File::open(&path).map_err(|error| format!("the SoundFont can't be opened: {error}"))?;
    let font = Arc::new(SoundFont::new(&mut file).map_err(|error| format!("the SoundFont is not valid: {error}"))?);
    *loaded = Some((path, font.clone()));
    Ok(font)
}

struct Midi {
    sequencer: MidiFileSequencer,
    file: Arc<MidiFile>,
    left: Vec<f32>,
    right: Vec<f32>,
}

impl Generator for Midi {
    fn render(&mut self) -> Option<Vec<f32>> {
        if self.sequencer.end_of_sequence() {
            return None;
        }
        self.sequencer.render(&mut self.left, &mut self.right);
        Some(self.left.iter().zip(&self.right).flat_map(|(left, right)| [*left, *right]).collect())
    }

    fn seek(&mut self, position_ms: u64) {
        self.sequencer.play(&self.file, false);
        let target = position_ms as f64 / 1000.0;
        while self.sequencer.get_position() < target && !self.sequencer.end_of_sequence() {
            self.sequencer.render(&mut self.left, &mut self.right);
        }
    }
}

extern "C" {
    fn openmpt_module_create_from_memory2(
        data: *const c_void,
        size: usize,
        logfunc: *const c_void,
        loguser: *mut c_void,
        errfunc: *const c_void,
        erruser: *mut c_void,
        error: *mut c_int,
        message: *mut *const c_char,
        ctls: *const c_void,
    ) -> *mut c_void;
    fn openmpt_module_destroy(module: *mut c_void);
    fn openmpt_module_set_repeat_count(module: *mut c_void, count: i32) -> c_int;
    fn openmpt_module_get_duration_seconds(module: *mut c_void) -> f64;
    fn openmpt_module_set_position_seconds(module: *mut c_void, seconds: f64) -> f64;
    fn openmpt_module_read_interleaved_float_stereo(module: *mut c_void, rate: i32, count: usize, buffer: *mut f32) -> usize;
    fn openmpt_module_get_metadata(module: *mut c_void, key: *const c_char) -> *const c_char;
    fn openmpt_free_string(text: *const c_char);
}

struct Openmpt {
    module: *mut c_void,
    rate: i32,
    end: u64,
    fade: u64,
    rendered: u64,
}

unsafe impl Send for Openmpt {}

impl Openmpt {
    fn load(bytes: &[u8], rate: u32) -> Result<Self, String> {
        let null = std::ptr::null_mut();
        let module = unsafe {
            openmpt_module_create_from_memory2(bytes.as_ptr().cast(), bytes.len(), null, null, null, null, null.cast(), null.cast(), null)
        };
        if module.is_null() {
            return Err("this module format is not supported".into());
        }
        let duration = unsafe { openmpt_module_get_duration_seconds(module) };
        let mut tail = vec![0.0f32; rate as usize * 2];
        let frames = unsafe {
            openmpt_module_set_position_seconds(module, (duration - 1.0).max(0.0));
            openmpt_module_read_interleaved_float_stereo(module, rate as i32, rate as usize, tail.as_mut_ptr())
        };
        let loud = tail[..frames * 2].iter().map(|sample| sample * sample).sum::<f32>() / (frames * 2).max(1) as f32;
        let looping = loud.sqrt() > LOOP_TAIL_RMS;
        unsafe {
            openmpt_module_set_repeat_count(module, if looping { -1 } else { 0 });
            openmpt_module_set_position_seconds(module, 0.0);
        }
        let fade = if looping && MODULE_ENDING.load(Ordering::Relaxed) { (LOOP_FADE_SECONDS * f64::from(rate)) as u64 } else { 0 };
        Ok(Self { module, rate: rate as i32, end: (duration * f64::from(rate)) as u64, fade, rendered: 0 })
    }

    fn seconds(&self) -> f64 {
        (self.end + self.fade) as f64 / f64::from(self.rate)
    }

    fn text(&self, key: &CStr) -> String {
        let value = unsafe { openmpt_module_get_metadata(self.module, key.as_ptr()) };
        if value.is_null() {
            return String::new();
        }
        let text = unsafe { CStr::from_ptr(value) }.to_string_lossy().trim().to_owned();
        unsafe { openmpt_free_string(value) };
        text
    }
}

impl Drop for Openmpt {
    fn drop(&mut self) {
        unsafe { openmpt_module_destroy(self.module) };
    }
}

impl Generator for Openmpt {
    fn render(&mut self) -> Option<Vec<f32>> {
        let left = (self.end + self.fade).saturating_sub(self.rendered);
        if self.fade > 0 && left == 0 {
            return None;
        }
        let wanted = if self.fade > 0 { CHUNK.min(left as usize) } else { CHUNK };
        let mut chunk = vec![0.0; wanted * 2];
        let frames = unsafe { openmpt_module_read_interleaved_float_stereo(self.module, self.rate, wanted, chunk.as_mut_ptr()) };
        chunk.truncate(frames * 2);
        for (index, frame) in chunk.chunks_mut(2).enumerate() {
            let past = (self.rendered + index as u64).saturating_sub(self.end);
            if past > 0 && self.fade > 0 {
                let gain = 1.0 - past as f32 / self.fade as f32;
                frame.iter_mut().for_each(|sample| *sample *= gain);
            }
        }
        self.rendered += frames as u64;
        (frames > 0).then_some(chunk)
    }

    fn seek(&mut self, position_ms: u64) {
        self.rendered = position_ms * self.rate as u64 / 1000;
        let position = if self.rendered > self.end { self.rendered - self.end } else { self.rendered };
        unsafe { openmpt_module_set_position_seconds(self.module, position as f64 / f64::from(self.rate)) };
    }
}

struct Tracker {
    player: XmrsPlayer<'static>,
    _module: Box<Module>,
    rate: u32,
    rendered: u64,
    limit: u64,
}

impl Generator for Tracker {
    fn render(&mut self) -> Option<Vec<f32>> {
        let mut chunk = Vec::with_capacity(CHUNK * 2);
        while chunk.len() < CHUNK * 2 && self.rendered < self.limit {
            let Some((left, right)) = self.player.sample(true) else {
                self.limit = 0;
                break;
            };
            chunk.push(f32::from(left) / 32768.0);
            chunk.push(f32::from(right) / 32768.0);
            self.rendered += 1;
        }
        (!chunk.is_empty()).then_some(chunk)
    }

    fn seek(&mut self, position_ms: u64) {
        if self.player.seek_seconds(position_ms as f64 / 1000.0) {
            self.rendered = position_ms * u64::from(self.rate) / 1000;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(id: &[u8], body: &[u8]) -> Vec<u8> {
        let mut bytes = id.to_vec();
        bytes.extend_from_slice(&(body.len() as u32).to_le_bytes());
        bytes.extend_from_slice(body);
        if body.len() % 2 == 1 {
            bytes.push(0);
        }
        bytes
    }

    fn list(kind: &[u8], chunks: &[Vec<u8>]) -> Vec<u8> {
        let mut body = kind.to_vec();
        for part in chunks {
            body.extend_from_slice(part);
        }
        chunk(b"LIST", &body)
    }

    fn name(text: &str, size: usize) -> Vec<u8> {
        let mut bytes = text.as_bytes().to_vec();
        bytes.resize(size, 0);
        bytes
    }

    fn words(values: &[u16]) -> Vec<u8> {
        values.iter().flat_map(|value| value.to_le_bytes()).collect()
    }

    fn soundfont() -> Vec<u8> {
        let wave: Vec<i16> = (0..400).map(|index| ((index as f32 / 100.0 * std::f32::consts::TAU).sin() * 12000.0) as i16).collect();
        let mut samples: Vec<u8> = wave.iter().flat_map(|sample| sample.to_le_bytes()).collect();
        samples.extend(vec![0u8; 46 * 2]);
        let preset = |label: &str, bag: u16| [name(label, 20), words(&[0, 0, bag]), vec![0; 12]].concat();
        let instrument = |label: &str, bag: u16| [name(label, 20), words(&[bag])].concat();
        let header = |label: &str, end: u32, kind: u16| {
            let mut bytes = name(label, 20);
            for value in [0u32, end, 0, end, 44100] {
                bytes.extend_from_slice(&value.to_le_bytes());
            }
            bytes.extend_from_slice(&[69, 0]);
            bytes.extend_from_slice(&words(&[0, kind]));
            bytes
        };
        let body = [
            b"sfbk".to_vec(),
            list(b"INFO", &[chunk(b"ifil", &words(&[2, 1])), chunk(b"isng", b"EMU8000\0"), chunk(b"INAM", b"Test\0\0")]),
            list(b"sdta", &[chunk(b"smpl", &samples)]),
            list(
                b"pdta",
                &[
                    chunk(b"phdr", &[preset("Tone", 0), preset("EOP", 1)].concat()),
                    chunk(b"pbag", &words(&[0, 0, 1, 0])),
                    chunk(b"pmod", &[0; 10]),
                    chunk(b"pgen", &words(&[41, 0, 0, 0])),
                    chunk(b"inst", &[instrument("Tone", 0), instrument("EOI", 1)].concat()),
                    chunk(b"ibag", &words(&[0, 0, 2, 0])),
                    chunk(b"imod", &[0; 10]),
                    chunk(b"igen", &words(&[54, 1, 53, 0, 0, 0])),
                    chunk(b"shdr", &[header("Sine", 400, 1), header("EOS", 0, 0)].concat()),
                ],
            ),
        ]
        .concat();
        chunk(b"RIFF", &body)
    }

    fn midi() -> Vec<u8> {
        let track = [0x00, 0x90, 60, 100, 0x81, 0x40, 0x80, 60, 0, 0x00, 0xff, 0x2f, 0x00];
        let mut bytes = b"MThd".to_vec();
        bytes.extend_from_slice(&6u32.to_be_bytes());
        bytes.extend_from_slice(&[0, 0, 0, 1, 0, 96]);
        bytes.extend_from_slice(b"MTrk");
        bytes.extend_from_slice(&(track.len() as u32).to_be_bytes());
        bytes.extend_from_slice(&track);
        bytes
    }

    fn module(looped: bool) -> Vec<u8> {
        let mut bytes = name("Nari test", 20);
        let length_words = 32u16;
        for index in 0..31 {
            bytes.extend(name("", 22));
            let length = if index == 0 { length_words } else { 0 };
            bytes.extend_from_slice(&length.to_be_bytes());
            bytes.extend_from_slice(&[0, 64]);
            bytes.extend_from_slice(&0u16.to_be_bytes());
            bytes.extend_from_slice(&(if index == 0 && looped { length_words } else { 1 }).to_be_bytes());
        }
        bytes.extend_from_slice(&[1, 127]);
        bytes.extend(vec![0u8; 128]);
        bytes.extend_from_slice(b"M.K.");
        let mut pattern = vec![0u8; 64 * 4 * 4];
        pattern[..4].copy_from_slice(&[0x01, 0xac, 0x10, 0x00]);
        bytes.extend(pattern);
        bytes.extend((0..length_words * 2).map(|index| if index % 16 < 8 { 100u8 } else { 156u8 }));
        bytes
    }

    fn loud(generator: &mut Box<dyn Generator>) -> (usize, f32) {
        let mut frames = 0;
        let mut peak = 0.0f32;
        while let Some(chunk) = generator.render() {
            frames += chunk.len() / 2;
            peak = chunk.iter().fold(peak, |top, sample| top.max(sample.abs()));
            if frames > 44100 * 20 {
                break;
            }
        }
        (frames, peak)
    }

    #[test]
    fn plays_midi_and_tracker_modules() {
        assert!(handles("song.MID") && handles("tune.xm") && handles("tune.MO3") && handles("x.sid") && !handles("song.mp3"));
        assert_eq!(open(&midi(), "song.mid", 44100).err().as_deref(), Some(NO_SOUNDFONT));
        let folder = std::env::temp_dir().join(format!("nari-synth-{}", std::process::id()));
        std::fs::create_dir_all(&folder).unwrap();
        let font = folder.join("test.sf2");
        std::fs::write(&font, soundfont()).unwrap();
        set_soundfont(&font.to_string_lossy());
        let mut song = open(&midi(), "song.mid", 44100).unwrap();
        let (frames, peak) = loud(&mut song);
        assert!((40000..60000).contains(&frames), "midi rendered {frames} frames");
        assert!(peak > 0.01, "midi peak was {peak}");
        song.seek(500);

        let mut tune = open(&module(false), "tune.mod", 44100).unwrap();
        let (frames, peak) = loud(&mut tune);
        assert!((44100 * 7..44100 * 9).contains(&frames), "module rendered {frames} frames");
        assert!(peak > 0.01, "module peak was {peak}");

        let mut looping = open(&module(true), "loop.mod", 44100).unwrap();
        let mut frames = 0;
        let mut last = Vec::new();
        while let Some(chunk) = looping.render() {
            frames += chunk.len() / 2;
            last = chunk;
            assert!(frames < 44100 * 30, "looping module never ended");
        }
        assert!((44100 * 17..44100 * 19).contains(&frames), "looping module rendered {frames} frames");
        assert!(last.iter().all(|sample| sample.abs() < 0.01), "looping module was not faded out");

        let file = folder.join("tune.mod");
        std::fs::write(&file, module(false)).unwrap();
        let info = metadata(&file.to_string_lossy(), "tune.mod").unwrap();
        assert_eq!(info.title, "Nari test");
        assert!((7000..9000).contains(&info.duration), "module lasts {}", info.duration);
        std::fs::write(&file, module(true)).unwrap();
        let info = metadata(&file.to_string_lossy(), "tune.mod").unwrap();
        assert!((17000..19000).contains(&info.duration), "looping module lasts {}", info.duration);
        let midi_file = folder.join("Piano Song.mid");
        std::fs::write(&midi_file, midi()).unwrap();
        let info = metadata(&midi_file.to_string_lossy(), "Piano Song.mid").unwrap();
        assert_eq!(info.title, "Piano Song");
        assert!((900..1200).contains(&info.duration), "midi lasts {}", info.duration);
        std::fs::remove_dir_all(folder).unwrap();
    }
}
