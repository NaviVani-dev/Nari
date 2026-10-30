pub struct Battery {
    pub level: i32,
    pub charging: bool,
}

pub struct Network {
    pub connection: &'static str,
    pub level: i32,
}

#[cfg_attr(target_os = "android", allow(dead_code))]
const NO_BATTERY: Battery = Battery { level: -1, charging: false };
#[cfg_attr(target_os = "android", allow(dead_code))]
const OFFLINE: Network = Network { connection: "none", level: 0 };

#[cfg(target_os = "linux")]
mod platform {
    use super::{Battery, Network, NO_BATTERY, OFFLINE};
    use std::fs;
    use std::path::Path;

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap_or_default().trim().to_owned()
    }

    pub fn battery() -> Battery {
        let supplies = fs::read_dir("/sys/class/power_supply").into_iter().flatten().flatten();
        for supply in supplies.map(|entry| entry.path()) {
            if read(&supply.join("type")) != "Battery" {
                continue;
            }
            return Battery {
                level: read(&supply.join("capacity")).parse().unwrap_or(-1),
                charging: read(&supply.join("status")) == "Charging",
            };
        }
        NO_BATTERY
    }

    pub fn network() -> Network {
        let mut state = OFFLINE;
        for interface in fs::read_dir("/sys/class/net").into_iter().flatten().flatten().map(|entry| entry.path()) {
            if !interface.join("device").exists() || read(&interface.join("operstate")) != "up" {
                continue;
            }
            if !interface.join("wireless").exists() {
                state = Network { connection: "ethernet", level: 4 };
                continue;
            }
            let name = interface.file_name().unwrap_or_default().to_string_lossy().into_owned();
            return Network { connection: "wireless", level: wireless_level(&name) };
        }
        state
    }

    fn wireless_level(name: &str) -> i32 {
        let table = read(Path::new("/proc/net/wireless"));
        let quality = table
            .lines()
            .find_map(|line| line.trim().strip_prefix(&format!("{name}:")))
            .and_then(|fields| fields.split_whitespace().nth(1))
            .and_then(|value| value.trim_end_matches('.').parse::<f32>().ok())
            .unwrap_or(70.0);
        (quality / 70.0 * 4.0).round().clamp(0.0, 4.0) as i32
    }

    pub fn reduce_motion() -> bool {
        zbus::block_on(async {
            let connection = zbus::Connection::session().await.ok()?;
            for (namespace, key) in [
                ("org.gnome.desktop.interface", "enable-animations"),
                ("org.kde.kdeglobals.KDE", "AnimationDurationFactor"),
            ] {
                let Ok(reply) = connection
                    .call_method(
                        Some("org.freedesktop.portal.Desktop"),
                        "/org/freedesktop/portal/desktop",
                        Some("org.freedesktop.portal.Settings"),
                        "ReadOne",
                        &(namespace, key),
                    )
                    .await
                else {
                    continue;
                };
                let Ok(value) = reply.body().deserialize::<zbus::zvariant::OwnedValue>() else {
                    continue;
                };
                if let Ok(enabled) = value.downcast_ref::<bool>() {
                    return Some(!enabled);
                }
                if let Ok(factor) = value.downcast_ref::<f64>() {
                    return Some(factor == 0.0);
                }
                if let Ok(text) = value.downcast_ref::<&str>() {
                    return Some(text.trim().parse::<f64>().is_ok_and(|factor| factor == 0.0));
                }
            }
            None
        })
        .unwrap_or(false)
    }
}

#[cfg(windows)]
mod platform {
    use super::{Battery, Network, NO_BATTERY, OFFLINE};
    use windows_sys::Win32::NetworkManagement::IpHelper::{
        GetAdaptersAddresses, GAA_FLAG_INCLUDE_GATEWAYS, IF_TYPE_IEEE80211, IP_ADAPTER_ADDRESSES_LH,
    };
    use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    use windows_sys::Win32::Networking::WinSock::AF_UNSPEC;
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};

    pub fn battery() -> Battery {
        let mut status: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
        if unsafe { GetSystemPowerStatus(&mut status) } == 0 || status.BatteryFlag & 128 != 0 || status.BatteryLifePercent > 100 {
            return NO_BATTERY;
        }
        Battery { level: i32::from(status.BatteryLifePercent), charging: status.BatteryFlag & 8 != 0 }
    }

    pub fn network() -> Network {
        let mut size = 16 * 1024u32;
        let mut buffer = vec![0u64; size as usize / 8 + 1];
        let first = buffer.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
        if unsafe { GetAdaptersAddresses(AF_UNSPEC as u32, GAA_FLAG_INCLUDE_GATEWAYS, std::ptr::null(), first, &mut size) } != 0 {
            return OFFLINE;
        }
        let mut state = OFFLINE;
        let mut adapter = first as *const IP_ADAPTER_ADDRESSES_LH;
        while let Some(current) = unsafe { adapter.as_ref() } {
            if current.OperStatus == IfOperStatusUp && !current.FirstGatewayAddress.is_null() {
                if current.IfType == IF_TYPE_IEEE80211 {
                    return Network { connection: "wireless", level: 4 };
                }
                state = Network { connection: "ethernet", level: 4 };
            }
            adapter = current.Next;
        }
        state
    }

    pub fn reduce_motion() -> bool {
        use windows_sys::Win32::UI::WindowsAndMessaging::{SystemParametersInfoW, SPI_GETCLIENTAREAANIMATION};
        let mut enabled: i32 = 1;
        unsafe { SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &mut enabled as *mut i32 as *mut _, 0) };
        enabled == 0
    }
}

#[cfg(target_os = "android")]
mod platform {
    use super::{Battery, Network};
    use crate::android::system;

    pub fn battery() -> Battery {
        Battery {
            level: system("battery_level").parse().unwrap_or(-1),
            charging: system("battery_charging") == "true",
        }
    }

    pub fn network() -> Network {
        let state: serde_json::Value = serde_json::from_str(&system("network")).unwrap_or_default();
        let connection = match state["connection"].as_str() {
            Some("ethernet") => "ethernet",
            Some("wireless") => "wireless",
            _ => "none",
        };
        Network {
            connection,
            level: state["level"].as_i64().unwrap_or(0) as i32,
        }
    }

    pub fn reduce_motion() -> bool {
        system("reduce_motion") == "true"
    }
}

#[cfg(any(target_os = "macos", test))]
mod darwin {
    use super::{Battery, Network, NO_BATTERY, OFFLINE};

    pub fn parse_battery(output: &str) -> Battery {
        let Some(line) = output.lines().find(|line| line.contains("InternalBattery")) else {
            return NO_BATTERY;
        };
        let Some(percent) = line.split('%').next().and_then(|head| head.rsplit(|c: char| !c.is_ascii_digit()).next()).and_then(|digits| digits.parse().ok()) else {
            return NO_BATTERY;
        };
        let state = line.split(';').nth(1).unwrap_or_default().trim();
        Battery { level: percent, charging: matches!(state, "charging" | "finishing charge") || (state == "charged" && output.contains("AC Power")) }
    }

    pub fn default_interface(route: &str) -> Option<String> {
        route.lines().find_map(|line| line.trim().strip_prefix("interface:")).map(|name| name.trim().to_owned())
    }

    pub fn parse_network(ports: &str, interface: &str) -> Network {
        let mut port = "";
        for line in ports.lines() {
            if let Some(name) = line.strip_prefix("Hardware Port:") {
                port = name.trim();
            } else if line.strip_prefix("Device:").is_some_and(|device| device.trim() == interface) {
                return if port.eq_ignore_ascii_case("wi-fi") || port.eq_ignore_ascii_case("airport") {
                    Network { connection: "wireless", level: 4 }
                } else {
                    Network { connection: "ethernet", level: 4 }
                };
            }
        }
        if interface.is_empty() { OFFLINE } else { Network { connection: "ethernet", level: 4 } }
    }

    #[cfg(target_os = "macos")]
    pub fn run(program: &str, args: &[&str]) -> String {
        std::process::Command::new(program).args(args).output().map(|out| String::from_utf8_lossy(&out.stdout).into_owned()).unwrap_or_default()
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::darwin::*;
    use super::{Battery, Network, NO_BATTERY, OFFLINE};

    pub fn battery() -> Battery {
        let output = run("/usr/bin/pmset", &["-g", "batt"]);
        if output.is_empty() { NO_BATTERY } else { parse_battery(&output) }
    }

    pub fn network() -> Network {
        let Some(interface) = default_interface(&run("/sbin/route", &["-n", "get", "default"])) else {
            return OFFLINE;
        };
        parse_network(&run("/usr/sbin/networksetup", &["-listallhardwareports"]), &interface)
    }

    pub fn reduce_motion() -> bool {
        run("/usr/bin/defaults", &["read", "com.apple.universalaccess", "reduceMotion"]).trim() == "1"
    }
}

#[cfg(target_os = "ios")]
mod platform {
    use super::{Battery, Network, NO_BATTERY, OFFLINE};
    use std::ffi::CStr;

    pub fn battery() -> Battery {
        NO_BATTERY
    }

    pub fn network() -> Network {
        let mut list: *mut libc::ifaddrs = std::ptr::null_mut();
        if unsafe { libc::getifaddrs(&mut list) } != 0 {
            return OFFLINE;
        }
        let mut online = false;
        let mut entry = list;
        while let Some(current) = unsafe { entry.as_ref() } {
            entry = current.ifa_next;
            let flags = current.ifa_flags as libc::c_int;
            if flags & libc::IFF_UP == 0 || flags & libc::IFF_RUNNING == 0 || flags & libc::IFF_LOOPBACK != 0 || !routable(current.ifa_addr) {
                continue;
            }
            let name = unsafe { CStr::from_ptr(current.ifa_name) }.to_bytes();
            online |= name.starts_with(b"en") || name.starts_with(b"pdp_ip");
        }
        unsafe { libc::freeifaddrs(list) };
        if online { Network { connection: "wireless", level: 4 } } else { OFFLINE }
    }

    fn routable(address: *const libc::sockaddr) -> bool {
        let Some(address) = (unsafe { address.as_ref() }) else {
            return false;
        };
        match address.sa_family as libc::c_int {
            libc::AF_INET => true,
            libc::AF_INET6 => {
                let octets = unsafe { (*(address as *const libc::sockaddr as *const libc::sockaddr_in6)).sin6_addr.s6_addr };
                !(octets[0] == 0xfe && octets[1] & 0xc0 == 0x80)
            }
            _ => false,
        }
    }

    pub fn reduce_motion() -> bool {
        false
    }
}

#[cfg(not(any(target_os = "linux", windows, target_os = "android", target_os = "macos", target_os = "ios")))]
mod platform {
    use super::{Battery, Network, NO_BATTERY, OFFLINE};

    pub fn battery() -> Battery {
        NO_BATTERY
    }

    pub fn network() -> Network {
        OFFLINE
    }

    pub fn reduce_motion() -> bool {
        false
    }
}

pub use platform::{battery, network, reduce_motion};

pub struct Output {
    pub kind: String,
    pub name: String,
}

#[cfg(target_os = "android")]
pub fn output() -> Output {
    let state: serde_json::Value = serde_json::from_str(&crate::android::system("output_device")).unwrap_or_default();
    Output {
        kind: state["kind"].as_str().unwrap_or_default().to_owned(),
        name: state["name"].as_str().unwrap_or_default().to_owned(),
    }
}

#[cfg(not(target_os = "android"))]
pub fn output() -> Output {
    use cpal::traits::{DeviceTrait, HostTrait};
    use cpal::{DeviceType, InterfaceType};
    let Some(description) = cpal::default_host()
        .default_output_device()
        .and_then(|device| device.description().ok())
    else {
        return Output { kind: String::new(), name: String::new() };
    };
    let name = description.name().to_owned();
    let kind = match (description.interface_type(), description.device_type()) {
        (InterfaceType::Bluetooth, _) => "earbuds",
        (_, DeviceType::Headphones | DeviceType::Headset) => "headphones",
        (_, DeviceType::Speaker) => "speaker",
        _ => output_kind(&name),
    };
    Output { kind: kind.to_owned(), name }
}

#[cfg_attr(target_os = "android", allow(dead_code))]
fn output_kind(name: &str) -> &'static str {
    let name = name.to_lowercase();
    let matches = |words: &[&str]| words.iter().any(|word| name.contains(word));
    if matches(&["bluetooth", "bluez", "airpods", "buds", "a2dp"]) {
        "earbuds"
    } else if matches(&["headphone", "headset", "auriculares", "casque"]) {
        "headphones"
    } else if matches(&["speaker", "altavo", "haut-parleur"]) {
        "speaker"
    } else {
        ""
    }
}

#[cfg(test)]
mod tests {
    use super::darwin::*;
    use super::output_kind;

    #[test]
    fn parses_pmset_and_network_ports() {
        let batt = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t87%; discharging; 3:20 remaining present: true\n";
        let state = parse_battery(batt);
        assert_eq!((state.level, state.charging), (87, false));
        let batt = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t55%; charging; 1:00 remaining present: true\n";
        assert!(parse_battery(batt).charging);
        assert_eq!(parse_battery("Now drawing from 'AC Power'\n").level, -1);
        assert_eq!(default_interface("   route to: default\n  interface: en0\n").as_deref(), Some("en0"));
        let ports = "Hardware Port: Ethernet\nDevice: en5\n\nHardware Port: Wi-Fi\nDevice: en0\n";
        assert_eq!(parse_network(ports, "en0").connection, "wireless");
        assert_eq!(parse_network(ports, "en5").connection, "ethernet");
    }

    #[test]
    fn classifies_output_names() {
        assert_eq!(output_kind("Headphones (Realtek(R) Audio)"), "headphones");
        assert_eq!(output_kind("Speakers (Realtek(R) Audio)"), "speaker");
        assert_eq!(output_kind("WH-1000XM4 Bluetooth"), "earbuds");
        assert_eq!(output_kind("default"), "");
    }
}
