use godot::builtin::VariantType;
use godot::classes::{ClassDb, Engine, Node, Object, ProjectSettings, ResourceLoader, SceneTree, Script};
use godot::prelude::*;
use mlua::{AnyUserData, Function, Lua, MetaMethod, MultiValue, Table, UserData, UserDataMethods, Value};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Weak;
use std::sync::Arc;

use super::sandbox::{looks_like_path, Policy, CLIPBOARD, NETWORK};

const BUILTINS: [&str; 5] = ["Vector2", "Vector2i", "Color", "Rect2", "Dictionary"];
const TYPE_KEY: &str = "__nari_type";
const PRUNE_EVERY: usize = 64;

pub struct Tracker {
    id: String,
    alive: Weak<()>,
    nodes: RefCell<Vec<InstanceId>>,
    connections: RefCell<Vec<(InstanceId, StringName, Callable)>>,
    policy: Option<Arc<Policy>>,
    locked: Cell<bool>,
}

pub fn install(lua: &Lua, id: &str, alive: Weak<()>, policy: Arc<Policy>) -> mlua::Result<()> {
    lua.set_app_data(Tracker {
        id: id.to_owned(),
        alive,
        nodes: RefCell::new(Vec::new()),
        connections: RefCell::new(Vec::new()),
        policy: (!policy.all).then_some(policy),
        locked: Cell::new(false),
    });
    let globals = lua.globals();
    for name in BUILTINS {
        let meta = lua.create_table()?;
        meta.set(TYPE_KEY, name)?;
        meta.set("__name", name)?;
        lua.set_named_registry_value(&format!("nari_{name}"), &meta)?;
    }
    globals.set(
        "Vector2",
        lua.create_function(|lua, (x, y): (Option<f64>, Option<f64>)| {
            builtin(lua, "Vector2", &[("x", Value::Number(x.unwrap_or(0.0))), ("y", Value::Number(y.unwrap_or(0.0)))])
        })?,
    )?;
    globals.set(
        "Vector2i",
        lua.create_function(|lua, (x, y): (Option<i64>, Option<i64>)| {
            builtin(lua, "Vector2i", &[("x", Value::Integer(x.unwrap_or(0))), ("y", Value::Integer(y.unwrap_or(0)))])
        })?,
    )?;
    globals.set(
        "Color",
        lua.create_function(|lua, args: MultiValue| {
            let args: Vec<Value> = args.into_iter().collect();
            let color = match args.first() {
                Some(Value::String(html)) => Color::from_html(html.to_str()?.as_ref())
                    .ok_or_else(|| mlua::Error::runtime("Color() needs a valid HTML color like \"#ff8800\""))?,
                _ => {
                    let part = |index: usize, fallback: f64| args.get(index).and_then(Value::as_f64).unwrap_or(fallback) as f32;
                    Color::from_rgba(part(0, 0.0), part(1, 0.0), part(2, 0.0), part(3, 1.0))
                }
            };
            to_lua(lua, &color.to_variant())
        })?,
    )?;
    globals.set(
        "Rect2",
        lua.create_function(|lua, (x, y, width, height): (Option<f64>, Option<f64>, Option<f64>, Option<f64>)| {
            let rect = Rect2::new(
                Vector2::new(x.unwrap_or(0.0) as f32, y.unwrap_or(0.0) as f32),
                Vector2::new(width.unwrap_or(0.0) as f32, height.unwrap_or(0.0) as f32),
            );
            to_lua(lua, &rect.to_variant())
        })?,
    )?;
    globals.set(
        "Dictionary",
        lua.create_function(|lua, table: Option<Table>| {
            let table = match table {
                Some(table) => table,
                None => lua.create_table()?,
            };
            table.set_metatable(Some(lua.named_registry_value::<Table>("nari_Dictionary")?))?;
            Ok(table)
        })?,
    )?;
    globals.set(
        "__nari_is_object",
        lua.create_function(|_, value: Value| {
            Ok(matches!(value, Value::UserData(data) if data.is::<GodotObject>()))
        })?,
    )?;
    let meta = lua.create_table()?;
    meta.set(
        "__index",
        lua.create_function(|lua, (globals, name): (Table, String)| {
            let value = resolve(lua, &name)?;
            if !value.is_nil() {
                globals.raw_set(name, value.clone())?;
            }
            Ok(value)
        })?,
    )?;
    globals.set_metatable(Some(meta))?;
    Ok(())
}

pub fn lock(lua: &Lua) {
    let Some(tracker) = lua.app_data_ref::<Tracker>() else {
        return;
    };
    tracker.locked.set(true);
    let globals = lua.globals();
    let cached: Vec<Value> = globals
        .pairs::<Value, Value>()
        .filter_map(Result::ok)
        .filter(|(_, value)| matches!(value, Value::UserData(data) if data.is::<GodotObject>() || data.is::<GodotClass>()))
        .map(|(key, _)| key)
        .collect();
    for key in cached {
        let _ = globals.raw_set(key, Value::Nil);
    }
}

fn sandbox(lua: &Lua) -> Option<Arc<Policy>> {
    let tracker = lua.app_data_ref::<Tracker>()?;
    if tracker.locked.get() {
        tracker.policy.clone()
    } else {
        None
    }
}

pub fn cleanup(lua: &Lua) {
    let Some(tracker) = lua.remove_app_data::<Tracker>() else {
        return;
    };
    for (object, signal, callable) in tracker.connections.take() {
        if let Ok(mut object) = Gd::<Object>::try_from_instance_id(object) {
            if object.is_connected(&signal, &callable) {
                object.disconnect(&signal, &callable);
            }
        }
    }
    for node in tracker.nodes.take() {
        if let Ok(mut node) = Gd::<Node>::try_from_instance_id(node) {
            node.queue_free();
        }
    }
}

fn tracker(lua: &Lua) -> mlua::Result<mlua::AppDataRef<'_, Tracker>> {
    lua.app_data_ref::<Tracker>()
        .ok_or_else(|| mlua::Error::runtime("the plugin was turned off"))
}

fn builtin(lua: &Lua, kind: &str, fields: &[(&str, Value)]) -> mlua::Result<Value> {
    let table = lua.create_table()?;
    for (key, value) in fields {
        table.set(*key, value.clone())?;
    }
    table.set_metatable(Some(lua.named_registry_value::<Table>(&format!("nari_{kind}"))?))?;
    Ok(Value::Table(table))
}

fn tree_root() -> Option<Gd<Node>> {
    Engine::singleton()
        .get_main_loop()?
        .try_cast::<SceneTree>()
        .ok()?
        .get_root()
        .upcast::<Node>()
        .into()
}

fn resolve(lua: &Lua, name: &str) -> mlua::Result<Value> {
    if let Some(policy) = sandbox(lua) {
        rules::global(&policy, name)?;
    }
    let settings = ProjectSettings::singleton();
    if settings.has_setting(&format!("autoload/{name}")) {
        if let Some(node) = tree_root().and_then(|root| root.get_node_or_null(name)) {
            return object(lua, node.upcast());
        }
    }
    let engine = Engine::singleton();
    if engine.has_singleton(name) {
        if let Some(singleton) = engine.get_singleton(name) {
            return object(lua, singleton);
        }
    }
    let trusted = sandbox(lua).is_none();
    if let Some(path) = global_class_path(name) {
        if let Some(script) = ResourceLoader::singleton().load(&path).and_then(|resource| resource.try_cast::<Script>().ok()) {
            return lua.create_userdata(GodotClass { name: name.to_owned(), script: Some(script), trusted }).map(Value::UserData);
        }
    }
    if ClassDb::singleton().class_exists(name) {
        return lua
            .create_userdata(GodotClass { name: name.to_owned(), script: None, trusted })
            .map(Value::UserData);
    }
    Ok(Value::Nil)
}

fn global_class_path(name: &str) -> Option<String> {
    thread_local! {
        static CLASSES: RefCell<Option<HashMap<String, String>>> = const { RefCell::new(None) };
    }
    CLASSES.with(|classes| {
        let mut classes = classes.borrow_mut();
        let known = classes.get_or_insert_with(|| {
            ProjectSettings::singleton()
                .get_global_class_list()
                .iter_shared()
                .filter_map(|entry| Some((entry.get("class")?.to_string(), entry.get("path")?.to_string())))
                .collect()
        });
        known.get(name).cloned()
    })
}

pub fn object(lua: &Lua, object: Gd<Object>) -> mlua::Result<Value> {
    let trusted = sandbox(lua).is_none();
    if let Ok(script) = object.clone().try_cast::<Script>() {
        let name = script.get_global_name().to_string();
        return lua.create_userdata(GodotClass { name, script: Some(script), trusted }).map(Value::UserData);
    }
    lua.create_userdata(GodotObject { object, trusted, identity: RefCell::new(None) }).map(Value::UserData)
}

fn call(lua: &Lua, mut target: Gd<Object>, method: &str, args: Vec<Value>, guard: Option<&Policy>) -> mlua::Result<Value> {
    let arguments = args
        .into_iter()
        .map(|value| to_variant(lua, value))
        .collect::<mlua::Result<Vec<_>>>()?;
    if let Some(policy) = guard {
        rules::arguments(policy, &target.get_class().to_string(), method, &arguments)?;
        rules::call(&target, method, &arguments)?;
    }
    let result = target
        .try_call(method, &arguments)
        .map_err(|error| mlua::Error::runtime(format!("{method}(): {error}")))?;
    track(lua, &result);
    to_lua(lua, &result)
}

fn track(lua: &Lua, value: &Variant) {
    let Ok(node) = value.try_to::<Gd<Node>>() else {
        return;
    };
    if node.get_parent().is_none() && !node.is_inside_tree() {
        if let Ok(tracker) = tracker(lua) {
            let mut nodes = tracker.nodes.borrow_mut();
            if nodes.len() % PRUNE_EVERY == PRUNE_EVERY - 1 {
                nodes.retain(|node| Gd::<Node>::try_from_instance_id(*node).is_ok());
            }
            nodes.push(node.instance_id());
        }
    }
}

fn method(lua: &Lua, target: InstanceId, name: String, guard: Option<Arc<Policy>>) -> mlua::Result<Value> {
    lua.create_function(move |lua, args: MultiValue| {
        let mut args: Vec<Value> = args.into_iter().collect();
        if let Some(Value::UserData(first)) = args.first() {
            let own = first.borrow::<GodotObject>().is_ok_and(|this| this.object.instance_id() == target)
                || first.borrow::<GodotClass>().is_ok_and(|this| this.object().is_some_and(|object| object.instance_id() == target));
            if own {
                args.remove(0);
            }
        }
        let object = Gd::<Object>::try_from_instance_id(target)
            .map_err(|_| mlua::Error::runtime(format!("{name}(): the object was freed")))?;
        call(lua, object, &name, args, guard.as_deref())
    })
    .map(Value::Function)
}

fn script_constant(script: &Gd<Script>, key: &str) -> Option<Variant> {
    let mut current = Some(script.clone());
    while let Some(script) = current {
        if let Some(value) = script.get_script_constant_map().get(key) {
            return Some(value);
        }
        current = script.get_base_script();
    }
    None
}

pub struct GodotObject {
    pub object: Gd<Object>,
    trusted: bool,
    identity: RefCell<Option<std::rc::Rc<rules::Identity>>>,
}

impl GodotObject {
    fn alive(&self) -> mlua::Result<Gd<Object>> {
        if self.object.is_instance_valid() {
            Ok(self.object.clone())
        } else {
            Err(mlua::Error::runtime("the Godot object was freed"))
        }
    }

    fn guard(&self, lua: &Lua) -> Option<Arc<Policy>> {
        if self.trusted {
            None
        } else {
            sandbox(lua)
        }
    }

    fn identity(&self, object: &Gd<Object>) -> std::rc::Rc<rules::Identity> {
        self.identity.borrow_mut().get_or_insert_with(|| std::rc::Rc::new(rules::Identity::of(object))).clone()
    }
}

impl UserData for GodotObject {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_meta_method(MetaMethod::Index, |lua, this, key: String| {
            let object = this.alive()?;
            let guard = this.guard(lua);
            if let Some(policy) = guard.as_deref() {
                rules::member(policy, &this.identity(&object), &object, &key)?;
            }
            if object.has_method(&key) {
                return method(lua, object.instance_id(), key, guard);
            }
            if object.has_signal(&key) {
                return lua
                    .create_userdata(GodotSignal { target: object.instance_id(), name: StringName::from(&key) })
                    .map(Value::UserData);
            }
            let value = object.get(&key);
            if value.is_nil() {
                if let Some(constant) = object.get_script().and_then(|script| script_constant(&script, &key)) {
                    return to_lua(lua, &constant);
                }
            }
            to_lua(lua, &value)
        });
        methods.add_meta_method(MetaMethod::NewIndex, |lua, this, (key, value): (String, Value)| {
            let value = to_variant(lua, value)?;
            let mut object = this.alive()?;
            if let Some(policy) = this.guard(lua) {
                rules::member(&policy, &this.identity(&object), &object, &key)?;
                rules::assignment(&object, &key)?;
            }
            let current = object.get(&key);
            if current.is_nil() || !compatible(current.get_type(), value.get_type()) {
                let declared = object
                    .get_property_list()
                    .iter_shared()
                    .find(|property| property.get("name").is_some_and(|name| name.to_string() == key))
                    .and_then(|property| property.get("type"))
                    .map(|kind| VariantType::from_sys(kind.to::<i64>() as _));
                match declared {
                    None => return Err(mlua::Error::runtime(format!("{} has no property '{key}'", object.get_class()))),
                    Some(VariantType::NIL) => {}
                    Some(kind) if !compatible(kind, value.get_type()) => {
                        return Err(mlua::Error::runtime(format!(
                            "'{key}' of {} takes a {}, not a {}",
                            object.get_class(),
                            type_name(kind),
                            type_name(value.get_type())
                        )))
                    }
                    Some(_) => {}
                }
            }
            object.set(&key, &value);
            Ok(())
        });
        methods.add_meta_method(MetaMethod::Eq, |_, this, other: AnyUserData| {
            Ok(other
                .borrow::<GodotObject>()
                .is_ok_and(|other| other.object.instance_id() == this.object.instance_id()))
        });
        methods.add_meta_method(MetaMethod::ToString, |_, this, ()| {
            Ok(match this.alive() {
                Ok(object) => format!("{}#{}", object.get_class(), object.instance_id()),
                Err(_) => "<freed object>".to_owned(),
            })
        });
    }
}

fn compatible(expected: VariantType, given: VariantType) -> bool {
    let numeric = |kind: VariantType| matches!(kind, VariantType::INT | VariantType::FLOAT | VariantType::BOOL);
    let text = |kind: VariantType| matches!(kind, VariantType::STRING | VariantType::STRING_NAME | VariantType::NODE_PATH);
    let list = |kind: VariantType| kind == VariantType::ARRAY || format!("{kind:?}").starts_with("PACKED_");
    expected == given
        || text(expected)
        || numeric(expected) && numeric(given)
        || list(expected) && list(given)
        || expected == VariantType::COLOR && text(given)
        || expected == VariantType::OBJECT && given == VariantType::NIL
}

fn type_name(kind: VariantType) -> String {
    match kind {
        VariantType::NIL => "nil".to_owned(),
        VariantType::BOOL => "boolean".to_owned(),
        VariantType::INT | VariantType::FLOAT => "number".to_owned(),
        VariantType::STRING | VariantType::STRING_NAME => "string".to_owned(),
        VariantType::ARRAY => "list".to_owned(),
        VariantType::DICTIONARY => "table".to_owned(),
        VariantType::CALLABLE => "function".to_owned(),
        other => format!("{other:?}").replace('_', " ").to_lowercase().replace("vector2", "Vector2").replace("color", "Color"),
    }
}

pub struct GodotClass {
    name: String,
    script: Option<Gd<Script>>,
    trusted: bool,
}

impl GodotClass {
    fn object(&self) -> Option<Gd<Object>> {
        self.script.clone().map(|script| script.upcast())
    }
}

impl UserData for GodotClass {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_meta_method(MetaMethod::Index, |lua, this, key: String| {
            let guard = if this.trusted { None } else { sandbox(lua) };
            if let Some(policy) = guard.as_deref() {
                rules::class(policy, &this.name, this.script.is_some(), &key)?;
            }
            let Some(script) = this.script.clone() else {
                if key == "new" {
                    let name = this.name.clone();
                    return lua
                        .create_function(move |lua, _: MultiValue| {
                            let created = ClassDb::singleton().instantiate(&name);
                            track(lua, &created);
                            to_lua(lua, &created)
                        })
                        .map(Value::Function);
                }
                let classes = ClassDb::singleton();
                if classes.class_has_integer_constant(&this.name, &key) {
                    return Ok(Value::Integer(classes.class_get_integer_constant(&this.name, &key)));
                }
                if classes.class_has_method(&this.name, &key) {
                    let name = this.name.clone();
                    return lua
                        .create_function(move |lua, args: MultiValue| {
                            let mut args: Vec<Value> = args.into_iter().collect();
                            if matches!(args.first(), Some(Value::UserData(first)) if first.borrow::<GodotClass>().is_ok_and(|class| class.name == name)) {
                                args.remove(0);
                            }
                            let arguments = args
                                .into_iter()
                                .map(|value| to_variant(lua, value))
                                .collect::<mlua::Result<Vec<_>>>()?;
                            if let Some(policy) = guard.as_deref() {
                                rules::arguments(policy, &name, &key, &arguments)?;
                            }
                            let result = ClassDb::singleton().class_call_static(&name, &key, &arguments);
                            track(lua, &result);
                            to_lua(lua, &result)
                        })
                        .map(Value::Function);
                }
                return Ok(Value::Nil);
            };
            if let Some(constant) = script_constant(&script, &key) {
                return to_lua(lua, &constant);
            }
            let object: Gd<Object> = script.clone().upcast();
            let static_method = script
                .get_script_method_list()
                .iter_shared()
                .any(|entry| entry.get("name").is_some_and(|name| name.to_string() == key));
            if key == "new" || static_method || object.has_method(&key) {
                return method(lua, object.instance_id(), key, guard);
            }
            to_lua(lua, &object.get(&key))
        });
        methods.add_meta_method(MetaMethod::Eq, |_, this, other: AnyUserData| {
            Ok(other.borrow::<GodotClass>().is_ok_and(|other| other.name == this.name))
        });
        methods.add_meta_method(MetaMethod::ToString, |_, this, ()| Ok(format!("<class {}>", this.name)));
    }
}

pub struct GodotSignal {
    target: InstanceId,
    name: StringName,
}

impl UserData for GodotSignal {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("connect", |lua, this, handler: Function| {
            let mut object = Gd::<Object>::try_from_instance_id(this.target)
                .map_err(|_| mlua::Error::runtime("the Godot object was freed"))?;
            let callable = callable(lua, handler)?;
            object.connect(&this.name, &callable);
            {
                let tracker = tracker(lua)?;
                let mut connections = tracker.connections.borrow_mut();
                if connections.len() % PRUNE_EVERY == PRUNE_EVERY - 1 {
                    connections.retain(|(target, _, _)| Gd::<Object>::try_from_instance_id(*target).is_ok());
                }
                connections.push((this.target, this.name.clone(), callable.clone()));
            }
            let (target, name) = (this.target, this.name.clone());
            lua.create_function(move |_, ()| {
                if let Ok(mut object) = Gd::<Object>::try_from_instance_id(target) {
                    if object.is_connected(&name, &callable) {
                        object.disconnect(&name, &callable);
                    }
                }
                Ok(())
            })
        });
        methods.add_method("emit", |lua, this, args: MultiValue| {
            let mut object = Gd::<Object>::try_from_instance_id(this.target)
                .map_err(|_| mlua::Error::runtime("the Godot object was freed"))?;
            let arguments = args
                .into_iter()
                .map(|value| to_variant(lua, value))
                .collect::<mlua::Result<Vec<_>>>()?;
            object.emit_signal(&this.name, &arguments);
            Ok(())
        });
    }
}

pub struct GodotVariant(Variant);

impl UserData for GodotVariant {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_meta_method(MetaMethod::ToString, |_, this, ()| Ok(this.0.to_string()));
    }
}

fn callable(lua: &Lua, handler: Function) -> mlua::Result<Callable> {
    let tracker = tracker(lua)?;
    let alive = tracker.alive.clone();
    let id = tracker.id.clone();
    let weak = lua.weak();
    Ok(Callable::from_fn(format!("plugin {id}"), move |args: &[&Variant]| {
        if alive.upgrade().is_none() {
            return Variant::nil();
        }
        let Some(lua) = weak.try_upgrade() else {
            return Variant::nil();
        };
        super::runtime::guarded(&lua, &id, || {
            let args = args.iter().map(|arg| to_lua(&lua, arg)).collect::<mlua::Result<Vec<_>>>()?;
            let value = handler.call::<Value>(MultiValue::from_iter(args))?;
            to_variant(&lua, value)
        })
        .unwrap_or_else(Variant::nil)
    }))
}

pub fn to_lua(lua: &Lua, variant: &Variant) -> mlua::Result<Value> {
    Ok(match variant.get_type() {
        VariantType::NIL => Value::Nil,
        VariantType::BOOL => Value::Boolean(variant.to()),
        VariantType::INT => Value::Integer(variant.to()),
        VariantType::FLOAT => Value::Number(variant.to()),
        VariantType::STRING | VariantType::STRING_NAME | VariantType::NODE_PATH => {
            Value::String(lua.create_string(variant.to_string())?)
        }
        VariantType::VECTOR2 => {
            let vector: Vector2 = variant.to();
            builtin(lua, "Vector2", &[("x", Value::Number(vector.x.into())), ("y", Value::Number(vector.y.into()))])?
        }
        VariantType::VECTOR2I => {
            let vector: Vector2i = variant.to();
            builtin(lua, "Vector2i", &[("x", Value::Integer(vector.x.into())), ("y", Value::Integer(vector.y.into()))])?
        }
        VariantType::COLOR => {
            let color: Color = variant.to();
            builtin(
                lua,
                "Color",
                &[
                    ("r", Value::Number(color.r.into())),
                    ("g", Value::Number(color.g.into())),
                    ("b", Value::Number(color.b.into())),
                    ("a", Value::Number(color.a.into())),
                ],
            )?
        }
        VariantType::RECT2 => {
            let rect: Rect2 = variant.to();
            builtin(
                lua,
                "Rect2",
                &[
                    ("position", to_lua(lua, &rect.position.to_variant())?),
                    ("size", to_lua(lua, &rect.size.to_variant())?),
                ],
            )?
        }
        VariantType::ARRAY => {
            let table = lua.create_table()?;
            for item in variant.to::<AnyArray>().iter_shared() {
                table.push(to_lua(lua, &item)?)?;
            }
            Value::Table(table)
        }
        VariantType::DICTIONARY => {
            let table = lua.create_table()?;
            for (key, value) in variant.to::<AnyDictionary>().iter_shared() {
                table.set(to_lua(lua, &key)?, to_lua(lua, &value)?)?;
            }
            table.set_metatable(Some(lua.named_registry_value::<Table>("nari_Dictionary")?))?;
            Value::Table(table)
        }
        VariantType::PACKED_STRING_ARRAY => sequence(lua, variant.to::<PackedStringArray>().as_slice().iter().map(|item| Value::String(lua.create_string(item.to_string()).unwrap())))?,
        VariantType::PACKED_INT32_ARRAY => sequence(lua, variant.to::<PackedInt32Array>().as_slice().iter().map(|item| Value::Integer((*item).into())))?,
        VariantType::PACKED_INT64_ARRAY => sequence(lua, variant.to::<PackedInt64Array>().as_slice().iter().map(|item| Value::Integer(*item)))?,
        VariantType::PACKED_FLOAT32_ARRAY => sequence(lua, variant.to::<PackedFloat32Array>().as_slice().iter().map(|item| Value::Number((*item).into())))?,
        VariantType::PACKED_FLOAT64_ARRAY => sequence(lua, variant.to::<PackedFloat64Array>().as_slice().iter().map(|item| Value::Number(*item)))?,
        VariantType::PACKED_BYTE_ARRAY => sequence(lua, variant.to::<PackedByteArray>().as_slice().iter().map(|item| Value::Integer((*item).into())))?,
        VariantType::OBJECT => match variant.try_to::<Option<Gd<Object>>>() {
            Ok(Some(target)) if target.is_instance_valid() => object(lua, target)?,
            _ => Value::Nil,
        },
        VariantType::CALLABLE => {
            let callable: Callable = variant.to();
            let guard = sandbox(lua);
            let function = lua.create_function(move |lua, args: MultiValue| {
                if !callable.is_valid() {
                    return Ok(Value::Nil);
                }
                let arguments = args
                    .into_iter()
                    .map(|value| to_variant(lua, value))
                    .collect::<mlua::Result<Vec<_>>>()?;
                if let (Some(policy), Some(target), Some(name)) = (guard.as_deref(), callable.object(), callable.method_name()) {
                    let name = name.to_string();
                    rules::member(policy, &rules::Identity::of(&target), &target, &name)?;
                    rules::arguments(policy, &target.get_class().to_string(), &name, &arguments)?;
                    rules::call(&target, &name, &arguments)?;
                }
                let result = callable.callv(&VarArray::from_iter(arguments));
                track(lua, &result);
                to_lua(lua, &result)
            })?;
            Value::Function(function)
        }
        _ => Value::UserData(lua.create_userdata(GodotVariant(variant.clone()))?),
    })
}

fn sequence(lua: &Lua, items: impl Iterator<Item = Value>) -> mlua::Result<Value> {
    let table = lua.create_table()?;
    for item in items {
        table.push(item)?;
    }
    Ok(Value::Table(table))
}

fn number(table: &Table, key: &str) -> mlua::Result<f32> {
    Ok(table.get::<Option<f64>>(key)?.unwrap_or(0.0) as f32)
}

pub fn to_variant(lua: &Lua, value: Value) -> mlua::Result<Variant> {
    Ok(match value {
        Value::Nil => Variant::nil(),
        Value::Boolean(value) => value.to_variant(),
        Value::Integer(value) => value.to_variant(),
        Value::Number(value) => value.to_variant(),
        Value::String(text) => GString::from(text.to_str()?.as_ref()).to_variant(),
        Value::Function(handler) => callable(lua, handler)?.to_variant(),
        Value::UserData(data) => {
            if let Ok(object) = data.borrow::<GodotObject>() {
                object.object.to_variant()
            } else if let Ok(class) = data.borrow::<GodotClass>() {
                class
                    .object()
                    .ok_or_else(|| mlua::Error::runtime(format!("{} is a native class and can't be passed as a value", class.name)))?
                    .to_variant()
            } else if let Ok(variant) = data.borrow::<GodotVariant>() {
                variant.0.clone()
            } else {
                return Err(mlua::Error::runtime("this value can't be passed to Godot"));
            }
        }
        Value::Table(table) => {
            let kind = table
                .metatable()
                .and_then(|meta| meta.raw_get::<Option<String>>(TYPE_KEY).ok().flatten());
            match kind.as_deref() {
                Some("Vector2") => Vector2::new(number(&table, "x")?, number(&table, "y")?).to_variant(),
                Some("Vector2i") => Vector2i::new(number(&table, "x")? as i32, number(&table, "y")? as i32).to_variant(),
                Some("Color") => Color::from_rgba(number(&table, "r")?, number(&table, "g")?, number(&table, "b")?, table.get::<Option<f64>>("a")?.unwrap_or(1.0) as f32).to_variant(),
                Some("Rect2") => {
                    let position = to_variant(lua, table.get("position")?)?.try_to::<Vector2>().unwrap_or_default();
                    let size = to_variant(lua, table.get("size")?)?.try_to::<Vector2>().unwrap_or_default();
                    Rect2::new(position, size).to_variant()
                }
                _ => {
                    let length = table.raw_len();
                    let pairs = table.clone().pairs::<Value, Value>().count();
                    if pairs == length && kind.is_none() {
                        let mut array = VarArray::new();
                        for item in table.sequence_values::<Value>() {
                            array.push(&to_variant(lua, item?)?);
                        }
                        array.to_variant()
                    } else {
                        let mut dictionary = VarDictionary::new();
                        for pair in table.pairs::<Value, Value>() {
                            let (key, item) = pair?;
                            dictionary.set(&to_variant(lua, key)?, &to_variant(lua, item)?);
                        }
                        dictionary.to_variant()
                    }
                }
            }
        }
        _ => return Err(mlua::Error::runtime("this Lua value can't be passed to Godot")),
    })
}

mod rules {
    use super::*;

    const BLOCKED_CLASSES: [&str; 26] = [
        "Engine", "ProjectSettings", "ClassDB", "ResourceSaver", "Script", "GDScriptNativeClass", "Expression",
        "JavaClassWrapper", "JavaScriptBridge", "JavaClass", "JavaObject", "JNISingleton", "GDExtension",
        "GDExtensionManager", "EngineDebugger", "Thread", "WorkerThreadPool", "MusicService", "ServiceTicker",
        "AynThor", "LuaRuntime", "ZIPReader", "ZIPPacker", "ConfigFile", "PCKPacker", "EditorInterface",
    ];
    const NETWORK_CLASSES: [&str; 21] = [
        "HTTPRequest", "HTTPClient", "StreamPeerTCP", "StreamPeerTLS", "StreamPeerSocket", "TCPServer", "UDPServer",
        "PacketPeerUDP", "PacketPeerDTLS", "DTLSServer", "WebSocketPeer", "WebSocketMultiplayerPeer",
        "WebRTCPeerConnection", "WebRTCDataChannel", "WebRTCMultiplayerPeer", "ENetConnection", "ENetMultiplayerPeer",
        "ENetPacketPeer", "IP", "UPNP", "WebView",
    ];
    const BLOCKED_NARI: [&str; 10] = ["Marketplace", "Themes", "Vault", "FileUtil", "Package", "NariPlugin", "Worker", "MotionPlayer", "NariMotion", "DevTools"];
    const BLOCKED_MEMBERS: [&str; 12] = [
        "call", "callv", "call_deferred", "set", "set_deferred", "set_indexed", "get", "get_indexed", "set_script",
        "get_script", "get_property_list", "get_method_list",
    ];
    const OS_ALLOWED: [&str; 13] = [
        "get_name", "get_locale", "get_locale_language", "has_feature", "get_processor_count", "is_debug_build",
        "get_version", "get_model_name", "get_ticks_msec", "get_ticks_usec", "low_processor_usage_mode",
        "is_userfs_persistent", "get_static_memory_usage",
    ];
    const PLUGINS_ALLOWED: [&str; 7] = ["is_nari_ready", "pick_text", "is_enabled", "is_marked", "manifests", "plugins_changed", "plugin_failed"];
    const MEDIA_PLAYER_BLOCKED: [&str; 5] = ["save_stream", "register_provider", "unregister_provider", "open_files", "open_target"];
    const SETTINGS_BLOCKED: [&str; 5] = ["set_value", "mark_private", "save", "reload", "plugins"];
    const DIR_STATICS: [&str; 7] = [
        "dir_exists_absolute", "get_files_at", "get_directories_at", "make_dir_absolute", "make_dir_recursive_absolute",
        "remove_absolute", "rename_absolute",
    ];
    const FILE_CLASSES: [&str; 3] = ["FileAccess", "DirAccess", "ResourceLoader"];
    const FILE_WORDS: [&str; 10] = ["load", "save", "file", "open", "remove", "rename", "copy", "make_dir", "store", "write"];
    const WRITE_WORDS: [&str; 10] = ["save", "store", "write", "remove", "rename", "copy", "make_dir", "create", "move", "delete"];
    const BUILTIN_PROVIDERS: &str = "res://systems/music/providers/";
    const FILE_READ: i64 = 1;

    fn refuse(what: &str) -> mlua::Error {
        mlua::Error::runtime(format!(
            "{what} isn't available to sandboxed plugins: add \"all\" to \"permissions\" in manifest.json if the plugin really needs it"
        ))
    }

    #[derive(Clone, Copy)]
    struct Kind {
        blocked: bool,
        network: bool,
    }

    fn kind(name: &str) -> Kind {
        thread_local! {
            static KINDS: RefCell<HashMap<String, Kind>> = RefCell::new(HashMap::new());
        }
        KINDS.with(|kinds| {
            if let Some(known) = kinds.borrow().get(name) {
                return *known;
            }
            let classes = ClassDb::singleton();
            let exists = classes.class_exists(name);
            let inherits = |base: &&str| name == *base || exists && classes.is_parent_class(name, *base);
            let found = Kind { blocked: BLOCKED_CLASSES.iter().any(inherits), network: NETWORK_CLASSES.iter().any(inherits) };
            kinds.borrow_mut().insert(name.to_owned(), found);
            found
        })
    }

    fn blocked_class(name: &str) -> bool {
        kind(name).blocked
    }

    fn network_class(name: &str) -> bool {
        kind(name).network
    }

    pub fn global(policy: &Policy, name: &str) -> mlua::Result<()> {
        if name.starts_with('_') || blocked_class(name) || BLOCKED_NARI.contains(&name) {
            return Err(refuse(name));
        }
        if network_class(name) || name == "HTTPService" {
            policy.require_network(name)?;
        }
        Ok(())
    }

    pub fn class(policy: &Policy, name: &str, scripted: bool, key: &str) -> mlua::Result<()> {
        if name.is_empty() || key.starts_with('_') || BLOCKED_MEMBERS.contains(&key) {
            return Err(refuse(&format!("{name}.{key}")));
        }
        global(policy, name)?;
        if !scripted && name == "DirAccess" && !DIR_STATICS.contains(&key) {
            return Err(refuse(&format!("DirAccess.{key}")));
        }
        Ok(())
    }

    fn nari_name(object: &Gd<Object>) -> Option<String> {
        let script = object.get_script()?;
        let global = script.get_global_name().to_string();
        if !global.is_empty() {
            return Some(global);
        }
        let node = object.clone().try_cast::<Node>().ok()?;
        let parent = node.get_parent()?;
        (parent.get_parent().is_none() && tree_root().is_some_and(|root| root == parent)).then(|| node.get_name().to_string())
    }

    fn script_path(object: &Gd<Object>) -> String {
        object.get_script().map(|script| script.get_path().to_string()).unwrap_or_default()
    }

    pub struct Identity {
        class: String,
        nari: String,
        blocked: bool,
        network: bool,
        builtin_provider: bool,
    }

    impl Identity {
        pub fn of(object: &Gd<Object>) -> Self {
            let class = object.get_class().to_string();
            let kind = kind(&class);
            Self {
                blocked: kind.blocked || class == "DirAccess",
                network: kind.network,
                nari: nari_name(object).unwrap_or_default(),
                builtin_provider: script_path(object).starts_with(BUILTIN_PROVIDERS),
                class,
            }
        }
    }

    pub fn member(policy: &Policy, identity: &Identity, object: &Gd<Object>, key: &str) -> mlua::Result<()> {
        let class = identity.class.as_str();
        if key.starts_with('_') || BLOCKED_MEMBERS.contains(&key) {
            return Err(refuse(&format!("{class}.{key}")));
        }
        if identity.blocked {
            return Err(refuse(class));
        }
        if identity.network {
            policy.require_network(class)?;
        }
        if class == "OS" && !OS_ALLOWED.contains(&key) {
            return Err(refuse(&format!("OS.{key}")));
        }
        if class == "DisplayServer" {
            if key.starts_with("clipboard_") {
                policy.require(policy.clipboard, CLIPBOARD, &format!("DisplayServer.{key}"))?;
            }
            if key.starts_with("screen_get_image") {
                return Err(refuse(&format!("DisplayServer.{key}")));
            }
        }
        let name = identity.nari.as_str();
        let blocked = match name {
            "" => false,
            "Plugins" => !PLUGINS_ALLOWED.contains(&key),
            "MediaPlayer" => MEDIA_PLAYER_BLOCKED.contains(&key),
            "SettingsManager" => SETTINGS_BLOCKED.contains(&key),
            "HTTPService" => {
                policy.require_network("HTTPService")?;
                false
            }
            other => BLOCKED_NARI.contains(&other),
        };
        if blocked {
            return Err(refuse(&format!("{name}.{key}")));
        }
        if name == "MediaPlayer" && key == "play_uri" {
            policy.require(policy.network, NETWORK, "MediaPlayer.play_uri()")?;
        }
        if identity.builtin_provider && object.has_method(key) {
            return Err(refuse(&format!("the built-in music providers' {key}()")));
        }
        Ok(())
    }

    pub fn assignment(object: &Gd<Object>, key: &str) -> mlua::Result<()> {
        if matches!(key, "script" | "source_code") {
            return Err(refuse(&format!("{}.{key}", object.get_class())));
        }
        Ok(())
    }

    pub fn arguments(policy: &Policy, class: &str, method: &str, arguments: &[Variant]) -> mlua::Result<()> {
        let file_class = FILE_CLASSES.contains(&class);
        if !file_class && !FILE_WORDS.iter().any(|word| method.contains(word)) {
            return Ok(());
        }
        let opens_for_writing = class == "FileAccess"
            && method.starts_with("open")
            && arguments.get(1).and_then(|mode| mode.try_to::<i64>().ok()).is_some_and(|mode| mode != FILE_READ);
        let writes = opens_for_writing || WRITE_WORDS.iter().any(|word| method.contains(word));
        for argument in arguments {
            if !matches!(argument.get_type(), VariantType::STRING | VariantType::STRING_NAME) {
                continue;
            }
            let text = argument.to_string();
            if file_class || looks_like_path(&text) {
                policy.check(&text, writes).map_err(mlua::Error::runtime)?;
            }
        }
        Ok(())
    }

    pub fn call(target: &Gd<Object>, method: &str, arguments: &[Variant]) -> mlua::Result<()> {
        if method == "get_value" && nari_name(target).as_deref() == Some("SettingsManager") && arguments.len() >= 2 {
            let private = target.clone().call("is_private", &arguments[..2]);
            if private.try_to::<bool>().unwrap_or(true) {
                return Err(refuse("private settings"));
            }
        }
        Ok(())
    }
}
