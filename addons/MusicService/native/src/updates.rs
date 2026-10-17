#[cfg(target_os = "linux")]
mod flatpak {
    use std::collections::HashMap;
    use zbus::blocking::{Connection, MessageIterator};
    use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};
    use zbus::message::Type as MessageType;
    use zbus::MatchRule;

    const DESTINATION: &str = "org.freedesktop.portal.Flatpak";
    const PATH: &str = "/org/freedesktop/portal/Flatpak";
    const MONITOR: &str = "org.freedesktop.portal.Flatpak.UpdateMonitor";
    const STATUS_EMPTY: u32 = 1;
    const STATUS_DONE: u32 = 2;
    const STATUS_FAILED: u32 = 3;
    const SPAWN_LATEST_VERSION: u32 = 2;

    fn number(info: &HashMap<String, OwnedValue>, key: &str) -> u32 {
        info.get(key).and_then(|value| u32::try_from(value).ok()).unwrap_or(0)
    }

    fn text(info: &HashMap<String, OwnedValue>, key: &str) -> String {
        info.get(key).and_then(|value| String::try_from(value.clone()).ok()).unwrap_or_default()
    }

    pub fn update() -> Result<(), String> {
        let connection = Connection::session().map_err(|error| error.to_string())?;
        let options: HashMap<&str, Value> = HashMap::new();
        let monitor: OwnedObjectPath = connection
            .call_method(Some(DESTINATION), PATH, Some(DESTINATION), "CreateUpdateMonitor", &(options,))
            .and_then(|reply| reply.body().deserialize().map_err(Into::into))
            .map_err(|error| format!("the Flatpak portal isn't available ({error})"))?;
        let rule = MatchRule::builder()
            .msg_type(MessageType::Signal)
            .interface(MONITOR)
            .and_then(|rule| rule.member("Progress"))
            .and_then(|rule| rule.path(monitor.clone()))
            .map_err(|error| error.to_string())?
            .build();
        let progress = MessageIterator::for_match_rule(rule, &connection, None).map_err(|error| error.to_string())?;
        let options: HashMap<&str, Value> = HashMap::new();
        connection
            .call_method(Some(DESTINATION), monitor.as_str(), Some(MONITOR), "Update", &("", options))
            .map_err(|error| error.to_string())?;
        for message in progress {
            let message = message.map_err(|error| error.to_string())?;
            let Ok((info,)) = message.body().deserialize::<(HashMap<String, OwnedValue>,)>() else {
                continue;
            };
            match number(&info, "status") {
                STATUS_DONE => return Ok(()),
                STATUS_EMPTY => return Err("Flathub doesn't have the new version for you yet".to_owned()),
                STATUS_FAILED => {
                    let reason = text(&info, "error_message");
                    return Err(if reason.is_empty() { text(&info, "error") } else { reason });
                }
                _ => {}
            }
        }
        Err("the update stopped without finishing".to_owned())
    }

    pub fn relaunch() -> bool {
        let Ok(connection) = Connection::session() else {
            return false;
        };
        let mut argv: Vec<Vec<u8>> = vec![b"nari\0".to_vec()];
        argv.extend(std::env::args().skip(1).map(|argument| [argument.into_bytes(), vec![0]].concat()));
        let fds: HashMap<u32, zbus::zvariant::Fd<'static>> = HashMap::new();
        let envs: HashMap<&str, &str> = HashMap::new();
        let options: HashMap<&str, Value> = HashMap::new();
        connection
            .call_method(Some(DESTINATION), PATH, Some(DESTINATION), "Spawn", &(b"/\0".to_vec(), argv, fds, envs, SPAWN_LATEST_VERSION, options))
            .is_ok()
    }
}

pub fn update_flatpak() -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        flatpak::update()
    }
    #[cfg(not(target_os = "linux"))]
    {
        Err("Flatpak updates only work on Linux".to_owned())
    }
}

pub fn relaunch_flatpak() -> bool {
    #[cfg(target_os = "linux")]
    {
        flatpak::relaunch()
    }
    #[cfg(not(target_os = "linux"))]
    {
        false
    }
}

pub fn install_apk(path: &str) -> String {
    #[cfg(target_os = "android")]
    {
        crate::android::system(&format!("install_apk:{path}"))
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = path;
        String::new()
    }
}
