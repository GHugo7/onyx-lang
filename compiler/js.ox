// The JavaScript target: the checked program as one .js file, with the
// runtime in it. Follows src/codegen_js.rs, and writes the same text.

import "ast"
import "checker"
import "errors"
import "modules"

const RUNTIME = embed("../src/runtime.js")

// Names that would clash with JavaScript syntax or with globals the
// generated code uses.
fn js_reserved() -> [string] {
    return ["arguments", "async", "await", "case", "class", "debugger", "default", "delete", "do", "enum",
        "eval", "export", "extends", "finally", "function", "implements", "import", "instanceof", "let",
        "new", "null", "package", "private", "protected", "public", "static", "super", "switch",
        "this", "throw", "try", "typeof", "undefined", "var", "void", "with", "yield", "NaN",
        "Infinity", "Math", "Map", "Array", "Date", "Promise", "Object", "String", "Number",
        "Symbol", "Error", "console", "process", "require", "globalThis"]
}

fn js_name(name: string) -> string {
    if js_reserved().contains(name) {
        return name + "$"
    }
    // Names from imported modules look like `module.name`.
    return name.replace(".", "$").replace("~", "$")
}

fn prop(name: string) -> string {
    if name == "constructor" || name == "__proto__" || name == "prototype" {
        return name + "$"
    }
    return name
}

fn hex_digits(n: int, width: int) -> string {
    var digits = "0123456789abcdef"
    var out = ""
    var rest = n
    for _ in 0..width {
        out = digits[rest & 15] + out
        rest = rest >> 4
    }
    return out
}

fn js_string(s: string) -> string {
    var out = "\""
    for c in s {
        var code = ord(c)
        if c == "\"" {
            out += "\\\""
        } else if c == "\\" {
            out += "\\\\"
        } else if c == "\n" {
            out += "\\n"
        } else if c == "\r" {
            out += "\\r"
        } else if c == "\t" {
            out += "\\t"
        } else if code < 0x20 || code == 0x2028 || code == 0x2029 {
            out += "\\u" + hex_digits(code, 4)
        } else {
            out += c
        }
    }
    return out + "\""
}

// A float as Rust's `{:?}` writes it: the shortest digits that read back as
// the same number, in decimal from 1e-4 to 1e16 (with `.0` when whole),
// with an exponent otherwise.
fn float_text(x: float) -> string {
    // The sign comes from the bits: `str` writes -0.0 as 0.0, as JavaScript does.
    var sign = ""
    if float_bits(x) < 0 {
        sign = "-"
    }
    var shown = str(abs(x))
    if shown == "inf" || shown == "NaN" {
        return sign + shown
    }
    // `str` gives the same digits, written as JavaScript does.
    var exponent = 0
    var mantissa = shown
    var e = shown.index_of("e")
    if e >= 0 {
        mantissa = shown.slice(0, e)
        exponent = parse_int(shown.slice(e + 1, shown.len()).replace("+", "")) or 0
    }
    var point = mantissa.index_of(".")
    if point < 0 {
        point = mantissa.len()
    }
    var digits = mantissa.replace(".", "")
    // The number is 0.digits * 10^power.
    var power = point + exponent
    while digits.len() > 0 && digits[0] == "0" {
        digits = digits.slice(1, digits.len())
        power -= 1
    }
    while digits.len() > 0 && digits[digits.len() - 1] == "0" {
        digits = digits.slice(0, digits.len() - 1)
    }
    if digits == "" {
        return sign + "0.0"
    }
    if power >= -3 && power <= 16 {
        if power <= 0 {
            return sign + "0." + "0".repeat(-power) + digits
        }
        if power < digits.len() {
            return sign + digits.slice(0, power) + "." + digits.slice(power, digits.len())
        }
        return sign + digits + "0".repeat(power - digits.len()) + ".0"
    }
    var out = sign + digits[0]
    if digits.len() > 1 {
        out += "." + digits.slice(1, digits.len())
    }
    return out + "e" + str(power - 1)
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

// In JavaScript an int and a float are the same kind of number, so a value
// alone does not tell whether `2` should be shown as `2` or `2.0`. Where
// the type says that floats are involved, the runtime is told where they
// are: `1` for a float, `[shape]` for a list of them, `{v: shape}` for the
// values of a map. Structs carry this information themselves (`$floats`).
fn float_shape(ty: checker.Type) -> [string] {
    match ty {
        Float {
            return ["1"]
        }
        List(elem) {
            for shape in float_shape(elem) {
                return ["[" + shape + "]"]
            }
            return []
        }
        Map(_, value) {
            for shape in float_shape(value) {
                return ["\{v: " + shape + "}"]
            }
            return []
        }
        else {
            return []
        }
    }
}

// Where the value of a `catch` expression goes.
enum Sink {
    Var(string)
    Assign(target: ast.Expr, op: ast.AssignOp)
    Return
    Discard
}

// `tests`: emit the `check` blocks and run them instead of `main`.
fn generate(program: ast.Program, an: checker.Analysis, sources: modules.Sources, test_mode: bool) -> string {
    var top: map<string, string> = {}
    var g = Js{an: an, sources: sources, test_mode: test_mode, out: [], indent: 0, tmp: 0, awaits: 0, handlers: 0, scopes: [top]}
    g.out.push("// Generated by the Onyx compiler. Do not edit.\n")
    g.out.push(RUNTIME)
    g.out.push("\n(async () => \{\n\"use strict\";\n")

    // Globals are visible everywhere, so register their names first.
    for item in program.items {
        match item {
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, _, _, _) {
                        top[name] = js_name(name)
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    for item in program.items {
        match item {
            Struct(s) {
                g.strukt(s)
            }
            Enum(e) {
                // A value of an enum: which variant (`v`) and what it carries (`f`).
                var names: [string] = []
                var floats: [string] = []
                for v in an.enums[e.name] {
                    names.push(js_string(v.name))
                    var shapes: [string] = []
                    for t in v.fields {
                        var shape = "0"
                        for s in float_shape(t) {
                            shape = s
                        }
                        shapes.push(shape)
                    }
                    floats.push("[" + shapes.join(", ") + "]")
                }
                g.line("class " + js_name(e.name) + " \{")
                g.line("  constructor(v, f) \{")
                g.line("    this.v = v;")
                g.line("    this.f = f;")
                g.line("  }")
                g.line("  static $enum = " + js_string(e.name) + ";")
                g.line("  static $variants = [" + names.join(", ") + "];")
                g.line("  static $floats = [" + floats.join(", ") + "];")
                g.line("}")
            }
            else {
            }
        }
    }
    for item in program.items {
        match item {
            Fn(f) {
                var header = "function " + js_name(f.name)
                if an.async_keys.has(checker.fn_key(f.name)) {
                    header = "async " + header
                }
                g.function(header, f)
            }
            else {
            }
        }
    }
    var globals: [string] = []
    for item in program.items {
        match item {
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, _, _, _) {
                        globals.push(js_name(name))
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    if globals.len() > 0 {
        g.line("let " + globals.join(", ") + ";")
    }
    if test_mode {
        g.line("const $tests = [];")
        for item in program.items {
            match item {
                Check(name, body) {
                    g.line("$tests.push([" + js_string(name) + ", async () => \{")
                    g.block_body(body)
                    g.line("}]);")
                }
                else {
                }
            }
        }
    }
    // Everything that runs is inside `$rt.run`, which reports failures properly.
    g.line("await $rt.run(async () => \{")
    g.indent += 1
    for item in program.items {
        match item {
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, _, _, init) {
                        var value = g.expr(init)
                        g.line(js_name(name) + " = " + value + ";")
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    if test_mode {
        g.line("await $rt.runTests($tests);")
    } else {
        g.line("await main();")
    }
    g.indent -= 1
    g.line("});")
    g.out.push("})();\n")
    return g.out.join("")
}

struct Js {
    an: checker.Analysis
    // Used to report the file and line of a failed `expect`.
    sources: modules.Sources
    test_mode: bool
    // The text so far, in pieces.
    out: [string]
    indent: int
    tmp: int
    // Number of `await`s emitted so far; used to decide whether a thunk must be async.
    awaits: int
    // How many `or`/`catch` subjects enclose the expression being generated,
    // within the current function. A `?` in there has to get past them.
    handlers: int
    // Onyx variable name -> JavaScript name, innermost scope last.
    scopes: [map<string, string>]

    fn line(self, text: string) {
        self.out.push("  ".repeat(self.indent) + text + "\n")
    }

    fn fresh(self, prefix: string) -> string {
        self.tmp += 1
        return "$" + prefix + str(self.tmp)
    }

    fn ty(self, e: ast.Expr) -> checker.Type {
        if self.an.types.has(e.id) {
            return self.an.types[e.id]
        }
        return checker.Type.Unknown
    }

    // ---- scopes ----

    fn push_scope(self) {
        var scope: map<string, string> = {}
        self.scopes.push(scope)
    }

    fn pop_scope(self) {
        self.scopes.remove(self.scopes.len() - 1)
    }

    // Declares an Onyx variable and returns its JavaScript name, renaming it
    // when it would shadow a variable of an enclosing scope (JavaScript's
    // `let x = x + 1` does not see the outer `x`).
    fn declare(self, name: string) -> string {
        var base = js_name(name)
        var taken = false
        for scope in self.scopes {
            if scope.values().contains(base) {
                taken = true
            }
        }
        var js = base
        if taken {
            js = base + self.fresh("")
        }
        var scope = self.scopes[self.scopes.len() - 1]
        scope[name] = js
        return js
    }

    fn resolve(self, name: string) -> string {
        if name == "self" {
            return "this"
        }
        var i = self.scopes.len() - 1
        while i >= 0 {
            if self.scopes[i].has(name) {
                return self.scopes[i][name]
            }
            i -= 1
        }
        return js_name(name)
    }

    // ---- declarations ----

    fn strukt(self, s: ast.StructDecl) {
        self.line("class " + js_name(s.name) + " \{")
        self.indent += 1
        self.line("static $name = " + js_string(s.name) + ";")
        // Which fields hold floats (see `float_shape`).
        var floats: [string] = []
        for f in self.an.structs[s.name].fields {
            for shape in float_shape(f.ty) {
                floats.push(prop(f.name) + ": " + shape)
            }
        }
        if floats.len() > 0 {
            self.line("static $floats = \{ " + floats.join(", ") + " };")
        }
        var params: [string] = []
        for i in 0..s.fields.len() {
            params.push("$" + str(i))
        }
        self.line("constructor(" + params.join(", ") + ") \{")
        self.indent += 1
        for i in 0..s.fields.len() {
            self.line("this." + prop(s.fields[i].name) + " = $" + str(i) + ";")
        }
        self.indent -= 1
        self.line("}")
        for m in s.methods {
            var header = prop(m.name)
            if self.an.async_keys.has(checker.method_key(s.name, m.name)) {
                header = "async " + header
            }
            self.function(header, m)
        }
        self.indent -= 1
        self.line("}")
    }

    fn function(self, header: string, f: ast.FnDecl) {
        self.push_scope()
        var params: [string] = []
        for p in f.params {
            params.push(self.declare(p.name))
        }
        self.line(header + "(" + params.join(", ") + ") \{")
        self.indent += 1
        for stmt in f.body.stmts {
            self.stmt(stmt)
        }
        self.indent -= 1
        self.line("}")
        self.pop_scope()
    }

    // Emits the statements of a block, indented, in a fresh scope (no braces).
    fn block_body(self, block: ast.Block) {
        self.push_scope()
        self.indent += 1
        for stmt in block.stmts {
            self.stmt(stmt)
        }
        self.indent -= 1
        self.pop_scope()
    }

    // ---- statements ----

    fn stmt(self, stmt: ast.Stmt) {
        match stmt.kind {
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
            Let(name, _, _, _, _, init) {
                if is_catch(init) {
                    // Declare first so the sink can assign from both branches.
                    var js = self.declare(name)
                    self.line("let " + js + ";")
                    self.catch_expr(init, Sink.Var(js))
                } else {
                    var value = self.expr(init)
                    var js = self.declare(name)
                    self.line("let " + js + " = " + value + ";")
                }
            }
            Assign(target, op, value) {
                if is_catch(value) {
                    self.catch_expr(value, Sink.Assign(target, op))
                } else {
                    var v = self.expr(value)
                    var code = self.assign(target, op, v)
                    self.line(code)
                }
            }
            Expr(e) {
                if is_catch(e) {
                    self.catch_expr(e, Sink.Discard)
                } else {
                    var code = self.expr(e)
                    self.line(code + ";")
                }
            }
            If(_, _, _) {
                self.if_stmt(stmt, "if")
            }
            While(cond, body) {
                var c = self.expr(cond)
                self.line("while (" + c + ") \{")
                self.block_body(body)
                self.line("}")
            }
            For(name, _, _, iter, body) {
                self.for_stmt(name, iter, body)
            }
            Return(value) {
                if value.len() == 0 {
                    self.line("return;")
                } else if is_catch(value[0]) {
                    self.catch_expr(value[0], Sink.Return)
                } else {
                    var code = self.expr(value[0])
                    self.line("return " + code + ";")
                }
            }
            Break {
                self.line("break;")
            }
            Continue {
                self.line("continue;")
            }
            Fail(value) {
                var v = self.expr(value)
                self.line("$rt.fail(" + v + ");")
            }
            Fork(body) {
                var saved = self.awaits
                var handlers = self.handlers
                self.handlers = 0
                self.line("$rt.fork(async () => \{")
                self.block_body(body)
                self.line("});")
                self.handlers = handlers
                self.awaits = saved
            }
            Send(channel, value) {
                var c = self.expr(channel)
                var v = self.expr(value)
                self.awaits += 1
                self.line("await " + c + ".send(" + v + ");")
            }
            Block(body) {
                self.line("\{")
                self.block_body(body)
                self.line("}")
            }
        }
    }

    fn if_stmt(self, stmt: ast.Stmt, keyword: string) {
        match stmt.kind {
            If(cond, then, els) {
                var c = self.expr(cond)
                self.line(keyword + " (" + c + ") \{")
                self.block_body(then)
                if els.len() == 0 {
                    self.line("}")
                    return
                }
                match els[0].kind {
                    // The condition of an `else if` is a plain expression: chain directly.
                    If(_, _, _) {
                        self.if_stmt(els[0], "} else if")
                    }
                    Block(body) {
                        self.line("} else \{")
                        self.block_body(body)
                        self.line("}")
                    }
                    else {
                        self.line("}")
                    }
                }
            }
            else {
            }
        }
    }

    fn for_stmt(self, name: string, iter: ast.Expr, body: ast.Block) {
        self.push_scope()
        match self.ty(iter) {
            Range {
                var lo = ""
                var hi = ""
                match iter.kind {
                    Range(lo_expr, hi_expr) {
                        lo = self.expr(lo_expr)
                        hi = self.expr(hi_expr)
                    }
                    else {
                        var r = self.fresh("r")
                        var value = self.expr(iter)
                        self.line("const " + r + " = " + value + ";")
                        lo = r + "[0]"
                        hi = r + "[1]"
                    }
                }
                var end = self.fresh("n")
                var v = self.declare(name)
                self.line("for (let " + v + " = " + lo + ", " + end + " = " + hi + "; " + v + " < " + end + "; " + v + "++) \{")
            }
            Map(_, _) {
                var m = self.expr(iter)
                var v = self.declare(name)
                self.line("for (const " + v + " of (" + m + ").keys()) \{")
            }
            Chan(_) {
                var c = self.fresh("c")
                var got = self.fresh("v")
                var ch = self.expr(iter)
                var v = self.declare(name)
                self.awaits += 1
                self.line("for (const " + c + " = " + ch + ";;) \{")
                self.indent += 1
                self.line("const " + got + " = await " + c + ".recvOpt();")
                self.line("if (" + got + " === $rt.CLOSED) break;")
                self.line("const " + v + " = " + got + ";")
                self.indent -= 1
            }
            else {
                var list = self.expr(iter)
                var v = self.declare(name)
                self.line("for (const " + v + " of " + list + ") \{")
            }
        }
        self.block_body(body)
        self.line("}")
        self.pop_scope()
    }

    // Builds the statement that stores `value` (already JavaScript) into `target`.
    fn assign(self, target: ast.Expr, op: ast.AssignOp, value: string) -> string {
        var is_int = self.ty(target) == checker.Type.Int
        match target.kind {
            Index(obj, index) {
                var o = self.expr(obj)
                var i = self.expr(index)
                match self.ty(obj) {
                    Map(_, _) {
                        return o + ".set(" + i + ", " + combine(op, is_int, "$rt.mapGet(" + o + ", " + i + ")", value) + ");"
                    }
                    else {
                        return "$rt.setIdx(" + o + ", " + i + ", " + combine(op, is_int, "$rt.idx(" + o + ", " + i + ")", value) + ");"
                    }
                }
            }
            else {
                var t = self.expr(target)
                return t + " = " + combine(op, is_int, t, value) + ";"
            }
        }
    }

    // `call() catch err { ... }`, lowered to try/catch.
    fn catch_expr(self, e: ast.Expr, sink: Sink) {
        match e.kind {
            Catch(inner, name, _, _, body) {
                var has_value = self.an.catch_values.has(e.id)
                self.handlers += 1
                var subject = self.expr(inner)
                self.handlers -= 1
                var caught = self.fresh("e")
                self.line("try \{")
                self.indent += 1
                self.sink(sink, subject)
                self.indent -= 1
                self.line("} catch (" + caught + ") \{")
                self.push_scope()
                self.indent += 1
                var err = self.declare(name)
                self.line("const " + err + " = $rt.caught(" + caught + ");")
                var count = body.stmts.len()
                if has_value && count > 0 {
                    count -= 1
                }
                for i in 0..count {
                    self.stmt(body.stmts[i])
                }
                if has_value && body.stmts.len() > 0 {
                    match body.stmts[body.stmts.len() - 1].kind {
                        Expr(value) {
                            var v = self.expr(value)
                            self.sink(sink, v)
                        }
                        else {
                        }
                    }
                }
                self.indent -= 1
                self.pop_scope()
                self.line("}")
            }
            else {
            }
        }
    }

    fn sink(self, sink: Sink, value: string) {
        match sink {
            Var(name) {
                self.line(name + " = " + value + ";")
            }
            Assign(target, op) {
                var code = self.assign(target, op, value)
                self.line(code)
            }
            Return {
                self.line("return " + value + ";")
            }
            Discard {
                self.line(value + ";")
            }
        }
    }

    // ---- expressions ----

    fn await_(self, code: string) -> string {
        self.awaits += 1
        return "(await " + code + ")"
    }

    // Converts an expression to its display string.
    fn to_str(self, e: ast.Expr) -> string {
        var code = self.expr(e)
        var ty = self.ty(e)
        if ty == checker.Type.Str {
            return code
        }
        if ty == checker.Type.Float {
            return "$rt.fstr(" + code + ")"
        }
        for shape in float_shape(ty) {
            return "$rt.str(" + code + ", " + shape + ")"
        }
        return "$rt.str(" + code + ")"
    }

    fn exprs(self, list: [ast.Expr]) -> string {
        var parts: [string] = []
        for e in list {
            parts.push(self.expr(e))
        }
        return parts.join(", ")
    }

    fn expr(self, e: ast.Expr) -> string {
        match e.kind {
            // Parentheses keep a negative literal from merging with a preceding `-`.
            Int(n) {
                if n < 0 {
                    return "(" + str(n) + ")"
                }
                return str(n)
            }
            Float(x) {
                if x < 0.0 {
                    return "(" + float_text(x) + ")"
                }
                return float_text(x)
            }
            Bool(b) {
                return str(b)
            }
            Str(parts) {
                if parts.len() == 1 {
                    match parts[0] {
                        Lit(s) {
                            return js_string(s)
                        }
                        else {
                        }
                    }
                }
                var pieces: [string] = []
                for p in parts {
                    match p {
                        Lit(s) {
                            pieces.push(js_string(s))
                        }
                        Code(inner) {
                            pieces.push(self.to_str(inner))
                        }
                    }
                }
                return "(" + pieces.join(" + ") + ")"
            }
            Ident(name) {
                return self.resolve(name)
            }
            List(items) {
                return "[" + self.exprs(items) + "]"
            }
            Map(entries) {
                var pairs: [string] = []
                for entry in entries {
                    var k = self.expr(entry.key)
                    var v = self.expr(entry.value)
                    pairs.push("[" + k + ", " + v + "]")
                }
                return "new Map([" + pairs.join(", ") + "])"
            }
            StructLit(name, _, _, fields) {
                // Constructor arguments follow the declaration order of the fields.
                var args: [string] = []
                for field in self.an.structs[name].fields {
                    for init in fields {
                        if init.name == field.name {
                            args.push(self.expr(init.value))
                            break
                        }
                    }
                }
                return "new " + js_name(name) + "(" + args.join(", ") + ")"
            }
            Unary(op, inner) {
                var v = self.expr(inner)
                if op == ast.UnOp.Neg {
                    return "(-" + v + ")"
                }
                return "(!" + v + ")"
            }
            Binary(op, lhs, rhs) {
                var l = self.expr(lhs)
                var r = self.expr(rhs)
                var both_int = self.ty(lhs) == checker.Type.Int && self.ty(rhs) == checker.Type.Int
                var simple_eq = primitive(self.ty(lhs)) && primitive(self.ty(rhs))
                if op == ast.BinOp.Div && both_int {
                    return "$rt.idiv(" + l + ", " + r + ")"
                }
                if op == ast.BinOp.Mod && both_int {
                    return "$rt.imod(" + l + ", " + r + ")"
                }
                if op == ast.BinOp.Eq && simple_eq {
                    return "(" + l + " === " + r + ")"
                }
                if op == ast.BinOp.NotEq && simple_eq {
                    return "(" + l + " !== " + r + ")"
                }
                if op == ast.BinOp.Eq {
                    return "$rt.eq(" + l + ", " + r + ")"
                }
                if op == ast.BinOp.NotEq {
                    return "(!$rt.eq(" + l + ", " + r + "))"
                }
                return "(" + l + " " + symbol(op) + " " + r + ")"
            }
            Call(callee, args) {
                return self.call(e, callee, args)
            }
            Field(obj, name, _, _) {
                if self.an.variants.has(e.id) {
                    var v = self.an.variants[e.id]
                    return "new " + js_name(v.enum_name) + "(" + str(v.index) + ", [])"
                }
                var o = self.expr(obj)
                return o + "." + prop(name)
            }
            Index(obj, index) {
                var o = self.expr(obj)
                var i = self.expr(index)
                match self.ty(obj) {
                    Map(_, _) {
                        return "$rt.mapGet(" + o + ", " + i + ")"
                    }
                    Str {
                        return "$rt.strIdx(" + o + ", " + i + ")"
                    }
                    else {
                        return "$rt.idx(" + o + ", " + i + ")"
                    }
                }
            }
            Lambda(params, _, _, body) {
                var is_async = self.an.async_keys.has(checker.lambda_key(e.id))
                var saved_awaits = self.awaits
                var saved_handlers = self.handlers
                self.handlers = 0
                var saved_out = self.out
                self.out = []
                self.push_scope()
                var names: [string] = []
                for p in params {
                    names.push(self.declare(p.name))
                }
                self.indent += 1
                for stmt in body.stmts {
                    self.stmt(stmt)
                }
                self.indent -= 1
                self.pop_scope()
                var body_code = self.out.join("")
                self.out = saved_out
                self.awaits = saved_awaits
                self.handlers = saved_handlers
                var close = "  ".repeat(self.indent)
                var keyword = ""
                if is_async {
                    keyword = "async "
                }
                return "(" + keyword + "(" + names.join(", ") + ") => \{\n" + body_code + close + "})"
            }
            // An error is an exception that travels up by itself. Inside the
            // subject of an `or` or a `catch`, though, `?` still means "leave
            // the function": the error is wrapped so that it gets past them.
            Try(inner) {
                if self.handlers == 0 {
                    return self.expr(inner)
                }
                var depth = self.handlers
                var before = self.awaits
                var value = self.expr(inner)
                if self.awaits > before {
                    return self.await_("$rt.passAsync(" + str(depth) + ", async () => " + value + ")")
                }
                return "$rt.pass(" + str(depth) + ", () => " + value + ")"
            }
            Or(inner, default) {
                var before = self.awaits
                self.handlers += 1
                var value = self.expr(inner)
                self.handlers -= 1
                var fallback = self.expr(default)
                if self.awaits > before {
                    return self.await_("$rt.orAsync(async () => " + value + ", async () => " + fallback + ")")
                }
                return "$rt.or(() => " + value + ", () => " + fallback + ")"
            }
            // The checker only accepts `catch` at statement level, handled in `stmt`.
            Catch(inner, _, _, _, _) {
                return self.expr(inner)
            }
            Recv(channel) {
                var c = self.expr(channel)
                return self.await_(c + ".recv()")
            }
            ChanNew(_, cap) {
                var size = "0"
                for c in cap {
                    size = self.expr(c)
                }
                return "new $rt.Chan(" + size + ")"
            }
            Range(lo, hi) {
                var l = self.expr(lo)
                var h = self.expr(hi)
                return "[" + l + ", " + h + "]"
            }
        }
    }

    fn call(self, e: ast.Expr, callee: ast.Expr, args: [ast.Expr]) -> string {
        if self.an.variants.has(e.id) {
            var v = self.an.variants[e.id]
            return "new " + js_name(v.enum_name) + "(" + str(v.index) + ", [" + self.exprs(args) + "])"
        }
        var kind = checker.CallKind.Dynamic
        if self.an.calls.has(e.id) {
            kind = self.an.calls[e.id]
        }
        var receiver: [ast.Expr] = []
        var field_name = ""
        match callee.kind {
            Field(obj, name, _, _) {
                receiver = [obj]
                field_name = name
            }
            else {
            }
        }
        match kind {
            Fn(name) {
                var code = js_name(name) + "(" + self.exprs(args) + ")"
                if self.an.async_keys.has(checker.fn_key(name)) {
                    return self.await_(code)
                }
                return code
            }
            Method(strukt, name) {
                if receiver.len() == 0 {
                    return ""
                }
                var o = self.expr(receiver[0])
                var code = o + "." + prop(name) + "(" + self.exprs(args) + ")"
                if self.an.async_keys.has(checker.method_key(strukt, name)) {
                    return self.await_(code)
                }
                return code
            }
            Dynamic {
                var f = ""
                if receiver.len() > 0 {
                    f = self.expr(receiver[0]) + "." + prop(field_name)
                } else {
                    f = self.expr(callee)
                }
                var code = f + "(" + self.exprs(args) + ")"
                return self.await_(code)
            }
            Builtin(name) {
                return self.builtin(name, e, args)
            }
            BuiltinMethod(recv, name) {
                if receiver.len() == 0 {
                    return ""
                }
                var obj = receiver[0]
                var o = self.expr(obj)
                var a = self.exprs(args)
                if recv == checker.Recv.List && name == "join" {
                    match self.ty(obj) {
                        List(elem) {
                            for shape in float_shape(elem) {
                                a = a + ", " + shape
                            }
                        }
                        else {
                        }
                    }
                }
                return self.builtin_method(recv, name, o, a)
            }
        }
    }

    fn builtin(self, name: string, e: ast.Expr, args: [ast.Expr]) -> string {
        if name == "print" || name == "eprint" {
            var parts: [string] = []
            for a in args {
                parts.push(self.to_str(a))
            }
            return "$rt." + name + "(" + parts.join(", ") + ")"
        }
        if name == "str" {
            return self.to_str(args[0])
        }
        if name == "expect" {
            var loc = errors.locate(self.sources, e.start)
            // The name of the file, without its folders.
            var parts = loc.file.split("/")
            parts = parts[parts.len() - 1].split("\\")
            var file = parts[parts.len() - 1]
            var place = file + ":" + str(loc.line)
            var cond = self.expr(args[0])
            return "$rt.expect(" + cond + ", " + js_string(place) + ")"
        }
        var a = self.exprs(args)
        if name == "int" {
            return "Math.trunc(" + a + ")"
        }
        if name == "float" {
            return a
        }
        if name == "sleep" {
            return self.await_("$rt.sleep(" + a + ")")
        }
        if name == "fetch" {
            return self.await_("$rt.fetch_(" + a + ")")
        }
        if name == "__field" {
            var value = self.expr(args[0])
            var which = self.expr(args[1])
            return value + ".f[" + which + "]"
        }
        if name == "__tag" {
            return a + ".v"
        }
        if name == "weak" && args.len() == 0 {
            return "$rt.noWeak"
        }
        var functions = runtime_functions()
        if functions.has(name) {
            return functions[name] + "(" + a + ")"
        }
        var constants = runtime_constants()
        if constants.has(name) {
            return constants[name]
        }
        if ["sqrt", "pow", "floor", "ceil", "round", "abs", "min", "max"].contains(name) {
            return "Math." + name + "(" + a + ")"
        }
        return "$rt.panic(\"unknown builtin " + name + "\")"
    }

    fn builtin_method(self, recv: checker.Recv, name: string, o: string, a: string) -> string {
        match recv {
            Str {
                if name == "len" {
                    return o + ".length"
                }
                if name == "upper" {
                    return o + ".toUpperCase()"
                }
                if name == "lower" {
                    return o + ".toLowerCase()"
                }
                if name == "trim" {
                    return o + ".trim()"
                }
                if name == "split" {
                    return "$rt.split(" + o + ", " + a + ")"
                }
                if name == "contains" {
                    return o + ".includes(" + a + ")"
                }
                if name == "starts_with" {
                    return o + ".startsWith(" + a + ")"
                }
                if name == "ends_with" {
                    return o + ".endsWith(" + a + ")"
                }
                if name == "replace" {
                    return "$rt.replace(" + o + ", " + a + ")"
                }
                if name == "index_of" {
                    return o + ".indexOf(" + a + ")"
                }
                if name == "slice" {
                    return o + ".slice(" + a + ")"
                }
                if name == "chars" {
                    return "Array.from(" + o + ")"
                }
                if name == "repeat" {
                    return "$rt.repeat(" + o + ", " + a + ")"
                }
            }
            List {
                if name == "len" {
                    return o + ".length"
                }
                if name == "slice" {
                    return o + ".slice(" + a + ")"
                }
                if name == "push" {
                    return o + ".push(" + a + ")"
                }
                if name == "reverse" {
                    return o + ".slice().reverse()"
                }
                if name == "clear" {
                    return "(" + o + ".length = 0)"
                }
                if ["pop", "first", "last", "sort"].contains(name) {
                    return "$rt.list." + name + "(" + o + ")"
                }
                if ["contains", "join", "insert", "remove"].contains(name) {
                    return "$rt.list." + name + "(" + o + ", " + a + ")"
                }
                if name == "index_of" {
                    return "$rt.list.indexOf(" + o + ", " + a + ")"
                }
                if name == "map" || name == "filter" {
                    return self.await_("$rt.list." + name + "(" + o + ", " + a + ")")
                }
                if name == "sort_by" {
                    return self.await_("$rt.list.sortBy(" + o + ", " + a + ")")
                }
            }
            Map {
                if name == "len" {
                    return o + ".size"
                }
                if name == "get" {
                    return "$rt.mapTryGet(" + o + ", " + a + ")"
                }
                if name == "has" {
                    return o + ".has(" + a + ")"
                }
                if name == "remove" {
                    return o + ".delete(" + a + ")"
                }
                if name == "keys" {
                    return "Array.from(" + o + ".keys())"
                }
                if name == "values" {
                    return "Array.from(" + o + ".values())"
                }
                if name == "clear" {
                    return o + ".clear()"
                }
            }
            Chan {
                if name == "close" {
                    return o + ".close()"
                }
            }
            Weak {
                if name == "get" {
                    return "$rt.weakGet(" + o + ")"
                }
            }
        }
        return "$rt.panic(\"unknown method " + name + "\")"
    }
}

fn is_catch(e: ast.Expr) -> bool {
    match e.kind {
        Catch(_, _, _, _, _) {
            return true
        }
        else {
            return false
        }
    }
}

fn primitive(ty: checker.Type) -> bool {
    return ty == checker.Type.Int || ty == checker.Type.Float || ty == checker.Type.Bool || ty == checker.Type.Str
}

// The value an assignment stores: `value` itself, or `current op value`.
fn combine(op: ast.AssignOp, is_int: bool, current: string, value: string) -> string {
    match op {
        Set {
            return value
        }
        Add {
            return current + " + " + value
        }
        Sub {
            return current + " - " + value
        }
        Mul {
            return current + " * " + value
        }
        Div {
            if is_int {
                return "$rt.idiv(" + current + ", " + value + ")"
            }
            return current + " / " + value
        }
    }
}

// The built-in functions without arguments, and the JavaScript they become.
fn runtime_constants() -> map<string, string> {
    return {
        "stdout_is_terminal": "$rt.isTerminal(1)",
        "stderr_is_terminal": "$rt.isTerminal(2)",
        "args": "$rt.args()",
        "now": "Date.now()",
        "random": "Math.random()"
    }
}

// The built-in functions that are calls to the runtime (or to JavaScript):
// the function each becomes.
fn runtime_functions() -> map<string, string> {
    return {
        "parse_int": "$rt.parseInt_",
        "parse_float": "$rt.parseFloat_",
        "read_file": "$rt.readFile",
        "write_file": "$rt.writeFile",
        "append_file": "$rt.appendFile",
        "file_exists": "$rt.fileExists",
        "set_executable": "$rt.setExecutable",
        "remove_file": "$rt.removeFile",
        "remove_dir": "$rt.removeDir",
        "make_dir": "$rt.makeDir",
        "list_dir": "$rt.listDir",
        "is_dir": "$rt.isDir",
        "run_program": "$rt.runProgram",
        "env": "$rt.env",
        "exit": "$rt.exit",
        "random_int": "$rt.randomInt",
        "bit_and": "$rt.bitAnd",
        "bit_or": "$rt.bitOr",
        "bit_xor": "$rt.bitXor",
        "shift_left": "$rt.shiftLeft",
        "shift_right": "$rt.shiftRight",
        "bit_not": "$rt.bitNot",
        "ord": "$rt.ord",
        "chr": "$rt.chr",
        "bytes": "$rt.bytes",
        "from_bytes": "$rt.fromBytes",
        "float_bits": "$rt.floatBits",
        "float_from_bits": "$rt.floatFromBits",
        "read_bytes": "$rt.readBytes",
        "write_bytes": "$rt.writeBytes",
        "weak": "$rt.weak",
        "input": "$rt.input",
        "panic": "$rt.panic"
    }
}
