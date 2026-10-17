use mlua::{Function, Lua, MultiValue, Table, Value};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

pub const NETWORK: &str = "network";
pub const CLIPBOARD: &str = "clipboard";
pub const ALL: &str = "all";

#[derive(Debug)]
pub struct Policy {
    pub all: bool,
    pub network: bool,
    pub clipboard: bool,
    user_root: PathBuf,
    read_roots: Vec<PathBuf>,
    write_roots: Vec<PathBuf>,
}

pub struct Roots<'a> {
    pub user: &'a Path,
    pub folder: &'a Path,
    pub data: &'a Path,
    pub downloads: &'a Path,
}

impl Policy {
    pub fn new(permissions: &[String], roots: Roots) -> Self {
        let has = |wanted: &str| permissions.iter().any(|permission| permission == wanted);
        let all = has(ALL);
        let data = resolve(roots.data);
        Self {
            all,
            network: all || has(NETWORK),
            clipboard: all || has(CLIPBOARD),
            user_root: roots.user.to_path_buf(),
            read_roots: vec![resolve(roots.folder), data.clone(), resolve(roots.downloads)],
            write_roots: vec![data],
        }
    }

    #[cfg(test)]
    pub fn unrestricted() -> Self {
        Self {
            all: true,
            network: true,
            clipboard: true,
            user_root: PathBuf::new(),
            read_roots: Vec::new(),
            write_roots: Vec::new(),
        }
    }

    pub fn require(&self, granted: bool, permission: &str, what: &str) -> mlua::Result<()> {
        if granted {
            return Ok(());
        }
        Err(mlua::Error::runtime(format!(
            "{what} needs the \"{permission}\" permission: add it to \"permissions\" in manifest.json"
        )))
    }

    pub fn require_network(&self, what: &str) -> mlua::Result<()> {
        self.require(self.network, NETWORK, what)
    }

    pub fn os_path(&self, path: &str) -> Option<PathBuf> {
        if let Some(rest) = path.strip_prefix("user://") {
            return Some(self.user_root.join(rest));
        }
        let path = path.strip_prefix("file://").unwrap_or(path);
        let candidate = Path::new(path);
        candidate.is_absolute().then(|| candidate.to_path_buf())
    }

    pub fn check(&self, path: &str, writes: bool) -> Result<PathBuf, String> {
        if self.all {
            return Ok(PathBuf::from(path));
        }
        if path.starts_with("res://") {
            return if writes { Err(denied(path, writes)) } else { Ok(PathBuf::from(path)) };
        }
        let resolved = self.os_path(path).map(|path| resolve(&path)).ok_or_else(|| denied(path, writes))?;
        let roots = if writes { &self.write_roots } else { &self.read_roots };
        if roots.iter().any(|root| resolved.starts_with(root)) {
            Ok(resolved)
        } else {
            Err(denied(path, writes))
        }
    }
}

fn denied(path: &str, writes: bool) -> String {
    let action = if writes { "write to" } else { "read" };
    format!("sandboxed plugins can't {action} '{path}': only their own folder, data folder and downloads are open to them")
}

pub fn looks_like_path(text: &str) -> bool {
    text.contains('/') || text.contains('\\') || text.starts_with("user:") || text.starts_with("res:") || text.starts_with("file:")
}

fn resolve(path: &Path) -> PathBuf {
    let mut clean = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                clean.pop();
            }
            Component::CurDir => {}
            other => clean.push(other.as_os_str()),
        }
    }
    let mut existing = clean.clone();
    let mut rest = Vec::new();
    while !existing.exists() {
        match (existing.file_name().map(|name| name.to_owned()), existing.parent().map(Path::to_path_buf)) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                existing = parent;
            }
            _ => return clean,
        }
    }
    let mut real = std::fs::canonicalize(&existing).unwrap_or(existing);
    for name in rest.into_iter().rev() {
        real.push(name);
    }
    real
}

pub fn restrict_lua(lua: &Lua, policy: &Arc<Policy>) -> mlua::Result<()> {
    if policy.all {
        return Ok(());
    }
    let globals = lua.globals();
    let io: Table = globals.get("io")?;
    let os: Table = globals.get("os")?;
    let open: Function = io.get("open")?;
    let remove: Function = os.get("remove")?;
    let rename: Function = os.get("rename")?;
    let load: Function = globals.get("load")?;

    let safe_io = lua.create_table()?;
    let guard = policy.clone();
    safe_io.set(
        "open",
        lua.create_function(move |_, (path, mode): (String, Option<String>)| {
            let writes = mode.as_deref().is_some_and(|mode| mode.contains(['w', 'a', '+']));
            let resolved = guard.check(&path, writes).map_err(mlua::Error::runtime)?;
            open.call::<MultiValue>((resolved.to_string_lossy().into_owned(), mode))
        })?,
    )?;
    safe_io.set("type", io.get::<Function>("type")?)?;
    safe_io.set("write", io.get::<Function>("write")?)?;
    globals.set("io", safe_io)?;

    let guard = policy.clone();
    os.set(
        "remove",
        lua.create_function(move |_, path: String| {
            let resolved = guard.check(&path, true).map_err(mlua::Error::runtime)?;
            remove.call::<MultiValue>(resolved.to_string_lossy().into_owned())
        })?,
    )?;
    let guard = policy.clone();
    os.set(
        "rename",
        lua.create_function(move |_, (from, to): (String, String)| {
            let from = guard.check(&from, true).map_err(mlua::Error::runtime)?;
            let to = guard.check(&to, true).map_err(mlua::Error::runtime)?;
            rename.call::<MultiValue>((from.to_string_lossy().into_owned(), to.to_string_lossy().into_owned()))
        })?,
    )?;
    for name in ["execute", "getenv", "tmpname", "setlocale"] {
        os.set(name, Value::Nil)?;
    }

    globals.set(
        "load",
        lua.create_function(move |lua, args: MultiValue| {
            let mut args: Vec<Value> = args.into_iter().collect();
            args.resize(args.len().max(3), Value::Nil);
            args[2] = Value::String(lua.create_string("t")?);
            load.call::<MultiValue>(MultiValue::from_iter(args))
        })?,
    )?;
    globals.set("loadfile", Value::Nil)?;
    globals.set("dofile", Value::Nil)?;

    let package: Table = globals.get("package")?;
    package.set("loadlib", Value::Nil)?;
    package.set("cpath", "")?;
    package.set("path", "")?;
    let searchers: Table = package.get("searchers")?;
    let preload: Function = searchers.get(1)?;
    let kept = lua.create_table()?;
    kept.push(preload)?;
    package.set("searchers", kept)?;
    Ok(())
}

pub fn permissions_global(lua: &Lua, policy: &Policy) -> mlua::Result<()> {
    let granted = lua.create_table()?;
    granted.set(NETWORK, policy.network)?;
    granted.set(CLIPBOARD, policy.clipboard)?;
    granted.set(ALL, policy.all)?;
    lua.globals().set("__nari_permissions", granted)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(root: &Path, permissions: &[&str]) -> Policy {
        let permissions: Vec<String> = permissions.iter().map(|permission| permission.to_string()).collect();
        Policy::new(
            &permissions,
            Roots {
                user: root,
                folder: &root.join("plugins/demo"),
                data: &root.join("plugin_data/demo"),
                downloads: &root.join("downloads/demo"),
            },
        )
    }

    #[test]
    fn paths_stay_inside_the_plugin_folders() {
        let root = std::env::temp_dir().join(format!("nari-sandbox-{}", std::process::id()));
        std::fs::create_dir_all(root.join("plugins/demo")).unwrap();
        std::fs::create_dir_all(root.join("plugin_data")).unwrap();
        let rules = policy(&root, &[]);
        assert!(rules.check("user://plugins/demo/main.lua", false).is_ok());
        assert!(rules.check("user://plugins/demo/main.lua", true).is_err());
        assert!(rules.check("user://plugin_data/demo/covers/a.jpg", true).is_ok());
        assert!(rules.check("user://plugin_data/demo/../demo.private", false).is_err());
        assert!(rules.check("user://plugin_data/other/x", false).is_err());
        assert!(rules.check("user://settings.cfg", false).is_err());
        assert!(rules.check("/etc/passwd", false).is_err());
        assert!(rules.check("relative.txt", false).is_err());
        assert!(rules.check("res://assets/icons/play.svg", false).is_ok());
        assert!(rules.check("res://anything", true).is_err());
        assert!(rules.check(&format!("{}/downloads/demo/song.mp3", root.display()), false).is_ok());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/etc", root.join("plugins/demo/escape")).unwrap();
            assert!(rules.check("user://plugins/demo/escape/passwd", false).is_err());
        }
        assert!(policy(&root, &["all"]).check("/etc/passwd", true).is_ok());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn lua_loses_the_dangerous_parts_of_its_standard_library() {
        let root = std::env::temp_dir().join(format!("nari-sandbox-lua-{}", std::process::id()));
        std::fs::create_dir_all(root.join("plugin_data/demo")).unwrap();
        let lua = Lua::new();
        restrict_lua(&lua, &Arc::new(policy(&root, &[]))).unwrap();
        let data = root.join("plugin_data/demo/note.txt").display().to_string();
        let script = format!(
            r#"
            local file = assert(io.open("{data}", "w"))
            file:write("hi")
            file:close()
            local read = io.open("{data}", "r"):read("a")
            local outside = pcall(io.open, "/etc/hostname", "r")
            local bytecode = load(string.dump(function() return 1 end))
            local chunk = load("return x", "=chunk")
            x = 7
            assert(chunk() == 7, "a loaded chunk keeps the globals")
            assert(load("return y", "=chunk", "t", {{ y = 3 }})() == 3, "an env given to load is kept")
            return read, outside, os.execute == nil, io.popen == nil, bytecode == nil, require == nil, loadfile == nil, os.time() > 0
            "#
        );
        let (read, outside, no_execute, no_popen, no_bytecode, no_require, no_loadfile, time): (String, bool, bool, bool, bool, bool, bool, bool) =
            lua.load(script).eval().unwrap();
        assert_eq!(read, "hi");
        assert!(!outside && no_execute && no_popen && no_bytecode && !no_require && no_loadfile && time);
        std::fs::remove_dir_all(root).unwrap();
    }
}
