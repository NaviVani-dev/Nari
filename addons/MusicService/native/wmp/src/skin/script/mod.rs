mod ast;
mod builtins;
mod convert;
mod heap;
mod interp;
mod lexer;
mod parser;
mod regex;
mod stack;
mod strings;

use std::collections::HashMap;
use std::sync::Arc;

use ast::FuncDef;
use heap::{Obj, Scope};
use lexer::Interner;

type Name = Arc<str>;

const MAX_SOURCE: usize = 8 << 20;

pub type HostId = u64;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Undefined,
    Null,
    Bool(bool),
    Number(f64),
    Str(Arc<str>),
    Object(ObjectRef),
    Host(HostId),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ObjectRef(u32);

pub trait Host {
    fn global(&mut self, name: &str) -> Option<Value>;
    fn has(&mut self, object: HostId, name: &str) -> bool;
    fn get(&mut self, object: HostId, name: &str) -> Value;
    fn set(&mut self, object: HostId, name: &str, value: Value);
    fn call(&mut self, object: HostId, name: &str, args: &[Value]) -> Result<Value, String>;
    fn index(&mut self, object: HostId, index: f64) -> Value {
        let _ = (object, index);
        Value::Undefined
    }
}

pub struct Limits {
    pub steps: u64,
    pub heap_bytes: usize,
    pub max_depth: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            steps: 400_000,
            heap_bytes: 16 << 20,
            max_depth: 96,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum ScriptError {
    Syntax { line: u32, message: String },
    Thrown(String),
    Budget,
    Memory,
    Depth,
}

impl std::fmt::Display for ScriptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScriptError::Syntax { line, message } => write!(f, "line {line}: {message}"),
            ScriptError::Thrown(message) => f.write_str(message),
            ScriptError::Budget => f.write_str("script ran for too long"),
            ScriptError::Memory => f.write_str("script used too much memory"),
            ScriptError::Depth => f.write_str("script nested too deeply"),
        }
    }
}

impl std::error::Error for ScriptError {}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Code(u32);

struct Protos {
    object: ObjectRef,
    function: ObjectRef,
    array: ObjectRef,
    string: ObjectRef,
    number: ObjectRef,
    boolean: ObjectRef,
    date: ObjectRef,
    regexp: ObjectRef,
    errors: [ObjectRef; 7],
}

pub struct Engine {
    limits: Limits,
    objs: Vec<Obj>,
    free_objs: Vec<u32>,
    scopes: Vec<Scope>,
    free_scopes: Vec<u32>,
    bytes: usize,
    dead: Obj,
    global: ObjectRef,
    protos: Protos,
    folded: HashMap<String, Name>,
    steps: u64,
    depth: u32,
    calls: u32,
    scope: Option<u32>,
    this: Value,
    last: Value,
    track: bool,
    is_new: bool,
    names: Interner,
    codes: Vec<Arc<FuncDef>>,
    code_cache: HashMap<String, Code>,
    regex_cache: HashMap<(Name, Name), Arc<regex::Program>>,
    rng: u64,
}

fn strip_prefix(source: &str) -> &str {
    let trimmed = source.trim_start();
    match trimmed.get(..8) {
        Some(prefix) if prefix.eq_ignore_ascii_case("jscript:") => trimmed.get(8..).unwrap_or(""),
        _ => source,
    }
}

impl Engine {
    pub fn new(limits: Limits) -> Self {
        builtins::create(limits)
    }

    pub fn load(&mut self, source: &str, host: &mut dyn Host) -> Result<(), ScriptError> {
        if source.len() > MAX_SOURCE {
            return Err(ScriptError::Memory);
        }
        let def = parser::parse(source, &mut self.names, parser::MAX_NESTING)?;
        self.begin();
        let result = self.run_program(&def, host);
        self.finish(result.map(|_| Value::Undefined), host)
            .map(|_| ())
    }

    pub fn compile(&mut self, source: &str) -> Result<Code, ScriptError> {
        stack::mark();
        if source.len() > MAX_SOURCE {
            return Err(ScriptError::Memory);
        }
        if let Some(code) = self.code_cache.get(source) {
            return Ok(*code);
        }
        let def = parser::parse(strip_prefix(source), &mut self.names, parser::MAX_NESTING)?;
        let code = Code(self.codes.len() as u32);
        self.codes.push(def);
        self.code_cache.insert(source.to_string(), code);
        Ok(code)
    }

    pub fn run(
        &mut self,
        code: Code,
        scope: Option<HostId>,
        args: &[(&str, Value)],
        host: &mut dyn Host,
    ) -> Result<Value, ScriptError> {
        let Some(def) = self.codes.get(code.0 as usize).cloned() else {
            return Err(ScriptError::Thrown("unknown code".to_string()));
        };
        self.begin();
        let result = self.run_handler(&def, scope, args, host);
        self.finish(result, host)
    }

    pub fn call_global(
        &mut self,
        name: &str,
        args: &[Value],
        host: &mut dyn Host,
    ) -> Result<Value, ScriptError> {
        self.begin();
        let function = self.global_value(name);
        if !self.is_callable(&function) {
            return Err(ScriptError::Thrown(format!("'{name}' is not a function")));
        }
        let this = self.this.clone();
        let result = self.call(&function, this, args, host);
        self.finish(result, host)
    }

    pub fn call_value(
        &mut self,
        function: &Value,
        args: &[Value],
        host: &mut dyn Host,
    ) -> Result<Value, ScriptError> {
        self.begin();
        let this = self.this.clone();
        let result = self.call(function, this, args, host);
        self.finish(result, host)
    }

    pub fn to_str(&mut self, value: &Value, host: &mut dyn Host) -> Arc<str> {
        self.begin();
        self.string_of(value, host)
            .unwrap_or_else(|_| Arc::from("[object Object]"))
    }

    pub fn to_number(&mut self, value: &Value, host: &mut dyn Host) -> f64 {
        self.begin();
        self.number(value, host).unwrap_or(f64::NAN)
    }

    pub fn heap_bytes(&self) -> usize {
        self.bytes
    }
}

pub fn to_bool(value: &Value) -> bool {
    match value {
        Value::Undefined | Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => *n != 0.0 && !n.is_nan(),
        Value::Str(s) => !s.is_empty(),
        Value::Object(_) | Value::Host(_) => true,
    }
}
