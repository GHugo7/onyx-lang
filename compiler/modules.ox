// Loads a program made of several files and links them into one program.
//
// Each imported file is a module. Its top-level names are prefixed with the
// module name (`add` in `utils.ox` becomes `utils.add`), and every reference
// is rewritten accordingly, so the type checker and the code generators only
// ever see one flat program with unique names.
//
// The compiler written in Rust finds out whether two imports name the same
// file by asking the system for its real path. Here paths are tidied up by
// hand (`a/./b/../c.ox` is `a/c.ox`), which comes to the same thing unless
// symbolic links are involved.

import "ast"
import "diag"
import "parser"

// ---- the source files ----

struct SourceFile {
    name: string
    start: int
    end: int
}

// All the source files of a program, stored back to back (with a line break
// between two of them), so that a position also tells which file it is in.
struct Sources {
    bytes: [int]
    files: [SourceFile]

    // Adds a file; returns where it starts.
    fn add(self, name: string, data: [int]) -> int {
        if self.bytes.len() > 0 {
            self.bytes.push(10)
        }
        var start = self.bytes.len()
        for b in data {
            self.bytes.push(b)
        }
        self.files.push(SourceFile{name: name, start: start, end: self.bytes.len()})
        return start
    }
}

// ---- paths ----

// `path` seen from the folder `dir`, without `.` and with the `..` that can
// be resolved resolved.
fn join(dir: string, path: string) -> string {
    var full = path
    if !path.starts_with("/") && dir != "" {
        full = dir + "/" + path
    }
    var absolute = full.starts_with("/")
    var parts: [string] = []
    for part in full.split("/") {
        if part == "" || part == "." {
            continue
        }
        if part == ".." {
            if parts.len() > 0 && parts[parts.len() - 1] != ".." {
                parts.remove(parts.len() - 1)
                continue
            }
            if absolute {
                continue
            }
        }
        parts.push(part)
    }
    var joined = parts.join("/")
    if absolute {
        return "/" + joined
    }
    return joined
}

// The folder that holds the file at `path`: "" for the current one.
fn dir_of(path: string) -> string {
    var parts = path.split("/")
    if parts.len() == 1 {
        return ""
    }
    var dir = parts.slice(0, parts.len() - 1).join("/")
    if dir == "" {
        return "/"
    }
    return dir
}

fn file_name(path: string) -> string {
    var parts = path.split("/")
    return parts[parts.len() - 1]
}

// Imports may leave out the `.ox` at the end.
fn with_extension(path: string) -> string {
    var name = file_name(path)
    if name.len() > 3 && name.ends_with(".ox") {
        return path
    }
    return path + ".ox"
}

// The name of a file without its `.ox`.
fn stem_of(path: string) -> string {
    var name = file_name(path)
    return name.slice(0, name.len() - 3)
}

fn is_letter(c: string) -> bool {
    var code = ord(c)
    return (code >= 97 && code <= 122) || (code >= 65 && code <= 90) || code >= 128
}

fn is_digit(c: string) -> bool {
    var code = ord(c)
    return code >= 48 && code <= 57
}

fn is_identifier(s: string) -> bool {
    if s == "" {
        return false
    }
    var first = true
    for c in s {
        var fits = c == "_" || is_letter(c) || (!first && is_digit(c))
        if !fits {
            return false
        }
        first = false
    }
    return true
}

// The prefix of a module's names, made from its file name.
fn module_base(stem: string) -> string {
    var out = ""
    for c in stem {
        if c == "_" || is_letter(c) || is_digit(c) {
            out += c
        } else {
            out += "_"
        }
    }
    return out
}

// The built-in functions, which a module may not define again.
fn is_builtin(name: string) -> bool {
    var names = ["print", "str", "int", "float", "abs", "min", "max", "weak", "embed", "parse_int", "parse_float",
        "read_file", "write_file", "append_file", "file_exists", "args", "env", "exit", "sleep", "now", "random",
        "random_int", "input", "fetch", "expect", "panic", "sqrt", "bit_and", "bit_or", "bit_xor", "shift_left",
        "shift_right", "bit_not", "ord", "chr", "bytes", "from_bytes", "read_bytes", "write_bytes", "pow",
        "floor", "ceil", "round", "float_bits", "float_from_bits", "__syscall", "__load8", "__load32", "__load64", "__store8", "__store32",
        "__store64", "__copy", "__and", "__or", "__xor", "__shl", "__shr", "__sar", "__call1", "__unwind",
        "__yield", "__switch", "__task_entry", "__fault_entry", "__bits", "__float", "__state", "__str_ptr",
        "__ptr_str", "__td_string"]
    return names.contains(name)
}

// ---- loading ----

struct Module {
    // Prefix for this module's names; empty for the entry file.
    name: string
    items: [ast.Item]
    // Import alias -> module number.
    imports: map<string, int>
    // The folder of the file, to read what it embeds.
    dir: string
}

// The top-level names of a module, before prefixing.
struct ModInfo {
    name: string
    types: map<string, bool>
    values: map<string, bool>
}

fn module_info(module: Module) -> ModInfo {
    var info = ModInfo{name: module.name, types: {}, values: {}}
    for item in module.items {
        match item {
            Fn(f) {
                info.values[f.name] = true
            }
            Struct(s) {
                info.types[s.name] = true
            }
            Interface(i) {
                info.types[i.name] = true
            }
            Enum(e) {
                info.types[e.name] = true
            }
            Global(stmt) {
                match stmt.kind {
                    Let(name, _, _, _, _, _) {
                        info.values[name] = true
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }
    return info
}

struct Loader {
    sources: Sources
    report: diag.Report
    modules: [Module]
    by_path: map<string, int>
    // Module numbers, dependencies first.
    order: [int]
    next_id: int
    used_names: map<string, bool>

    fn load_file(self, path: string, name: string, data: [int]) -> int! {
        var start = self.sources.add(path, data)
        var program = parser.parse(self.sources.bytes, start, start + data.len(), self.next_id, self.report)?
        self.next_id = program.next_id
        var idx = self.modules.len()
        self.by_path[path] = idx
        var imports: map<string, int> = {}
        self.modules.push(Module{name: name, items: [], imports: imports, dir: dir_of(path)})
        self.absorb(idx, dir_of(path), program)?
        self.order.push(idx)
        return idx
    }

    // Adds the items of a parsed file, found in `dir`, to module `idx`,
    // loading what it imports.
    fn absorb(self, idx: int, dir: string, program: ast.Program) -> void! {
        var imports = self.modules[idx].imports
        for item in program.items {
            match item {
                Import(path, alias, start, end) {
                    var file = with_extension(join(dir, path))
                    var stem = stem_of(file)
                    var name = stem
                    for a in alias {
                        name = a
                    }
                    if !is_identifier(name) {
                        var d = self.report.add("E0402", "`{name}` cannot be used as a module name", start, end)
                        d.help = "give it a name: `import \"{path}\" as my_module`"
                        fail "modules"
                    }
                    if imports.has(name) {
                        var d = self.report.add("E0402", "the name `{name}` is already used by another import", start, end)
                        d.help = "rename one of them: `import \"{path}\" as other_name`"
                        fail "modules"
                    }
                    var target = -1
                    if self.by_path.has(file) {
                        target = self.by_path[file]
                    } else {
                        var data = read_bytes(file) catch err {
                            var d = self.report.add("E0400", "cannot find module \"{path}\"", start, end)
                            d.label = "no such file"
                            d.help = "imports are relative to the importing file; looked for `{file}`"
                            fail "modules"
                        }
                        // Module prefixes must be unique even when two files share a name.
                        var base = module_base(stem)
                        var unique = base
                        var n = 2
                        while self.used_names.has(unique) {
                            unique = base + "~" + str(n)
                            n += 1
                        }
                        self.used_names[unique] = true
                        target = self.load_file(file, unique, data)?
                    }
                    imports[name] = target
                }
                else {
                }
            }
        }

        // A module's own names would hide an import of the same name.
        for item in program.items {
            var name = ""
            var start = 0
            var end = 0
            match item {
                Fn(f) {
                    name = f.name
                    start = f.name_start
                    end = f.name_end
                }
                Global(stmt) {
                    match stmt.kind {
                        Let(n, s, e, _, _, _) {
                            name = n
                            start = s
                            end = e
                        }
                        else {
                        }
                    }
                }
                else {
                }
            }
            if name != "" && imports.has(name) {
                var d = self.report.add("E0402", "`{name}` is also the name of an imported module", start, end)
                d.help = "rename it, or import the module under another name with `as`"
                fail "modules"
            }
        }

        for item in program.items {
            self.modules[idx].items.push(item)
        }
    }
}

// ---- resolving names ----

struct Resolver {
    infos: [ModInfo]
    me: int
    imports: map<string, int>
    dir: string
    // Local variables in scope; they hide top-level names and imports.
    scopes: [map<string, bool>]
    report: diag.Report

    fn qualify(self, module: int, name: string) -> string {
        var prefix = self.infos[module].name
        if prefix == "" {
            return name
        }
        return prefix + "." + name
    }

    fn is_local(self, name: string) -> bool {
        for scope in self.scopes {
            if scope.has(name) {
                return true
            }
        }
        return false
    }

    fn declare(self, name: string) {
        if self.scopes.len() > 0 {
            var top = self.scopes[self.scopes.len() - 1]
            top[name] = true
        }
    }

    fn push(self, names: [string]) {
        var scope: map<string, bool> = {}
        for name in names {
            scope[name] = true
        }
        self.scopes.push(scope)
    }

    fn pop(self) {
        self.scopes.remove(self.scopes.len() - 1)
    }

    fn check_private(self, module: int, name: string, start: int, end: int) {
        if module != self.me && name.starts_with("_") {
            var d = self.report.add("E0401", "`{name}` is private to its module", start, end)
            d.help = "names starting with `_` can only be used in the file that defines them"
        }
    }

    // `embed("file")`: the text of the file, read when the program is
    // compiled, as a string literal. The path is relative to the file that
    // contains the call, like an import. Returns whether `e` was one.
    fn embed(self, e: ast.Expr) -> bool {
        var args: [ast.Expr] = []
        match e.kind {
            Call(callee, call_args) {
                match callee.kind {
                    Ident(name) {
                        if name != "embed" || self.is_local(name) {
                            return false
                        }
                    }
                    else {
                        return false
                    }
                }
                args = call_args
            }
            else {
                return false
            }
        }
        var path = ""
        if args.len() == 1 {
            match args[0].kind {
                Str(parts) {
                    if parts.len() == 1 {
                        match parts[0] {
                            Lit(text) {
                                path = text
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
        if path == "" {
            var d = self.report.add("E0104", "`embed` takes the path of a file, written as a plain string", e.start, e.end)
            d.help = "for example `embed(\"data/words.txt\")`"
            return true
        }
        var file = join(self.dir, path)
        var data = read_bytes(file) catch err {
            var d = self.report.add("E0400", "cannot read the file \"{path}\"", e.start, e.end)
            d.label = "no such file"
            d.help = "the path is relative to the file that contains `embed`; looked for `{file}`"
            return true
        }
        e.kind = ast.ExprKind.Str([ast.StrPart.Lit(from_bytes(data))])
        return true
    }

    // Resolves a type or struct name, possibly written `module.Name`.
    fn type_name(self, name: string, start: int, end: int) -> string {
        var dot = name.index_of(".")
        if dot >= 0 {
            var alias = name.slice(0, dot)
            var item = name.slice(dot + 1, name.len())
            if self.imports.has(alias) {
                var module = self.imports[alias]
                if self.infos[module].types.has(item) {
                    self.check_private(module, item, start, end)
                    return self.qualify(module, item)
                }
                self.report.add("E0401", "module `{alias}` has no type `{item}`", start, end)
                return name
            }
            var d = self.report.add("E0401", "unknown module `{alias}`", start, end)
            d.help = "add `import \"{alias}\"` at the top of the file"
            return name
        }
        if self.infos[self.me].types.has(name) {
            return self.qualify(self.me, name)
        }
        return name
    }

    fn type_expr(self, t: ast.TypeExpr) {
        match t.kind {
            Named(name) {
                t.kind = ast.TypeKind.Named(self.type_name(name, t.start, t.end))
            }
            List(elem) {
                self.type_expr(elem)
            }
            Chan(elem) {
                self.type_expr(elem)
            }
            Weak(elem) {
                self.type_expr(elem)
            }
            Map(key, value) {
                self.type_expr(key)
                self.type_expr(value)
            }
            Fn(params, ret, _) {
                for p in params {
                    self.type_expr(p)
                }
                for r in ret {
                    self.type_expr(r)
                }
            }
        }
    }

    fn item(self, item: ast.Item) {
        var prefixed = self.infos[self.me].name != ""
        match item {
            Fn(f) {
                if prefixed && is_builtin(f.name) {
                    self.report.add("E0103", "`{f.name}` is a built-in function and cannot be redefined", f.name_start, f.name_end)
                }
                f.name = self.qualify(self.me, f.name)
                self.function(f)
            }
            Struct(s) {
                s.name = self.qualify(self.me, s.name)
                for field in s.fields {
                    self.type_expr(field.ty)
                }
                for m in s.methods {
                    self.function(m)
                }
            }
            Enum(e) {
                e.name = self.qualify(self.me, e.name)
                for variant in e.variants {
                    for field in variant.fields {
                        self.type_expr(field)
                    }
                }
            }
            Interface(i) {
                i.name = self.qualify(self.me, i.name)
                for m in i.methods {
                    for p in m.params {
                        self.type_expr(p.ty)
                    }
                    for r in m.ret {
                        self.type_expr(r)
                    }
                }
            }
            Global(stmt) {
                match stmt.kind {
                    Let(name, name_start, name_end, mutable, ty, init) {
                        for t in ty {
                            self.type_expr(t)
                        }
                        self.expr(init)
                        stmt.kind = ast.StmtKind.Let(self.qualify(self.me, name), name_start, name_end, mutable, ty, init)
                    }
                    else {
                    }
                }
            }
            Check(_, body) {
                self.block(body)
            }
            Import(_, _, _, _) {
            }
        }
    }

    fn function(self, f: ast.FnDecl) {
        var names: [string] = []
        if f.has_self {
            names.push("self")
        }
        for p in f.params {
            self.type_expr(p.ty)
            names.push(p.name)
        }
        for r in f.ret {
            self.type_expr(r)
        }
        self.push(names)
        for stmt in f.body.stmts {
            self.stmt(stmt)
        }
        self.pop()
    }

    fn block(self, block: ast.Block) {
        self.push([])
        for stmt in block.stmts {
            self.stmt(stmt)
        }
        self.pop()
    }

    fn stmt(self, stmt: ast.Stmt) {
        match stmt.kind {
            Let(name, _, _, _, ty, init) {
                for t in ty {
                    self.type_expr(t)
                }
                self.expr(init)
                self.declare(name)
            }
            Assign(target, _, value) {
                self.expr(target)
                self.expr(value)
            }
            Expr(e) {
                self.expr(e)
            }
            Fail(e) {
                self.expr(e)
            }
            If(cond, then, els) {
                self.expr(cond)
                self.block(then)
                for other in els {
                    self.stmt(other)
                }
            }
            While(cond, body) {
                self.expr(cond)
                self.block(body)
            }
            For(name, _, _, iter, body) {
                self.expr(iter)
                self.push([name])
                self.block(body)
                self.pop()
            }
            Return(value) {
                for v in value {
                    self.expr(v)
                }
            }
            Break, Continue {
            }
            Fork(body) {
                self.block(body)
            }
            Block(body) {
                self.block(body)
            }
            Send(channel, value) {
                self.expr(channel)
                self.expr(value)
            }
            Match(subject, arms, default) {
                self.expr(subject)
                for arm in arms {
                    var names: [string] = []
                    for pattern in arm.patterns {
                        match pattern {
                            Literal(value) {
                                self.expr(value)
                            }
                            Variant(_, _, _, bindings) {
                                for b in bindings {
                                    names.push(b.text)
                                }
                            }
                        }
                    }
                    self.push(names)
                    self.block(arm.body)
                    self.pop()
                }
                for body in default {
                    self.block(body)
                }
            }
        }
    }

    // `module.item`, if `e` is that: it becomes a plain name. Returns
    // whether it was.
    fn module_item(self, e: ast.Expr) -> bool {
        match e.kind {
            Field(obj, name, name_start, name_end) {
                match obj.kind {
                    Ident(alias) {
                        if self.is_local(alias) || !self.imports.has(alias) {
                            return false
                        }
                        var module = self.imports[alias]
                        var info = self.infos[module]
                        // A type: `module.Enum`, on its way to `module.Enum.Variant`.
                        if info.values.has(name) || info.types.has(name) {
                            self.check_private(module, name, name_start, name_end)
                            e.kind = ast.ExprKind.Ident(self.qualify(module, name))
                        } else {
                            self.report.add("E0401", "module `{alias}` has no function or variable `{name}`", name_start, name_end)
                        }
                        return true
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

    fn expr(self, e: ast.Expr) {
        if self.module_item(e) || self.embed(e) {
            return
        }
        match e.kind {
            Int(_), Float(_), Bool(_) {
            }
            Str(parts) {
                for part in parts {
                    match part {
                        Code(inner) {
                            self.expr(inner)
                        }
                        else {
                        }
                    }
                }
            }
            Ident(name) {
                var mine = self.infos[self.me]
                // A type name in an expression is an enum: `Shape.Circle(1.0)`.
                if !self.is_local(name) && (mine.values.has(name) || mine.types.has(name)) {
                    e.kind = ast.ExprKind.Ident(self.qualify(self.me, name))
                }
            }
            List(items) {
                for item in items {
                    self.expr(item)
                }
            }
            Map(entries) {
                for entry in entries {
                    self.expr(entry.key)
                    self.expr(entry.value)
                }
            }
            StructLit(name, name_start, name_end, fields) {
                var resolved = self.type_name(name, name_start, name_end)
                for f in fields {
                    self.expr(f.value)
                }
                e.kind = ast.ExprKind.StructLit(resolved, name_start, name_end, fields)
            }
            Unary(_, inner) {
                self.expr(inner)
            }
            Try(inner) {
                self.expr(inner)
            }
            Recv(inner) {
                self.expr(inner)
            }
            Binary(_, lhs, rhs) {
                self.expr(lhs)
                self.expr(rhs)
            }
            Call(callee, args) {
                self.expr(callee)
                for a in args {
                    self.expr(a)
                }
            }
            Field(obj, _, _, _) {
                self.expr(obj)
            }
            Index(obj, index) {
                self.expr(obj)
                self.expr(index)
            }
            Lambda(params, ret, _, body) {
                var names: [string] = []
                for p in params {
                    self.type_expr(p.ty)
                    names.push(p.name)
                }
                for r in ret {
                    self.type_expr(r)
                }
                self.push(names)
                for stmt in body.stmts {
                    self.stmt(stmt)
                }
                self.pop()
            }
            Or(inner, default) {
                self.expr(inner)
                self.expr(default)
            }
            Catch(inner, name, _, _, body) {
                self.expr(inner)
                self.push([name])
                for stmt in body.stmts {
                    self.stmt(stmt)
                }
                self.pop()
            }
            ChanNew(elem, cap) {
                self.type_expr(elem)
                for c in cap {
                    self.expr(c)
                }
            }
            Range(lo, hi) {
                self.expr(lo)
                self.expr(hi)
            }
        }
    }
}

// A program and the sources it was read from.
struct Linked {
    program: ast.Program
    sources: Sources
    // Where the source of the runtime is in `sources` (-1 when it was not added).
    runtime_start: int
    runtime_end: int
}

// The runtime of the native target, written in Onyx: added to the program
// when it is compiled to machine code.
const RUNTIME = embed("../src/native/runtime.ox")

// Loads `entry` and everything it imports, followed by the runtime when
// `with_runtime`. Fails with "fatal" when the entry file cannot be read,
// with something else after noting the problems in `report`.
fn load(entry: string, with_runtime: bool, report: diag.Report) -> Linked! {
    var data = read_bytes(entry) catch err {
        fail "fatal"
    }
    var loader = Loader{
        sources: Sources{bytes: [], files: []},
        report: report,
        modules: [],
        by_path: {},
        order: [],
        next_id: 0,
        used_names: {}
    }
    loader.load_file(join("", entry), "", data)?

    var infos: [ModInfo] = []
    for module in loader.modules {
        infos.push(module_info(module))
    }
    var items: [ast.Item] = []
    for idx in loader.order {
        var module = loader.modules[idx]
        var resolver = Resolver{infos: infos, me: idx, imports: module.imports, dir: module.dir, scopes: [], report: report}
        for item in module.items {
            resolver.item(item)
        }
        var is_entry = infos[idx].name == ""
        for item in module.items {
            match item {
                Import(_, _, _, _) {
                }
                // Only the checks of the file being tested are run.
                Check(_, _) {
                    if is_entry {
                        items.push(item)
                    }
                }
                else {
                    items.push(item)
                }
            }
        }
    }
    var runtime_start = -1
    var runtime_end = -1
    if with_runtime {
        // Parsed after everything else, with no imports to resolve.
        var text = bytes(RUNTIME)
        runtime_start = loader.sources.add("<onyx runtime>", text)
        runtime_end = runtime_start + text.len()
        var prelude = parser.parse(loader.sources.bytes, runtime_start, runtime_end, loader.next_id, report)?
        for item in prelude.items {
            items.push(item)
        }
    }
    if report.diags.len() > 0 {
        report.diags = report.diags.sort_by(fn(d: diag.Diag) -> int {
            return d.start
        })
        fail "modules"
    }
    var program = ast.Program{items: items, next_id: loader.next_id}
    return Linked{program: program, sources: loader.sources, runtime_start: runtime_start, runtime_end: runtime_end}
}
