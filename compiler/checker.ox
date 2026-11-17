// The type checker. Verifies the program and records what the code
// generators need to know: the type of every expression, what each call
// calls, which bodies of code may wait (and so must run as tasks).
//
// It follows src/checker.rs function by function, so that both report the
// same problems with the same words.

import "ast"
import "diag"
import "lexer"

// ---- types ----

struct FnSig {
    params: [Type]
    ret: Type
    fallible: bool
}

enum Type {
    Int
    Float
    Bool
    Str
    Void
    Error
    List(Type)
    Map(key: Type, value: Type)
    Chan(Type)
    // A reference that does not keep its object alive.
    Weak(Type)
    // A value that is one of several variants.
    Enum(string)
    Struct(string)
    Interface(string)
    Fn(FnSig)
    Range
    // Produced after an error was reported; silences follow-up errors.
    Unknown
}

// A type as messages show it.
fn show(t: Type) -> string {
    match t {
        Int {
            return "int"
        }
        Float {
            return "float"
        }
        Bool {
            return "bool"
        }
        Str {
            return "string"
        }
        Void {
            return "void"
        }
        Error {
            return "error"
        }
        List(elem) {
            return "[" + show(elem) + "]"
        }
        Map(key, value) {
            return "map<" + show(key) + ", " + show(value) + ">"
        }
        Chan(elem) {
            return "chan<" + show(elem) + ">"
        }
        Weak(elem) {
            return "weak<" + show(elem) + ">"
        }
        Enum(name) {
            return name
        }
        Struct(name) {
            return name
        }
        Interface(name) {
            return name
        }
        Fn(sig) {
            return show_sig(sig)
        }
        Range {
            return "range"
        }
        Unknown {
            return "?"
        }
    }
}

fn show_sig(sig: FnSig) -> string {
    var out = "fn(" + sig.params.map(show).join(", ") + ")"
    if sig.ret != Type.Void || sig.fallible {
        out += " -> " + show(sig.ret)
    }
    if sig.fallible {
        out += "!"
    }
    return out
}

fn is_numeric(t: Type) -> bool {
    return t == Type.Int || t == Type.Float
}

fn is_unknown(t: Type) -> bool {
    return t == Type.Unknown
}

fn is_fn(t: Type) -> bool {
    match t {
        Fn(_) {
            return true
        }
        else {
            return false
        }
    }
}

// ---- what the checker finds out ----

struct Field {
    name: string
    ty: Type
}

struct StructInfo {
    fields: [Field]
    methods: map<string, FnSig>
}

struct Method {
    name: string
    sig: FnSig
}

struct InterfaceInfo {
    methods: [Method]
}

struct Variant {
    name: string
    fields: [Type]
}

// A variant of an enum: which enum, and its position (-1: none).
struct VariantRef {
    enum_name: string
    index: int
}

enum Recv {
    Str
    List
    Map
    Chan
    Weak
}

// What a call expression calls.
enum CallKind {
    // A top-level function.
    Fn(string)
    // A method on a struct.
    Method(strukt: string, name: string)
    // A built-in function such as `print`.
    Builtin(string)
    // A method on a built-in type such as `list.push`.
    BuiltinMethod(recv: Recv, name: string)
    // A function value or a method called through an interface: only known
    // when the program runs.
    Dynamic
}

struct Analysis {
    types: map<int, Type>
    calls: map<int, CallKind>
    // Keys (see `fn_key` etc.) of the bodies that may wait, and so must be
    // compiled as tasks.
    async_keys: map<string, bool>
    structs: map<string, StructInfo>
    // Signatures of the top-level functions.
    fns: map<string, FnSig>
    // `catch` expressions whose block ends with a value.
    catch_values: map<int, bool>
    // Calls that can fail.
    fallible_calls: map<int, bool>
    // Expressions of type `int` whose value is used as a `float`.
    widened: map<int, bool>
    // The variants of each enum, with the types of what they carry.
    enums: map<string, [Variant]>
    // Expressions that make a value of an enum.
    variants: map<int, VariantRef>
}

fn fn_key(name: string) -> string {
    return "fn:" + name
}

fn method_key(strukt: string, name: string) -> string {
    return "m:" + strukt + "." + name
}

fn lambda_key(id: int) -> string {
    return "lambda:" + str(id)
}

// ---- built-in functions ----

struct BuiltinSig {
    params: [Type]
    ret: Type
    fallible: bool
    is_async: bool
}

fn bsig(params: [Type], ret: Type, fallible: bool, is_async: bool) -> BuiltinSig {
    return BuiltinSig{params: params, ret: ret, fallible: fallible, is_async: is_async}
}

// The built-in functions with a fixed signature.
fn builtin_sig(name: string) -> BuiltinSig! {
    var i = Type.Int
    var s = Type.Str
    var f = Type.Float
    var none: [Type] = []
    match name {
        "parse_int" {
            return bsig([s], i, true, false)
        }
        "parse_float" {
            return bsig([s], f, true, false)
        }
        "read_file" {
            return bsig([s], s, true, false)
        }
        "write_file", "append_file" {
            return bsig([s, s], Type.Void, true, false)
        }
        "file_exists" {
            return bsig([s], Type.Bool, false, false)
        }
        "args" {
            return bsig(none, Type.List(s), false, false)
        }
        "env" {
            return bsig([s], s, true, false)
        }
        "exit" {
            return bsig([i], Type.Void, false, false)
        }
        "sleep" {
            return bsig([i], Type.Void, false, true)
        }
        "now" {
            return bsig(none, i, false, false)
        }
        "random" {
            return bsig(none, f, false, false)
        }
        "random_int" {
            return bsig([i, i], i, false, false)
        }
        "input" {
            return bsig([s], s, false, false)
        }
        "fetch" {
            return bsig([s], s, true, true)
        }
        "expect" {
            return bsig([Type.Bool], Type.Void, false, false)
        }
        "panic" {
            return bsig([s], Type.Void, false, false)
        }
        "sqrt" {
            return bsig([f], f, false, false)
        }
        "bit_and", "bit_or", "bit_xor", "shift_left", "shift_right" {
            return bsig([i, i], i, false, false)
        }
        "bit_not" {
            return bsig([i], i, false, false)
        }
        "ord" {
            return bsig([s], i, false, false)
        }
        "chr" {
            return bsig([i], s, false, false)
        }
        "bytes" {
            return bsig([s], Type.List(i), false, false)
        }
        "from_bytes" {
            return bsig([Type.List(i)], s, false, false)
        }
        "read_bytes" {
            return bsig([s], Type.List(i), true, false)
        }
        "write_bytes" {
            return bsig([s, Type.List(i)], Type.Void, true, false)
        }
        "pow" {
            return bsig([f, f], f, false, false)
        }
        "floor", "ceil", "round" {
            return bsig([f], i, false, false)
        }
        // Low-level operations of the native runtime (see src/native/runtime.ox).
        "__syscall" {
            return bsig([i, i, i, i, i, i, i], i, false, false)
        }
        "__load8", "__load32", "__load64" {
            return bsig([i], i, false, false)
        }
        "__store8", "__store32", "__store64" {
            return bsig([i, i], Type.Void, false, false)
        }
        "__copy" {
            return bsig([i, i, i], Type.Void, false, false)
        }
        "__and", "__or", "__xor", "__shl", "__shr", "__sar", "__call1" {
            return bsig([i, i], i, false, false)
        }
        "__unwind", "__yield" {
            return bsig(none, Type.Void, false, false)
        }
        "__switch" {
            return bsig([i, i], Type.Void, false, false)
        }
        "__task_entry", "__fault_entry", "__state", "__td_string" {
            return bsig(none, i, false, false)
        }
        "__bits" {
            return bsig([f], i, false, false)
        }
        "__float" {
            return bsig([i], f, false, false)
        }
        "__str_ptr" {
            return bsig([s], i, false, false)
        }
        "__ptr_str" {
            return bsig([i], s, false, false)
        }
        else {
            fail "not a built-in function"
        }
    }
}

fn is_builtin(name: string) -> bool {
    if ["print", "str", "int", "float", "abs", "min", "max", "weak"].contains(name) {
        return true
    }
    builtin_sig(name) catch err {
        return false
    }
    return true
}

fn is_builtin_type(name: string) -> bool {
    return ["int", "float", "bool", "string", "void", "error", "map"].contains(name)
}

fn symbol(op: ast.BinOp) -> string {
    match op {
        Add {
            return "+"
        }
        Sub {
            return "-"
        }
        Mul {
            return "*"
        }
        Div {
            return "/"
        }
        Mod {
            return "%"
        }
        Eq {
            return "=="
        }
        NotEq {
            return "!="
        }
        Lt {
            return "<"
        }
        Le {
            return "<="
        }
        Gt {
            return ">"
        }
        Ge {
            return ">="
        }
        And {
            return "&&"
        }
        Or {
            return "||"
        }
    }
}

fn plural(n: int) -> string {
    if n == 1 {
        return ""
    }
    return "s"
}

// ---- does a block always leave? ----

// Does this block always leave: by `return` / `fail` / a call that never
// comes back, or, when `allow_jump` is set, also by `break` / `continue`?
fn exits(block: ast.Block, allow_jump: bool) -> bool {
    for s in block.stmts {
        if stmt_exits(s, allow_jump) {
            return true
        }
    }
    return false
}

fn stmt_exits(stmt: ast.Stmt, allow_jump: bool) -> bool {
    match stmt.kind {
        Return(_), Fail(_) {
            return true
        }
        Break, Continue {
            return allow_jump
        }
        Block(b) {
            return exits(b, allow_jump)
        }
        If(_, then, els) {
            if els.len() == 0 {
                return false
            }
            return exits(then, allow_jump) && stmt_exits(els[0], allow_jump)
        }
        // A `match` handles every case, so it leaves when all its cases do.
        Match(_, arms, default) {
            for arm in arms {
                if !exits(arm.body, allow_jump) {
                    return false
                }
            }
            for body in default {
                if !exits(body, allow_jump) {
                    return false
                }
            }
            return true
        }
        While(cond, body) {
            return cond.kind == ast.ExprKind.Bool(true) && !contains_break(body)
        }
        Expr(e) {
            match e.kind {
                Call(callee, _) {
                    match callee.kind {
                        Ident(name) {
                            return name == "panic" || name == "exit"
                        }
                        else {
                            return false
                        }
                    }
                }
                else {
                    return false
                }
            }
        }
        else {
            return false
        }
    }
}

fn contains_break(block: ast.Block) -> bool {
    for s in block.stmts {
        match s.kind {
            Break {
                return true
            }
            Block(b) {
                if contains_break(b) {
                    return true
                }
            }
            Match(_, arms, default) {
                for arm in arms {
                    if contains_break(arm.body) {
                        return true
                    }
                }
                for body in default {
                    if contains_break(body) {
                        return true
                    }
                }
            }
            If(_, then, els) {
                if contains_break(then) {
                    return true
                }
                for other in els {
                    match other.kind {
                        Block(b) {
                            if contains_break(b) {
                                return true
                            }
                        }
                        If(_, _, _) {
                            if contains_break(ast.Block{stmts: [other], start: other.start, end: other.end}) {
                                return true
                            }
                        }
                        else {
                        }
                    }
                }
            }
            else {
            }
        }
    }
    return false
}

// ---- the checker ----

enum CtxKind {
    Fn
    Fork
    Check
    Global
}

// The body of code being checked.
struct FnCtx {
    kind: CtxKind
    key: string
    ret: Type
    fallible: bool
    loop_depth: int
}

// What the checker records about each body of code (a function, a method,
// a lambda, a `fork` block, the initialiser of a top-level variable).
struct AsyncInfo {
    // Contains an operation that waits (channel, sleep, ...).
    direct: bool
    // Functions and methods it calls directly.
    calls: [string]
    // Top-level variables it reads or writes.
    globals: [string]
    // Bodies that run as part of this one without being called (`fork` blocks).
    inline: [string]
    // Methods called through an interface: any struct's method of that name may run.
    interface_calls: [string]
    // Calls a function value: any function that is used as a value may run.
    dynamic: bool
}

struct Var {
    ty: Type
    mutable: bool
}

struct GlobalInit {
    name: string
    start: int
    end: int
}

struct UseTooEarly {
    name: string
    start: int
    end: int
    used: string
    chain: [string]
}

// What a call gives, and whether it can fail.
struct Outcome {
    ty: Type
    fallible: bool
}

fn outcome(ty: Type, fallible: bool) -> Outcome {
    return Outcome{ty: ty, fallible: fallible}
}

struct Checker {
    src: [int]
    report: diag.Report
    structs: map<string, StructInfo>
    interfaces: map<string, InterfaceInfo>
    fns: map<string, FnSig>
    scopes: [map<string, Var>]
    ctx: [FnCtx]
    // Calls that are wrapped in `?`, `or` or `catch`.
    handling: map<int, bool>
    // The one `catch` expression allowed at the current statement (-1: none),
    // and whether it must give a value.
    catch_id: int
    catch_needs: bool
    async_info: map<string, AsyncInfo>
    // Functions and lambdas that are stored or passed around as values.
    escaping: [string]
    // Every top-level variable, with its position in initialisation order.
    global_names: map<string, int>
    // The top-level variables checked so far, with where their initialiser is.
    global_inits: [GlobalInit]
    forks: int
    // Byte range of the native runtime's source (-1: none); `__` names are
    // only visible there.
    runtime_start: int
    runtime_end: int
    an: Analysis

    fn err(self, code: string, message: string, start: int, end: int) -> diag.Diag {
        return self.report.add(code, message, start, end)
    }

    fn text(self, start: int, end: int) -> string {
        return lexer.text_of(self.src, start, end)
    }

    fn in_runtime(self, start: int, end: int) -> bool {
        return self.runtime_start >= 0 && start >= self.runtime_start && end <= self.runtime_end
    }

    fn mismatch(self, expected: Type, found: Type, start: int, end: int) {
        var d = self.err("E0102", "type mismatch: expected `{show(expected)}`, found `{show(found)}`", start, end)
        d.label = "this is `{show(found)}`"
        match expected {
            Str {
                d.help = "convert with `str(...)` or use interpolation: \"\{value\}\""
            }
            Int {
                if found == Type.Float {
                    d.help = "convert with `int(...)` (drops the decimals), `round(...)`, `floor(...)` or `ceil(...)`"
                } else if found == Type.Str {
                    d.help = "convert with `parse_int(...)`, which can fail: `parse_int(s) or 0`"
                }
            }
            Float {
                if found == Type.Str {
                    d.help = "convert with `parse_float(...)`, which can fail: `parse_float(s) or 0.0`"
                }
            }
            Interface(i) {
                match found {
                    Struct(s) {
                        d.help = "`{s}` does not implement `{i}`: {self.missing_methods(s, i)}"
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }

    // ---- declarations ----

    fn run(self, program: ast.Program, require_main: bool) {
        // 1. Type names.
        for item in program.items {
            var name = ""
            var start = 0
            var end = 0
            var kind = ""
            match item {
                Struct(s) {
                    name = s.name
                    start = s.name_start
                    end = s.name_end
                    kind = "struct"
                }
                Interface(i) {
                    name = i.name
                    start = i.name_start
                    end = i.name_end
                    kind = "interface"
                }
                Enum(e) {
                    name = e.name
                    start = e.name_start
                    end = e.name_end
                    kind = "enum"
                }
                else {
                    continue
                }
            }
            self.check_reserved(name, start, end)
            if is_builtin_type(name) {
                self.err("E0103", "`{name}` is a built-in type", start, end)
            } else if self.structs.has(name) || self.interfaces.has(name) || self.an.enums.has(name) {
                var d = self.err("E0103", "type `{name}` is defined twice", start, end)
                d.label = "already defined above"
            } else if kind == "enum" {
                self.an.enums[name] = []
            } else if kind == "struct" {
                self.structs[name] = StructInfo{fields: [], methods: {}}
            } else {
                self.interfaces[name] = InterfaceInfo{methods: []}
            }
        }

        // 2. Signatures.
        for item in program.items {
            match item {
                Struct(s) {
                    var info = StructInfo{fields: [], methods: {}}
                    for f in s.fields {
                        var ty = self.resolve(f.ty)
                        if has_field(info, f.name) {
                            self.err("E0103", "field `{f.name}` is defined twice", f.start, f.end)
                        } else {
                            info.fields.push(Field{name: f.name, ty: ty})
                        }
                    }
                    for m in s.methods {
                        if !m.has_self {
                            var d = self.err("E0003", "method `{m.name}` must take `self` as its first parameter", m.name_start, m.name_end)
                            d.help = "write `fn {m.name}(self, ...)`"
                        }
                        var sig = self.signature(m.params, m.ret, m.fallible)
                        if info.methods.has(m.name) || has_field(info, m.name) {
                            self.err("E0103", "`{m.name}` is defined twice in `{s.name}`", m.name_start, m.name_end)
                        } else {
                            info.methods[m.name] = sig
                        }
                    }
                    self.structs[s.name] = info
                }
                Interface(i) {
                    var info = InterfaceInfo{methods: []}
                    for m in i.methods {
                        var sig = self.signature(m.params, m.ret, m.fallible)
                        var twice = false
                        for known in info.methods {
                            if known.name == m.name {
                                twice = true
                            }
                        }
                        if twice {
                            self.err("E0103", "method `{m.name}` is defined twice", m.name_start, m.name_end)
                        } else {
                            info.methods.push(Method{name: m.name, sig: sig})
                        }
                    }
                    self.interfaces[i.name] = info
                }
                Enum(e) {
                    var variants: [Variant] = []
                    for v in e.variants {
                        var fields: [Type] = []
                        for t in v.fields {
                            fields.push(self.resolve(t))
                        }
                        var twice = false
                        for known in variants {
                            if known.name == v.name {
                                twice = true
                            }
                        }
                        if twice {
                            self.err("E0103", "variant `{v.name}` is defined twice", v.start, v.end)
                        } else {
                            variants.push(Variant{name: v.name, fields: fields})
                        }
                    }
                    if variants.len() == 0 {
                        self.err("E0003", "enum `{e.name}` has no variant", e.name_start, e.name_end)
                    }
                    self.an.enums[e.name] = variants
                }
                Fn(f) {
                    var sig = self.signature(f.params, f.ret, f.fallible)
                    self.check_reserved(f.name, f.name_start, f.name_end)
                    if is_builtin(f.name) {
                        self.err("E0103", "`{f.name}` is a built-in function and cannot be redefined", f.name_start, f.name_end)
                    } else if self.structs.has(f.name) || self.interfaces.has(f.name) {
                        self.err("E0103", "`{f.name}` is already the name of a type", f.name_start, f.name_end)
                    } else if self.fns.has(f.name) {
                        var d = self.err("E0103", "function `{f.name}` is defined twice", f.name_start, f.name_end)
                        d.label = "already defined above"
                    } else {
                        self.fns[f.name] = sig
                    }
                }
                else {
                }
            }
        }

        // 3. Top-level variables, in the order in which they get their values.
        var globals: [ast.Stmt] = []
        for item in program.items {
            match item {
                Global(stmt) {
                    match stmt.kind {
                        Let(name, _, _, _, _, _) {
                            if !self.global_names.has(name) {
                                self.global_names[name] = globals.len()
                            }
                            globals.push(stmt)
                        }
                        else {
                        }
                    }
                }
                else {
                }
            }
        }
        for stmt in globals {
            match stmt.kind {
                Let(name, name_start, name_end, _, _, init) {
                    self.check_reserved(name, name_start, name_end)
                    self.global_inits.push(GlobalInit{name: name, start: init.start, end: init.end})
                    self.push_ctx(CtxKind.Global, "global:" + name, Type.Void, false)
                    self.stmt(stmt)
                    self.ctx.remove(self.ctx.len() - 1)
                }
                else {
                }
            }
        }

        // 4. Bodies.
        for item in program.items {
            match item {
                Fn(f) {
                    self.function(f, fn_key(f.name), "")
                }
                Struct(s) {
                    for m in s.methods {
                        self.function(m, method_key(s.name, m.name), s.name)
                    }
                }
                Check(_, body) {
                    self.push_ctx(CtxKind.Check, "check", Type.Void, false)
                    self.block(body)
                    self.ctx.remove(self.ctx.len() - 1)
                }
                else {
                }
            }
        }

        // 5. Entry point.
        if require_main {
            self.check_main(program)
        }

        // 6. Propagate the waiting through the calls.
        var waits: map<string, bool> = {}
        for key in self.async_info.keys() {
            if self.async_info[key].direct {
                waits[key] = true
            }
        }
        var changed = true
        while changed {
            changed = false
            for key in self.async_info.keys() {
                if waits.has(key) {
                    continue
                }
                for callee in self.async_info[key].calls {
                    if waits.has(callee) {
                        waits[key] = true
                        changed = true
                        break
                    }
                }
            }
        }
        self.an.async_keys = waits

        // 7. No top-level variable may be used before it has its value.
        self.check_initialization_order()
    }

    fn check_main(self, program: ast.Program) {
        for item in program.items {
            match item {
                Fn(f) {
                    if f.name != "main" {
                        continue
                    }
                    if f.params.len() > 0 {
                        var d = self.err("E0116", "`main` takes no parameters", f.name_start, f.name_end)
                        d.help = "use `args()` to read command-line arguments"
                    }
                    for ret in f.ret {
                        if ret.kind != ast.TypeKind.Named("void") {
                            var d = self.err("E0116", "`main` cannot return a value", ret.start, ret.end)
                            d.help = "use `exit(code)` to set the exit code; `-> void!` is allowed"
                        }
                    }
                    return
                }
                else {
                }
            }
        }
        var d = self.err("E0116", "this program has no `main` function", 0, 0)
        d.help = "add `fn main() \{ ... \}`"
    }

    // Names starting with two underscores belong to the runtime.
    fn check_reserved(self, name: string, start: int, end: int) {
        var parts = name.split(".")
        var own = parts[parts.len() - 1]
        if own.starts_with("__") && !self.in_runtime(start, end) {
            var d = self.err("E0103", "the name `{own}` is reserved", start, end)
            d.help = "names starting with two underscores are reserved for the Onyx runtime; one underscore makes a name private to its file"
        }
    }

    // Top-level variables get their values one after the other, imported
    // files first. An initialiser may call functions, and those functions may
    // use other top-level variables: this finds the ones that would be used
    // too early. The search follows every call that *could* happen, so it
    // can reject a program that would in fact have been fine.
    fn check_initialization_order(self) {
        // In a fixed order (structs and methods by name), so that the chain
        // of calls reported is always the same one.
        var methods_named: map<string, [string]> = {}
        for strukt in self.structs.keys().sort() {
            for method in self.structs[strukt].methods.keys().sort() {
                if !methods_named.has(method) {
                    methods_named[method] = []
                }
                methods_named[method].push(method_key(strukt, method))
            }
        }

        var errors: [UseTooEarly] = []
        for i in 0..self.global_inits.len() {
            var init = self.global_inits[i]
            var start = "global:" + init.name
            var parent: map<string, string> = {}
            var seen: map<string, bool> = {}
            seen[start] = true
            var queue = [start]
            var head = 0
            var found = false
            while head < queue.len() && !found {
                var key = queue[head]
                head += 1
                if !self.async_info.has(key) {
                    continue
                }
                var info = self.async_info[key]
                for used in info.globals {
                    if self.global_names.has(used) && self.global_names[used] >= i {
                        // The chain of calls that leads from the initialiser to the use.
                        var chain: [string] = []
                        var at = key
                        while at != start {
                            var shown = describe(at)
                            if shown != "" {
                                chain.push(shown)
                            }
                            at = parent[at]
                        }
                        errors.push(UseTooEarly{name: init.name, start: init.start, end: init.end, used: used, chain: chain.reverse()})
                        found = true
                        break
                    }
                }
                if found {
                    break
                }
                var next: [string] = []
                for c in info.calls {
                    next.push(c)
                }
                for c in info.inline {
                    next.push(c)
                }
                for method in info.interface_calls {
                    if methods_named.has(method) {
                        for k in methods_named[method] {
                            next.push(k)
                        }
                    }
                }
                if info.dynamic {
                    for k in self.escaping {
                        next.push(k)
                    }
                }
                for callee in next {
                    if !seen.has(callee) {
                        seen[callee] = true
                        parent[callee] = key
                        queue.push(callee)
                    }
                }
            }
        }

        for e in errors {
            var via = ""
            if e.chain.len() > 0 {
                via = " through " + e.chain.join(", then ")
            }
            var message = ""
            var label = ""
            if e.used == e.name {
                message = "`{e.name}` is used while its own value is being computed"
                label = "this uses `{e.name}`{via}"
            } else {
                message = "`{e.used}` may be used before it has a value"
                label = "this uses `{e.used}`{via}, but `{e.used}` gets its value later"
            }
            var help = "top-level variables get their values from top to bottom, imported files first; declare `{e.used}` before `{e.name}`, or compute `{e.name}` inside a function"
            if module_of(e.used) != module_of(e.name) {
                help += ". These two are in files that import each other, so the file that is run decides which comes first"
            }
            var d = self.err("E0118", message, e.start, e.end)
            d.label = label
            d.help = help
        }
    }

    fn signature(self, params: [ast.Param], ret: [ast.TypeExpr], fallible: bool) -> FnSig {
        var types: [Type] = []
        for p in params {
            types.push(self.resolve(p.ty))
        }
        var result = Type.Void
        for r in ret {
            result = self.resolve(r)
        }
        return FnSig{params: types, ret: result, fallible: fallible}
    }

    fn resolve(self, t: ast.TypeExpr) -> Type {
        match t.kind {
            Named(name) {
                match name {
                    "int" {
                        return Type.Int
                    }
                    "float" {
                        return Type.Float
                    }
                    "bool" {
                        return Type.Bool
                    }
                    "string" {
                        return Type.Str
                    }
                    "void" {
                        return Type.Void
                    }
                    "error" {
                        return Type.Error
                    }
                    else {
                    }
                }
                if self.structs.has(name) {
                    return Type.Struct(name)
                }
                if self.interfaces.has(name) {
                    return Type.Interface(name)
                }
                if self.an.enums.has(name) {
                    return Type.Enum(name)
                }
                var d = self.err("E0101", "unknown type `{name}`", t.start, t.end)
                var hint = ""
                match name {
                    "str", "String" {
                        hint = "string"
                    }
                    "i32", "i64", "long", "Int", "number" {
                        hint = "int"
                    }
                    "f32", "f64", "double", "Float" {
                        hint = "float"
                    }
                    "boolean", "Bool" {
                        hint = "bool"
                    }
                    else {
                    }
                }
                if hint != "" {
                    d.help = "did you mean `{hint}`?"
                }
                return Type.Unknown
            }
            List(elem) {
                return Type.List(self.resolve(elem))
            }
            Map(k, v) {
                var key = self.resolve(k)
                self.check_map_key(key, k.start, k.end)
                return Type.Map(key, self.resolve(v))
            }
            Chan(elem) {
                return Type.Chan(self.resolve(elem))
            }
            Weak(target) {
                var ty = self.resolve(target)
                self.check_weak_target(ty, target.start, target.end)
                return Type.Weak(ty)
            }
            Fn(params, ret, fallible) {
                var types: [Type] = []
                for p in params {
                    types.push(self.resolve(p))
                }
                var result = Type.Void
                for r in ret {
                    result = self.resolve(r)
                }
                return Type.Fn(FnSig{params: types, ret: result, fallible: fallible})
            }
        }
    }

    fn check_weak_target(self, ty: Type, start: int, end: int) {
        var fits = is_unknown(ty)
        match ty {
            Struct(_), Interface(_), List(_), Map(_, _) {
                fits = true
            }
            else {
            }
        }
        if !fits {
            var d = self.err("E0102", "there are no weak references to `{show(ty)}`", start, end)
            d.help = "a weak reference points to an object: a struct, an interface value, a list or a map"
        }
    }

    fn check_map_key(self, key: Type, start: int, end: int) {
        if !(key == Type.Int || key == Type.Str || key == Type.Bool || is_unknown(key)) {
            var d = self.err("E0113", "`{show(key)}` cannot be used as a map key", start, end)
            d.help = "map keys must be int, string or bool"
        }
    }

    // ---- type relations ----

    fn missing_methods(self, strukt: string, iface: string) -> string {
        if !self.structs.has(strukt) || !self.interfaces.has(iface) {
            return ""
        }
        var s = self.structs[strukt]
        var problems: [string] = []
        for m in self.interfaces[iface].methods {
            if !s.methods.has(m.name) {
                problems.push("missing method `{m.name}`")
            } else if s.methods[m.name] != m.sig {
                problems.push("method `{m.name}` has type `{show_sig(s.methods[m.name])}` but `{show_sig(m.sig)}` is required")
            }
        }
        return problems.join(", ")
    }

    fn assignable(self, from: Type, to: Type) -> bool {
        if from == to || is_unknown(from) || is_unknown(to) {
            return true
        }
        match from {
            Int {
                return to == Type.Float
            }
            Struct(s) {
                match to {
                    Interface(i) {
                        return self.missing_methods(s, i) == ""
                    }
                    else {
                        return false
                    }
                }
            }
            Weak(a) {
                match to {
                    Weak(b) {
                        return self.assignable(a, b)
                    }
                    else {
                        return false
                    }
                }
            }
            List(a) {
                match to {
                    List(b) {
                        return is_unknown(a) || is_unknown(b)
                    }
                    else {
                        return false
                    }
                }
            }
            Chan(a) {
                match to {
                    Chan(b) {
                        return is_unknown(a) || is_unknown(b)
                    }
                    else {
                        return false
                    }
                }
            }
            Map(k1, v1) {
                match to {
                    Map(k2, v2) {
                        return (k1 == k2 || is_unknown(k1) || is_unknown(k2)) && (v1 == v2 || is_unknown(v1) || is_unknown(v2))
                    }
                    else {
                        return false
                    }
                }
            }
            else {
                return false
            }
        }
    }

    fn require(self, found: Type, expected: Type, e: ast.Expr) {
        if !self.assignable(found, expected) {
            self.mismatch(expected, found, e.start, e.end)
        }
        self.widen(found, expected, e)
    }

    // Notes that the int `e` is used where a float is expected: targets
    // that store the two differently have to convert it there.
    fn widen(self, found: Type, expected: Type, e: ast.Expr) {
        if found == Type.Int && expected == Type.Float {
            self.an.widened[e.id] = true
        }
    }

    // ---- scopes and bodies of code ----

    fn info(self, key: string) -> AsyncInfo {
        if !self.async_info.has(key) {
            self.async_info[key] = AsyncInfo{direct: false, calls: [], globals: [], inline: [], interface_calls: [], dynamic: false}
        }
        return self.async_info[key]
    }

    fn push_ctx(self, kind: CtxKind, key: string, ret: Type, fallible: bool) {
        self.info(key)
        self.ctx.push(FnCtx{kind: kind, key: key, ret: ret, fallible: fallible, loop_depth: 0})
    }

    fn cur(self) -> FnCtx {
        return self.ctx[self.ctx.len() - 1]
    }

    fn mark_async(self) {
        var info = self.info(self.cur().key)
        info.direct = true
    }

    fn add_call(self, callee: string) {
        self.info(self.cur().key).calls.push(callee)
    }

    // The innermost scope where `name` is a variable, or -1.
    fn find(self, name: string) -> int {
        var i = self.scopes.len() - 1
        while i >= 0 {
            if self.scopes[i].has(name) {
                return i
            }
            i -= 1
        }
        return -1
    }

    // Records that the current body uses `name`, if it is a top-level variable.
    fn use_global(self, name: string) {
        if self.find(name) == 0 {
            self.info(self.cur().key).globals.push(name)
        }
    }

    // A function given to `map`, `filter` or `sort_by` is called right there.
    fn callback(self, arg: ast.Expr) {
        var key = ""
        match arg.kind {
            Lambda(_, _, _, _) {
                key = lambda_key(arg.id)
            }
            Ident(name) {
                if self.find(name) < 0 && self.fns.has(name) {
                    key = fn_key(name)
                }
            }
            else {
            }
        }
        // Checking the argument registered it as a value that may be called
        // from anywhere; it is not: it only runs here.
        if key != "" && self.escaping.len() > 0 && self.escaping[self.escaping.len() - 1] == key {
            self.escaping.remove(self.escaping.len() - 1)
            self.add_call(key)
            return
        }
        var info = self.info(self.cur().key)
        info.dynamic = true
    }

    fn push_scope(self) {
        var scope: map<string, Var> = {}
        self.scopes.push(scope)
    }

    fn pop_scope(self) {
        self.scopes.remove(self.scopes.len() - 1)
    }

    fn declare(self, name: string, ty: Type, mutable: bool, start: int, end: int) {
        var scope = self.scopes[self.scopes.len() - 1]
        if scope.has(name) {
            var d = self.err("E0103", "`{name}` is already defined in this scope", start, end)
            d.help = "pick another name, or assign to the existing variable without `var`"
            return
        }
        scope[name] = Var{ty: ty, mutable: mutable}
    }

    fn function(self, f: ast.FnDecl, key: string, self_struct: string) {
        var sig = self.signature_quiet(f.params, f.ret, f.fallible)
        self.push_ctx(CtxKind.Fn, key, sig.ret, sig.fallible)
        self.push_scope()
        if self_struct != "" {
            self.declare("self", Type.Struct(self_struct), false, f.name_start, f.name_end)
        }
        for i in 0..f.params.len() {
            var p = f.params[i]
            self.declare(p.name, sig.params[i], true, p.start, p.end)
        }
        for stmt in f.body.stmts {
            self.stmt(stmt)
        }
        if sig.ret != Type.Void && !is_unknown(sig.ret) && !exits(f.body, false) {
            var d = self.err("E0109", "function `{f.name}` does not return a value on every path", f.name_start, f.name_end)
            d.label = "must return `{show(sig.ret)}`"
        }
        self.pop_scope()
        self.ctx.remove(self.ctx.len() - 1)
    }

    // Like `signature`, but without reporting unknown types a second time.
    fn signature_quiet(self, params: [ast.Param], ret: [ast.TypeExpr], fallible: bool) -> FnSig {
        var n = self.report.diags.len()
        var sig = self.signature(params, ret, fallible)
        while self.report.diags.len() > n {
            self.report.diags.remove(self.report.diags.len() - 1)
        }
        return sig
    }

    // If `obj.name` names a variant of an enum (`Shape.Circle`): the enum
    // and the position of the variant. An unknown variant is reported.
    fn variant(self, obj: ast.Expr, name: string, start: int, end: int) -> VariantRef {
        var none = VariantRef{enum_name: "", index: -1}
        var enum_name = ""
        match obj.kind {
            Ident(n) {
                enum_name = n
            }
            else {
                return none
            }
        }
        if self.find(enum_name) >= 0 || !self.an.enums.has(enum_name) {
            return none
        }
        var variants = self.an.enums[enum_name]
        for i in 0..variants.len() {
            if variants[i].name == name {
                return VariantRef{enum_name: enum_name, index: i}
            }
        }
        var d = self.err("E0106", "`{enum_name}` has no variant `{name}`", start, end)
        d.help = "its variants: " + variant_names(variants).join(", ")
        return none
    }

    // `obj` is the name of an enum (and not of a variable).
    fn is_enum_name(self, obj: ast.Expr) -> bool {
        match obj.kind {
            Ident(n) {
                return self.find(n) < 0 && self.an.enums.has(n)
            }
            else {
                return false
            }
        }
    }

    fn match_stmt(self, stmt: ast.Stmt, subject: ast.Expr, arms: [ast.MatchArm], default: [ast.Block]) {
        var ty = self.expr(subject, Type.Unknown)
        var variants: [Variant] = []
        match ty {
            Enum(name) {
                variants = self.an.enums[name]
            }
            else {
            }
        }
        var handled: [bool] = []
        for v in variants {
            handled.push(false)
        }
        var saw_true = false
        var saw_false = false
        for arm in arms {
            self.push_scope()
            for pattern in arm.patterns {
                match pattern {
                    Literal(value) {
                        if !is_plain_pattern(value) {
                            var d = self.err("E0003", "a pattern is a whole number, a string, `true`, `false` or a variant", value.start, value.end)
                            d.help = "for anything else, use `if`"
                            continue
                        }
                        var found = self.expr(value, ty)
                        if !is_unknown(ty) && found != ty {
                            self.mismatch(ty, found, value.start, value.end)
                        }
                        if value.kind == ast.ExprKind.Bool(true) {
                            saw_true = true
                        }
                        if value.kind == ast.ExprKind.Bool(false) {
                            saw_false = true
                        }
                    }
                    Variant(name, start, end, bindings) {
                        var enum_name = ""
                        match ty {
                            Enum(n) {
                                enum_name = n
                            }
                            else {
                            }
                        }
                        if enum_name == "" {
                            if !is_unknown(ty) {
                                self.err("E0102", "`{name}` would be a variant of an enum, but this `match` is on `{show(ty)}`", start, end)
                            }
                            continue
                        }
                        var index = -1
                        for i in 0..variants.len() {
                            if variants[i].name == name {
                                index = i
                            }
                        }
                        if index < 0 {
                            var d = self.err("E0106", "`{enum_name}` has no variant `{name}`", start, end)
                            d.help = "its variants: " + variant_names(variants).join(", ")
                            continue
                        }
                        if handled[index] {
                            self.err("E0103", "`{name}` is already handled above", start, end)
                        }
                        handled[index] = true
                        var carried = variants[index].fields
                        if bindings.len() != carried.len() {
                            var given = "s were"
                            if bindings.len() == 1 {
                                given = " was"
                            }
                            var d = self.err("E0104", "`{name}` carries {carried.len()} value{plural(carried.len())} but {bindings.len()} name{given} given", start, end)
                            d.help = "give one name per value; `_` for those that are not needed"
                            continue
                        }
                        var named = false
                        for b in bindings {
                            if b.text != "_" {
                                named = true
                            }
                        }
                        if arm.patterns.len() > 1 && named {
                            var d = self.err("E0003", "a case for several patterns cannot name the values they carry", start, end)
                            d.help = "write one case per pattern, or use `_`"
                            continue
                        }
                        for i in 0..bindings.len() {
                            var b = bindings[i]
                            if b.text != "_" {
                                self.declare(b.text, carried[i], true, b.start, b.end)
                            }
                        }
                    }
                }
            }
            self.block(arm.body)
            self.pop_scope()
        }
        for body in default {
            self.block(body)
            return
        }
        // Without `else`, every possible value must have its case.
        var missing: [string] = []
        for i in 0..variants.len() {
            if !handled[i] {
                missing.push(variants[i].name)
            }
        }
        var complete = false
        match ty {
            Enum(_) {
                complete = missing.len() == 0
            }
            Bool {
                complete = saw_true && saw_false
            }
            Unknown {
                complete = true
            }
            else {
            }
        }
        if !complete {
            var d = self.err("E0119", "this `match` does not handle every case", stmt.start, stmt.end)
            if missing.len() == 0 {
                d.help = "add an `else \{ ... \}` for the other values"
            } else {
                d.help = "missing: " + missing.join(", ") + "; handle them, or add an `else \{ ... \}`"
            }
        }
    }

    fn block(self, block: ast.Block) {
        self.push_scope()
        for stmt in block.stmts {
            self.stmt(stmt)
        }
        self.pop_scope()
    }

    // ---- statements ----

    // Checks an expression in a position where a `catch` block is allowed.
    fn stmt_expr(self, e: ast.Expr, expected: Type, needs_value: bool) -> Type {
        match e.kind {
            Catch(_, _, _, _, _) {
                self.catch_id = e.id
                self.catch_needs = needs_value
            }
            else {
            }
        }
        return self.expr(e, expected)
    }

    fn stmt(self, stmt: ast.Stmt) {
        match stmt.kind {
            Match(subject, arms, default) {
                self.match_stmt(stmt, subject, arms, default)
            }
            Let(name, name_start, name_end, mutable, ty, init) {
                var annotated = Type.Unknown
                for t in ty {
                    annotated = self.resolve(t)
                }
                var found = self.stmt_expr(init, annotated, true)
                var var_ty = found
                if ty.len() > 0 {
                    self.require(found, annotated, init)
                    var_ty = annotated
                }
                if var_ty == Type.Void {
                    var d = self.err("E0102", "this expression does not produce a value", init.start, init.end)
                    d.label = "returns nothing"
                }
                if self.cur().kind == CtxKind.Global && (self.fns.has(name) || self.structs.has(name)) {
                    self.err("E0103", "`{name}` is already the name of a function or type", name_start, name_end)
                }
                self.declare(name, var_ty, mutable, name_start, name_end)
            }
            Assign(target, op, value) {
                var target_ty = self.assign_target(target)
                var found = self.stmt_expr(value, target_ty, true)
                if op == ast.AssignOp.Set {
                    self.require(found, target_ty, value)
                } else if op == ast.AssignOp.Add && target_ty == Type.Str {
                    self.require(found, Type.Str, value)
                } else if !is_numeric(target_ty) && !is_unknown(target_ty) {
                    self.err("E0107", "this operator cannot be used on `{show(target_ty)}`", target.start, target.end)
                } else {
                    self.require(found, target_ty, value)
                }
            }
            Expr(e) {
                self.stmt_expr(e, Type.Unknown, false)
            }
            If(cond, then, els) {
                var t = self.expr(cond, Type.Bool)
                self.require(t, Type.Bool, cond)
                self.block(then)
                for other in els {
                    self.stmt(other)
                }
            }
            While(cond, body) {
                var t = self.expr(cond, Type.Bool)
                self.require(t, Type.Bool, cond)
                var c = self.cur()
                c.loop_depth += 1
                self.block(body)
                c.loop_depth -= 1
            }
            For(name, name_start, name_end, iter, body) {
                var iter_ty = self.expr(iter, Type.Unknown)
                var var_ty = Type.Unknown
                match iter_ty {
                    List(t) {
                        var_ty = t
                    }
                    Str {
                        var_ty = Type.Str
                    }
                    Map(k, _) {
                        var_ty = k
                    }
                    Range {
                        var_ty = Type.Int
                    }
                    Chan(t) {
                        self.mark_async()
                        var_ty = t
                    }
                    Unknown {
                    }
                    else {
                        var d = self.err("E0114", "cannot loop over `{show(iter_ty)}`", iter.start, iter.end)
                        d.help = "`for` works on lists, strings, maps, channels and ranges like `0..10`"
                    }
                }
                self.push_scope()
                self.declare(name, var_ty, false, name_start, name_end)
                var c = self.cur()
                c.loop_depth += 1
                self.block(body)
                c.loop_depth -= 1
                self.pop_scope()
            }
            Return(value) {
                var kind = self.cur().kind
                if kind == CtxKind.Fork || kind == CtxKind.Global {
                    var d = self.err("E0117", "`return` cannot be used here", stmt.start, stmt.end)
                    d.help = "a `fork` block runs as a separate task and cannot return from the enclosing function"
                    return
                }
                var ret = self.cur().ret
                for v in value {
                    var found = self.stmt_expr(v, ret, true)
                    if ret == Type.Void {
                        if found != Type.Void && !is_unknown(found) {
                            var d = self.err("E0102", "this function does not return a value", v.start, v.end)
                            d.help = "add a return type: `-> {show(found)}`"
                        }
                    } else {
                        self.require(found, ret, v)
                    }
                }
                if value.len() == 0 && ret != Type.Void && !is_unknown(ret) {
                    var d = self.err("E0102", "this function must return `{show(ret)}`", stmt.start, stmt.end)
                    d.label = "missing a value"
                }
            }
            Break {
                if self.cur().loop_depth == 0 {
                    self.err("E0111", "`break` outside of a loop", stmt.start, stmt.end)
                }
            }
            Continue {
                if self.cur().loop_depth == 0 {
                    self.err("E0111", "`continue` outside of a loop", stmt.start, stmt.end)
                }
            }
            Fail(value) {
                if !self.cur().fallible {
                    var d = self.err("E0203", "`fail` used in a function that cannot fail", stmt.start, stmt.end)
                    d.help = "add `!` to the function's return type, e.g. `-> int!` or `-> void!`"
                }
                var t = self.expr(value, Type.Str)
                if !(t == Type.Str || t == Type.Error || is_unknown(t)) {
                    var d = self.err("E0102", "`fail` takes a message or an error, found `{show(t)}`", value.start, value.end)
                    d.help = "write `fail \"something went wrong\"`"
                }
            }
            Fork(body) {
                // The block starts running right away, as part of the enclosing body.
                self.forks += 1
                var key = "fork:" + str(self.forks)
                self.info(self.cur().key).inline.push(key)
                self.push_ctx(CtxKind.Fork, key, Type.Void, false)
                self.block(body)
                self.ctx.remove(self.ctx.len() - 1)
            }
            Send(channel, value) {
                var chan_ty = self.expr(channel, Type.Unknown)
                match chan_ty {
                    Chan(elem) {
                        var found = self.expr(value, elem)
                        self.require(found, elem, value)
                    }
                    Unknown {
                        self.expr(value, Type.Unknown)
                    }
                    else {
                        self.expr(value, Type.Unknown)
                        var d = self.err("E0300", "cannot send to `{show(chan_ty)}`", channel.start, channel.end)
                        d.label = "not a channel"
                    }
                }
                self.mark_async()
            }
            Block(b) {
                self.block(b)
            }
        }
    }

    fn assign_target(self, target: ast.Expr) -> Type {
        match target.kind {
            Ident(name) {
                var at = self.find(name)
                if at < 0 {
                    return self.expr(target, Type.Unknown)
                }
                var v = self.scopes[at][name]
                self.use_global(name)
                if !v.mutable {
                    var d = self.err("E0108", "cannot assign to `{name}`", target.start, target.end)
                    d.label = "this is a constant"
                    d.help = "declare it with `var {name} = ...` to make it changeable"
                }
                self.an.types[target.id] = v.ty
                return v.ty
            }
            Field(_, _, _, _) {
                return self.expr(target, Type.Unknown)
            }
            Index(obj, _) {
                var ty = self.expr(target, Type.Unknown)
                if self.an.types.has(obj.id) && self.an.types[obj.id] == Type.Str {
                    var d = self.err("E0108", "strings cannot be modified in place", target.start, target.end)
                    d.help = "build a new string instead"
                }
                return ty
            }
            else {
                self.expr(target, Type.Unknown)
                var d = self.err("E0108", "this expression cannot be assigned to", target.start, target.end)
                d.help = "only variables, fields and indexed elements can be assigned"
                return Type.Unknown
            }
        }
    }

    // ---- expressions ----

    // The type of `e`. `expected` is the type wanted where `e` is (`Unknown`
    // when there is none); it only serves to give a type to `[]`, `\{\}` and
    // `weak()`.
    fn expr(self, e: ast.Expr, expected: Type) -> Type {
        var ty = self.expr_inner(e, expected)
        self.an.types[e.id] = ty
        return ty
    }

    fn expr_inner(self, e: ast.Expr, expected: Type) -> Type {
        match e.kind {
            Int(_) {
                return Type.Int
            }
            Float(_) {
                return Type.Float
            }
            Bool(_) {
                return Type.Bool
            }
            Str(parts) {
                for part in parts {
                    match part {
                        Code(inner) {
                            if self.expr(inner, Type.Unknown) == Type.Void {
                                self.err("E0102", "this expression does not produce a value", inner.start, inner.end)
                            }
                        }
                        else {
                        }
                    }
                }
                return Type.Str
            }
            Ident(name) {
                return self.ident(e, name)
            }
            List(items) {
                var has_want = false
                var want = Type.Unknown
                match expected {
                    List(t) {
                        has_want = true
                        want = t
                    }
                    else {
                    }
                }
                if items.len() == 0 {
                    if has_want {
                        return Type.List(want)
                    }
                    var d = self.err("E0110", "cannot infer the type of this empty list", e.start, e.end)
                    d.help = "add a type annotation: `var items: [string] = []`"
                    return Type.List(Type.Unknown)
                }
                return Type.List(self.unify_items(items, has_want, want))
            }
            Map(entries) {
                var has_want = false
                var want_key = Type.Unknown
                var want_value = Type.Unknown
                match expected {
                    Map(k, v) {
                        has_want = true
                        want_key = k
                        want_value = v
                    }
                    else {
                    }
                }
                if entries.len() == 0 {
                    if has_want {
                        return Type.Map(want_key, want_value)
                    }
                    var d = self.err("E0110", "cannot infer the type of this empty map", e.start, e.end)
                    d.help = "add a type annotation: `var ages: map<string, int> = \{\}`"
                    return Type.Map(Type.Unknown, Type.Unknown)
                }
                var keys: [ast.Expr] = []
                var values: [ast.Expr] = []
                for entry in entries {
                    keys.push(entry.key)
                    values.push(entry.value)
                }
                var key = self.unify_items(keys, has_want, want_key)
                var value = self.unify_items(values, has_want, want_value)
                self.check_map_key(key, entries[0].key.start, entries[0].key.end)
                return Type.Map(key, value)
            }
            StructLit(name, name_start, name_end, fields) {
                return self.struct_literal(e, name, name_start, name_end, fields)
            }
            Unary(op, inner) {
                var t = self.expr(inner, expected)
                if op == ast.UnOp.Neg {
                    if is_numeric(t) || is_unknown(t) {
                        return t
                    }
                    self.err("E0107", "cannot negate `{show(t)}`", e.start, e.end)
                    return Type.Unknown
                }
                if !(t == Type.Bool || is_unknown(t)) {
                    self.err("E0107", "`!` needs a bool, found `{show(t)}`", e.start, e.end)
                }
                return Type.Bool
            }
            Binary(op, lhs, rhs) {
                return self.binary(e, op, lhs, rhs)
            }
            Call(callee, args) {
                var result = self.call(e, callee, args, expected)
                if result.fallible {
                    self.an.fallible_calls[e.id] = true
                }
                var handled = self.handling.has(e.id)
                if handled {
                    self.handling.remove(e.id)
                }
                if result.fallible && !handled {
                    var name = self.text(callee.start, callee.end)
                    var d = self.err("E0200", "`{name}()` can fail", e.start, e.end)
                    d.label = "this call may return an error"
                    d.help = "handle it with `?`, `or`, or `catch`"
                } else if !result.fallible && handled && !is_unknown(result.ty) {
                    var name = self.text(callee.start, callee.end)
                    var d = self.err("E0202", "`{name}()` cannot fail", e.start, e.end)
                    d.label = "there is no error to handle here"
                }
                return result.ty
            }
            Field(obj, name, name_start, name_end) {
                return self.field(e, obj, name, name_start, name_end)
            }
            Index(obj, index) {
                var obj_ty = self.expr(obj, Type.Unknown)
                match obj_ty {
                    List(elem) {
                        var it = self.expr(index, Type.Int)
                        self.require(it, Type.Int, index)
                        return elem
                    }
                    Str {
                        var it = self.expr(index, Type.Int)
                        self.require(it, Type.Int, index)
                        return Type.Str
                    }
                    Map(k, v) {
                        var it = self.expr(index, k)
                        self.require(it, k, index)
                        return v
                    }
                    Unknown {
                        self.expr(index, Type.Unknown)
                        return Type.Unknown
                    }
                    else {
                        self.expr(index, Type.Unknown)
                        self.err("E0115", "cannot index into `{show(obj_ty)}`", obj.start, obj.end)
                        return Type.Unknown
                    }
                }
            }
            Lambda(params, ret, fallible, body) {
                var sig = self.signature(params, ret, fallible)
                self.push_ctx(CtxKind.Fn, lambda_key(e.id), sig.ret, sig.fallible)
                self.push_scope()
                for i in 0..params.len() {
                    var p = params[i]
                    self.declare(p.name, sig.params[i], true, p.start, p.end)
                }
                for stmt in body.stmts {
                    self.stmt(stmt)
                }
                if sig.ret != Type.Void && !is_unknown(sig.ret) && !exits(body, false) {
                    var d = self.err("E0109", "this function does not return a value on every path", e.start, e.end)
                    d.label = "must return `{show(sig.ret)}`"
                }
                self.pop_scope()
                self.ctx.remove(self.ctx.len() - 1)
                self.escaping.push(lambda_key(e.id))
                return Type.Fn(sig)
            }
            Try(inner) {
                if !self.handleable(inner, "?") {
                    return self.expr(inner, expected)
                }
                if !self.cur().fallible {
                    var help = ""
                    match self.cur().kind {
                        Fork {
                            help = "a `fork` block has no caller to pass the error to; use `or` or `catch`"
                        }
                        Check {
                            help = "inside a `check` block, use `or` or `catch`"
                        }
                        Global {
                            help = "use `or` to provide a default value"
                        }
                        Fn {
                            help = "add `!` to this function's return type (e.g. `-> int!`), or use `or` / `catch`"
                        }
                    }
                    var d = self.err("E0201", "`?` used in a function that cannot fail", e.start, e.end)
                    d.help = help
                }
                self.handling[inner.id] = true
                return self.expr(inner, expected)
            }
            Or(inner, default) {
                if !self.handleable(inner, "or") {
                    self.expr(default, Type.Unknown)
                    return self.expr(inner, expected)
                }
                self.handling[inner.id] = true
                var ty = self.expr(inner, expected)
                if ty == Type.Void {
                    self.expr(default, Type.Unknown)
                    var d = self.err("E0102", "`or` needs a call that returns a value", inner.start, inner.end)
                    d.label = "returns nothing"
                    d.help = "use `catch err \{ ... \}` to handle the error of a call without a result"
                    return Type.Void
                }
                var found = self.expr(default, ty)
                self.require(found, ty, default)
                return ty
            }
            Catch(inner, name, name_start, name_end, body) {
                return self.catch_expr(e, inner, name, name_start, name_end, body, expected)
            }
            Recv(inner) {
                self.mark_async()
                var t = self.expr(inner, Type.Unknown)
                match t {
                    Chan(elem) {
                        return elem
                    }
                    Unknown {
                        return Type.Unknown
                    }
                    else {
                        var d = self.err("E0300", "cannot receive from `{show(t)}`", inner.start, inner.end)
                        d.label = "not a channel"
                        return Type.Unknown
                    }
                }
            }
            ChanNew(elem, cap) {
                var elem_ty = self.resolve(elem)
                for c in cap {
                    var t = self.expr(c, Type.Int)
                    self.require(t, Type.Int, c)
                }
                return Type.Chan(elem_ty)
            }
            Range(lo, hi) {
                for bound in [lo, hi] {
                    var t = self.expr(bound, Type.Int)
                    self.require(t, Type.Int, bound)
                }
                return Type.Range
            }
        }
    }

    fn ident(self, e: ast.Expr, name: string) -> Type {
        var hidden = name.starts_with("__") && !self.in_runtime(e.start, e.end)
        if hidden {
            var d = self.err("E0100", "unknown name `{name}`", e.start, e.end)
            d.label = "not found in this scope"
            d.help = "names starting with `__` are reserved for the Onyx runtime"
            return Type.Unknown
        }
        var at = self.find(name)
        if at >= 0 {
            self.use_global(name)
            return self.scopes[at][name].ty
        }
        if self.fns.has(name) {
            self.escaping.push(fn_key(name))
            return Type.Fn(self.fns[name])
        }
        if self.global_names.has(name) {
            var d = self.err("E0118", "`{name}` is used before it has a value", e.start, e.end)
            d.label = "`{name}` is declared further down"
            d.help = "top-level variables get their values from top to bottom, imported files first; move the declaration of `{name}` above this line"
        } else if is_builtin(name) {
            var d = self.err("E0100", "built-in function `{name}` can only be called", e.start, e.end)
            d.help = "write `{name}(...)`, or wrap it in a lambda"
        } else if self.structs.has(name) || self.interfaces.has(name) {
            self.err("E0100", "`{name}` is a type, not a value", e.start, e.end)
        } else {
            var d = self.err("E0100", "unknown name `{name}`", e.start, e.end)
            d.label = "not found in this scope"
            if ["nil", "null", "None", "undefined"].contains(name) {
                d.help = "Onyx has no null value; functions that may have no result return an error instead (`-> T!`)"
            } else if name == "this" {
                d.help = "use `self` inside methods"
            }
        }
        return Type.Unknown
    }

    fn struct_literal(self, e: ast.Expr, name: string, name_start: int, name_end: int, fields: [ast.FieldInit]) -> Type {
        if !self.structs.has(name) {
            for f in fields {
                self.expr(f.value, Type.Unknown)
            }
            self.err("E0101", "unknown struct `{name}`", name_start, name_end)
            return Type.Unknown
        }
        var info = self.structs[name]
        var seen: map<string, bool> = {}
        for f in fields {
            var index = -1
            for i in 0..info.fields.len() {
                if info.fields[i].name == f.name && index < 0 {
                    index = i
                }
            }
            if index >= 0 {
                var fty = info.fields[index].ty
                var found = self.expr(f.value, fty)
                self.require(found, fty, f.value)
                if seen.has(f.name) {
                    self.err("E0112", "field `{f.name}` is set twice", f.name_start, f.name_end)
                }
                seen[f.name] = true
            } else {
                self.expr(f.value, Type.Unknown)
                var names: [string] = []
                for known in info.fields {
                    names.push(known.name)
                }
                var d = self.err("E0112", "struct `{name}` has no field `{f.name}`", f.name_start, f.name_end)
                d.help = "available fields: " + names.join(", ")
            }
        }
        var missing: [string] = []
        for known in info.fields {
            if !seen.has(known.name) {
                missing.push(known.name)
            }
        }
        if missing.len() > 0 {
            var d = self.err("E0112", "missing field(s) in `{name}`: " + missing.join(", "), e.start, e.end)
            d.help = "every field must be given a value"
        }
        return Type.Struct(name)
    }

    fn field(self, e: ast.Expr, obj: ast.Expr, name: string, name_start: int, name_end: int) -> Type {
        var v = self.variant(obj, name, name_start, name_end)
        if v.index >= 0 {
            // `Shape.Empty`: a variant that carries nothing.
            var carried = self.an.enums[v.enum_name][v.index].fields.len()
            if carried > 0 {
                var them = "them"
                if carried == 1 {
                    them = "it"
                }
                var d = self.err("E0104", "`{name}` carries {carried} value{plural(carried)}", e.start, e.end)
                d.help = "give {them}: `{v.enum_name}.{name}(...)`"
            }
            self.an.variants[e.id] = v
            return Type.Enum(v.enum_name)
        }
        if self.is_enum_name(obj) {
            return Type.Unknown
        }
        var obj_ty = self.expr(obj, Type.Unknown)
        match obj_ty {
            Struct(s) {
                var info = self.structs[s]
                for f in info.fields {
                    if f.name == name {
                        return f.ty
                    }
                }
                if info.methods.has(name) {
                    var d = self.err("E0106", "`{name}` is a method and must be called", name_start, name_end)
                    d.help = "write `.{name}(...)`"
                } else {
                    var names: [string] = []
                    for f in info.fields {
                        names.push(f.name)
                    }
                    var d = self.err("E0106", "`{s}` has no field `{name}`", name_start, name_end)
                    d.help = "available fields: " + names.join(", ")
                }
                return Type.Unknown
            }
            Error {
                if name == "message" {
                    return Type.Str
                }
            }
            Unknown {
                return Type.Unknown
            }
            else {
            }
        }
        var d = self.err("E0106", "`{show(obj_ty)}` has no field `{name}`", name_start, name_end)
        if ["len", "length", "size"].contains(name) {
            d.help = "use the method `.len()`"
        }
        return Type.Unknown
    }

    fn catch_expr(self, e: ast.Expr, inner: ast.Expr, name: string, name_start: int, name_end: int, body: ast.Block, expected: Type) -> Type {
        var needs_value = false
        if self.catch_id == e.id {
            needs_value = self.catch_needs
        } else {
            var d = self.err("E0205", "`catch` cannot be used inside a larger expression", e.start, e.end)
            d.help = "use it directly in a `var`, an assignment, a `return` or as a statement; inside expressions use `or`"
        }
        self.catch_id = -1
        if self.handleable(inner, "catch") {
            self.handling[inner.id] = true
        }
        var ty = self.expr(inner, expected)
        self.push_scope()
        self.declare(name, Type.Error, false, name_start, name_end)
        for stmt in body.stmts {
            self.stmt(stmt)
        }
        self.pop_scope()
        if needs_value && ty != Type.Void && !is_unknown(ty) && !exits(body, true) {
            var has_last = false
            var last_ty = Type.Unknown
            var last_id = -1
            if body.stmts.len() > 0 {
                match body.stmts[body.stmts.len() - 1].kind {
                    Expr(last) {
                        if self.an.types.has(last.id) {
                            has_last = true
                            last_ty = self.an.types[last.id]
                            last_id = last.id
                        }
                    }
                    else {
                    }
                }
            }
            if has_last && last_ty != Type.Void && self.assignable(last_ty, ty) {
                if last_ty == Type.Int && ty == Type.Float {
                    self.an.widened[last_id] = true
                }
                self.an.catch_values[e.id] = true
            } else if has_last && last_ty != Type.Void {
                var last = body.stmts[body.stmts.len() - 1]
                self.mismatch(ty, last_ty, last.start, last.end)
            } else {
                var d = self.err("E0204", "this `catch` block must produce a `{show(ty)}` or leave the function", body.start, body.end)
                d.help = "end the block with a value, or with `return`, `fail`, `break` or `continue`"
            }
        }
        return ty
    }

    // `?`, `or` and `catch` only make sense on a call.
    fn handleable(self, inner: ast.Expr, what: string) -> bool {
        match inner.kind {
            Call(_, _) {
                return true
            }
            else {
            }
        }
        var d = self.err("E0202", "`{what}` has no error to handle here", inner.start, inner.end)
        d.label = "this expression cannot fail"
        d.help = "`or` and `catch` apply to everything on their left; use parentheses, e.g. `1 + (parse_int(s) or 0)`"
        return false
    }

    // Checks list items / map keys / map values and returns their common type.
    fn unify_items(self, items: [ast.Expr], has_want: bool, want: Type) -> Type {
        var has_elem = has_want
        var elem = want
        for item in items {
            var expected = Type.Unknown
            if has_elem {
                expected = elem
            }
            var found = self.expr(item, expected)
            if !has_elem {
                has_elem = true
                elem = found
                continue
            }
            if self.assignable(found, elem) {
                continue
            }
            // `[1, 2.5]` widens to float when no type was requested.
            if !has_want && self.assignable(elem, found) {
                elem = found
            } else {
                self.mismatch(elem, found, item.start, item.end)
            }
        }
        if has_elem && elem == Type.Float {
            // The ints among them become floats, also those seen before the
            // first float.
            for item in items {
                if self.an.types.has(item.id) && self.an.types[item.id] == Type.Int {
                    self.an.widened[item.id] = true
                }
            }
        }
        if !has_elem {
            return Type.Unknown
        }
        return elem
    }

    fn binary(self, e: ast.Expr, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) -> Type {
        var l = self.expr(lhs, Type.Unknown)
        var r = self.expr(rhs, l)
        var arithmetic = op == ast.BinOp.Add || op == ast.BinOp.Sub || op == ast.BinOp.Mul || op == ast.BinOp.Div || op == ast.BinOp.Mod
        if is_unknown(l) || is_unknown(r) {
            if arithmetic {
                return Type.Unknown
            }
            return Type.Bool
        }
        var numeric = is_numeric(l) && is_numeric(r)
        var logic = op == ast.BinOp.And || op == ast.BinOp.Or
        if numeric && !logic {
            // In `2 * x` with a float `x`, the 2 is a float too.
            self.widen(l, r, lhs)
            self.widen(r, l, rhs)
        }
        if op == ast.BinOp.Add && l == Type.Str && r == Type.Str {
            return Type.Str
        }
        if arithmetic && numeric {
            if l == Type.Int && r == Type.Int {
                return Type.Int
            }
            return Type.Float
        }
        if (op == ast.BinOp.Eq || op == ast.BinOp.NotEq) && (self.assignable(l, r) || self.assignable(r, l)) && !is_fn(l) && l != Type.Void {
            return Type.Bool
        }
        var compares = op == ast.BinOp.Lt || op == ast.BinOp.Le || op == ast.BinOp.Gt || op == ast.BinOp.Ge
        if compares && (numeric || (l == Type.Str && r == Type.Str)) {
            return Type.Bool
        }
        if logic && l == Type.Bool && r == Type.Bool {
            return Type.Bool
        }
        var d = self.err("E0107", "cannot apply `{symbol(op)}` to `{show(l)}` and `{show(r)}`", e.start, e.end)
        if op == ast.BinOp.Add && (l == Type.Str || r == Type.Str) {
            d.help = "to build a string, use interpolation: \"total: \{n\}\""
        }
        if arithmetic {
            return Type.Unknown
        }
        return Type.Bool
    }

    // ---- calls ----

    fn args(self, params: [Type], args: [ast.Expr], call: ast.Expr, what: string) {
        if params.len() != args.len() {
            var verb = "were"
            if args.len() == 1 {
                verb = "was"
            }
            self.err("E0104", "{what} takes {params.len()} argument{plural(params.len())} but {args.len()} {verb} given", call.start, call.end)
        }
        for i in 0..args.len() {
            var arg = args[i]
            if i < params.len() {
                var found = self.expr(arg, params[i])
                self.require(found, params[i], arg)
            } else {
                self.expr(arg, Type.Unknown)
            }
        }
    }

    fn skip_args(self, args: [ast.Expr]) -> Outcome {
        for a in args {
            self.expr(a, Type.Unknown)
        }
        return outcome(Type.Unknown, false)
    }

    fn call(self, e: ast.Expr, callee: ast.Expr, args: [ast.Expr], expected: Type) -> Outcome {
        match callee.kind {
            Ident(name) {
                if self.find(name) < 0 {
                    return self.call_name(e, callee, name, args, expected)
                }
            }
            Field(obj, name, name_start, name_end) {
                return self.call_field(e, obj, name, name_start, name_end, args)
            }
            else {
            }
        }
        var callee_ty = self.expr(callee, Type.Unknown)
        match callee_ty {
            Fn(sig) {
                return self.dynamic_call(e, sig, args, self.text(callee.start, callee.end), false)
            }
            else {
                if !is_unknown(callee_ty) {
                    var d = self.err("E0105", "`{show(callee_ty)}` is not a function", callee.start, callee.end)
                    d.label = "cannot be called"
                }
                return self.skip_args(args)
            }
        }
    }

    fn call_name(self, e: ast.Expr, callee: ast.Expr, name: string, args: [ast.Expr], expected: Type) -> Outcome {
        var internal = name.starts_with("__") && !self.in_runtime(e.start, e.end)
        if internal {
            var d = self.err("E0100", "unknown function `{name}`", callee.start, callee.end)
            d.label = "not found"
            d.help = "names starting with `__` are reserved for the Onyx runtime"
            return self.skip_args(args)
        }
        if self.fns.has(name) {
            var sig = self.fns[name]
            self.args(sig.params, args, e, "`{name}`")
            self.an.calls[e.id] = CallKind.Fn(name)
            self.add_call(fn_key(name))
            return outcome(sig.ret, sig.fallible)
        }
        if is_builtin(name) {
            self.an.calls[e.id] = CallKind.Builtin(name)
            if name == "weak" && args.len() == 0 {
                // An empty weak reference: what it would point to comes from
                // where it is used.
                match expected {
                    Weak(_) {
                        return outcome(expected, false)
                    }
                    else {
                        var d = self.err("E0110", "cannot tell what this empty weak reference would point to", e.start, e.end)
                        d.help = "say it where the value goes: `var w: weak<Node> = weak()`"
                        return outcome(Type.Unknown, false)
                    }
                }
            }
            return self.builtin_call(name, e, args)
        }
        if self.structs.has(name) {
            var d = self.err("E0105", "`{name}` is a struct, not a function", callee.start, callee.end)
            d.help = "create one with `{name}\{field: value, ...\}`"
        } else {
            var d = self.err("E0100", "unknown function `{name}`", callee.start, callee.end)
            d.label = "not found"
        }
        return self.skip_args(args)
    }

    fn call_field(self, e: ast.Expr, obj: ast.Expr, name: string, name_start: int, name_end: int, args: [ast.Expr]) -> Outcome {
        var v = self.variant(obj, name, name_start, name_end)
        if v.index >= 0 {
            // `Shape.Circle(2.0)`
            var carried = self.an.enums[v.enum_name][v.index].fields
            self.args(carried, args, e, "`{name}`")
            self.an.variants[e.id] = v
            return outcome(Type.Enum(v.enum_name), false)
        }
        if self.is_enum_name(obj) {
            return self.skip_args(args)
        }
        var obj_ty = self.expr(obj, Type.Unknown)
        match obj_ty {
            Struct(s) {
                var info = self.structs[s]
                if info.methods.has(name) {
                    var sig = info.methods[name]
                    self.args(sig.params, args, e, "`{name}`")
                    self.an.calls[e.id] = CallKind.Method(s, name)
                    self.add_call(method_key(s, name))
                    return outcome(sig.ret, sig.fallible)
                }
                for f in info.fields {
                    if f.name == name {
                        match f.ty {
                            Fn(sig) {
                                return self.dynamic_call(e, sig, args, name, false)
                            }
                            else {
                            }
                        }
                    }
                }
                var names = info.methods.keys().sort()
                var d = self.err("E0106", "`{s}` has no method `{name}`", name_start, name_end)
                if names.len() > 0 {
                    d.help = "available methods: " + names.join(", ")
                }
            }
            Interface(i) {
                for m in self.interfaces[i].methods {
                    if m.name == name {
                        return self.dynamic_call(e, m.sig, args, name, true)
                    }
                }
                self.err("E0106", "interface `{i}` has no method `{name}`", name_start, name_end)
            }
            Str, List(_), Map(_, _), Chan(_), Weak(_) {
                return self.builtin_method(e, obj_ty, name, name_start, name_end, args)
            }
            Unknown {
            }
            else {
                self.err("E0106", "`{show(obj_ty)}` has no method `{name}`", name_start, name_end)
            }
        }
        return self.skip_args(args)
    }

    // A call whose target is only known when the program runs: a function
    // value, or (`interface_method`) a method called through an interface.
    fn dynamic_call(self, e: ast.Expr, sig: FnSig, args: [ast.Expr], what: string, interface_method: bool) -> Outcome {
        self.args(sig.params, args, e, "`{what}`")
        self.an.calls[e.id] = CallKind.Dynamic
        self.mark_async()
        var info = self.info(self.cur().key)
        if interface_method {
            info.interface_calls.push(what)
        } else {
            info.dynamic = true
        }
        return outcome(sig.ret, sig.fallible)
    }

    fn arity(self, name: string, e: ast.Expr, args: [ast.Expr], n: int) -> bool {
        if args.len() != n {
            self.err("E0104", "`{name}` takes {n} argument{plural(n)} but {args.len()} were given", e.start, e.end)
            return false
        }
        return true
    }

    fn numeric(self, name: string, arg_types: [Type], args: [ast.Expr], i: int) {
        var t = arg_types[i]
        if !is_numeric(t) && !is_unknown(t) {
            self.err("E0102", "`{name}` needs a number, found `{show(t)}`", args[i].start, args[i].end)
        }
    }

    fn builtin_call(self, name: string, e: ast.Expr, args: [ast.Expr]) -> Outcome {
        var known = true
        var s = builtin_sig(name) catch err {
            known = false
            bsig([], Type.Unknown, false, false)
        }
        if known {
            self.args(s.params, args, e, "`{name}`")
            if s.is_async {
                self.mark_async()
            }
            return outcome(s.ret, s.fallible)
        }
        var arg_types: [Type] = []
        for a in args {
            arg_types.push(self.expr(a, Type.Unknown))
        }
        match name {
            "print" {
                for i in 0..args.len() {
                    if arg_types[i] == Type.Void {
                        self.err("E0102", "this expression does not produce a value", args[i].start, args[i].end)
                    }
                }
                return outcome(Type.Void, false)
            }
            "str" {
                self.arity(name, e, args, 1)
                return outcome(Type.Str, false)
            }
            "weak" {
                if self.arity(name, e, args, 1) {
                    var target = arg_types[0]
                    self.check_weak_target(target, args[0].start, args[0].end)
                    return outcome(Type.Weak(target), false)
                }
                return outcome(Type.Unknown, false)
            }
            "int", "float" {
                if self.arity(name, e, args, 1) {
                    if arg_types[0] == Type.Str {
                        var d = self.err("E0102", "`{name}()` converts numbers, found `string`", args[0].start, args[0].end)
                        d.help = "to read a number from text use `parse_{name}(s)`, which can fail"
                    } else {
                        self.numeric(name, arg_types, args, 0)
                    }
                }
                if name == "int" {
                    return outcome(Type.Int, false)
                }
                return outcome(Type.Float, false)
            }
            "abs" {
                if self.arity(name, e, args, 1) {
                    self.numeric(name, arg_types, args, 0)
                    return outcome(arg_types[0], false)
                }
                return outcome(Type.Unknown, false)
            }
            "min", "max" {
                if self.arity(name, e, args, 2) {
                    self.numeric(name, arg_types, args, 0)
                    self.numeric(name, arg_types, args, 1)
                    var both_int = arg_types[0] == Type.Int && arg_types[1] == Type.Int
                    if !both_int {
                        self.widen(arg_types[0], Type.Float, args[0])
                        self.widen(arg_types[1], Type.Float, args[1])
                        return outcome(Type.Float, false)
                    }
                    return outcome(Type.Int, false)
                }
                return outcome(Type.Unknown, false)
            }
            else {
                return outcome(Type.Unknown, false)
            }
        }
    }

    // `list.map(f)` and `list.sort_by(f)`: what they give depends on `f`.
    fn transform(self, e: ast.Expr, t: Type, name: string, args: [ast.Expr]) -> Outcome {
        self.an.calls[e.id] = CallKind.BuiltinMethod(Recv.List, name)
        self.mark_async()
        if args.len() != 1 {
            self.err("E0104", "`{name}` takes 1 argument but {args.len()} were given", e.start, e.end)
            return self.skip_args(args)
        }
        var ft = self.expr(args[0], Type.Unknown)
        self.callback(args[0])
        var ret = Type.Unknown
        var fits = is_unknown(ft)
        match ft {
            Fn(sig) {
                if sig.params.len() == 1 && !sig.fallible && self.assignable(t, sig.params[0]) {
                    ret = sig.ret
                    fits = true
                }
            }
            else {
            }
        }
        if !fits {
            self.err("E0102", "`{name}` needs a function taking one `{show(t)}`, found `{show(ft)}`", args[0].start, args[0].end)
        }
        if name == "map" {
            if ret == Type.Void {
                self.err("E0102", "the function given to `map` must return a value", args[0].start, args[0].end)
            }
            return outcome(Type.List(ret), false)
        }
        if !(ret == Type.Int || ret == Type.Float || ret == Type.Str || is_unknown(ret)) {
            self.err("E0102", "`sort_by` needs a function returning int, float or string, found `{show(ret)}`", args[0].start, args[0].end)
        }
        return outcome(Type.List(t), false)
    }

    fn builtin_method(self, e: ast.Expr, recv: Type, name: string, name_start: int, name_end: int, args: [ast.Expr]) -> Outcome {
        var found = true
        var kind = Recv.Str
        var params: [Type] = []
        var ret = Type.Void
        var fallible = false
        var is_async = false
        match recv {
            Str {
                match name {
                    "len" {
                        ret = Type.Int
                    }
                    "upper", "lower", "trim" {
                        ret = Type.Str
                    }
                    "split" {
                        params = [Type.Str]
                        ret = Type.List(Type.Str)
                    }
                    "contains", "starts_with", "ends_with" {
                        params = [Type.Str]
                        ret = Type.Bool
                    }
                    "replace" {
                        params = [Type.Str, Type.Str]
                        ret = Type.Str
                    }
                    "index_of" {
                        params = [Type.Str]
                        ret = Type.Int
                    }
                    "slice" {
                        params = [Type.Int, Type.Int]
                        ret = Type.Str
                    }
                    "chars" {
                        ret = Type.List(Type.Str)
                    }
                    "repeat" {
                        params = [Type.Int]
                        ret = Type.Str
                    }
                    else {
                        found = false
                    }
                }
            }
            List(t) {
                kind = Recv.List
                var sortable = t == Type.Int || t == Type.Float || t == Type.Str || is_unknown(t)
                match name {
                    "len" {
                        ret = Type.Int
                    }
                    "push" {
                        params = [t]
                    }
                    "pop", "first", "last" {
                        ret = t
                        fallible = true
                    }
                    "contains" {
                        params = [t]
                        ret = Type.Bool
                    }
                    "index_of" {
                        params = [t]
                        ret = Type.Int
                    }
                    "reverse" {
                        ret = Type.List(t)
                    }
                    "slice" {
                        params = [Type.Int, Type.Int]
                        ret = Type.List(t)
                    }
                    "insert" {
                        params = [Type.Int, t]
                    }
                    "remove" {
                        params = [Type.Int]
                        ret = t
                    }
                    "clear" {
                    }
                    "join" {
                        params = [Type.Str]
                        ret = Type.Str
                    }
                    "sort" {
                        if !sortable {
                            var d = self.err("E0102", "cannot sort a list of `{show(t)}`", name_start, name_end)
                            d.help = "`.sort()` works on int, float and string; use `.sort_by(fn(x: T) -> int \{ ... \})` for other types"
                        }
                        ret = Type.List(t)
                    }
                    "filter" {
                        params = [Type.Fn(FnSig{params: [t], ret: Type.Bool, fallible: false})]
                        ret = Type.List(t)
                        is_async = true
                    }
                    "map", "sort_by" {
                        return self.transform(e, t, name, args)
                    }
                    else {
                        found = false
                    }
                }
            }
            Map(k, v) {
                kind = Recv.Map
                match name {
                    "len" {
                        ret = Type.Int
                    }
                    "get" {
                        params = [k]
                        ret = v
                        fallible = true
                    }
                    "has" {
                        params = [k]
                        ret = Type.Bool
                    }
                    "remove" {
                        params = [k]
                    }
                    "keys" {
                        ret = Type.List(k)
                    }
                    "values" {
                        ret = Type.List(v)
                    }
                    "clear" {
                    }
                    else {
                        found = false
                    }
                }
            }
            Chan(_) {
                kind = Recv.Chan
                found = name == "close"
            }
            Weak(target) {
                kind = Recv.Weak
                found = name == "get"
                ret = target
                fallible = true
            }
            else {
                found = false
            }
        }
        if !found {
            for a in args {
                self.expr(a, Type.Unknown)
            }
            var d = self.err("E0106", "`{show(recv)}` has no method `{name}`", name_start, name_end)
            if ["length", "size", "count"].contains(name) {
                d.help = "use `.len()`"
            } else if ["append", "add"].contains(name) && kind == Recv.List {
                d.help = "use `.push(value)`"
            }
            return outcome(Type.Unknown, false)
        }
        self.args(params, args, e, "`{name}`")
        if kind == Recv.List && name == "filter" && args.len() == 1 {
            self.callback(args[0])
        }
        self.an.calls[e.id] = CallKind.BuiltinMethod(kind, name)
        if is_async {
            self.mark_async()
        }
        return outcome(ret, fallible)
    }
}

fn has_field(info: StructInfo, name: string) -> bool {
    for f in info.fields {
        if f.name == name {
            return true
        }
    }
    return false
}

fn variant_names(variants: [Variant]) -> [string] {
    var names: [string] = []
    for v in variants {
        names.push(v.name)
    }
    return names
}

// A pattern of `match` that is a value: a whole number, a string without
// interpolation, `true` or `false`.
fn is_plain_pattern(value: ast.Expr) -> bool {
    match value.kind {
        Int(_), Bool(_) {
            return true
        }
        Str(parts) {
            for part in parts {
                match part {
                    Code(_) {
                        return false
                    }
                    else {
                    }
                }
            }
            return true
        }
        Unary(op, inner) {
            match inner.kind {
                Int(_) {
                    return op == ast.UnOp.Neg
                }
                else {
                    return false
                }
            }
        }
        else {
            return false
        }
    }
}

// How a body of code is named in messages ("" for those that are not).
fn describe(key: string) -> string {
    if key.starts_with("fn:") {
        return "`" + key.slice(3, key.len()) + "`"
    }
    if key.starts_with("m:") {
        return "`" + key.slice(2, key.len()) + "`"
    }
    if key.starts_with("lambda:") {
        return "a lambda"
    }
    return ""
}

// The module of a prefixed name: `geo` for `geo.area`, "" for `area`.
fn module_of(name: string) -> string {
    var parts = name.split(".")
    if parts.len() == 1 {
        return ""
    }
    return parts.slice(0, parts.len() - 1).join(".")
}

// Checks a program. `runtime_start` and `runtime_end` are where the source
// of the native runtime is (-1 when it is not part of the program). Fails
// after noting the problems in `report`.
fn check(program: ast.Program, src: [int], require_main: bool, runtime_start: int, runtime_end: int, report: diag.Report) -> Analysis! {
    var c = Checker{
        src: src,
        report: report,
        structs: {},
        interfaces: {},
        fns: {},
        scopes: [],
        ctx: [],
        handling: {},
        catch_id: -1,
        catch_needs: false,
        async_info: {},
        escaping: [],
        global_names: {},
        global_inits: [],
        forks: 0,
        runtime_start: runtime_start,
        runtime_end: runtime_end,
        an: Analysis{
            types: {},
            calls: {},
            async_keys: {},
            structs: {},
            fns: {},
            catch_values: {},
            fallible_calls: {},
            widened: {},
            enums: {},
            variants: {}
        }
    }
    c.push_scope()
    c.run(program, require_main)
    if report.diags.len() > 0 {
        report.diags = report.diags.sort_by(fn(d: diag.Diag) -> int {
            return d.start
        })
        fail "types"
    }
    c.an.structs = c.structs
    c.an.fns = c.fns
    return c.an
}

// ---- the analysis as text ----

fn recv_name(r: Recv) -> string {
    match r {
        Str {
            return "Str"
        }
        List {
            return "List"
        }
        Map {
            return "Map"
        }
        Chan {
            return "Chan"
        }
        Weak {
            return "Weak"
        }
    }
}

// The analysis as text, in the same form as `onyx types` of the compiler
// written in Rust.
fn dump(an: Analysis) -> [string] {
    var lines: [string] = []
    for id in an.types.keys().sort() {
        var line = str(id) + " " + show(an.types[id])
        if an.calls.has(id) {
            match an.calls[id] {
                Fn(name) {
                    line += " call=fn:" + name
                }
                Method(strukt, name) {
                    line += " call=method:" + strukt + "." + name
                }
                Builtin(name) {
                    line += " call=builtin:" + name
                }
                BuiltinMethod(recv, name) {
                    line += " call=" + recv_name(recv) + "." + name
                }
                Dynamic {
                    line += " call=dynamic"
                }
            }
        }
        if an.fallible_calls.has(id) {
            line += " fallible"
        }
        if an.widened.has(id) {
            line += " widened"
        }
        if an.catch_values.has(id) {
            line += " catch-value"
        }
        if an.variants.has(id) {
            var v = an.variants[id]
            line += " variant={v.enum_name}:{v.index}"
        }
        lines.push(line)
    }
    for key in an.async_keys.keys().sort() {
        lines.push("async " + key)
    }
    for name in an.fns.keys().sort() {
        lines.push("fn " + name + " " + show_sig(an.fns[name]))
    }
    for name in an.structs.keys().sort() {
        var info = an.structs[name]
        lines.push("struct " + name)
        for f in info.fields {
            lines.push("  field " + f.name + " " + show(f.ty))
        }
        for method in info.methods.keys().sort() {
            lines.push("  method " + method + " " + show_sig(info.methods[method]))
        }
    }
    for name in an.enums.keys().sort() {
        lines.push("enum " + name)
        for v in an.enums[name] {
            var line = "  variant " + v.name
            for t in v.fields {
                line += " " + show(t)
            }
            lines.push(line)
        }
    }
    return lines
}
