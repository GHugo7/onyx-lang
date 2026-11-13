//! Type checker. Verifies the program and produces the side tables the
//! code generators need (expression types, call targets, async functions).

use crate::ast::*;
use crate::diagnostics::{Diagnostic, Span};
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::rc::Rc;

#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    Int,
    Float,
    Bool,
    Str,
    Void,
    Error,
    List(Box<Type>),
    Map(Box<Type>, Box<Type>),
    Chan(Box<Type>),
    Struct(String),
    Interface(String),
    Fn(Rc<FnSig>),
    Range,
    /// Produced after an error was reported; silences follow-up errors.
    Unknown,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FnSig {
    pub params: Vec<Type>,
    pub ret: Type,
    pub fallible: bool,
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Type::Int => write!(f, "int"),
            Type::Float => write!(f, "float"),
            Type::Bool => write!(f, "bool"),
            Type::Str => write!(f, "string"),
            Type::Void => write!(f, "void"),
            Type::Error => write!(f, "error"),
            Type::List(t) => write!(f, "[{t}]"),
            Type::Map(k, v) => write!(f, "map<{k}, {v}>"),
            Type::Chan(t) => write!(f, "chan<{t}>"),
            Type::Struct(n) | Type::Interface(n) => write!(f, "{n}"),
            Type::Fn(sig) => {
                write!(f, "fn(")?;
                for (i, p) in sig.params.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{p}")?;
                }
                write!(f, ")")?;
                if sig.ret != Type::Void || sig.fallible {
                    write!(f, " -> {}", sig.ret)?;
                }
                if sig.fallible {
                    write!(f, "!")?;
                }
                Ok(())
            }
            Type::Range => write!(f, "range"),
            Type::Unknown => write!(f, "?"),
        }
    }
}

impl Type {
    fn is_numeric(&self) -> bool {
        matches!(self, Type::Int | Type::Float)
    }
    fn is_unknown(&self) -> bool {
        matches!(self, Type::Unknown)
    }
}

#[derive(Debug, Clone, Default)]
pub struct StructInfo {
    pub fields: Vec<(String, Type)>,
    pub methods: HashMap<String, Rc<FnSig>>,
}

#[derive(Debug, Clone, Default)]
struct InterfaceInfo {
    methods: Vec<(String, Rc<FnSig>)>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Recv {
    Str,
    List,
    Map,
    Chan,
}

/// What a call expression resolves to.
#[derive(Debug, Clone, PartialEq)]
pub enum CallKind {
    /// A top-level function.
    Fn(String),
    /// A method on a struct: (struct, method).
    Method(String, String),
    /// A built-in function such as `print`.
    Builtin(String),
    /// A method on a built-in type such as `list.push`.
    BuiltinMethod(Recv, String),
    /// A function value or interface method; resolved at run time.
    Dynamic,
}

#[derive(Debug, Default)]
pub struct Analysis {
    pub types: HashMap<usize, Type>,
    pub calls: HashMap<usize, CallKind>,
    /// Keys (see `fn_key` etc.) of the functions that must be compiled as async.
    pub async_keys: HashSet<String>,
    pub structs: HashMap<String, StructInfo>,
    /// Signatures of the top-level functions.
    pub fns: HashMap<String, Rc<FnSig>>,
    /// `catch` expressions whose block ends with a value.
    pub catch_values: HashSet<usize>,
    /// Calls that can fail.
    pub fallible_calls: HashSet<usize>,
    /// Expressions of type `int` whose value is used as a `float`.
    pub widened: HashSet<usize>,
}

pub fn fn_key(name: &str) -> String {
    format!("fn:{name}")
}
pub fn method_key(strukt: &str, name: &str) -> String {
    format!("m:{strukt}.{name}")
}
pub fn lambda_key(id: usize) -> String {
    format!("lambda:{id}")
}

/// (parameters, return type, can fail, is async)
fn builtin_sig(name: &str) -> Option<(Vec<Type>, Type, bool, bool)> {
    use Type::*;
    let list_str = || List(Box::new(Str));
    Some(match name {
        "parse_int" => (vec![Str], Int, true, false),
        "parse_float" => (vec![Str], Float, true, false),
        "read_file" => (vec![Str], Str, true, false),
        "write_file" => (vec![Str, Str], Void, true, false),
        "append_file" => (vec![Str, Str], Void, true, false),
        "file_exists" => (vec![Str], Bool, false, false),
        "args" => (vec![], list_str(), false, false),
        "env" => (vec![Str], Str, true, false),
        "exit" => (vec![Int], Void, false, false),
        "sleep" => (vec![Int], Void, false, true),
        "now" => (vec![], Int, false, false),
        "random" => (vec![], Float, false, false),
        "random_int" => (vec![Int, Int], Int, false, false),
        "input" => (vec![Str], Str, false, false),
        "fetch" => (vec![Str], Str, true, true),
        "expect" => (vec![Bool], Void, false, false),
        "panic" => (vec![Str], Void, false, false),
        "sqrt" => (vec![Float], Float, false, false),
        "pow" => (vec![Float, Float], Float, false, false),
        "floor" | "ceil" | "round" => (vec![Float], Int, false, false),
        // Low-level operations of the native runtime (see src/native/runtime.ox).
        "__syscall" => (vec![Int; 7], Int, false, false),
        "__load8" | "__load32" | "__load64" => (vec![Int], Int, false, false),
        "__store8" | "__store32" | "__store64" => (vec![Int, Int], Void, false, false),
        "__copy" => (vec![Int, Int, Int], Void, false, false),
        "__and" | "__or" | "__xor" | "__shl" | "__shr" | "__sar" => (vec![Int, Int], Int, false, false),
        "__bits" => (vec![Float], Int, false, false),
        "__float" => (vec![Int], Float, false, false),
        "__state" => (vec![], Int, false, false),
        "__str_ptr" => (vec![Str], Int, false, false),
        "__ptr_str" => (vec![Int], Str, false, false),
        "__td_string" => (vec![], Int, false, false),
        _ => return None,
    })
}

pub fn is_builtin(name: &str) -> bool {
    builtin_sig(name).is_some()
        || matches!(name, "print" | "str" | "int" | "float" | "abs" | "min" | "max")
}

const BUILTIN_TYPES: &[&str] = &["int", "float", "bool", "string", "void", "error", "map"];

#[derive(Clone)]
struct Var {
    ty: Type,
    mutable: bool,
}

#[derive(PartialEq, Clone, Copy)]
enum CtxKind {
    Fn,
    Fork,
    Check,
    Global,
}

struct FnCtx {
    kind: CtxKind,
    key: String,
    ret: Type,
    fallible: bool,
    loop_depth: u32,
}

/// What the checker records about each body of code (a function, a method,
/// a lambda, a `fork` block, the initialiser of a top-level variable).
#[derive(Default)]
struct AsyncInfo {
    /// Contains an operation that waits (channel, sleep, ...).
    direct: bool,
    /// Functions and methods it calls directly.
    calls: Vec<String>,
    /// Top-level variables it reads or writes.
    globals: Vec<String>,
    /// Bodies that run as part of this one without being called (`fork` blocks).
    inline: Vec<String>,
    /// Methods called through an interface: any struct's method of that name may run.
    interface_calls: Vec<String>,
    /// Calls a function value: any function that is used as a value may run.
    dynamic: bool,
}

struct Checker<'a> {
    src: &'a str,
    diags: Vec<Diagnostic>,
    structs: HashMap<String, StructInfo>,
    interfaces: HashMap<String, InterfaceInfo>,
    fns: HashMap<String, Rc<FnSig>>,
    scopes: Vec<HashMap<String, Var>>,
    ctx: Vec<FnCtx>,
    /// Calls that are wrapped in `?`, `or` or `catch`.
    handling: HashSet<usize>,
    /// The one `catch` expression allowed at the current statement: (id, needs a value).
    catch_slot: Option<(usize, bool)>,
    async_info: HashMap<String, AsyncInfo>,
    /// Functions and lambdas that are stored or passed around as values.
    escaping: Vec<String>,
    /// Every top-level variable, with its position in initialisation order.
    global_names: HashMap<String, usize>,
    /// (name, span of the initialiser) of the top-level variables checked so far.
    global_inits: Vec<(String, Span)>,
    forks: usize,
    /// Byte range of the native runtime's source; `__` names are only visible there.
    runtime: Option<(usize, usize)>,
    an: Analysis,
}

pub fn check(
    program: &Program,
    src: &str,
    require_main: bool,
    runtime: Option<(usize, usize)>,
) -> Result<Analysis, Vec<Diagnostic>> {
    let mut c = Checker {
        src,
        diags: Vec::new(),
        structs: HashMap::new(),
        interfaces: HashMap::new(),
        fns: HashMap::new(),
        scopes: vec![HashMap::new()],
        ctx: Vec::new(),
        handling: HashSet::new(),
        catch_slot: None,
        async_info: HashMap::new(),
        escaping: Vec::new(),
        global_names: HashMap::new(),
        global_inits: Vec::new(),
        forks: 0,
        runtime,
        an: Analysis::default(),
    };
    c.run(program, require_main);
    if c.diags.is_empty() {
        c.an.structs = c.structs;
        c.an.fns = c.fns;
        Ok(c.an)
    } else {
        c.diags.sort_by_key(|d| d.span.start);
        Err(c.diags)
    }
}

impl<'a> Checker<'a> {
    fn err(&mut self, d: Diagnostic) {
        self.diags.push(d);
    }

    fn text(&self, span: Span) -> &str {
        self.src.get(span.start..span.end).unwrap_or("")
    }

    fn mismatch(&mut self, expected: &Type, found: &Type, span: Span) {
        let mut d = Diagnostic::new(
            "E0102",
            format!("type mismatch: expected `{expected}`, found `{found}`"),
            span,
        )
        .label(format!("this is `{found}`"));
        d = match (expected, found) {
            (Type::Str, _) => d.help("convert with `str(...)` or use interpolation: \"{value}\""),
            (Type::Int, Type::Float) => d.help("convert with `int(...)` (drops the decimals), `round(...)`, `floor(...)` or `ceil(...)`"),
            (Type::Int, Type::Str) => d.help("convert with `parse_int(...)`, which can fail: `parse_int(s) or 0`"),
            (Type::Float, Type::Str) => d.help("convert with `parse_float(...)`, which can fail: `parse_float(s) or 0.0`"),
            (Type::Interface(i), Type::Struct(s)) => {
                let missing = self.missing_methods(s, i);
                d.help(format!("`{s}` does not implement `{i}`: {missing}"))
            }
            _ => d,
        };
        self.err(d);
    }

    // ---- declarations ----

    fn run(&mut self, program: &Program, require_main: bool) {
        // 1. Type names.
        for item in &program.items {
            let (name, span) = match item {
                Item::Struct(s) => (&s.name, s.name_span),
                Item::Interface(i) => (&i.name, i.name_span),
                _ => continue,
            };
            self.check_reserved(name, span);
            if BUILTIN_TYPES.contains(&name.as_str()) {
                self.err(Diagnostic::new("E0103", format!("`{name}` is a built-in type"), span));
            } else if self.structs.contains_key(name) || self.interfaces.contains_key(name) {
                self.err(Diagnostic::new("E0103", format!("type `{name}` is defined twice"), span)
                    .label("already defined above"));
            } else if matches!(item, Item::Struct(_)) {
                self.structs.insert(name.clone(), StructInfo::default());
            } else {
                self.interfaces.insert(name.clone(), InterfaceInfo::default());
            }
        }

        // 2. Signatures.
        for item in &program.items {
            match item {
                Item::Struct(s) => {
                    let mut info = StructInfo::default();
                    for f in &s.fields {
                        let ty = self.resolve(&f.ty);
                        if info.fields.iter().any(|(n, _)| n == &f.name) {
                            self.err(Diagnostic::new("E0103", format!("field `{}` is defined twice", f.name), f.span));
                        } else {
                            info.fields.push((f.name.clone(), ty));
                        }
                    }
                    for m in &s.methods {
                        if !m.has_self {
                            self.err(Diagnostic::new(
                                "E0003",
                                format!("method `{}` must take `self` as its first parameter", m.name),
                                m.name_span,
                            )
                            .help(format!("write `fn {}(self, ...)`", m.name)));
                        }
                        let sig = self.signature(&m.params, &m.ret, m.fallible);
                        if info.methods.contains_key(&m.name) || info.fields.iter().any(|(n, _)| n == &m.name) {
                            self.err(Diagnostic::new("E0103", format!("`{}` is defined twice in `{}`", m.name, s.name), m.name_span));
                        } else {
                            info.methods.insert(m.name.clone(), sig);
                        }
                    }
                    self.structs.insert(s.name.clone(), info);
                }
                Item::Interface(i) => {
                    let mut info = InterfaceInfo::default();
                    for m in &i.methods {
                        let sig = self.signature(&m.params, &m.ret, m.fallible);
                        if info.methods.iter().any(|(n, _)| n == &m.name) {
                            self.err(Diagnostic::new("E0103", format!("method `{}` is defined twice", m.name), m.name_span));
                        } else {
                            info.methods.push((m.name.clone(), sig));
                        }
                    }
                    self.interfaces.insert(i.name.clone(), info);
                }
                Item::Fn(f) => {
                    let sig = self.signature(&f.params, &f.ret, f.fallible);
                    self.check_reserved(&f.name, f.name_span);
                    if is_builtin(&f.name) {
                        self.err(Diagnostic::new("E0103", format!("`{}` is a built-in function and cannot be redefined", f.name), f.name_span));
                    } else if self.structs.contains_key(&f.name) || self.interfaces.contains_key(&f.name) {
                        self.err(Diagnostic::new("E0103", format!("`{}` is already the name of a type", f.name), f.name_span));
                    } else if self.fns.contains_key(&f.name) {
                        self.err(Diagnostic::new("E0103", format!("function `{}` is defined twice", f.name), f.name_span)
                            .label("already defined above"));
                    } else {
                        self.fns.insert(f.name.clone(), sig);
                    }
                }
                _ => {}
            }
        }

        // 3. Top-level variables, in the order in which they get their values.
        let globals: Vec<(&Stmt, &String, &Expr, Span)> = program
            .items
            .iter()
            .filter_map(|item| match item {
                Item::Global(stmt) => match &stmt.kind {
                    StmtKind::Let { name, init, name_span, .. } => Some((stmt, name, init, *name_span)),
                    _ => None,
                },
                _ => None,
            })
            .collect();
        for (i, (_, name, _, _)) in globals.iter().enumerate() {
            self.global_names.entry((*name).clone()).or_insert(i);
        }
        for (stmt, name, init, name_span) in globals {
            self.check_reserved(name, name_span);
            self.global_inits.push((name.clone(), init.span));
            self.push_ctx(CtxKind::Global, format!("global:{name}"), Type::Void, false);
            self.stmt(stmt);
            self.ctx.pop();
        }

        // 4. Bodies.
        for item in &program.items {
            match item {
                Item::Fn(f) => self.function(f, fn_key(&f.name), None),
                Item::Struct(s) => {
                    for m in &s.methods {
                        self.function(m, method_key(&s.name, &m.name), Some(&s.name));
                    }
                }
                Item::Check { body, .. } => {
                    self.push_ctx(CtxKind::Check, "check".into(), Type::Void, false);
                    self.block(body);
                    self.ctx.pop();
                }
                _ => {}
            }
        }

        // 5. Entry point.
        if require_main {
            let main = program.items.iter().find_map(|i| match i {
                Item::Fn(f) if f.name == "main" => Some(f),
                _ => None,
            });
            match main {
                None => self.err(Diagnostic::new("E0116", "this program has no `main` function", Span::new(0, 0))
                    .help("add `fn main() { ... }`")),
                Some(f) => {
                    if !f.params.is_empty() {
                        self.err(Diagnostic::new("E0116", "`main` takes no parameters", f.name_span)
                            .help("use `args()` to read command-line arguments"));
                    }
                    if let Some(ret) = &f.ret {
                        if !matches!(&ret.kind, TypeKind::Named(n) if n == "void") {
                            self.err(Diagnostic::new("E0116", "`main` cannot return a value", ret.span)
                                .help("use `exit(code)` to set the exit code; `-> void!` is allowed"));
                        }
                    }
                }
            }
        }

        // 6. Propagate async-ness through the call graph.
        let mut set: HashSet<String> =
            self.async_info.iter().filter(|(_, i)| i.direct).map(|(k, _)| k.clone()).collect();
        loop {
            let mut changed = false;
            for (key, info) in &self.async_info {
                if !set.contains(key) && info.calls.iter().any(|c| set.contains(c)) {
                    set.insert(key.clone());
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
        self.an.async_keys = set;

        // 7. No top-level variable may be used before it has its value.
        self.check_initialization_order();
    }

    /// Names starting with two underscores belong to the runtime.
    fn check_reserved(&mut self, name: &str, span: Span) {
        let own_name = name.rsplit('.').next().unwrap_or(name);
        let in_runtime = self.runtime.is_some_and(|(start, end)| span.start >= start && span.end <= end);
        if own_name.starts_with("__") && !in_runtime {
            self.err(Diagnostic::new("E0103", format!("the name `{own_name}` is reserved"), span)
                .help("names starting with two underscores are reserved for the Onyx runtime; one underscore makes a name private to its file"));
        }
    }

    /// Top-level variables get their values one after the other, imported
    /// files first. An initialiser may call functions, and those functions may
    /// use other top-level variables: this finds the ones that would be used
    /// too early. The search follows every call that *could* happen, so it
    /// can reject a program that would in fact have been fine.
    fn check_initialization_order(&mut self) {
        let mut methods_named: HashMap<&str, Vec<String>> = HashMap::new();
        for (strukt, info) in &self.structs {
            for method in info.methods.keys() {
                methods_named.entry(method.as_str()).or_default().push(method_key(strukt, method));
            }
        }
        let describe = |key: &str| -> Option<String> {
            if let Some(name) = key.strip_prefix("fn:") {
                Some(format!("`{name}`"))
            } else if let Some(name) = key.strip_prefix("m:") {
                Some(format!("`{name}`"))
            } else if key.starts_with("lambda:") {
                Some("a lambda".to_string())
            } else {
                None
            }
        };

        let mut errors = Vec::new();
        for (i, (name, init_span)) in self.global_inits.iter().enumerate() {
            let start = format!("global:{name}");
            let mut parent: HashMap<String, String> = HashMap::new();
            let mut seen: HashSet<String> = HashSet::from([start.clone()]);
            let mut queue = std::collections::VecDeque::from([start.clone()]);
            'search: while let Some(key) = queue.pop_front() {
                let Some(info) = self.async_info.get(&key) else { continue };
                for used in &info.globals {
                    if self.global_names.get(used).is_some_and(|&j| j >= i) {
                        // The chain of calls that leads from the initialiser to the use.
                        let mut chain = Vec::new();
                        let mut at = key.clone();
                        while at != start {
                            chain.extend(describe(&at));
                            at = parent[&at].clone();
                        }
                        chain.reverse();
                        errors.push((name.clone(), *init_span, used.clone(), chain));
                        break 'search;
                    }
                }
                let mut next: Vec<&String> = info.calls.iter().chain(info.inline.iter()).collect();
                for method in &info.interface_calls {
                    if let Some(keys) = methods_named.get(method.as_str()) {
                        next.extend(keys);
                    }
                }
                if info.dynamic {
                    next.extend(self.escaping.iter());
                }
                for callee in next {
                    if seen.insert(callee.clone()) {
                        parent.insert(callee.clone(), key.clone());
                        queue.push_back(callee.clone());
                    }
                }
            }
        }

        for (name, span, used, chain) in errors {
            let via = if chain.is_empty() { String::new() } else { format!(" through {}", chain.join(", then ")) };
            let (message, label) = if used == name {
                (
                    format!("`{name}` is used while its own value is being computed"),
                    format!("this uses `{name}`{via}"),
                )
            } else {
                (
                    format!("`{used}` may be used before it has a value"),
                    format!("this uses `{used}`{via}, but `{used}` gets its value later"),
                )
            };
            let module = |n: &str| n.rsplit_once('.').map(|(m, _)| m.to_string()).unwrap_or_default();
            let mut help = format!(
                "top-level variables get their values from top to bottom, imported files first; declare `{used}` before `{name}`, or compute `{name}` inside a function"
            );
            if module(&used) != module(&name) {
                help.push_str(". These two are in files that import each other, so the file that is run decides which comes first");
            }
            self.err(Diagnostic::new("E0118", message, span).label(label).help(help));
        }
    }

    fn signature(&mut self, params: &[Param], ret: &Option<TypeExpr>, fallible: bool) -> Rc<FnSig> {
        let params = params.iter().map(|p| self.resolve(&p.ty)).collect();
        let ret = ret.as_ref().map(|t| self.resolve(t)).unwrap_or(Type::Void);
        Rc::new(FnSig { params, ret, fallible })
    }

    fn resolve(&mut self, t: &TypeExpr) -> Type {
        match &t.kind {
            TypeKind::Named(name) => match name.as_str() {
                "int" => Type::Int,
                "float" => Type::Float,
                "bool" => Type::Bool,
                "string" => Type::Str,
                "void" => Type::Void,
                "error" => Type::Error,
                _ if self.structs.contains_key(name) => Type::Struct(name.clone()),
                _ if self.interfaces.contains_key(name) => Type::Interface(name.clone()),
                _ => {
                    let mut d = Diagnostic::new("E0101", format!("unknown type `{name}`"), t.span);
                    let hint = match name.as_str() {
                        "str" | "String" => Some("string"),
                        "i32" | "i64" | "long" | "Int" | "number" => Some("int"),
                        "f32" | "f64" | "double" | "Float" => Some("float"),
                        "boolean" | "Bool" => Some("bool"),
                        _ => None,
                    };
                    if let Some(h) = hint {
                        d = d.help(format!("did you mean `{h}`?"));
                    }
                    self.err(d);
                    Type::Unknown
                }
            },
            TypeKind::List(elem) => Type::List(Box::new(self.resolve(elem))),
            TypeKind::Map(k, v) => {
                let key = self.resolve(k);
                self.check_map_key(&key, k.span);
                Type::Map(Box::new(key), Box::new(self.resolve(v)))
            }
            TypeKind::Chan(elem) => Type::Chan(Box::new(self.resolve(elem))),
            TypeKind::Fn { params, ret, fallible } => {
                let params = params.iter().map(|p| self.resolve(p)).collect();
                let ret = ret.as_ref().map(|r| self.resolve(r)).unwrap_or(Type::Void);
                Type::Fn(Rc::new(FnSig { params, ret, fallible: *fallible }))
            }
        }
    }

    fn check_map_key(&mut self, key: &Type, span: Span) {
        if !matches!(key, Type::Int | Type::Str | Type::Bool | Type::Unknown) {
            self.err(Diagnostic::new("E0113", format!("`{key}` cannot be used as a map key"), span)
                .help("map keys must be int, string or bool"));
        }
    }

    // ---- type relations ----

    fn missing_methods(&self, strukt: &str, iface: &str) -> String {
        let (Some(s), Some(i)) = (self.structs.get(strukt), self.interfaces.get(iface)) else {
            return String::new();
        };
        let mut problems = Vec::new();
        for (name, sig) in &i.methods {
            match s.methods.get(name) {
                None => problems.push(format!("missing method `{name}`")),
                Some(m) if m != sig => problems.push(format!(
                    "method `{name}` has type `{}` but `{}` is required",
                    Type::Fn(m.clone()),
                    Type::Fn(sig.clone())
                )),
                _ => {}
            }
        }
        problems.join(", ")
    }

    fn assignable(&self, from: &Type, to: &Type) -> bool {
        if from == to || from.is_unknown() || to.is_unknown() {
            return true;
        }
        match (from, to) {
            (Type::Int, Type::Float) => true,
            (Type::Struct(s), Type::Interface(i)) => self.missing_methods(s, i).is_empty(),
            (Type::List(a), Type::List(b)) | (Type::Chan(a), Type::Chan(b)) => a.is_unknown() || b.is_unknown(),
            (Type::Map(k1, v1), Type::Map(k2, v2)) => {
                (k1 == k2 || k1.is_unknown() || k2.is_unknown()) && (v1 == v2 || v1.is_unknown() || v2.is_unknown())
            }
            _ => false,
        }
    }

    fn require(&mut self, found: &Type, expected: &Type, e: &Expr) {
        if !self.assignable(found, expected) {
            self.mismatch(expected, found, e.span);
        }
        self.widen(found, expected, e);
    }

    /// Notes that the int `e` is used where a float is expected: targets
    /// that store the two differently have to convert it there.
    fn widen(&mut self, found: &Type, expected: &Type, e: &Expr) {
        if *found == Type::Int && *expected == Type::Float {
            self.an.widened.insert(e.id);
        }
    }

    // ---- scopes & contexts ----

    fn push_ctx(&mut self, kind: CtxKind, key: String, ret: Type, fallible: bool) {
        self.async_info.entry(key.clone()).or_default();
        self.ctx.push(FnCtx { kind, key, ret, fallible, loop_depth: 0 });
    }

    fn cur(&mut self) -> &mut FnCtx {
        self.ctx.last_mut().expect("no function context")
    }

    fn mark_async(&mut self) {
        let key = self.cur().key.clone();
        self.async_info.entry(key).or_default().direct = true;
    }

    fn add_call(&mut self, callee: String) {
        let key = self.cur().key.clone();
        self.async_info.entry(key).or_default().calls.push(callee);
    }

    /// Records that the current body uses `name`, if it is a top-level variable.
    fn use_global(&mut self, name: &str) {
        if self.scopes.iter().rposition(|s| s.contains_key(name)) == Some(0) {
            let key = self.cur().key.clone();
            self.async_info.entry(key).or_default().globals.push(name.to_string());
        }
    }

    /// A function given to `map`, `filter` or `sort_by` is called right there.
    fn callback(&mut self, arg: &Expr) {
        let key = match &arg.kind {
            ExprKind::Lambda { .. } => Some(lambda_key(arg.id)),
            ExprKind::Ident(name) if self.lookup(name).is_none() && self.fns.contains_key(name) => Some(fn_key(name)),
            _ => None,
        };
        match key {
            // Checking the argument registered it as a value that may be called
            // from anywhere; it is not: it only runs here.
            Some(key) if self.escaping.last() == Some(&key) => {
                self.escaping.pop();
                self.add_call(key);
            }
            _ => {
                let current = self.cur().key.clone();
                self.async_info.entry(current).or_default().dynamic = true;
            }
        }
    }

    fn declare(&mut self, name: &str, ty: Type, mutable: bool, span: Span) {
        let scope = self.scopes.last_mut().unwrap();
        if scope.contains_key(name) {
            self.err(Diagnostic::new("E0103", format!("`{name}` is already defined in this scope"), span)
                .help("pick another name, or assign to the existing variable without `var`"));
            return;
        }
        scope.insert(name.to_string(), Var { ty, mutable });
    }

    fn lookup(&self, name: &str) -> Option<Var> {
        self.scopes.iter().rev().find_map(|s| s.get(name)).cloned()
    }

    fn function(&mut self, f: &FnDecl, key: String, self_struct: Option<&str>) {
        let sig = self.signature_quiet(&f.params, &f.ret, f.fallible);
        self.push_ctx(CtxKind::Fn, key, sig.ret.clone(), sig.fallible);
        self.scopes.push(HashMap::new());
        if let Some(s) = self_struct {
            self.declare("self", Type::Struct(s.to_string()), false, f.name_span);
        }
        for (p, ty) in f.params.iter().zip(sig.params.iter()) {
            self.declare(&p.name, ty.clone(), true, p.span);
        }
        for stmt in &f.body.stmts {
            self.stmt(stmt);
        }
        if sig.ret != Type::Void && !sig.ret.is_unknown() && !exits(&f.body, false) {
            self.err(Diagnostic::new(
                "E0109",
                format!("function `{}` does not return a value on every path", f.name),
                f.name_span,
            )
            .label(format!("must return `{}`", sig.ret)));
        }
        self.scopes.pop();
        self.ctx.pop();
    }

    /// Like `signature`, but without reporting unknown types a second time.
    fn signature_quiet(&mut self, params: &[Param], ret: &Option<TypeExpr>, fallible: bool) -> Rc<FnSig> {
        let n = self.diags.len();
        let sig = self.signature(params, ret, fallible);
        self.diags.truncate(n);
        sig
    }

    fn block(&mut self, block: &Block) {
        self.scopes.push(HashMap::new());
        for stmt in &block.stmts {
            self.stmt(stmt);
        }
        self.scopes.pop();
    }

    // ---- statements ----

    /// Checks an expression in a position where a `catch` block is allowed.
    fn stmt_expr(&mut self, e: &Expr, expected: Option<&Type>, needs_value: bool) -> Type {
        if matches!(e.kind, ExprKind::Catch { .. }) {
            self.catch_slot = Some((e.id, needs_value));
        }
        self.expr(e, expected)
    }

    fn stmt(&mut self, stmt: &Stmt) {
        match &stmt.kind {
            StmtKind::Let { name, name_span, mutable, ty, init } => {
                let annotated = ty.as_ref().map(|t| self.resolve(t));
                let found = self.stmt_expr(init, annotated.as_ref(), true);
                let var_ty = match annotated {
                    Some(a) => {
                        self.require(&found, &a, init);
                        a
                    }
                    None => found,
                };
                if var_ty == Type::Void {
                    self.err(Diagnostic::new("E0102", "this expression does not produce a value", init.span)
                        .label("returns nothing"));
                }
                if self.cur().kind == CtxKind::Global && (self.fns.contains_key(name) || self.structs.contains_key(name)) {
                    self.err(Diagnostic::new("E0103", format!("`{name}` is already the name of a function or type"), *name_span));
                }
                self.declare(name, var_ty, *mutable, *name_span);
            }
            StmtKind::Assign { target, op, value } => {
                let target_ty = self.assign_target(target);
                let found = self.stmt_expr(value, Some(&target_ty), true);
                match op {
                    AssignOp::Set => self.require(&found, &target_ty, value),
                    AssignOp::Add if target_ty == Type::Str => self.require(&found, &Type::Str, value),
                    _ => {
                        if !target_ty.is_numeric() && !target_ty.is_unknown() {
                            self.err(Diagnostic::new(
                                "E0107",
                                format!("this operator cannot be used on `{target_ty}`"),
                                target.span,
                            ));
                        } else {
                            self.require(&found, &target_ty, value);
                        }
                    }
                }
            }
            StmtKind::Expr(e) => {
                self.stmt_expr(e, None, false);
            }
            StmtKind::If { cond, then, els } => {
                let t = self.expr(cond, Some(&Type::Bool));
                self.require(&t, &Type::Bool, cond);
                self.block(then);
                if let Some(els) = els {
                    self.stmt(els);
                }
            }
            StmtKind::While { cond, body } => {
                let t = self.expr(cond, Some(&Type::Bool));
                self.require(&t, &Type::Bool, cond);
                self.cur().loop_depth += 1;
                self.block(body);
                self.cur().loop_depth -= 1;
            }
            StmtKind::For { var, var_span, iter, body } => {
                let iter_ty = self.expr(iter, None);
                let var_ty = match iter_ty {
                    Type::List(t) => *t,
                    Type::Str => Type::Str,
                    Type::Map(k, _) => *k,
                    Type::Range => Type::Int,
                    Type::Chan(t) => {
                        self.mark_async();
                        *t
                    }
                    Type::Unknown => Type::Unknown,
                    other => {
                        self.err(Diagnostic::new("E0114", format!("cannot loop over `{other}`"), iter.span)
                            .help("`for` works on lists, strings, maps, channels and ranges like `0..10`"));
                        Type::Unknown
                    }
                };
                self.scopes.push(HashMap::new());
                self.declare(var, var_ty, false, *var_span);
                self.cur().loop_depth += 1;
                self.block(body);
                self.cur().loop_depth -= 1;
                self.scopes.pop();
            }
            StmtKind::Return(value) => {
                if self.cur().kind == CtxKind::Fork || self.cur().kind == CtxKind::Global {
                    self.err(Diagnostic::new("E0117", "`return` cannot be used here", stmt.span)
                        .help("a `fork` block runs as a separate task and cannot return from the enclosing function"));
                    return;
                }
                let ret = self.cur().ret.clone();
                match value {
                    Some(v) => {
                        let found = self.stmt_expr(v, Some(&ret), true);
                        if ret == Type::Void {
                            if found != Type::Void && !found.is_unknown() {
                                self.err(Diagnostic::new("E0102", "this function does not return a value", v.span)
                                    .help(format!("add a return type: `-> {found}`")));
                            }
                        } else {
                            self.require(&found, &ret, v);
                        }
                    }
                    None => {
                        if ret != Type::Void && !ret.is_unknown() {
                            self.err(Diagnostic::new("E0102", format!("this function must return `{ret}`"), stmt.span)
                                .label("missing a value"));
                        }
                    }
                }
            }
            StmtKind::Break | StmtKind::Continue => {
                if self.cur().loop_depth == 0 {
                    let word = if matches!(stmt.kind, StmtKind::Break) { "break" } else { "continue" };
                    self.err(Diagnostic::new("E0111", format!("`{word}` outside of a loop"), stmt.span));
                }
            }
            StmtKind::Fail(value) => {
                if !self.cur().fallible {
                    self.err(Diagnostic::new("E0203", "`fail` used in a function that cannot fail", stmt.span)
                        .help("add `!` to the function's return type, e.g. `-> int!` or `-> void!`"));
                }
                let t = self.expr(value, Some(&Type::Str));
                if !matches!(t, Type::Str | Type::Error | Type::Unknown) {
                    self.err(Diagnostic::new("E0102", format!("`fail` takes a message or an error, found `{t}`"), value.span)
                        .help("write `fail \"something went wrong\"`"));
                }
            }
            StmtKind::Fork(body) => {
                // The block starts running right away, as part of the enclosing body.
                self.forks += 1;
                let key = format!("fork:{}", self.forks);
                let parent = self.cur().key.clone();
                self.async_info.entry(parent).or_default().inline.push(key.clone());
                self.push_ctx(CtxKind::Fork, key, Type::Void, false);
                self.block(body);
                self.ctx.pop();
            }
            StmtKind::Send { chan, value } => {
                let chan_ty = self.expr(chan, None);
                match chan_ty {
                    Type::Chan(elem) => {
                        let found = self.expr(value, Some(&elem));
                        self.require(&found, &elem, value);
                    }
                    Type::Unknown => {
                        self.expr(value, None);
                    }
                    other => {
                        self.expr(value, None);
                        self.err(Diagnostic::new("E0300", format!("cannot send to `{other}`"), chan.span)
                            .label("not a channel"));
                    }
                }
                self.mark_async();
            }
            StmtKind::Block(b) => self.block(b),
        }
    }

    fn assign_target(&mut self, target: &Expr) -> Type {
        match &target.kind {
            ExprKind::Ident(name) => match self.lookup(name) {
                Some(var) => {
                    self.use_global(name);
                    if !var.mutable {
                        self.err(Diagnostic::new("E0108", format!("cannot assign to `{name}`"), target.span)
                            .label("this is a constant")
                            .help(format!("declare it with `var {name} = ...` to make it changeable")));
                    }
                    self.an.types.insert(target.id, var.ty.clone());
                    var.ty
                }
                None => self.expr(target, None),
            },
            ExprKind::Field { .. } => self.expr(target, None),
            ExprKind::Index { obj, .. } => {
                let ty = self.expr(target, None);
                if self.an.types.get(&obj.id) == Some(&Type::Str) {
                    self.err(Diagnostic::new("E0108", "strings cannot be modified in place", target.span)
                        .help("build a new string instead"));
                }
                ty
            }
            _ => {
                self.expr(target, None);
                self.err(Diagnostic::new("E0108", "this expression cannot be assigned to", target.span)
                    .help("only variables, fields and indexed elements can be assigned"));
                Type::Unknown
            }
        }
    }

    // ---- expressions ----

    fn expr(&mut self, e: &Expr, expected: Option<&Type>) -> Type {
        let ty = self.expr_inner(e, expected);
        self.an.types.insert(e.id, ty.clone());
        ty
    }

    fn expr_inner(&mut self, e: &Expr, expected: Option<&Type>) -> Type {
        match &e.kind {
            ExprKind::Int(_) => Type::Int,
            ExprKind::Float(_) => Type::Float,
            ExprKind::Bool(_) => Type::Bool,
            ExprKind::Str(parts) => {
                for part in parts {
                    if let StrPart::Expr(inner) = part {
                        if self.expr(inner, None) == Type::Void {
                            self.err(Diagnostic::new("E0102", "this expression does not produce a value", inner.span));
                        }
                    }
                }
                Type::Str
            }
            ExprKind::Ident(name) => {
                let hidden = name.starts_with("__")
                    && !self.runtime.is_some_and(|(start, end)| e.span.start >= start && e.span.end <= end);
                if hidden {
                    self.err(Diagnostic::new("E0100", format!("unknown name `{name}`"), e.span)
                        .label("not found in this scope")
                        .help("names starting with `__` are reserved for the Onyx runtime"));
                    return Type::Unknown;
                }
                if let Some(var) = self.lookup(name) {
                    self.use_global(name);
                    return var.ty;
                }
                if let Some(sig) = self.fns.get(name).cloned() {
                    self.escaping.push(fn_key(name));
                    return Type::Fn(sig);
                }
                let d = if self.global_names.contains_key(name) {
                    Diagnostic::new("E0118", format!("`{name}` is used before it has a value"), e.span)
                        .label(format!("`{name}` is declared further down"))
                        .help(format!("top-level variables get their values from top to bottom, imported files first; move the declaration of `{name}` above this line"))
                } else if is_builtin(name) {
                    Diagnostic::new("E0100", format!("built-in function `{name}` can only be called"), e.span)
                        .help(format!("write `{name}(...)`, or wrap it in a lambda"))
                } else if self.structs.contains_key(name) || self.interfaces.contains_key(name) {
                    Diagnostic::new("E0100", format!("`{name}` is a type, not a value"), e.span)
                } else {
                    let mut d = Diagnostic::new("E0100", format!("unknown name `{name}`"), e.span)
                        .label("not found in this scope");
                    if matches!(name.as_str(), "nil" | "null" | "None" | "undefined") {
                        d = d.help("Onyx has no null value; functions that may have no result return an error instead (`-> T!`)");
                    } else if name == "this" {
                        d = d.help("use `self` inside methods");
                    }
                    d
                };
                self.err(d);
                Type::Unknown
            }
            ExprKind::List(items) => {
                let want = match expected {
                    Some(Type::List(t)) => Some((**t).clone()),
                    _ => None,
                };
                if items.is_empty() {
                    return match want {
                        Some(t) => Type::List(Box::new(t)),
                        None => {
                            self.err(Diagnostic::new("E0110", "cannot infer the type of this empty list", e.span)
                                .help("add a type annotation: `var items: [string] = []`"));
                            Type::List(Box::new(Type::Unknown))
                        }
                    };
                }
                let elem = self.unify_items(items.iter(), want);
                Type::List(Box::new(elem))
            }
            ExprKind::Map(entries) => {
                let want = match expected {
                    Some(Type::Map(k, v)) => Some(((**k).clone(), (**v).clone())),
                    _ => None,
                };
                if entries.is_empty() {
                    return match want {
                        Some((k, v)) => Type::Map(Box::new(k), Box::new(v)),
                        None => {
                            self.err(Diagnostic::new("E0110", "cannot infer the type of this empty map", e.span)
                                .help("add a type annotation: `var ages: map<string, int> = {}`"));
                            Type::Map(Box::new(Type::Unknown), Box::new(Type::Unknown))
                        }
                    };
                }
                let (wk, wv) = match want {
                    Some((k, v)) => (Some(k), Some(v)),
                    None => (None, None),
                };
                let key = self.unify_items(entries.iter().map(|(k, _)| k), wk);
                let value = self.unify_items(entries.iter().map(|(_, v)| v), wv);
                self.check_map_key(&key, entries[0].0.span);
                Type::Map(Box::new(key), Box::new(value))
            }
            ExprKind::StructLit { name, name_span, fields } => {
                let Some(info) = self.structs.get(name).cloned() else {
                    for f in fields {
                        self.expr(&f.value, None);
                    }
                    self.err(Diagnostic::new("E0101", format!("unknown struct `{name}`"), *name_span));
                    return Type::Unknown;
                };
                let mut seen: HashSet<&str> = HashSet::new();
                for f in fields {
                    match info.fields.iter().find(|(n, _)| n == &f.name) {
                        Some((_, fty)) => {
                            let found = self.expr(&f.value, Some(fty));
                            self.require(&found, fty, &f.value);
                            if !seen.insert(&f.name) {
                                self.err(Diagnostic::new("E0112", format!("field `{}` is set twice", f.name), f.name_span));
                            }
                        }
                        None => {
                            self.expr(&f.value, None);
                            let names: Vec<&str> = info.fields.iter().map(|(n, _)| n.as_str()).collect();
                            self.err(Diagnostic::new("E0112", format!("struct `{name}` has no field `{}`", f.name), f.name_span)
                                .help(format!("available fields: {}", names.join(", "))));
                        }
                    }
                }
                let missing: Vec<&str> = info
                    .fields
                    .iter()
                    .map(|(n, _)| n.as_str())
                    .filter(|n| !seen.contains(n))
                    .collect();
                if !missing.is_empty() {
                    self.err(Diagnostic::new("E0112", format!("missing field(s) in `{name}`: {}", missing.join(", ")), e.span)
                        .help("every field must be given a value"));
                }
                Type::Struct(name.clone())
            }
            ExprKind::Unary { op, expr } => {
                let t = self.expr(expr, expected);
                match op {
                    UnOp::Neg if t.is_numeric() || t.is_unknown() => t,
                    UnOp::Not if t == Type::Bool || t.is_unknown() => Type::Bool,
                    UnOp::Neg => {
                        self.err(Diagnostic::new("E0107", format!("cannot negate `{t}`"), e.span));
                        Type::Unknown
                    }
                    UnOp::Not => {
                        self.err(Diagnostic::new("E0107", format!("`!` needs a bool, found `{t}`"), e.span));
                        Type::Bool
                    }
                }
            }
            ExprKind::Binary { op, lhs, rhs } => self.binary(e, *op, lhs, rhs),
            ExprKind::Call { callee, args } => {
                let (ty, fallible) = self.call(e, callee, args, expected);
                if fallible {
                    self.an.fallible_calls.insert(e.id);
                }
                let handled = self.handling.remove(&e.id);
                if fallible && !handled {
                    let name = self.text(callee.span).to_string();
                    self.err(Diagnostic::new("E0200", format!("`{name}()` can fail"), e.span)
                        .label("this call may return an error")
                        .help("handle it with `?`, `or`, or `catch`"));
                } else if !fallible && handled && !ty.is_unknown() {
                    let name = self.text(callee.span).to_string();
                    self.err(Diagnostic::new("E0202", format!("`{name}()` cannot fail"), e.span)
                        .label("there is no error to handle here"));
                }
                ty
            }
            ExprKind::Field { obj, name, name_span } => {
                let obj_ty = self.expr(obj, None);
                match &obj_ty {
                    Type::Struct(s) => {
                        let info = &self.structs[s];
                        if let Some((_, ty)) = info.fields.iter().find(|(n, _)| n == name) {
                            return ty.clone();
                        }
                        let d = if info.methods.contains_key(name) {
                            Diagnostic::new("E0106", format!("`{name}` is a method and must be called"), *name_span)
                                .help(format!("write `.{name}(...)`"))
                        } else {
                            let names: Vec<&str> = info.fields.iter().map(|(n, _)| n.as_str()).collect();
                            Diagnostic::new("E0106", format!("`{s}` has no field `{name}`"), *name_span)
                                .help(format!("available fields: {}", names.join(", ")))
                        };
                        self.err(d);
                        Type::Unknown
                    }
                    Type::Error if name == "message" => Type::Str,
                    Type::Unknown => Type::Unknown,
                    other => {
                        let mut d = Diagnostic::new("E0106", format!("`{other}` has no field `{name}`"), *name_span);
                        if matches!(name.as_str(), "len" | "length" | "size") {
                            d = d.help("use the method `.len()`");
                        }
                        self.err(d);
                        Type::Unknown
                    }
                }
            }
            ExprKind::Index { obj, index } => {
                let obj_ty = self.expr(obj, None);
                match obj_ty {
                    Type::List(elem) => {
                        let it = self.expr(index, Some(&Type::Int));
                        self.require(&it, &Type::Int, index);
                        *elem
                    }
                    Type::Str => {
                        let it = self.expr(index, Some(&Type::Int));
                        self.require(&it, &Type::Int, index);
                        Type::Str
                    }
                    Type::Map(k, v) => {
                        let it = self.expr(index, Some(&k));
                        self.require(&it, &k, index);
                        *v
                    }
                    Type::Unknown => {
                        self.expr(index, None);
                        Type::Unknown
                    }
                    other => {
                        self.expr(index, None);
                        self.err(Diagnostic::new("E0115", format!("cannot index into `{other}`"), obj.span));
                        Type::Unknown
                    }
                }
            }
            ExprKind::Lambda { params, ret, fallible, body } => {
                let sig = self.signature(params, ret, *fallible);
                self.push_ctx(CtxKind::Fn, lambda_key(e.id), sig.ret.clone(), sig.fallible);
                self.scopes.push(HashMap::new());
                for (p, ty) in params.iter().zip(sig.params.iter()) {
                    self.declare(&p.name, ty.clone(), true, p.span);
                }
                for stmt in &body.stmts {
                    self.stmt(stmt);
                }
                if sig.ret != Type::Void && !sig.ret.is_unknown() && !exits(body, false) {
                    self.err(Diagnostic::new("E0109", "this function does not return a value on every path", e.span)
                        .label(format!("must return `{}`", sig.ret)));
                }
                self.scopes.pop();
                self.ctx.pop();
                self.escaping.push(lambda_key(e.id));
                Type::Fn(sig)
            }
            ExprKind::Try(inner) => {
                if !self.handleable(inner, "?") {
                    return self.expr(inner, expected);
                }
                if !self.cur().fallible {
                    let help = match self.cur().kind {
                        CtxKind::Fork => "a `fork` block has no caller to pass the error to; use `or` or `catch`",
                        CtxKind::Check => "inside a `check` block, use `or` or `catch`",
                        CtxKind::Global => "use `or` to provide a default value",
                        CtxKind::Fn => "add `!` to this function's return type (e.g. `-> int!`), or use `or` / `catch`",
                    };
                    self.err(Diagnostic::new("E0201", "`?` used in a function that cannot fail", e.span).help(help));
                }
                self.handling.insert(inner.id);
                self.expr(inner, expected)
            }
            ExprKind::Or { expr, default } => {
                if !self.handleable(expr, "or") {
                    self.expr(default, None);
                    return self.expr(expr, expected);
                }
                self.handling.insert(expr.id);
                let ty = self.expr(expr, expected);
                if ty == Type::Void {
                    self.expr(default, None);
                    self.err(Diagnostic::new("E0102", "`or` needs a call that returns a value", expr.span)
                        .label("returns nothing")
                        .help("use `catch err { ... }` to handle the error of a call without a result"));
                    return Type::Void;
                }
                let d = self.expr(default, Some(&ty));
                self.require(&d, &ty, default);
                ty
            }
            ExprKind::Catch { expr, name, name_span, body } => {
                let slot = self.catch_slot.take();
                let needs_value = match slot {
                    Some((id, needs)) if id == e.id => needs,
                    _ => {
                        self.err(Diagnostic::new("E0205", "`catch` cannot be used inside a larger expression", e.span)
                            .help("use it directly in a `var`, an assignment, a `return` or as a statement; inside expressions use `or`"));
                        false
                    }
                };
                let ty = if self.handleable(expr, "catch") {
                    self.handling.insert(expr.id);
                    self.expr(expr, expected)
                } else {
                    self.expr(expr, expected)
                };
                self.scopes.push(HashMap::new());
                self.declare(name, Type::Error, false, *name_span);
                for stmt in &body.stmts {
                    self.stmt(stmt);
                }
                self.scopes.pop();
                if needs_value && ty != Type::Void && !ty.is_unknown() && !exits(body, true) {
                    let last_ty = match body.stmts.last() {
                        Some(Stmt { kind: StmtKind::Expr(last), .. }) => self.an.types.get(&last.id).cloned(),
                        _ => None,
                    };
                    match last_ty {
                        Some(t) if t != Type::Void && self.assignable(&t, &ty) => {
                            if let (Type::Int, Type::Float, Some(Stmt { kind: StmtKind::Expr(last), .. })) = (&t, &ty, body.stmts.last()) {
                                self.an.widened.insert(last.id);
                            }
                            self.an.catch_values.insert(e.id);
                        }
                        Some(t) if t != Type::Void => {
                            let span = body.stmts.last().unwrap().span;
                            self.mismatch(&ty, &t, span);
                        }
                        _ => self.err(Diagnostic::new(
                            "E0204",
                            format!("this `catch` block must produce a `{ty}` or leave the function"),
                            body.span,
                        )
                        .help("end the block with a value, or with `return`, `fail`, `break` or `continue`")),
                    }
                }
                ty
            }
            ExprKind::Recv(inner) => {
                self.mark_async();
                match self.expr(inner, None) {
                    Type::Chan(elem) => *elem,
                    Type::Unknown => Type::Unknown,
                    other => {
                        self.err(Diagnostic::new("E0300", format!("cannot receive from `{other}`"), inner.span)
                            .label("not a channel"));
                        Type::Unknown
                    }
                }
            }
            ExprKind::ChanNew { elem, cap } => {
                let elem = self.resolve(elem);
                if let Some(cap) = cap {
                    let t = self.expr(cap, Some(&Type::Int));
                    self.require(&t, &Type::Int, cap);
                }
                Type::Chan(Box::new(elem))
            }
            ExprKind::Range { lo, hi } => {
                for bound in [lo, hi] {
                    let t = self.expr(bound, Some(&Type::Int));
                    self.require(&t, &Type::Int, bound);
                }
                Type::Range
            }
        }
    }

    /// `?`, `or` and `catch` only make sense on a call.
    fn handleable(&mut self, inner: &Expr, what: &str) -> bool {
        if matches!(inner.kind, ExprKind::Call { .. }) {
            return true;
        }
        self.err(Diagnostic::new("E0202", format!("`{what}` has no error to handle here"), inner.span)
            .label("this expression cannot fail")
            .help("`or` and `catch` apply to everything on their left; use parentheses, e.g. `1 + (parse_int(s) or 0)`"));
        false
    }

    /// Checks list items / map keys / map values and returns their common type.
    fn unify_items<'e>(&mut self, items: impl Iterator<Item = &'e Expr>, want: Option<Type>) -> Type {
        let mut elem = want.clone();
        let items: Vec<&Expr> = items.collect();
        for &item in &items {
            let found = self.expr(item, elem.as_ref());
            match &elem {
                None => elem = Some(found),
                Some(current) => {
                    if self.assignable(&found, current) {
                        continue;
                    }
                    // `[1, 2.5]` widens to float when no type was requested.
                    if want.is_none() && self.assignable(current, &found) {
                        elem = Some(found);
                    } else {
                        let current = current.clone();
                        self.mismatch(&current, &found, item.span);
                    }
                }
            }
        }
        if elem == Some(Type::Float) {
            // The ints among them become floats, also those seen before the
            // first float.
            for item in items {
                if self.an.types.get(&item.id) == Some(&Type::Int) {
                    self.an.widened.insert(item.id);
                }
            }
        }
        elem.unwrap_or(Type::Unknown)
    }

    fn binary(&mut self, e: &Expr, op: BinOp, lhs: &Expr, rhs: &Expr) -> Type {
        let l = self.expr(lhs, None);
        let r = self.expr(rhs, Some(&l));
        if l.is_unknown() || r.is_unknown() {
            return match op {
                BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod => Type::Unknown,
                _ => Type::Bool,
            };
        }
        let numeric = l.is_numeric() && r.is_numeric();
        if numeric && !matches!(op, BinOp::And | BinOp::Or) {
            // In `2 * x` with a float `x`, the 2 is a float too.
            self.widen(&l, &r, lhs);
            self.widen(&r, &l, rhs);
        }
        let result = match op {
            BinOp::Add if l == Type::Str && r == Type::Str => Some(Type::Str),
            BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod if numeric => {
                Some(if l == Type::Int && r == Type::Int { Type::Int } else { Type::Float })
            }
            BinOp::Eq | BinOp::NotEq
                if (self.assignable(&l, &r) || self.assignable(&r, &l)) && !matches!(l, Type::Fn(_) | Type::Void) =>
            {
                Some(Type::Bool)
            }
            BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge if numeric || (l == Type::Str && r == Type::Str) => {
                Some(Type::Bool)
            }
            BinOp::And | BinOp::Or if l == Type::Bool && r == Type::Bool => Some(Type::Bool),
            _ => None,
        };
        if let Some(t) = result {
            return t;
        }
        let mut d = Diagnostic::new(
            "E0107",
            format!("cannot apply `{}` to `{l}` and `{r}`", op.symbol()),
            e.span,
        );
        if op == BinOp::Add && (l == Type::Str || r == Type::Str) {
            d = d.help("to build a string, use interpolation: \"total: {n}\"");
        }
        self.err(d);
        match op {
            BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod => Type::Unknown,
            _ => Type::Bool,
        }
    }

    // ---- calls ----

    fn args(&mut self, params: &[Type], args: &[Expr], call: &Expr, what: &str) {
        if params.len() != args.len() {
            self.err(Diagnostic::new(
                "E0104",
                format!(
                    "{what} takes {} argument{} but {} {} given",
                    params.len(),
                    if params.len() == 1 { "" } else { "s" },
                    args.len(),
                    if args.len() == 1 { "was" } else { "were" }
                ),
                call.span,
            ));
        }
        for (i, arg) in args.iter().enumerate() {
            match params.get(i) {
                Some(p) => {
                    let found = self.expr(arg, Some(p));
                    self.require(&found, p, arg);
                }
                None => {
                    self.expr(arg, None);
                }
            }
        }
    }

    fn call(&mut self, e: &Expr, callee: &Expr, args: &[Expr], expected: Option<&Type>) -> (Type, bool) {
        match &callee.kind {
            ExprKind::Ident(name) if self.lookup(name).is_none() => {
                let internal = name.starts_with("__")
                    && !self.runtime.is_some_and(|(start, end)| e.span.start >= start && e.span.end <= end);
                if internal {
                    self.err(Diagnostic::new("E0100", format!("unknown function `{name}`"), callee.span)
                        .label("not found")
                        .help("names starting with `__` are reserved for the Onyx runtime"));
                    for a in args {
                        self.expr(a, None);
                    }
                    return (Type::Unknown, false);
                }
                if let Some(sig) = self.fns.get(name).cloned() {
                    self.args(&sig.params, args, e, &format!("`{name}`"));
                    self.an.calls.insert(e.id, CallKind::Fn(name.clone()));
                    self.add_call(fn_key(name));
                    return (sig.ret.clone(), sig.fallible);
                }
                if is_builtin(name) {
                    self.an.calls.insert(e.id, CallKind::Builtin(name.clone()));
                    return self.builtin_call(name, e, args);
                }
                let d = if self.structs.contains_key(name) {
                    Diagnostic::new("E0105", format!("`{name}` is a struct, not a function"), callee.span)
                        .help(format!("create one with `{name}{{field: value, ...}}`"))
                } else {
                    Diagnostic::new("E0100", format!("unknown function `{name}`"), callee.span)
                        .label("not found")
                };
                self.err(d);
                for a in args {
                    self.expr(a, None);
                }
                (Type::Unknown, false)
            }
            ExprKind::Field { obj, name, name_span } => {
                let obj_ty = self.expr(obj, None);
                match &obj_ty {
                    Type::Struct(s) => {
                        let info = &self.structs[s];
                        if let Some(sig) = info.methods.get(name).cloned() {
                            self.args(&sig.params, args, e, &format!("`{name}`"));
                            self.an.calls.insert(e.id, CallKind::Method(s.clone(), name.clone()));
                            self.add_call(method_key(s, name));
                            return (sig.ret.clone(), sig.fallible);
                        }
                        if let Some((_, Type::Fn(sig))) = info.fields.iter().find(|(n, _)| n == name).cloned() {
                            return self.dynamic_call(e, &sig, args, name, false);
                        }
                        let mut names: Vec<&str> = info.methods.keys().map(|k| k.as_str()).collect();
                        names.sort();
                        let mut d = Diagnostic::new("E0106", format!("`{s}` has no method `{name}`"), *name_span);
                        if !names.is_empty() {
                            d = d.help(format!("available methods: {}", names.join(", ")));
                        }
                        self.err(d);
                    }
                    Type::Interface(i) => {
                        let sig = self.interfaces[i].methods.iter().find(|(n, _)| n == name).map(|(_, s)| s.clone());
                        if let Some(sig) = sig {
                            return self.dynamic_call(e, &sig, args, name, true);
                        }
                        self.err(Diagnostic::new("E0106", format!("interface `{i}` has no method `{name}`"), *name_span));
                    }
                    Type::Str | Type::List(_) | Type::Map(..) | Type::Chan(_) => {
                        return self.builtin_method(e, &obj_ty, name, *name_span, args, expected);
                    }
                    Type::Unknown => {}
                    other => {
                        self.err(Diagnostic::new("E0106", format!("`{other}` has no method `{name}`"), *name_span));
                    }
                }
                for a in args {
                    self.expr(a, None);
                }
                (Type::Unknown, false)
            }
            _ => {
                let callee_ty = self.expr(callee, None);
                match callee_ty {
                    Type::Fn(sig) => {
                        let what = self.text(callee.span).to_string();
                        self.dynamic_call(e, &sig, args, &what, false)
                    }
                    other => {
                        if !other.is_unknown() {
                            self.err(Diagnostic::new("E0105", format!("`{other}` is not a function"), callee.span)
                                .label("cannot be called"));
                        }
                        for a in args {
                            self.expr(a, None);
                        }
                        (Type::Unknown, false)
                    }
                }
            }
        }
    }

    /// A call whose target is only known when the program runs: a function
    /// value, or (`interface_method`) a method called through an interface.
    fn dynamic_call(
        &mut self,
        e: &Expr,
        sig: &Rc<FnSig>,
        args: &[Expr],
        what: &str,
        interface_method: bool,
    ) -> (Type, bool) {
        self.args(&sig.params, args, e, &format!("`{what}`"));
        self.an.calls.insert(e.id, CallKind::Dynamic);
        self.mark_async();
        let key = self.cur().key.clone();
        let info = self.async_info.entry(key).or_default();
        if interface_method {
            info.interface_calls.push(what.to_string());
        } else {
            info.dynamic = true;
        }
        (sig.ret.clone(), sig.fallible)
    }

    fn builtin_call(&mut self, name: &str, e: &Expr, args: &[Expr]) -> (Type, bool) {
        if let Some((params, ret, fallible, is_async)) = builtin_sig(name) {
            self.args(&params, args, e, &format!("`{name}`"));
            if is_async {
                self.mark_async();
            }
            return (ret, fallible);
        }
        let arg_types: Vec<Type> = args.iter().map(|a| self.expr(a, None)).collect();
        let arity = |c: &mut Self, n: usize| {
            if args.len() != n {
                c.err(Diagnostic::new(
                    "E0104",
                    format!("`{name}` takes {n} argument{} but {} were given", if n == 1 { "" } else { "s" }, args.len()),
                    e.span,
                ));
                false
            } else {
                true
            }
        };
        let numeric = |c: &mut Self, i: usize| {
            let t = &arg_types[i];
            if !t.is_numeric() && !t.is_unknown() {
                c.err(Diagnostic::new("E0102", format!("`{name}` needs a number, found `{t}`"), args[i].span));
            }
        };
        match name {
            "print" => {
                for (t, a) in arg_types.iter().zip(args) {
                    if *t == Type::Void {
                        self.err(Diagnostic::new("E0102", "this expression does not produce a value", a.span));
                    }
                }
                (Type::Void, false)
            }
            "str" => {
                arity(self, 1);
                (Type::Str, false)
            }
            "int" | "float" => {
                if arity(self, 1) {
                    let t = &arg_types[0];
                    if *t == Type::Str {
                        self.err(Diagnostic::new("E0102", format!("`{name}()` converts numbers, found `string`"), args[0].span)
                            .help(format!("to read a number from text use `parse_{name}(s)`, which can fail")));
                    } else {
                        numeric(self, 0);
                    }
                }
                (if name == "int" { Type::Int } else { Type::Float }, false)
            }
            "abs" => {
                if arity(self, 1) {
                    numeric(self, 0);
                    return (arg_types[0].clone(), false);
                }
                (Type::Unknown, false)
            }
            "min" | "max" => {
                if arity(self, 2) {
                    numeric(self, 0);
                    numeric(self, 1);
                    let both_int = arg_types[0] == Type::Int && arg_types[1] == Type::Int;
                    if !both_int {
                        self.widen(&arg_types[0], &Type::Float, &args[0]);
                        self.widen(&arg_types[1], &Type::Float, &args[1]);
                    }
                    return (if both_int { Type::Int } else { Type::Float }, false);
                }
                (Type::Unknown, false)
            }
            _ => (Type::Unknown, false),
        }
    }

    fn builtin_method(
        &mut self,
        e: &Expr,
        recv: &Type,
        name: &str,
        name_span: Span,
        args: &[Expr],
        _expected: Option<&Type>,
    ) -> (Type, bool) {
        use Type::*;
        let list = |t: &Type| List(Box::new(t.clone()));
        // (receiver kind, parameters, return type, can fail, is async)
        let found: Option<(Recv, Vec<Type>, Type, bool, bool)> = match recv {
            Str => {
                let m = match name {
                    "len" => Some((vec![], Int)),
                    "upper" | "lower" | "trim" => Some((vec![], Str)),
                    "split" => Some((vec![Str], list(&Str))),
                    "contains" | "starts_with" | "ends_with" => Some((vec![Str], Bool)),
                    "replace" => Some((vec![Str, Str], Str)),
                    "index_of" => Some((vec![Str], Int)),
                    "slice" => Some((vec![Int, Int], Str)),
                    "chars" => Some((vec![], list(&Str))),
                    "repeat" => Some((vec![Int], Str)),
                    _ => None,
                };
                m.map(|(p, r)| (Recv::Str, p, r, false, false))
            }
            List(elem) => {
                let t = (**elem).clone();
                let sortable = matches!(t, Int | Float | Str | Unknown);
                let m = match name {
                    "len" => Some((vec![], Int, false, false)),
                    "push" => Some((vec![t.clone()], Void, false, false)),
                    "pop" | "first" | "last" => Some((vec![], t.clone(), true, false)),
                    "contains" => Some((vec![t.clone()], Bool, false, false)),
                    "index_of" => Some((vec![t.clone()], Int, false, false)),
                    "reverse" => Some((vec![], list(&t), false, false)),
                    "slice" => Some((vec![Int, Int], list(&t), false, false)),
                    "insert" => Some((vec![Int, t.clone()], Void, false, false)),
                    "remove" => Some((vec![Int], t.clone(), false, false)),
                    "clear" => Some((vec![], Void, false, false)),
                    "join" => Some((vec![Str], Str, false, false)),
                    "sort" => {
                        if !sortable {
                            self.err(Diagnostic::new("E0102", format!("cannot sort a list of `{t}`"), name_span)
                                .help("`.sort()` works on int, float and string; use `.sort_by(fn(x: T) -> int { ... })` for other types"));
                        }
                        Some((vec![], list(&t), false, false))
                    }
                    "filter" => {
                        let f = Fn(Rc::new(FnSig { params: vec![t.clone()], ret: Bool, fallible: false }));
                        Some((vec![f], list(&t), false, true))
                    }
                    "map" | "sort_by" => {
                        // The callback's return type is inferred from the argument.
                        self.an.calls.insert(e.id, CallKind::BuiltinMethod(Recv::List, name.to_string()));
                        self.mark_async();
                        if args.len() != 1 {
                            self.err(Diagnostic::new("E0104", format!("`{name}` takes 1 argument but {} were given", args.len()), e.span));
                            for a in args {
                                self.expr(a, None);
                            }
                            return (Unknown, false);
                        }
                        let ft = self.expr(&args[0], None);
                        self.callback(&args[0]);
                        let ret = match &ft {
                            Fn(sig) if sig.params.len() == 1 && !sig.fallible && self.assignable(&t, &sig.params[0]) => {
                                sig.ret.clone()
                            }
                            Unknown => Unknown,
                            other => {
                                let other = other.clone();
                                self.err(Diagnostic::new(
                                    "E0102",
                                    format!("`{name}` needs a function taking one `{t}`, found `{other}`"),
                                    args[0].span,
                                ));
                                Unknown
                            }
                        };
                        if name == "map" {
                            if ret == Void {
                                self.err(Diagnostic::new("E0102", "the function given to `map` must return a value", args[0].span));
                            }
                            return (list(&ret), false);
                        }
                        if !matches!(ret, Int | Float | Str | Unknown) {
                            self.err(Diagnostic::new("E0102", format!("`sort_by` needs a function returning int, float or string, found `{ret}`"), args[0].span));
                        }
                        return (list(&t), false);
                    }
                    _ => None,
                };
                m.map(|(p, r, f, a)| (Recv::List, p, r, f, a))
            }
            Map(k, v) => {
                let (k, v) = ((**k).clone(), (**v).clone());
                let m = match name {
                    "len" => Some((vec![], Int, false)),
                    "get" => Some((vec![k.clone()], v.clone(), true)),
                    "has" => Some((vec![k.clone()], Bool, false)),
                    "remove" => Some((vec![k.clone()], Void, false)),
                    "keys" => Some((vec![], list(&k), false)),
                    "values" => Some((vec![], list(&v), false)),
                    "clear" => Some((vec![], Void, false)),
                    _ => None,
                };
                m.map(|(p, r, f)| (Recv::Map, p, r, f, false))
            }
            Chan(_) => match name {
                "close" => Some((Recv::Chan, vec![], Void, false, false)),
                _ => None,
            },
            _ => None,
        };
        match found {
            Some((kind, params, ret, fallible, is_async)) => {
                self.args(&params, args, e, &format!("`{name}`"));
                if kind == Recv::List && name == "filter" && args.len() == 1 {
                    self.callback(&args[0]);
                }
                self.an.calls.insert(e.id, CallKind::BuiltinMethod(kind, name.to_string()));
                if is_async {
                    self.mark_async();
                }
                (ret, fallible)
            }
            None => {
                for a in args {
                    self.expr(a, None);
                }
                let mut d = Diagnostic::new("E0106", format!("`{recv}` has no method `{name}`"), name_span);
                if matches!(name, "length" | "size" | "count") {
                    d = d.help("use `.len()`");
                } else if matches!(name, "append" | "add") && matches!(recv, List(_)) {
                    d = d.help("use `.push(value)`");
                }
                self.err(d);
                (Unknown, false)
            }
        }
    }
}

/// Does this block always leave: by `return` / `fail` / a diverging call, or,
/// when `allow_jump` is set, also by `break` / `continue`?
fn exits(block: &Block, allow_jump: bool) -> bool {
    block.stmts.iter().any(|s| stmt_exits(s, allow_jump))
}

fn stmt_exits(stmt: &Stmt, allow_jump: bool) -> bool {
    match &stmt.kind {
        StmtKind::Return(_) | StmtKind::Fail(_) => true,
        StmtKind::Break | StmtKind::Continue => allow_jump,
        StmtKind::Block(b) => exits(b, allow_jump),
        StmtKind::If { then, els: Some(els), .. } => exits(then, allow_jump) && stmt_exits(els, allow_jump),
        StmtKind::While { cond, body } => {
            matches!(cond.kind, ExprKind::Bool(true)) && !contains_break(body)
        }
        StmtKind::Expr(Expr { kind: ExprKind::Call { callee, .. }, .. }) => {
            matches!(&callee.kind, ExprKind::Ident(n) if n == "panic" || n == "exit")
        }
        _ => false,
    }
}

fn contains_break(block: &Block) -> bool {
    block.stmts.iter().any(|s| match &s.kind {
        StmtKind::Break => true,
        StmtKind::Block(b) => contains_break(b),
        StmtKind::If { then, els, .. } => {
            contains_break(then)
                || els.as_ref().is_some_and(|e| match &e.kind {
                    StmtKind::Block(b) => contains_break(b),
                    StmtKind::If { .. } => contains_break(&Block { stmts: vec![(**e).clone()], span: e.span }),
                    _ => false,
                })
        }
        _ => false,
    })
}
