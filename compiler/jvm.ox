// The JVM target: the checked and prepared program as a .jar, which
// `java -jar` runs. Written only in Onyx (the compiler written in Rust does
// not have this target).
//
// How an Onyx program looks on the JVM:
//
// - an `int` is a Java `long`, a `float` a `double`, a `bool` a `boolean`,
//   a `string` a `java.lang.String`;
// - a list is a `java.util.ArrayList` of objects: numbers in it are boxed
//   (`Long`, `Double`, `Boolean`);
// - a map is an object of the runtime (`__JrtMap`, written in Onyx in
//   compiler/jvm/runtime.ox), which keeps the order in which keys came
//   and lets a loop see the keys added while it runs, as on the other
//   targets;
// - the top-level functions are static methods of `onyx.Main`, and the
//   top-level variables its static fields;
// - a struct is a class `onyx.S$Name`, with a field per field and a method
//   per method; an interface is a Java interface `onyx.I$Name`, and each
//   struct implements those whose methods it has;
// - an enum value is an `onyx.E$Name`: which variant, and what it carries;
// - a function value is an object of an interface `onyx.F$n`, one per kind
//   of function; each lambda is a class `onyx.L$id` that keeps what it
//   captured in its fields;
// - an error is an exception, `onyx.Failure`, thrown by `fail` and caught
//   by `or` and `catch`; a bug (division by zero, an index out of
//   bounds...) is another one, `onyx.Panic`, which nothing catches.
//
// The JVM takes care of memory and of the stack. The classes are of
// version 49 (see classfile.ox): the JVM checks the types by itself.
//
// The runtime is written in Onyx too: the built-in functions that take more
// than a few instructions are calls to its functions, which are compiled
// with the program, only those that are used.

import "ast"
import "checker"
import "classfile"
import "diag"
import "errors"
import "jar"
import "modules"

const MAIN = "onyx/Main"
const FAILURE = "onyx/Failure"
const PANIC = "onyx/Panic"
const EXPECT = "onyx/ExpectFail"
// Implemented by the classes of structs and enums: equality and text.
const VALUE = "onyx/Value"
// Extended by the interfaces of function values.
const FN = "onyx/Fn"
const OBJECT = "java/lang/Object"
const STRING = "java/lang/String"
const BUILDER = "java/lang/StringBuilder"
const LIST = "java/util/ArrayList"
const MAP_STRUCT = "__JrtMap"
const WEAK_STRUCT = "__JrtWeak"
const CHAN_STRUCT = "__JrtChan"

const OBJECT_DESC = "Ljava/lang/Object;"
const STRING_DESC = "Ljava/lang/String;"
const LIST_DESC = "Ljava/util/ArrayList;"

// The instructions that classfile.Code has no function for.
const POP = 0x57
const POP2 = 0x58
const DUP = 0x59
const DUP_X1 = 0x5A
const DUP2 = 0x5C
const SWAP = 0x5F
const LADD = 0x61
const DADD = 0x63
const LSUB = 0x65
const DSUB = 0x67
const LMUL = 0x69
const DMUL = 0x6B
const LDIV = 0x6D
const DDIV = 0x6F
const LREM = 0x71
const DREM = 0x73
const LNEG = 0x75
const DNEG = 0x77
const LSHL = 0x79
const LSHR = 0x7B
const LAND = 0x7F
const LOR = 0x81
const IXOR = 0x82
const LXOR = 0x83
const I2L = 0x85
const L2I = 0x88
const L2D = 0x8A
const D2L = 0x8F
const D2F = 0x90
const F2D = 0x8D
const LCMP = 0x94
const DCMPL = 0x97
const DCMPG = 0x98
const IFEQ = 0x99
const IFNE = 0x9A
const IFLT = 0x9B
const IFGE = 0x9C
const IFGT = 0x9D
const IFLE = 0x9E
const IF_ICMPEQ = 0x9F
const IF_ICMPNE = 0xA0
const IF_ACMPEQ = 0xA5
const IF_ACMPNE = 0xA6
const IFNULL = 0xC6
const LALOAD = 0x2F
const LASTORE = 0x50
const NEWARRAY = 0xBC
const T_LONG = 11

// ---- names ----

// A name as the JVM accepts it in a class, a field or a method: letters,
// digits and `_` stay, `.` (between a module and its names) becomes `$`,
// anything else its code (`$box<int>` -> `$box$3cint$3e`).
fn mangle(name: string) -> string {
    var out = ""
    for c in name {
        if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "$" {
            out += c
        } else if c == "." {
            out += "$"
        } else {
            out += "$" + hex(ord(c))
        }
    }
    return out
}

fn hex(n: int) -> string {
    var digits = "0123456789abcdef"
    var out = ""
    var rest = n
    while rest > 0 || out == "" {
        out = digits[rest & 15] + out
        rest = rest >> 4
    }
    return out
}

fn struct_class(name: string) -> string {
    return "onyx/S$" + mangle(name)
}

fn interface_class(name: string) -> string {
    return "onyx/I$" + mangle(name)
}

fn enum_class(name: string) -> string {
    return "onyx/E$" + mangle(name)
}

fn lambda_class(id: int) -> string {
    return "onyx/L$" + str(id)
}

fn wrapper_class(name: string) -> string {
    return "onyx/W$" + mangle(name)
}

// The name of the method of an Onyx method: `m$` first, so that none
// clashes with the methods every Java object has.
fn method_name(name: string) -> string {
    return "m$" + mangle(name)
}

fn field_name(name: string) -> string {
    return mangle(name)
}

fn global_name(name: string) -> string {
    return "g$" + mangle(name)
}

// ---- descriptors ----

// The class of an object descriptor (`Ljava/lang/String;` -> java/lang/String);
// an array keeps its descriptor (`[J`), as `checkcast` wants it.
fn class_in(descriptor: string) -> string {
    if descriptor.starts_with("L") {
        return descriptor.slice(1, descriptor.len() - 1)
    }
    return descriptor
}

fn is_primitive(descriptor: string) -> bool {
    return descriptor.len() == 1
}

// How the load and store instructions name a value of this descriptor:
// 0 int (and boolean), 1 long, 2 float, 3 double, 4 reference, 5 nothing.
fn kind_of(descriptor: string) -> int {
    if descriptor == "J" {
        return 1
    }
    if descriptor == "D" {
        return 3
    }
    if descriptor == "F" {
        return 2
    }
    if descriptor == "V" {
        return 5
    }
    if is_primitive(descriptor) {
        return 0
    }
    return 4
}

// The jump that does the opposite of `opcode` (IFEQ <-> IFNE, IFLT <-> IFGE...).
fn negate(opcode: int) -> int {
    if (opcode - IFEQ) % 2 == 0 {
        return opcode + 1
    }
    return opcode - 1
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

// Adds the value on the stack (of this descriptor) to the StringBuilder
// under it.
fn append(code: classfile.Code, descriptor: string) {
    var d = descriptor
    if !is_primitive(d) && d != STRING_DESC {
        d = OBJECT_DESC
    }
    code.invokevirtual(BUILDER, "append", "(" + d + ")Ljava/lang/StringBuilder;")
}

// ---- what is compiled ----

struct JParam {
    name: string
    ty: checker.Type
}

// A body of code to compile into a method: a top-level function (static,
// in Main), a method of a struct, or a lambda.
struct JFn {
    class_name: string
    name: string
    is_static: bool
    params: [JParam]
    ret: checker.Type
    body: ast.Block
    // A method: the type of `self` (none for the others).
    self_type: [checker.Type]
    // A lambda: what it captured, which its object keeps in fields.
    captures: [checker.Captured]
}

struct Local {
    name: string
    slot: int
    // The type of what the slot holds.
    ty: checker.Type
}

struct JLoop {
    next: int
    end: int
}

// Where the value of a `catch` expression goes.
enum Sink {
    // Into a new variable, in this slot.
    Slot(slot: int, ty: checker.Type)
    // Into an existing variable.
    Assign(target: ast.Expr)
    Return
    Discard
}

// ---- the program ----

fn generate(program: ast.Program, an: checker.Analysis, tests: bool, sources: modules.Sources, report: diag.Report) -> [int]! {
    var none: [checker.Type] = []
    var no_captures: [checker.Captured] = []
    var g = Jvm{
        an: an,
        report: report,
        tests: tests,
        sources: sources,
        classes: {},
        class_order: [],
        items: {},
        requested: {},
        queue: [],
        globals: {},
        fn_types: {},
        struct_methods: {},
        value_structs: [],
        value_enums: [],
        eq_done: {},
        repr_done: {},
        used_globals: {},
        cls: classfile.new_class(MAIN, 0, OBJECT),
        code: classfile.new_code(classfile.new_pool(), 0),
        scopes: [],
        marks: [],
        next_slot: 0,
        loops: [],
        ret: checker.Type.Void,
        captured: {},
        this_class: ""
    }
    var main = g.class_named(MAIN, classfile.ACC_PUBLIC | classfile.ACC_SUPER, OBJECT)
    main.interfaces.push("java/lang/Runnable")
    main.field(classfile.ACC_PUBLIC | classfile.ACC_STATIC, "args", "[Ljava/lang/String;")
    g.exception_class(FAILURE)
    g.exception_class(PANIC)
    g.exception_class(EXPECT)
    var value = g.class_named(VALUE, classfile.ACC_PUBLIC | classfile.ACC_INTERFACE | classfile.ACC_ABSTRACT, OBJECT)
    value.abstract_method("v$eq", "(Ljava/lang/Object;)Z")
    value.abstract_method("v$repr", "()Ljava/lang/String;")
    g.class_named(FN, classfile.ACC_PUBLIC | classfile.ACC_INTERFACE | classfile.ACC_ABSTRACT, OBJECT)

    // What can be compiled. Only what is used gets compiled.
    var runtime_globals: [ast.Stmt] = []
    var user_globals: [ast.Stmt] = []
    var checks: [ast.Item] = []
    for item in program.items {
        match item {
            Fn(f) {
                if an.fns.has(f.name) {
                    var sig = an.fns[f.name]
                    g.items[checker.fn_key(f.name)] = JFn{class_name: MAIN, name: mangle(f.name), is_static: true, params: params_of(f.params, sig), ret: sig.ret, body: f.body, self_type: none, captures: no_captures}
                }
            }
            Struct(s) {
                var keys: [string] = []
                if an.structs.has(s.name) {
                    var info = an.structs[s.name]
                    for m in s.methods {
                        if info.methods.has(m.name) {
                            var sig = info.methods[m.name]
                            var key = checker.method_key(s.name, m.name)
                            g.items[key] = JFn{class_name: struct_class(s.name), name: method_name(m.name), is_static: false, params: params_of(m.params, sig), ret: sig.ret, body: m.body, self_type: [checker.Type.Struct(s.name)], captures: no_captures}
                            keys.push(key)
                        }
                    }
                }
                g.struct_methods[s.name] = keys
            }
            Check(_, _) {
                checks.push(item)
            }
            else {
            }
        }
    }
    for item in program.items {
        match item {
            Global(stmt) {
                match stmt.kind {
                    Let(name, name_start, _, _, _, init) {
                        var ty = g.declared(name_start, init)
                        g.globals[name] = ty
                        if name.starts_with("__jrt_") {
                            runtime_globals.push(stmt)
                        } else {
                            main.field(classfile.ACC_PUBLIC | classfile.ACC_STATIC, global_name(name), g.desc(ty))
                            user_globals.push(stmt)
                        }
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
    }

    // `main(String[])` runs the program in a thread of its own, whose stack
    // is large enough for deep recursion.
    var code = classfile.new_code(main.pool, 1)
    code.load(4, 0)
    code.putstatic(MAIN, "args", "[Ljava/lang/String;")
    code.new_object("java/lang/Thread")
    code.op(DUP, 1)
    code.aconst_null()
    code.new_object(MAIN)
    code.op(DUP, 1)
    code.invokespecial(MAIN, "<init>", "()V")
    code.sconst("main")
    code.lconst(536870912)
    code.invokespecial("java/lang/Thread", "<init>", "(Ljava/lang/ThreadGroup;Ljava/lang/Runnable;Ljava/lang/String;J)V")
    code.op(DUP, 1)
    code.invokevirtual("java/lang/Thread", "start", "()V")
    code.invokevirtual("java/lang/Thread", "join", "()V")
    code.return_value(5)
    main.method(classfile.ACC_PUBLIC | classfile.ACC_STATIC, "main", "([Ljava/lang/String;)V", code)
    g.constructor(main, OBJECT)

    // `run()`: the runtime's variables, then the program's, then `main` (or
    // the checks), then the tasks that are left; whatever goes wrong ends in
    // `__jrt_crash`.
    var params: [JParam] = []
    g.begin(MAIN, false, params)
    code = g.code
    var start = code.new_label()
    var end = code.new_label()
    var handler = code.new_label()
    var done = code.new_label()
    code.bind(start)
    code.invokestatic(MAIN, "init$runtime", "()V")
    for stmt in user_globals {
        g.init_global(stmt)
    }
    if tests {
        g.run_checks(checks)
    } else if g.items.has("fn:main") {
        g.call_function("fn:main")
        g.discard(g.items["fn:main"].ret)
    }
    if an.has_forks {
        g.runtime("__jrt_run_tasks")
    }
    code.bind(end)
    code.goto(done)
    code.handler(start, end, handler, "")
    code.bind(handler)
    g.runtime("__jrt_crash")
    code.bind(done)
    g.runtime("__jrt_finish")
    code.return_value(5)
    main.method(classfile.ACC_PUBLIC, "run", "()V", code)

    g.complete(runtime_globals)

    if report.diags.len() > 0 {
        fail "jvm"
    }
    var archive = jar.new_jar(MAIN)
    for name in g.class_order {
        archive.add(name + ".class", g.classes[name].bytes())
    }
    return archive.bytes()
}

// The parameters of a function, with their names and types.
fn params_of(params: [ast.Param], sig: checker.FnSig) -> [JParam] {
    var out: [JParam] = []
    for i in 0..min(params.len(), sig.params.len()) {
        out.push(JParam{name: params[i].name, ty: sig.params[i]})
    }
    return out
}

// Does a struct have every method of an interface (with the same types)?
fn satisfies(info: checker.StructInfo, iface: checker.InterfaceInfo) -> bool {
    for m in iface.methods {
        if !info.methods.has(m.name) || info.methods[m.name] != m.sig {
            return false
        }
    }
    return true
}

struct Jvm {
    an: checker.Analysis
    report: diag.Report
    tests: bool
    sources: modules.Sources
    classes: map<string, classfile.ClassFile>
    // The classes, in the order they were made.
    class_order: [string]
    // What can be compiled, by key (`fn:name`, `m:Struct.name`,
    // `lambda:id`), and what was asked for, to compile in turn.
    items: map<string, JFn>
    requested: map<string, bool>
    queue: [string]
    // The top-level variables and their types.
    globals: map<string, checker.Type>
    // The interface of each kind of function value, by the descriptor of
    // its method.
    fn_types: map<string, string>
    // The keys of the methods of each struct.
    struct_methods: map<string, [string]>
    // The structs and enums whose classes were made, and those that got
    // their equality and their text.
    value_structs: [string]
    value_enums: [string]
    eq_done: map<string, bool>
    repr_done: map<string, bool>
    // The top-level variables that the compiled code uses.
    used_globals: map<string, bool>

    // ---- the method being written ----
    cls: classfile.ClassFile
    code: classfile.Code
    scopes: [[Local]]
    // Where `next_slot` was when each scope began.
    marks: [int]
    next_slot: int
    loops: [JLoop]
    // What the function returns.
    ret: checker.Type
    // In a lambda: what it captured, kept in fields of `this_class`.
    captured: map<string, checker.Type>
    this_class: string

    fn unsupported(self, start: int, end: int, what: string) {
        var d = self.report.add("E0500", what + " are not supported by the JVM target yet", start, end)
        d.help = "the JVM target is new and grows step by step; this program still runs with `onyx run`"
    }

    fn ty(self, e: ast.Expr) -> checker.Type {
        if self.an.types.has(e.id) {
            return self.an.types[e.id]
        }
        return checker.Type.Unknown
    }

    // The type of a variable: the one written in its declaration, or else
    // that of its first value.
    fn declared(self, name_start: int, init: ast.Expr) -> checker.Type {
        var ty = self.ty(init)
        match ty {
            Struct(name) {
                if name.starts_with("$box<") {
                    // A variable shared with lambdas, moved into a box by
                    // capture.ox: it holds the box.
                    return ty
                }
            }
            else {
            }
        }
        if self.an.declared.has(name_start) {
            return self.an.declared[name_start]
        }
        return ty
    }

    // ---- classes ----

    fn class_named(self, name: string, access: int, super_name: string) -> classfile.ClassFile {
        if self.classes.has(name) {
            return self.classes[name]
        }
        var c = classfile.new_class(name, access, super_name)
        self.classes[name] = c
        self.class_order.push(name)
        return c
    }

    // `<init>()V`, which only calls that of the class above.
    fn constructor(self, c: classfile.ClassFile, super_name: string) {
        var code = classfile.new_code(c.pool, 1)
        code.load(4, 0)
        code.invokespecial(super_name, "<init>", "()V")
        code.return_value(5)
        c.method(classfile.ACC_PUBLIC, "<init>", "()V", code)
    }

    // An exception class: a message, and no stack trace (which costs time
    // to make and that nobody reads).
    fn exception_class(self, name: string) {
        var c = self.class_named(name, classfile.ACC_PUBLIC | classfile.ACC_SUPER, "java/lang/RuntimeException")
        var code = classfile.new_code(c.pool, 2)
        code.load(4, 0)
        code.load(4, 1)
        code.aconst_null()
        code.iconst(0)
        code.iconst(0)
        code.invokespecial("java/lang/RuntimeException", "<init>", "(Ljava/lang/String;Ljava/lang/Throwable;ZZ)V")
        code.return_value(5)
        c.method(classfile.ACC_PUBLIC, "<init>", "(Ljava/lang/String;)V", code)
    }

    // The descriptor of the values of a type; the class it needs is made
    // on the way.
    fn desc(self, ty: checker.Type) -> string {
        match ty {
            Int {
                return "J"
            }
            Float {
                return "D"
            }
            Bool {
                return "Z"
            }
            Str {
                return STRING_DESC
            }
            Error {
                return "L" + FAILURE + ";"
            }
            Void {
                return "V"
            }
            List(_) {
                return LIST_DESC
            }
            Map(_, _) {
                return "L" + self.ensure_struct(MAP_STRUCT) + ";"
            }
            Weak(_) {
                return "L" + self.ensure_struct(WEAK_STRUCT) + ";"
            }
            Chan(_) {
                return "L" + self.ensure_struct(CHAN_STRUCT) + ";"
            }
            Struct(name) {
                return "L" + self.ensure_struct(name) + ";"
            }
            Interface(name) {
                return "L" + self.ensure_interface(name) + ";"
            }
            Enum(name) {
                return "L" + self.ensure_enum(name) + ";"
            }
            Fn(sig) {
                return "L" + self.fn_interface(sig) + ";"
            }
            Range {
                return "[J"
            }
            else {
                return OBJECT_DESC
            }
        }
    }

    fn method_desc(self, params: [checker.Type], ret: checker.Type) -> string {
        var out = "("
        for p in params {
            out += self.desc(p)
        }
        return out + ")" + self.desc(ret)
    }

    fn ensure_interface(self, name: string) -> string {
        var class_name = interface_class(name)
        if self.classes.has(class_name) {
            return class_name
        }
        var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_INTERFACE | classfile.ACC_ABSTRACT, OBJECT)
        if self.an.interfaces.has(name) {
            for m in self.an.interfaces[name].methods {
                c.abstract_method(method_name(m.name), self.method_desc(m.sig.params, m.sig.ret))
            }
        }
        return class_name
    }

    // The class of a struct: its fields, and `new$`, which makes an object
    // out of the values of its fields. Equality and text come later, if the
    // program needs them (see `finish_values`).
    fn ensure_struct(self, name: string) -> string {
        var class_name = struct_class(name)
        if self.classes.has(class_name) {
            return class_name
        }
        var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_SUPER, OBJECT)
        if !name.starts_with("__Jrt") {
            // The runtime's own structs are never compared nor shown.
            c.interfaces.push(VALUE)
            self.value_structs.push(name)
        }
        if !self.an.structs.has(name) {
            return class_name
        }
        var info = self.an.structs[name]
        for iname in self.an.interfaces.keys() {
            if satisfies(info, self.an.interfaces[iname]) {
                c.interfaces.push(self.ensure_interface(iname))
            }
        }
        var descs: [string] = []
        for f in info.fields {
            var d = self.desc(f.ty)
            descs.push(d)
            c.field(classfile.ACC_PUBLIC, field_name(f.name), d)
        }
        self.constructor(c, OBJECT)

        var code = classfile.new_code(c.pool, 0)
        code.new_object(class_name)
        code.op(DUP, 1)
        code.invokespecial(class_name, "<init>", "()V")
        var slot = 0
        for i in 0..descs.len() {
            code.op(DUP, 1)
            code.load(kind_of(descs[i]), slot)
            code.putfield(class_name, field_name(info.fields[i].name), descs[i])
            slot += classfile.slots_of(descs[i])
        }
        code.uses_local(0, slot)
        code.return_value(4)
        c.method(classfile.ACC_PUBLIC | classfile.ACC_STATIC, "new$", "(" + descs.join("") + ")L" + class_name + ";", code)
        return class_name
    }

    // `v$eq(Object)` of a struct: the same struct, with equal fields.
    fn struct_eq(self, name: string) {
        var class_name = struct_class(name)
        var c = self.classes[class_name]
        var fields: [checker.Field] = []
        if self.an.structs.has(name) {
            fields = self.an.structs[name].fields
        }
        var code = classfile.new_code(c.pool, 3)
        var differ = code.new_label()
        code.load(4, 1)
        code.instance_of(class_name)
        code.if_zero(IFEQ, differ)
        code.load(4, 1)
        code.checkcast(class_name)
        code.store(4, 2)
        for f in fields {
            var d = self.desc(f.ty)
            code.load(4, 0)
            code.getfield(class_name, field_name(f.name), d)
            code.load(4, 2)
            code.getfield(class_name, field_name(f.name), d)
            self.equal_jump(code, d, differ)
        }
        code.iconst(1)
        code.return_value(0)
        code.bind(differ)
        code.iconst(0)
        code.return_value(0)
        c.method(classfile.ACC_PUBLIC, "v$eq", "(Ljava/lang/Object;)Z", code)
    }

    // `v$repr()` of a struct: `Name{field: value, ...}`.
    fn struct_repr(self, name: string) {
        var class_name = struct_class(name)
        var c = self.classes[class_name]
        var fields: [checker.Field] = []
        if self.an.structs.has(name) {
            fields = self.an.structs[name].fields
        }
        var code = classfile.new_code(c.pool, 1)
        code.new_object(BUILDER)
        code.op(DUP, 1)
        code.invokespecial(BUILDER, "<init>", "()V")
        var text = name + "\{"
        for i in 0..fields.len() {
            if i > 0 {
                text += ", "
            }
            text += fields[i].name + ": "
            code.sconst(text)
            text = ""
            append(code, STRING_DESC)
            var d = self.desc(fields[i].ty)
            code.load(4, 0)
            code.getfield(class_name, field_name(fields[i].name), d)
            convert_in(code, d, OBJECT_DESC)
            self.runtime_in(code, "__jrt_repr")
            append(code, STRING_DESC)
        }
        code.sconst(text + "}")
        append(code, STRING_DESC)
        code.invokevirtual(BUILDER, "toString", "()Ljava/lang/String;")
        code.return_value(4)
        c.method(classfile.ACC_PUBLIC, "v$repr", "()Ljava/lang/String;", code)
    }

    // Jumps to `differ` unless the two values on the stack are equal, as
    // `==` sees it.
    fn equal_jump(self, code: classfile.Code, descriptor: string, differ: int) {
        if descriptor == "J" {
            code.op(LCMP, -3)
            code.if_zero(IFNE, differ)
        } else if descriptor == "D" {
            code.op(DCMPL, -3)
            code.if_zero(IFNE, differ)
        } else if descriptor == "Z" {
            code.if_icmp(IF_ICMPNE, differ)
        } else {
            self.runtime_in(code, "__jrt_eq")
            code.if_zero(IFEQ, differ)
        }
    }

    // The class of an enum: `v`, the number of the variant, and `f`, the
    // list of what it carries (none when it carries nothing).
    fn ensure_enum(self, name: string) -> string {
        var class_name = enum_class(name)
        if self.classes.has(class_name) {
            return class_name
        }
        var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_SUPER, OBJECT)
        c.interfaces.push(VALUE)
        self.value_enums.push(name)
        c.field(classfile.ACC_PUBLIC, "v", "I")
        c.field(classfile.ACC_PUBLIC, "f", LIST_DESC)
        self.constructor(c, OBJECT)

        var code = classfile.new_code(c.pool, 2)
        code.new_object(class_name)
        code.op(DUP, 1)
        code.invokespecial(class_name, "<init>", "()V")
        code.op(DUP, 1)
        code.load(0, 0)
        code.putfield(class_name, "v", "I")
        code.op(DUP, 1)
        code.load(4, 1)
        code.putfield(class_name, "f", LIST_DESC)
        code.return_value(4)
        c.method(classfile.ACC_PUBLIC | classfile.ACC_STATIC, "new$", "(ILjava/util/ArrayList;)L" + class_name + ";", code)
        return class_name
    }

    // `v$eq(Object)` of an enum: the same variant, carrying equal values.
    fn enum_eq(self, name: string) {
        var class_name = enum_class(name)
        var c = self.classes[class_name]
        var code = classfile.new_code(c.pool, 3)
        var differ = code.new_label()
        code.load(4, 1)
        code.instance_of(class_name)
        code.if_zero(IFEQ, differ)
        code.load(4, 1)
        code.checkcast(class_name)
        code.store(4, 2)
        code.load(4, 0)
        code.getfield(class_name, "v", "I")
        code.load(4, 2)
        code.getfield(class_name, "v", "I")
        code.if_icmp(IF_ICMPNE, differ)
        code.load(4, 0)
        code.getfield(class_name, "f", LIST_DESC)
        code.load(4, 2)
        code.getfield(class_name, "f", LIST_DESC)
        self.runtime_in(code, "__jrt_eq")
        code.return_value(0)
        code.bind(differ)
        code.iconst(0)
        code.return_value(0)
        c.method(classfile.ACC_PUBLIC, "v$eq", "(Ljava/lang/Object;)Z", code)
    }

    // `v$repr()` of an enum: `Shape.Circle(2.0)`, `Shape.Empty`.
    fn enum_repr(self, name: string) {
        var class_name = enum_class(name)
        var c = self.classes[class_name]
        var code = classfile.new_code(c.pool, 1)
        var variants: [checker.Variant] = []
        if self.an.enums.has(name) {
            variants = self.an.enums[name]
        }
        for i in 0..variants.len() {
            var next = code.new_label()
            code.load(4, 0)
            code.getfield(class_name, "v", "I")
            code.iconst(i)
            code.if_icmp(IF_ICMPNE, next)
            code.sconst(name + "." + variants[i].name)
            code.load(4, 0)
            code.getfield(class_name, "f", LIST_DESC)
            self.runtime_in(code, "__jrt_variant")
            code.return_value(4)
            code.bind(next)
        }
        code.sconst(name)
        code.return_value(4)
        c.method(classfile.ACC_PUBLIC, "v$repr", "()Ljava/lang/String;", code)
    }

    // Equality and text for the structs and enums, once the runtime's
    // `__jrt_eq` and `__jrt_repr` (which call them) are part of the
    // program. Whether something was added.
    fn finish_values(self) -> bool {
        var more = false
        var eq = self.requested.has("fn:__jrt_eq")
        var repr = self.requested.has("fn:__jrt_repr")
        for name in self.value_structs {
            if eq && !self.eq_done.has("S" + name) {
                self.eq_done["S" + name] = true
                self.struct_eq(name)
                more = true
            }
            if repr && !self.repr_done.has("S" + name) {
                self.repr_done["S" + name] = true
                self.struct_repr(name)
                more = true
            }
        }
        for name in self.value_enums {
            if eq && !self.eq_done.has("E" + name) {
                self.eq_done["E" + name] = true
                self.enum_eq(name)
                more = true
            }
            if repr && !self.repr_done.has("E" + name) {
                self.repr_done["E" + name] = true
                self.enum_repr(name)
                more = true
            }
        }
        return more
    }

    // The interface of the function values of this type: one method,
    // `call`.
    fn fn_interface(self, sig: checker.FnSig) -> string {
        var descriptor = self.method_desc(sig.params, sig.ret)
        if self.fn_types.has(descriptor) {
            return self.fn_types[descriptor]
        }
        var class_name = "onyx/F$" + str(self.fn_types.len())
        self.fn_types[descriptor] = class_name
        var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_INTERFACE | classfile.ACC_ABSTRACT, OBJECT)
        c.interfaces.push(FN)
        c.abstract_method("call", descriptor)
        return class_name
    }

    // A top-level function used as a value: an object whose `call` calls it.
    fn ensure_wrapper(self, name: string, sig: checker.FnSig) -> string {
        var class_name = wrapper_class(name)
        if self.classes.has(class_name) {
            return class_name
        }
        var iface = self.fn_interface(sig)
        var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_SUPER, OBJECT)
        c.interfaces.push(iface)
        self.constructor(c, OBJECT)
        var f = self.request(checker.fn_key(name))
        var descriptor = self.method_desc(sig.params, sig.ret)
        var code = classfile.new_code(c.pool, 1)
        var slot = 1
        for p in classfile.parameters_of(descriptor) {
            code.load(kind_of(p), slot)
            slot += classfile.slots_of(p)
        }
        code.invokestatic(MAIN, f.name, self.fn_desc(f))
        code.return_value(kind_of(classfile.return_of(descriptor)))
        c.method(classfile.ACC_PUBLIC, "call", descriptor, code)
        return class_name
    }

    // ---- functions ----

    // Notes that a function is needed (it gets compiled later) and returns
    // what calling it takes.
    fn request(self, key: string) -> JFn {
        if !self.items.has(key) {
            panic("the JVM target has no function `{key}`")
        }
        if !self.requested.has(key) {
            self.requested[key] = true
            self.queue.push(key)
        }
        return self.items[key]
    }

    fn fn_desc(self, f: JFn) -> string {
        var params: [checker.Type] = []
        for p in f.params {
            params.push(p.ty)
        }
        return self.method_desc(params, f.ret)
    }

    // Calls a function whose arguments (and object) are on the stack.
    fn call_function(self, key: string) {
        var f = self.request(key)
        if f.is_static {
            self.code.invokestatic(f.class_name, f.name, self.fn_desc(f))
        } else {
            self.code.invokevirtual(f.class_name, f.name, self.fn_desc(f))
        }
    }

    // Calls a function of the runtime, from code written apart.
    fn runtime_in(self, code: classfile.Code, name: string) {
        var f = self.request(checker.fn_key(name))
        code.invokestatic(MAIN, f.name, self.fn_desc(f))
    }

    // Calls a function of the runtime, whose arguments are on the stack.
    fn runtime(self, name: string) {
        self.runtime_in(self.code, name)
    }

    // Calls a method of a struct of the runtime (`__JrtMap`...), whose
    // object and arguments are on the stack.
    fn runtime_method(self, strukt: string, name: string) {
        self.call_function(checker.method_key(strukt, name))
    }

    // Objects of a struct are made: its methods are needed (an interface may
    // call any of them).
    fn struct_made(self, name: string) {
        if self.struct_methods.has(name) {
            for key in self.struct_methods[name] {
                self.request(key)
            }
        }
    }

    // Starts writing a method of `class_name`.
    fn begin(self, class_name: string, is_static: bool, params: [JParam]) {
        self.cls = self.classes[class_name]
        self.code = classfile.new_code(self.cls.pool, 0)
        self.next_slot = 0
        if !is_static {
            self.next_slot = 1
        }
        var scope: [Local] = []
        for p in params {
            scope.push(Local{name: p.name, slot: self.next_slot, ty: p.ty})
            self.next_slot += classfile.slots_of(self.desc(p.ty))
        }
        self.code.uses_local(0, self.next_slot)
        self.scopes = [scope]
        self.marks = [self.next_slot]
        self.loops = []
        self.captured = {}
        self.this_class = class_name
        self.ret = checker.Type.Void
    }

    fn function(self, f: JFn) {
        var c = self.classes[f.class_name]
        self.begin(f.class_name, f.is_static, f.params)
        for t in f.self_type {
            self.scopes[0].push(Local{name: "self", slot: 0, ty: t})
        }
        for captured in f.captures {
            self.captured[captured.name] = captured.ty
        }
        self.ret = f.ret
        self.stmts(f.body.stmts)
        // The end of the body: a function without a value returns; one with
        // a value cannot get there (the checker made sure of it).
        if !self.code.dead {
            if self.ret == checker.Type.Void {
                self.code.return_value(5)
            } else {
                self.code.aconst_null()
                self.code.athrow()
            }
        }
        var access = classfile.ACC_PUBLIC
        if f.is_static {
            access = access | classfile.ACC_STATIC
        }
        c.method(access, f.name, self.fn_desc(f), self.code)
    }

    // Compiles what was asked for, which may ask for more: functions, the
    // equality and text of structs, the runtime's variables (those that are
    // used, in `init$runtime`).
    fn complete(self, runtime_globals: [ast.Stmt]) {
        var seen: map<string, bool> = {}
        var params: [JParam] = []
        while true {
            while self.queue.len() > 0 {
                var key = self.queue.remove(0)
                self.function(self.items[key])
            }
            var more = self.finish_values()
            for stmt in runtime_globals {
                match stmt.kind {
                    Let(name, _, _, _, _, _) {
                        if self.used_globals.has(name) && !seen.has(name) {
                            // What its value needs: written aside, only to
                            // find the functions and variables it uses.
                            seen[name] = true
                            more = true
                            self.begin(MAIN, true, params)
                            self.init_global(stmt)
                        }
                    }
                    else {
                    }
                }
            }
            if !more && self.queue.len() == 0 {
                break
            }
        }
        // In the order of their declarations, as one may need another.
        self.begin(MAIN, true, params)
        var main = self.classes[MAIN]
        for stmt in runtime_globals {
            match stmt.kind {
                Let(name, _, _, _, _, _) {
                    if seen.has(name) {
                        main.field(classfile.ACC_PUBLIC | classfile.ACC_STATIC, global_name(name), self.desc(self.globals[name]))
                        self.init_global(stmt)
                    }
                }
                else {
                }
            }
        }
        self.code.return_value(5)
        main.method(classfile.ACC_PUBLIC | classfile.ACC_STATIC, "init$runtime", "()V", self.code)
    }

    // The `check` blocks, each a method, run one after the other: one that
    // fails does not stop the others.
    fn run_checks(self, checks: [ast.Item]) {
        var none: [checker.Type] = []
        var no_captures: [checker.Captured] = []
        var no_params: [JParam] = []
        self.code.lconst(checks.len())
        self.runtime("__jrt_tests_begin")
        for i in 0..checks.len() {
            match checks[i] {
                Check(name, body) {
                    var key = "check:" + str(i)
                    self.items[key] = JFn{class_name: MAIN, name: "check$" + str(i), is_static: true, params: no_params, ret: checker.Type.Void, body: body, self_type: none, captures: no_captures}
                    var code = self.code
                    var start = code.new_label()
                    var end = code.new_label()
                    var handler = code.new_label()
                    var done = code.new_label()
                    code.bind(start)
                    self.call_function(key)
                    code.bind(end)
                    code.sconst(name)
                    code.aconst_null()
                    self.runtime("__jrt_test_done")
                    code.goto(done)
                    code.handler(start, end, handler, "java/lang/Throwable")
                    code.bind(handler)
                    code.sconst(name)
                    code.op(SWAP, 0)
                    self.runtime("__jrt_test_done")
                    code.bind(done)
                }
                else {
                }
            }
        }
        self.code.lconst(checks.len())
        self.runtime("__jrt_tests_end")
    }

    // ---- variables ----

    fn push_scope(self) {
        var scope: [Local] = []
        self.scopes.push(scope)
        self.marks.push(self.next_slot)
    }

    // Ends a scope; its slots are free again.
    fn pop_scope(self) {
        self.scopes.remove(self.scopes.len() - 1)
        self.next_slot = self.marks.remove(self.marks.len() - 1)
    }

    // A slot for a value of this descriptor, which nothing uses yet.
    fn slot_of_desc(self, descriptor: string) -> int {
        var slot = self.next_slot
        var size = max(classfile.slots_of(descriptor), 1)
        self.next_slot += size
        self.code.uses_local(slot, size)
        return slot
    }

    fn slot_for(self, ty: checker.Type) -> int {
        return self.slot_of_desc(self.desc(ty))
    }

    // Gives a name to a slot, in the current scope.
    fn name_slot(self, name: string, slot: int, ty: checker.Type) {
        self.scopes[self.scopes.len() - 1].push(Local{name: name, slot: slot, ty: ty})
    }

    fn declare(self, name: string, ty: checker.Type) -> int {
        var slot = self.slot_for(ty)
        self.name_slot(name, slot, ty)
        return slot
    }

    fn lookup(self, name: string) -> [Local] {
        var s = self.scopes.len() - 1
        while s >= 0 {
            var scope = self.scopes[s]
            var i = scope.len() - 1
            while i >= 0 {
                if scope[i].name == name {
                    return [scope[i]]
                }
                i -= 1
            }
            s -= 1
        }
        return []
    }

    // The type of a variable, as it was declared.
    fn type_of_name(self, name: string) -> checker.Type {
        for local in self.lookup(name) {
            return local.ty
        }
        if self.captured.has(name) {
            return self.captured[name]
        }
        if self.globals.has(name) {
            return self.globals[name]
        }
        return checker.Type.Unknown
    }

    // Pushes the value of a variable (or of a function used as a value),
    // as a value of type `want`.
    fn load_name(self, name: string, want: checker.Type) {
        var code = self.code
        for local in self.lookup(name) {
            code.load(kind_of(self.desc(local.ty)), local.slot)
            self.convert(local.ty, want)
            return
        }
        if self.captured.has(name) {
            var ty = self.captured[name]
            code.load(4, 0)
            code.getfield(self.this_class, "c$" + mangle(name), self.desc(ty))
            self.convert(ty, want)
            return
        }
        if self.globals.has(name) {
            var ty = self.globals[name]
            self.used_globals[name] = true
            code.getstatic(MAIN, global_name(name), self.desc(ty))
            self.convert(ty, want)
            return
        }
        if self.an.fns.has(name) {
            var sig = self.an.fns[name]
            var class_name = self.ensure_wrapper(name, sig)
            code.new_object(class_name)
            code.op(DUP, 1)
            code.invokespecial(class_name, "<init>", "()V")
            self.convert(checker.Type.Fn(sig), want)
            return
        }
        panic("the JVM target does not know `{name}`")
    }

    // Stores the value on the stack, of type `from`, into a variable.
    fn store_name(self, name: string, from: checker.Type) {
        for local in self.lookup(name) {
            self.convert(from, local.ty)
            self.code.store(kind_of(self.desc(local.ty)), local.slot)
            return
        }
        if self.globals.has(name) {
            var ty = self.globals[name]
            self.used_globals[name] = true
            self.convert(from, ty)
            self.code.putstatic(MAIN, global_name(name), self.desc(ty))
            return
        }
        panic("the JVM target cannot assign to `{name}`")
    }

    fn init_global(self, stmt: ast.Stmt) {
        match stmt.kind {
            Let(name, _, _, _, _, init) {
                if is_catch(init) {
                    var target = ast.Expr{id: -1, start: stmt.start, end: stmt.end, kind: ast.ExprKind.Ident(name)}
                    self.catch_stmt(init, Sink.Assign(target))
                } else {
                    self.expr(init)
                    self.store_name(name, self.ty(init))
                }
            }
            else {
            }
        }
    }

    // ---- conversions ----

    // Turns the value on the stack, of type `from`, into one of type `to`.
    fn convert(self, from: checker.Type, to: checker.Type) {
        if from == to {
            return
        }
        convert_in(self.code, self.desc(from), self.desc(to))
    }

    // Removes a value of this type from the stack.
    fn discard(self, ty: checker.Type) {
        var size = classfile.slots_of(self.desc(ty))
        if size == 2 {
            self.code.op(POP2, -2)
        } else if size == 1 {
            self.code.op(POP, -1)
        }
    }

    // Pushes some value of this type, where the code is wrong anyway (a
    // problem was reported): the rest can still be written.
    fn dummy(self, ty: checker.Type) {
        var d = self.desc(ty)
        if d == "J" {
            self.code.lconst(0)
        } else if d == "D" {
            self.code.dconst(0.0)
        } else if d == "V" {
        } else if is_primitive(d) {
            self.code.iconst(0)
        } else {
            self.code.aconst_null()
        }
    }

    // Throws a new exception of `class`, whose message is on the stack.
    fn throw_new(self, class: string) {
        var code = self.code
        code.new_object(class)
        code.op(DUP_X1, 1)
        code.op(SWAP, 0)
        code.invokespecial(class, "<init>", "(Ljava/lang/String;)V")
        code.athrow()
    }

    // ---- statements ----

    fn stmts(self, list: [ast.Stmt]) {
        for s in list {
            if self.code.dead {
                // What follows a `return`, a `break`... never runs.
                return
            }
            self.stmt(s)
        }
    }

    fn block(self, b: ast.Block) {
        self.push_scope()
        self.stmts(b.stmts)
        self.pop_scope()
    }

    fn stmt(self, s: ast.Stmt) {
        var code = self.code
        match s.kind {
            Let(name, name_start, _, _, _, init) {
                var ty = self.declared(name_start, init)
                if is_catch(init) {
                    // The variable gets its value on one of two paths.
                    var slot = self.slot_for(ty)
                    self.catch_stmt(init, Sink.Slot(slot, ty))
                    self.name_slot(name, slot, ty)
                } else {
                    // The value is computed before the name exists: it may
                    // mention a variable of the same name, further out.
                    self.expr(init)
                    self.convert(self.ty(init), ty)
                    var slot = self.declare(name, ty)
                    code.store(kind_of(self.desc(ty)), slot)
                }
            }
            Assign(target, op, value) {
                self.assign(target, op, value)
            }
            Expr(e) {
                if is_catch(e) {
                    self.catch_stmt(e, Sink.Discard)
                } else {
                    self.expr(e)
                    if !code.dead {
                        self.discard(self.ty(e))
                    }
                }
            }
            If(cond, then, els) {
                var otherwise = code.new_label()
                self.jump_unless(cond, otherwise)
                self.block(then)
                if els.len() == 0 {
                    code.bind(otherwise)
                } else {
                    var end = code.new_label()
                    if !code.dead {
                        code.goto(end)
                    }
                    code.bind(otherwise)
                    self.push_scope()
                    self.stmt(els[0])
                    self.pop_scope()
                    code.bind(end)
                }
            }
            While(cond, body) {
                var top = code.new_label()
                var end = code.new_label()
                code.bind(top)
                self.jump_unless(cond, end)
                self.loops.push(JLoop{next: top, end: end})
                self.block(body)
                self.loops.remove(self.loops.len() - 1)
                if !code.dead {
                    code.goto(top)
                }
                code.bind(end)
            }
            For(name, _, _, iter, body) {
                self.for_stmt(name, iter, body)
            }
            Return(value) {
                if value.len() == 0 {
                    code.return_value(5)
                } else if is_catch(value[0]) {
                    self.catch_stmt(value[0], Sink.Return)
                } else {
                    self.expr(value[0])
                    self.return_top(self.ty(value[0]))
                }
            }
            Break {
                code.goto(self.loops[self.loops.len() - 1].end)
            }
            Continue {
                code.goto(self.loops[self.loops.len() - 1].next)
            }
            Fail(value) {
                self.expr(value)
                if self.ty(value) == checker.Type.Error {
                    // The error that was caught goes on as it is.
                    code.athrow()
                } else {
                    self.convert(self.ty(value), checker.Type.Str)
                    self.throw_new(FAILURE)
                }
            }
            Fork(_) {
                self.unsupported(s.start, s.end, "`fork` blocks")
            }
            Send(channel, value) {
                self.expr(channel)
                self.expr(value)
                self.convert(self.ty(value), checker.Type.Object)
                self.runtime("__jrt_chan_send")
            }
            Block(b) {
                self.block(b)
            }
            Match(_, _, _) {
                panic("`match` is rewritten by desugar before this pass")
            }
        }
    }

    // Returns the value on the stack, of type `from`.
    fn return_top(self, from: checker.Type) {
        self.convert(from, self.ret)
        self.code.return_value(kind_of(self.desc(self.ret)))
    }

    fn loop_body(self, body: ast.Block, next: int, end: int) {
        self.loops.push(JLoop{next: next, end: end})
        self.block(body)
        self.loops.remove(self.loops.len() - 1)
    }

    // Adds `by` to the int in `slot`.
    fn add_to(self, slot: int, by: int) {
        self.code.load(1, slot)
        self.code.lconst(by)
        self.code.op(LADD, -2)
        self.code.store(1, slot)
    }

    fn for_stmt(self, name: string, iter: ast.Expr, body: ast.Block) {
        var code = self.code
        self.push_scope()
        var top = code.new_label()
        var next = code.new_label()
        var end = code.new_label()
        var int_ty = checker.Type.Int
        match self.ty(iter) {
            Range {
                // `for i in lo..hi`: `i` counts from lo up to hi, which is
                // computed once.
                var counter = self.slot_for(int_ty)
                var limit = self.slot_for(int_ty)
                match iter.kind {
                    Range(lo, hi) {
                        self.expr(lo)
                        self.convert(self.ty(lo), int_ty)
                        code.store(1, counter)
                        self.expr(hi)
                        self.convert(self.ty(hi), int_ty)
                        code.store(1, limit)
                    }
                    else {
                        self.expr(iter)
                        code.op(DUP, 1)
                        code.iconst(0)
                        code.op(LALOAD, 0)
                        code.store(1, counter)
                        code.iconst(1)
                        code.op(LALOAD, 0)
                        code.store(1, limit)
                    }
                }
                self.name_slot(name, counter, int_ty)
                code.bind(top)
                code.load(1, counter)
                code.load(1, limit)
                code.op(LCMP, -3)
                code.if_zero(IFGE, end)
                self.loop_body(body, next, end)
                code.bind(next)
                self.add_to(counter, 1)
                code.goto(top)
            }
            List(elem) {
                // The length is read on every turn: what is added during
                // the loop is seen.
                self.expr(iter)
                var list = self.slot_of_desc(LIST_DESC)
                code.store(4, list)
                var index = self.slot_for(int_ty)
                code.lconst(0)
                code.store(1, index)
                code.bind(top)
                code.load(1, index)
                code.load(4, list)
                code.invokevirtual(LIST, "size", "()I")
                code.op(I2L, 1)
                code.op(LCMP, -3)
                code.if_zero(IFGE, end)
                code.load(4, list)
                code.load(1, index)
                code.op(L2I, -1)
                code.invokevirtual(LIST, "get", "(I)Ljava/lang/Object;")
                self.convert(checker.Type.Object, elem)
                var item = self.declare(name, elem)
                code.store(kind_of(self.desc(elem)), item)
                self.loop_body(body, next, end)
                code.bind(next)
                self.add_to(index, 1)
                code.goto(top)
            }
            Str {
                // Character by character: one or two UTF-16 units each.
                self.expr(iter)
                var text = self.slot_of_desc(STRING_DESC)
                code.store(4, text)
                var index = self.slot_for(int_ty)
                var width = self.slot_for(int_ty)
                code.lconst(0)
                code.store(1, index)
                code.bind(top)
                code.load(1, index)
                code.load(4, text)
                code.invokevirtual(STRING, "length", "()I")
                code.op(I2L, 1)
                code.op(LCMP, -3)
                code.if_zero(IFGE, end)
                code.load(4, text)
                code.load(1, index)
                code.op(L2I, -1)
                code.invokevirtual(STRING, "codePointAt", "(I)I")
                code.invokestatic("java/lang/Character", "charCount", "(I)I")
                code.op(I2L, 1)
                code.store(1, width)
                code.load(4, text)
                code.load(1, index)
                code.op(L2I, -1)
                code.load(1, index)
                code.load(1, width)
                code.op(LADD, -2)
                code.op(L2I, -1)
                code.invokevirtual(STRING, "substring", "(II)Ljava/lang/String;")
                var item = self.declare(name, checker.Type.Str)
                code.store(4, item)
                self.loop_body(body, next, end)
                code.bind(next)
                code.load(1, index)
                code.load(1, width)
                code.op(LADD, -2)
                code.store(1, index)
                code.goto(top)
            }
            Map(key, _) {
                // Entry by entry, in the order they were added; removed
                // ones are skipped, new ones are seen.
                self.expr(iter)
                var the_map = self.slot_of_desc(OBJECT_DESC)
                code.store(4, the_map)
                var position = self.slot_for(int_ty)
                code.lconst(0)
                code.store(1, position)
                code.bind(top)
                code.load(4, the_map)
                code.load(1, position)
                self.runtime_method(MAP_STRUCT, "next")
                code.op(DUP2, 2)
                code.store(1, position)
                code.lconst(0)
                code.op(LCMP, -3)
                code.if_zero(IFLT, end)
                code.load(4, the_map)
                code.load(1, position)
                self.runtime_method(MAP_STRUCT, "key")
                self.convert(checker.Type.Object, key)
                var item = self.declare(name, key)
                code.store(kind_of(self.desc(key)), item)
                self.loop_body(body, next, end)
                code.bind(next)
                self.add_to(position, 1)
                code.goto(top)
            }
            Chan(elem) {
                // Receives until the channel is closed and empty.
                self.expr(iter)
                var channel = self.slot_of_desc(OBJECT_DESC)
                code.store(4, channel)
                var got = self.slot_of_desc(OBJECT_DESC)
                code.bind(top)
                code.load(4, channel)
                self.runtime("__jrt_chan_take")
                code.store(4, got)
                self.load_name("__jrt_chan_ok", checker.Type.Bool)
                code.if_zero(IFEQ, end)
                code.load(4, got)
                self.convert(checker.Type.Object, elem)
                var item = self.declare(name, elem)
                code.store(kind_of(self.desc(elem)), item)
                self.loop_body(body, next, end)
                code.bind(next)
                code.goto(top)
            }
            else {
                self.unsupported(iter.start, iter.end, "loops over this")
            }
        }
        code.bind(end)
        self.pop_scope()
    }

    // `target = value`, `target += value`...
    fn assign(self, target: ast.Expr, op: ast.AssignOp, value: ast.Expr) {
        var code = self.code
        if is_catch(value) {
            self.catch_stmt(value, Sink.Assign(target))
            return
        }
        match target.kind {
            Ident(name) {
                if op == ast.AssignOp.Set {
                    self.expr(value)
                    self.store_name(name, self.ty(value))
                } else {
                    var ty = self.type_of_name(name)
                    self.load_name(name, ty)
                    self.expr(value)
                    self.combine(op, ty, self.ty(value))
                    self.store_name(name, ty)
                }
            }
            Field(obj, name, _, _) {
                match self.ty(obj) {
                    Struct(s) {
                        var class_name = self.ensure_struct(s)
                        var fty = self.field_type(s, name)
                        var d = self.desc(fty)
                        self.expr(obj)
                        if op == ast.AssignOp.Set {
                            self.expr(value)
                            self.convert(self.ty(value), fty)
                        } else {
                            code.op(DUP, 1)
                            code.getfield(class_name, field_name(name), d)
                            self.expr(value)
                            self.combine(op, fty, self.ty(value))
                        }
                        code.putfield(class_name, field_name(name), d)
                    }
                    else {
                        self.unsupported(target.start, target.end, "assignments to this")
                    }
                }
            }
            Index(obj, index) {
                var object = checker.Type.Object
                self.push_scope()
                match self.ty(obj) {
                    Map(_, v) {
                        self.expr(obj)
                        self.expr(index)
                        self.convert(self.ty(index), object)
                        if op == ast.AssignOp.Set {
                            self.expr(value)
                            self.convert(self.ty(value), object)
                        } else {
                            code.op(DUP2, 2)
                            self.runtime_method(MAP_STRUCT, "at")
                            self.convert(object, v)
                            self.expr(value)
                            self.combine(op, v, self.ty(value))
                            self.convert(v, object)
                        }
                        self.runtime_method(MAP_STRUCT, "set")
                    }
                    List(elem) {
                        self.expr(obj)
                        var list = self.slot_of_desc(LIST_DESC)
                        code.store(4, list)
                        self.expr(index)
                        self.convert(self.ty(index), checker.Type.Int)
                        var at = self.slot_for(checker.Type.Int)
                        code.store(1, at)
                        code.load(4, list)
                        code.load(1, at)
                        if op == ast.AssignOp.Set {
                            self.expr(value)
                            self.convert(self.ty(value), object)
                        } else {
                            code.load(4, list)
                            code.load(1, at)
                            self.runtime("__jrt_list_at")
                            self.convert(object, elem)
                            self.expr(value)
                            self.combine(op, elem, self.ty(value))
                            self.convert(elem, object)
                        }
                        self.runtime("__jrt_list_set")
                    }
                    else {
                        self.unsupported(target.start, target.end, "assignments to this")
                    }
                }
                self.pop_scope()
            }
            else {
                self.unsupported(target.start, target.end, "assignments to this")
            }
        }
    }

    fn field_type(self, strukt: string, name: string) -> checker.Type {
        if self.an.structs.has(strukt) {
            for f in self.an.structs[strukt].fields {
                if f.name == name {
                    return f.ty
                }
            }
        }
        return checker.Type.Unknown
    }

    // `current op value`, with `current` (of type `ty`) and the value (of
    // type `from`) on the stack.
    fn combine(self, op: ast.AssignOp, ty: checker.Type, from: checker.Type) {
        self.convert(from, ty)
        if ty == checker.Type.Str {
            self.code.invokevirtual(STRING, "concat", "(Ljava/lang/String;)Ljava/lang/String;")
            return
        }
        var float = ty == checker.Type.Float
        match op {
            Add {
                arith(self.code, ast.BinOp.Add, float)
            }
            Sub {
                arith(self.code, ast.BinOp.Sub, float)
            }
            Mul {
                arith(self.code, ast.BinOp.Mul, float)
            }
            Div {
                arith(self.code, ast.BinOp.Div, float)
            }
            Set {
            }
        }
    }

    // `call() catch err { ... }`: the call in a region of code whose
    // failures go to the block.
    fn catch_stmt(self, e: ast.Expr, sink: Sink) {
        var code = self.code
        match e.kind {
            Catch(inner, name, _, _, body) {
                if code.stack != 0 {
                    self.unsupported(e.start, e.end, "`catch` inside this expression")
                    return
                }
                var start = code.new_label()
                var end = code.new_label()
                var handler = code.new_label()
                var done = code.new_label()
                code.bind(start)
                self.expr(inner)
                code.bind(end)
                self.sink(sink, self.ty(inner))
                if !code.dead {
                    code.goto(done)
                }
                code.handler(start, end, handler, FAILURE)
                code.bind(handler)
                self.push_scope()
                var slot = self.declare(name, checker.Type.Error)
                code.store(4, slot)
                var list = body.stmts
                var has_value = self.an.catch_values.has(e.id) && list.len() > 0
                var count = list.len()
                if has_value {
                    count -= 1
                }
                self.stmts(list.slice(0, count))
                if has_value && !code.dead {
                    var last = list[count]
                    match last.kind {
                        Expr(value) {
                            if is_catch(value) {
                                self.catch_stmt(value, sink)
                            } else {
                                self.expr(value)
                                if !code.dead {
                                    self.sink(sink, self.ty(value))
                                }
                            }
                        }
                        else {
                            self.stmt(last)
                        }
                    }
                }
                self.pop_scope()
                code.bind(done)
            }
            else {
            }
        }
    }

    // Puts the value on the stack (of type `from`) where a `catch` sends it.
    fn sink(self, sink: Sink, from: checker.Type) {
        match sink {
            Slot(slot, ty) {
                self.convert(from, ty)
                self.code.store(kind_of(self.desc(ty)), slot)
            }
            Assign(target) {
                match target.kind {
                    Ident(name) {
                        self.store_name(name, from)
                    }
                    else {
                        self.unsupported(target.start, target.end, "this assignment of a `catch`")
                    }
                }
            }
            Return {
                self.return_top(from)
            }
            Discard {
                self.discard(from)
            }
        }
    }

    // ---- expressions ----

    // Pushes the value of `e`, of the descriptor of its type (nothing for a
    // call that returns nothing).
    fn expr(self, e: ast.Expr) {
        var code = self.code
        match e.kind {
            Int(n) {
                if self.ty(e) == checker.Type.Float {
                    code.dconst(float(n))
                } else {
                    code.lconst(n)
                }
            }
            Float(x) {
                code.dconst(x)
            }
            Bool(b) {
                if b {
                    code.iconst(1)
                } else {
                    code.iconst(0)
                }
            }
            Str(parts) {
                self.string(parts)
            }
            Ident(name) {
                self.load_name(name, self.ty(e))
            }
            List(items) {
                code.new_object(LIST)
                code.op(DUP, 1)
                code.iconst(items.len())
                code.invokespecial(LIST, "<init>", "(I)V")
                for item in items {
                    code.op(DUP, 1)
                    self.expr(item)
                    self.convert(self.ty(item), checker.Type.Object)
                    code.invokevirtual(LIST, "add", "(Ljava/lang/Object;)Z")
                    code.op(POP, -1)
                }
            }
            Map(entries) {
                self.runtime("__jrt_map_new")
                for entry in entries {
                    code.op(DUP, 1)
                    self.expr(entry.key)
                    self.convert(self.ty(entry.key), checker.Type.Object)
                    self.expr(entry.value)
                    self.convert(self.ty(entry.value), checker.Type.Object)
                    self.runtime_method(MAP_STRUCT, "set")
                }
            }
            StructLit(name, _, _, fields) {
                // The values, in the order of the declaration of the fields.
                var class_name = self.ensure_struct(name)
                self.struct_made(name)
                var descs = ""
                if self.an.structs.has(name) {
                    for f in self.an.structs[name].fields {
                        for init in fields {
                            if init.name == f.name {
                                self.expr(init.value)
                                self.convert(self.ty(init.value), f.ty)
                                break
                            }
                        }
                        descs += self.desc(f.ty)
                    }
                }
                code.invokestatic(class_name, "new$", "(" + descs + ")L" + class_name + ";")
            }
            Unary(op, inner) {
                self.expr(inner)
                if op == ast.UnOp.Neg {
                    if self.desc(self.ty(inner)) == "D" {
                        code.op(DNEG, 0)
                    } else {
                        code.op(LNEG, 0)
                    }
                } else {
                    code.iconst(1)
                    code.op(IXOR, -1)
                }
            }
            Binary(op, lhs, rhs) {
                self.binary(e, op, lhs, rhs)
            }
            Call(callee, args) {
                self.call(e, callee, args)
            }
            Field(obj, name, _, _) {
                if self.an.variants.has(e.id) {
                    // `Shape.Empty`: a variant that carries nothing.
                    var v = self.an.variants[e.id]
                    var class_name = self.ensure_enum(v.enum_name)
                    code.iconst(v.index)
                    code.aconst_null()
                    code.invokestatic(class_name, "new$", "(ILjava/util/ArrayList;)L" + class_name + ";")
                    return
                }
                match self.ty(obj) {
                    Struct(s) {
                        var class_name = self.ensure_struct(s)
                        var fty = self.field_type(s, name)
                        self.expr(obj)
                        code.getfield(class_name, field_name(name), self.desc(fty))
                        self.convert(fty, self.ty(e))
                    }
                    Error {
                        self.expr(obj)
                        code.invokevirtual("java/lang/Throwable", "getMessage", "()Ljava/lang/String;")
                    }
                    else {
                        self.unsupported(e.start, e.end, "fields of this kind")
                        self.dummy(self.ty(e))
                    }
                }
            }
            Index(obj, index) {
                self.expr(obj)
                self.expr(index)
                match self.ty(obj) {
                    Str {
                        self.convert(self.ty(index), checker.Type.Int)
                        self.runtime("__jrt_char_at")
                    }
                    Map(_, _) {
                        self.convert(self.ty(index), checker.Type.Object)
                        self.runtime_method(MAP_STRUCT, "at")
                        self.convert(checker.Type.Object, self.ty(e))
                    }
                    else {
                        self.convert(self.ty(index), checker.Type.Int)
                        self.runtime("__jrt_list_at")
                        self.convert(checker.Type.Object, self.ty(e))
                    }
                }
            }
            Lambda(params, _, _, body) {
                self.lambda(e, params, body)
            }
            // An error travels up by itself, as an exception.
            Try(inner) {
                self.expr(inner)
                self.convert(self.ty(inner), self.ty(e))
            }
            Or(inner, default) {
                self.or_expr(e, inner, default)
            }
            Catch(_, _, _, _, _) {
                self.unsupported(e.start, e.end, "`catch` inside an expression")
                self.dummy(self.ty(e))
            }
            Recv(channel) {
                self.expr(channel)
                self.runtime("__jrt_chan_recv")
                self.convert(checker.Type.Object, self.ty(e))
            }
            ChanNew(_, cap) {
                if cap.len() > 0 {
                    self.expr(cap[0])
                    self.convert(self.ty(cap[0]), checker.Type.Int)
                } else {
                    code.lconst(0)
                }
                self.runtime("__jrt_chan_new")
            }
            Range(lo, hi) {
                // A range kept as a value: an array of its two ends.
                code.iconst(2)
                code.op(NEWARRAY, 0)
                code.u1(T_LONG)
                code.op(DUP, 1)
                code.iconst(0)
                self.expr(lo)
                self.convert(self.ty(lo), checker.Type.Int)
                code.op(LASTORE, -4)
                code.op(DUP, 1)
                code.iconst(1)
                self.expr(hi)
                self.convert(self.ty(hi), checker.Type.Int)
                code.op(LASTORE, -4)
            }
        }
    }

    // Pushes a string constant; a very long one (the JVM's constants stop
    // at 65535 bytes) is put together from pieces.
    fn text(self, s: string) {
        var code = self.code
        if s.len() <= 8000 {
            code.sconst(s)
            return
        }
        code.new_object(BUILDER)
        code.op(DUP, 1)
        code.invokespecial(BUILDER, "<init>", "()V")
        var at = 0
        while at < s.len() {
            var piece = min(8000, s.len() - at)
            code.sconst(s.slice(at, at + piece))
            append(code, STRING_DESC)
            at += piece
        }
        code.invokevirtual(BUILDER, "toString", "()Ljava/lang/String;")
    }

    // A string with `{...}` in it.
    fn string(self, parts: [ast.StrPart]) {
        var code = self.code
        if parts.len() == 0 {
            code.sconst("")
            return
        }
        if parts.len() == 1 {
            match parts[0] {
                Lit(s) {
                    self.text(s)
                }
                Code(inner) {
                    self.to_str(inner)
                }
            }
            return
        }
        code.new_object(BUILDER)
        code.op(DUP, 1)
        code.invokespecial(BUILDER, "<init>", "()V")
        for p in parts {
            match p {
                Lit(s) {
                    self.text(s)
                    append(code, STRING_DESC)
                }
                Code(inner) {
                    self.append_value(inner)
                }
            }
        }
        code.invokevirtual(BUILDER, "toString", "()Ljava/lang/String;")
    }

    // Adds the text of the value of `e` to the StringBuilder on the stack.
    fn append_value(self, e: ast.Expr) {
        var ty = self.ty(e)
        if ty == checker.Type.Int || ty == checker.Type.Bool || ty == checker.Type.Str {
            self.expr(e)
            append(self.code, self.desc(ty))
        } else {
            self.to_str(e)
            append(self.code, STRING_DESC)
        }
    }

    // Pushes the text of the value of `e`, as `print` and `str` show it.
    fn to_str(self, e: ast.Expr) {
        self.expr(e)
        self.text_of(self.ty(e))
    }

    // Turns the value on the stack, of type `ty`, into its text.
    fn text_of(self, ty: checker.Type) {
        var code = self.code
        match ty {
            Str {
            }
            Int {
                code.invokestatic("java/lang/Long", "toString", "(J)Ljava/lang/String;")
            }
            Float {
                self.runtime("__jrt_float_str")
            }
            Bool {
                code.invokestatic(STRING, "valueOf", "(Z)Ljava/lang/String;")
            }
            Error {
                code.invokevirtual("java/lang/Throwable", "getMessage", "()Ljava/lang/String;")
            }
            else {
                self.convert(ty, checker.Type.Object)
                self.runtime("__jrt_str")
            }
        }
    }

    fn binary(self, e: ast.Expr, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr) {
        var code = self.code
        var ty = self.ty(e)
        if is_comparison(op) || op == ast.BinOp.And || op == ast.BinOp.Or {
            // A truth value: 1 or 0.
            var no = code.new_label()
            var done = code.new_label()
            self.jump_unless(e, no)
            code.iconst(1)
            code.goto(done)
            code.bind(no)
            code.iconst(0)
            code.bind(done)
            return
        }
        if ty == checker.Type.Str {
            // `a + b + c`: one StringBuilder for the whole chain.
            var pieces: [ast.Expr] = []
            self.concat_parts(e, pieces)
            if pieces.len() == 2 {
                self.expr(pieces[0])
                self.expr(pieces[1])
                code.invokevirtual(STRING, "concat", "(Ljava/lang/String;)Ljava/lang/String;")
                return
            }
            code.new_object(BUILDER)
            code.op(DUP, 1)
            code.invokespecial(BUILDER, "<init>", "()V")
            for piece in pieces {
                self.expr(piece)
                append(code, STRING_DESC)
            }
            code.invokevirtual(BUILDER, "toString", "()Ljava/lang/String;")
            return
        }
        self.expr(lhs)
        self.convert(self.ty(lhs), ty)
        self.expr(rhs)
        self.convert(self.ty(rhs), ty)
        arith(code, op, self.desc(ty) == "D")
    }

    // The strings that a chain of `+` puts together.
    fn concat_parts(self, e: ast.Expr, out: [ast.Expr]) {
        match e.kind {
            Binary(op, lhs, rhs) {
                if op == ast.BinOp.Add && self.ty(e) == checker.Type.Str {
                    self.concat_parts(lhs, out)
                    self.concat_parts(rhs, out)
                    return
                }
            }
            else {
            }
        }
        out.push(e)
    }

    // ---- conditions ----

    // Jumps to `label` when `e` is false; goes on when it is true.
    fn jump_unless(self, e: ast.Expr, label: int) {
        match e.kind {
            Bool(b) {
                if !b {
                    self.code.goto(label)
                }
                return
            }
            Unary(op, inner) {
                if op == ast.UnOp.Not {
                    self.jump_if(inner, label)
                    return
                }
            }
            Binary(op, lhs, rhs) {
                if op == ast.BinOp.And {
                    self.jump_unless(lhs, label)
                    self.jump_unless(rhs, label)
                    return
                }
                if op == ast.BinOp.Or {
                    var yes = self.code.new_label()
                    self.jump_if(lhs, yes)
                    self.jump_unless(rhs, label)
                    self.code.bind(yes)
                    return
                }
                if is_comparison(op) {
                    self.compare(op, lhs, rhs, label, false)
                    return
                }
            }
            else {
            }
        }
        self.expr(e)
        self.code.if_zero(IFEQ, label)
    }

    // Jumps to `label` when `e` is true; goes on when it is false.
    fn jump_if(self, e: ast.Expr, label: int) {
        match e.kind {
            Bool(b) {
                if b {
                    self.code.goto(label)
                }
                return
            }
            Unary(op, inner) {
                if op == ast.UnOp.Not {
                    self.jump_unless(inner, label)
                    return
                }
            }
            Binary(op, lhs, rhs) {
                if op == ast.BinOp.And {
                    var no = self.code.new_label()
                    self.jump_unless(lhs, no)
                    self.jump_if(rhs, label)
                    self.code.bind(no)
                    return
                }
                if op == ast.BinOp.Or {
                    self.jump_if(lhs, label)
                    self.jump_if(rhs, label)
                    return
                }
                if is_comparison(op) {
                    self.compare(op, lhs, rhs, label, true)
                    return
                }
            }
            else {
            }
        }
        self.expr(e)
        self.code.if_zero(IFNE, label)
    }

    // Compares `lhs` and `rhs` and jumps to `label` when the comparison is
    // `when`.
    fn compare(self, op: ast.BinOp, lhs: ast.Expr, rhs: ast.Expr, label: int, when: bool) {
        var code = self.code
        var lt = self.ty(lhs)
        var rt = self.ty(rhs)
        var jump = 0
        var numbers = checker.is_numeric(lt) && checker.is_numeric(rt)
        if numbers {
            var float = lt == checker.Type.Float || rt == checker.Type.Float
            var as_ty = checker.Type.Int
            if float {
                as_ty = checker.Type.Float
            }
            self.expr(lhs)
            self.convert(lt, as_ty)
            self.expr(rhs)
            self.convert(rt, as_ty)
            if !float {
                code.op(LCMP, -3)
            } else if op == ast.BinOp.Lt || op == ast.BinOp.Le {
                // NaN compares as greater: `<` and `<=` are false.
                code.op(DCMPG, -3)
            } else {
                // NaN compares as smaller: `>`, `>=` and `==` are false.
                code.op(DCMPL, -3)
            }
            jump = zero_jump(op)
        } else if lt == checker.Type.Bool && rt == checker.Type.Bool {
            self.expr(lhs)
            self.expr(rhs)
            jump = IF_ICMPEQ
            if op == ast.BinOp.NotEq {
                jump = IF_ICMPNE
            }
        } else if lt == checker.Type.Str && rt == checker.Type.Str {
            self.expr(lhs)
            self.expr(rhs)
            if op == ast.BinOp.Eq || op == ast.BinOp.NotEq {
                code.invokevirtual(STRING, "equals", "(Ljava/lang/Object;)Z")
                jump = IFNE
                if op == ast.BinOp.NotEq {
                    jump = IFEQ
                }
            } else {
                code.invokevirtual(STRING, "compareTo", "(Ljava/lang/String;)I")
                jump = zero_jump(op)
            }
        } else if self.variant_of(lhs) >= 0 || self.variant_of(rhs) >= 0 {
            // Against a variant that carries nothing: the variants are compared.
            var other = lhs
            var index = self.variant_of(rhs)
            if index < 0 {
                other = rhs
                index = self.variant_of(lhs)
            }
            var class_name = self.ensure_enum(self.an.variants[self.variant_id(lhs, rhs)].enum_name)
            self.expr(other)
            code.getfield(class_name, "v", "I")
            code.iconst(index)
            jump = IF_ICMPEQ
            if op == ast.BinOp.NotEq {
                jump = IF_ICMPNE
            }
        } else {
            // Lists, structs...: compared by what is in them.
            self.expr(lhs)
            self.convert(lt, checker.Type.Object)
            self.expr(rhs)
            self.convert(rt, checker.Type.Object)
            self.runtime("__jrt_eq")
            jump = IFNE
            if op == ast.BinOp.NotEq {
                jump = IFEQ
            }
        }
        if !when {
            jump = negate(jump)
        }
        if jump >= IF_ICMPEQ {
            code.if_icmp(jump, label)
        } else {
            code.if_zero(jump, label)
        }
    }

    // The position of the variant `e` makes, when it is one that carries
    // nothing (`Shape.Empty`), or -1.
    fn variant_of(self, e: ast.Expr) -> int {
        match e.kind {
            Field(_, _, _, _) {
                if self.an.variants.has(e.id) {
                    return self.an.variants[e.id].index
                }
            }
            else {
            }
        }
        return -1
    }

    // The id of whichever of the two is such a variant.
    fn variant_id(self, lhs: ast.Expr, rhs: ast.Expr) -> int {
        if self.variant_of(lhs) >= 0 {
            return lhs.id
        }
        return rhs.id
    }

    // ---- calls ----

    // Pushes the arguments, each as a value of the type the function takes.
    fn args(self, args: [ast.Expr], params: [checker.Type]) {
        for i in 0..args.len() {
            self.expr(args[i])
            if i < params.len() {
                self.convert(self.ty(args[i]), params[i])
            }
        }
    }

    fn param_types(self, f: JFn) -> [checker.Type] {
        var out: [checker.Type] = []
        for p in f.params {
            out.push(p.ty)
        }
        return out
    }

    // Calls the runtime function `name` with the values of `values`; the
    // result becomes a value of the type of `e`.
    fn call_runtime(self, name: string, values: [ast.Expr], e: ast.Expr) {
        var f = self.request(checker.fn_key(name))
        self.args(values, self.param_types(f))
        self.code.invokestatic(MAIN, f.name, self.fn_desc(f))
        self.convert(f.ret, self.ty(e))
    }

    fn call(self, e: ast.Expr, callee: ast.Expr, args: [ast.Expr]) {
        var code = self.code
        if self.an.variants.has(e.id) {
            // `Shape.Circle(2.0)`: the variant, and the list of what it carries.
            var v = self.an.variants[e.id]
            var class_name = self.ensure_enum(v.enum_name)
            code.iconst(v.index)
            code.new_object(LIST)
            code.op(DUP, 1)
            code.iconst(args.len())
            code.invokespecial(LIST, "<init>", "(I)V")
            for arg in args {
                code.op(DUP, 1)
                self.expr(arg)
                self.convert(self.ty(arg), checker.Type.Object)
                code.invokevirtual(LIST, "add", "(Ljava/lang/Object;)Z")
                code.op(POP, -1)
            }
            code.invokestatic(class_name, "new$", "(ILjava/util/ArrayList;)L" + class_name + ";")
            return
        }
        var kind = checker.CallKind.Dynamic
        if self.an.calls.has(e.id) {
            kind = self.an.calls[e.id]
        }
        match kind {
            Fn(name) {
                var f = self.request(checker.fn_key(name))
                self.args(args, self.param_types(f))
                var start = code.new_label()
                var end = code.new_label()
                code.bind(start)
                code.invokestatic(MAIN, f.name, self.fn_desc(f))
                code.bind(end)
                if self.an.async_keys.has(checker.fn_key(name)) {
                    self.after_await(e, start, end)
                }
                self.convert(f.ret, self.ty(e))
            }
            Method(strukt, name) {
                var f = self.request(checker.method_key(strukt, name))
                match callee.kind {
                    Field(obj, _, _, _) {
                        self.expr(obj)
                        self.convert(self.ty(obj), checker.Type.Struct(strukt))
                    }
                    else {
                    }
                }
                self.args(args, self.param_types(f))
                var start = code.new_label()
                var end = code.new_label()
                code.bind(start)
                code.invokevirtual(f.class_name, f.name, self.fn_desc(f))
                code.bind(end)
                if self.an.async_keys.has(checker.method_key(strukt, name)) {
                    self.after_await(e, start, end)
                }
                self.convert(f.ret, self.ty(e))
            }
            Dynamic {
                self.dynamic_call(e, callee, args)
            }
            Builtin(name) {
                self.builtin(e, name, args)
            }
            BuiltinMethod(recv, name) {
                match callee.kind {
                    Field(obj, _, _, _) {
                        self.builtin_method(e, recv, name, obj, args)
                    }
                    else {
                    }
                }
            }
        }
    }

    // A method called through an interface, or a function value called.
    fn dynamic_call(self, e: ast.Expr, callee: ast.Expr, args: [ast.Expr]) {
        var code = self.code
        match callee.kind {
            Field(obj, name, _, _) {
                match self.ty(obj) {
                    Interface(iname) {
                        var iface = self.ensure_interface(iname)
                        for m in self.an.interfaces[iname].methods {
                            if m.name == name {
                                self.expr(obj)
                                self.args(args, m.sig.params)
                                var start = code.new_label()
                                var end = code.new_label()
                                code.bind(start)
                                code.invokeinterface(iface, method_name(name), self.method_desc(m.sig.params, m.sig.ret))
                                code.bind(end)
                                self.after_await(e, start, end)
                                self.convert(m.sig.ret, self.ty(e))
                                return
                            }
                        }
                    }
                    Struct(s) {
                        // A function kept in a field.
                        match self.field_type(s, name) {
                            Fn(sig) {
                                var class_name = self.ensure_struct(s)
                                var iface = self.fn_interface(sig)
                                self.expr(obj)
                                code.getfield(class_name, field_name(name), "L" + iface + ";")
                                self.args(args, sig.params)
                                var start = code.new_label()
                                var end = code.new_label()
                                code.bind(start)
                                code.invokeinterface(iface, "call", self.method_desc(sig.params, sig.ret))
                                code.bind(end)
                                self.after_await(e, start, end)
                                self.convert(sig.ret, self.ty(e))
                                return
                            }
                            else {
                            }
                        }
                    }
                    else {
                    }
                }
            }
            else {
            }
        }
        match self.ty(callee) {
            Fn(sig) {
                var iface = self.fn_interface(sig)
                self.expr(callee)
                self.args(args, sig.params)
                var start = code.new_label()
                var end = code.new_label()
                code.bind(start)
                code.invokeinterface(iface, "call", self.method_desc(sig.params, sig.ret))
                code.bind(end)
                self.after_await(e, start, end)
                self.convert(sig.ret, self.ty(e))
            }
            else {
                self.unsupported(e.start, e.end, "calls of this kind")
                self.dummy(self.ty(e))
            }
        }
    }

    // A lambda: an object of a class of its own, which keeps the values it
    // captured; its body is the method `call`, compiled later.
    fn lambda(self, e: ast.Expr, params: [ast.Param], body: ast.Block) {
        var code = self.code
        var sig = checker.FnSig{params: [], ret: checker.Type.Void, fallible: false}
        match self.ty(e) {
            Fn(s) {
                sig = s
            }
            else {
            }
        }
        var captures: [checker.Captured] = []
        if self.an.captures.has(e.id) {
            captures = self.an.captures[e.id]
        }
        var class_name = lambda_class(e.id)
        var descs = ""
        for captured in captures {
            descs += self.desc(captured.ty)
        }
        if !self.classes.has(class_name) {
            var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_SUPER, OBJECT)
            c.interfaces.push(self.fn_interface(sig))
            for captured in captures {
                c.field(classfile.ACC_PUBLIC, "c$" + mangle(captured.name), self.desc(captured.ty))
            }
            self.constructor(c, OBJECT)
            var make = classfile.new_code(c.pool, 0)
            make.new_object(class_name)
            make.op(DUP, 1)
            make.invokespecial(class_name, "<init>", "()V")
            var slot = 0
            for captured in captures {
                var d = self.desc(captured.ty)
                make.op(DUP, 1)
                make.load(kind_of(d), slot)
                make.putfield(class_name, "c$" + mangle(captured.name), d)
                slot += classfile.slots_of(d)
            }
            make.uses_local(0, slot)
            make.return_value(4)
            c.method(classfile.ACC_PUBLIC | classfile.ACC_STATIC, "new$", "(" + descs + ")L" + class_name + ";", make)
            var none: [checker.Type] = []
            var key = checker.lambda_key(e.id)
            self.items[key] = JFn{class_name: class_name, name: "call", is_static: false, params: params_of(params, sig), ret: sig.ret, body: body, self_type: none, captures: captures}
            self.request(key)
        }
        for captured in captures {
            self.load_name(captured.name, captured.ty)
        }
        code.invokestatic(class_name, "new$", "(" + descs + ")L" + class_name + ";")
    }

    // `call() or default`: the call in a region of code whose failures go
    // to the default. The stack is empty there (see lower.ox), as the JVM
    // empties it when it catches an exception.
    fn or_expr(self, e: ast.Expr, inner: ast.Expr, default: ast.Expr) {
        var code = self.code
        var ty = self.ty(e)
        if code.stack != 0 {
            self.unsupported(e.start, e.end, "`or` inside this expression")
            self.dummy(ty)
            return
        }
        // When either side waits, the JavaScript target goes through a
        // helper that waits a few more turns; so do we (as the native one).
        var waits = self.an.has_forks && (self.awaits(inner) || self.awaits(default))
        var start = code.new_label()
        var end = code.new_label()
        var handler = code.new_label()
        var done = code.new_label()
        code.bind(start)
        self.expr(inner)
        self.convert(self.ty(inner), ty)
        code.bind(end)
        if waits {
            self.yield_point()
            self.yield_point()
        }
        code.goto(done)
        code.handler(start, end, handler, FAILURE)
        code.bind(handler)
        code.op(POP, -1)
        if waits {
            self.yield_point()
        }
        self.expr(default)
        self.convert(self.ty(default), ty)
        if waits {
            for _ in 0..3 {
                self.yield_point()
            }
        }
        code.bind(done)
    }

    // After a call that the JavaScript target awaits: the tasks that are
    // ready go first, whether the call returned or failed. When it failed
    // (the call is the code from `start` to `end`), its error goes on after.
    fn after_await(self, e: ast.Expr, start: int, end: int) {
        if !self.an.has_forks {
            return
        }
        var code = self.code
        self.yield_point()
        if self.an.fallible_calls.has(e.id) {
            var after = code.new_label()
            var handler = code.new_label()
            code.goto(after)
            code.handler(start, end, handler, FAILURE)
            code.bind(handler)
            self.runtime("__jrt_yield")
            code.athrow()
            code.bind(after)
        }
    }

    // Where the JavaScript target has an `await`: the tasks that are ready
    // get to run before this one goes on. Only in a program with tasks.
    fn yield_point(self) {
        if self.an.has_forks {
            self.runtime("__jrt_yield")
        }
    }

    // Whether evaluating `e` lets other tasks run (in the JavaScript target:
    // whether it contains an `await`). Lambdas are functions of their own.
    fn awaits(self, e: ast.Expr) -> bool {
        match e.kind {
            Recv(_) {
                return true
            }
            Call(callee, args) {
                var waits = true
                if self.an.calls.has(e.id) {
                    match self.an.calls[e.id] {
                        Fn(name) {
                            waits = self.an.async_keys.has(checker.fn_key(name))
                        }
                        Method(strukt, name) {
                            waits = self.an.async_keys.has(checker.method_key(strukt, name))
                        }
                        Dynamic {
                            waits = true
                        }
                        Builtin(name) {
                            waits = name == "sleep"
                        }
                        BuiltinMethod(_, name) {
                            waits = name == "map" || name == "filter" || name == "sort_by"
                        }
                    }
                }
                if waits || self.awaits(callee) {
                    return true
                }
                for a in args {
                    if self.awaits(a) {
                        return true
                    }
                }
                return false
            }
            Str(parts) {
                for p in parts {
                    match p {
                        Code(inner) {
                            if self.awaits(inner) {
                                return true
                            }
                        }
                        else {
                        }
                    }
                }
                return false
            }
            List(items) {
                for item in items {
                    if self.awaits(item) {
                        return true
                    }
                }
                return false
            }
            Map(entries) {
                for entry in entries {
                    if self.awaits(entry.key) || self.awaits(entry.value) {
                        return true
                    }
                }
                return false
            }
            StructLit(_, _, _, fields) {
                for f in fields {
                    if self.awaits(f.value) {
                        return true
                    }
                }
                return false
            }
            Unary(_, inner) {
                return self.awaits(inner)
            }
            Try(inner) {
                return self.awaits(inner)
            }
            Catch(inner, _, _, _, _) {
                return self.awaits(inner)
            }
            Field(obj, _, _, _) {
                return self.awaits(obj)
            }
            Binary(_, lhs, rhs) {
                return self.awaits(lhs) || self.awaits(rhs)
            }
            Index(obj, index) {
                return self.awaits(obj) || self.awaits(index)
            }
            Range(lo, hi) {
                return self.awaits(lo) || self.awaits(hi)
            }
            Or(inner, default) {
                return self.awaits(inner) || self.awaits(default)
            }
            ChanNew(_, cap) {
                for c in cap {
                    if self.awaits(c) {
                        return true
                    }
                }
                return false
            }
            else {
                return false
            }
        }
    }

    // `onyx.Keyed`: an item and the key it is sorted by, for Java's sort,
    // which compares the keys with `__jrt_compare`.
    fn ensure_keyed_class(self) {
        var class_name = "onyx/Keyed"
        if self.classes.has(class_name) {
            return
        }
        var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_SUPER, OBJECT)
        c.interfaces.push("java/lang/Comparable")
        c.field(classfile.ACC_PUBLIC, "key", OBJECT_DESC)
        c.field(classfile.ACC_PUBLIC, "item", OBJECT_DESC)
        var init = classfile.new_code(c.pool, 3)
        init.load(4, 0)
        init.invokespecial(OBJECT, "<init>", "()V")
        init.load(4, 0)
        init.load(4, 1)
        init.putfield(class_name, "key", OBJECT_DESC)
        init.load(4, 0)
        init.load(4, 2)
        init.putfield(class_name, "item", OBJECT_DESC)
        init.return_value(5)
        c.method(classfile.ACC_PUBLIC, "<init>", "(Ljava/lang/Object;Ljava/lang/Object;)V", init)
        var compare = classfile.new_code(c.pool, 2)
        compare.load(4, 0)
        compare.getfield(class_name, "key", OBJECT_DESC)
        compare.load(4, 1)
        compare.checkcast(class_name)
        compare.getfield(class_name, "key", OBJECT_DESC)
        self.runtime_in(compare, "__jrt_compare")
        compare.op(L2I, -1)
        compare.return_value(0)
        c.method(classfile.ACC_PUBLIC, "compareTo", "(Ljava/lang/Object;)I", compare)
        var item = classfile.new_code(c.pool, 1)
        item.load(4, 0)
        item.getfield(class_name, "item", OBJECT_DESC)
        item.return_value(4)
        c.method(classfile.ACC_PUBLIC, "item", "()Ljava/lang/Object;", item)
    }

    // `onyx.Task`: what a task's thread runs. It waits for its turn, runs
    // the function of the `fork` block, and lets the next task go on.
    fn ensure_task_class(self) {
        var class_name = "onyx/Task"
        if self.classes.has(class_name) {
            return
        }
        var c = self.class_named(class_name, classfile.ACC_PUBLIC | classfile.ACC_SUPER, OBJECT)
        c.interfaces.push("java/lang/Runnable")
        c.field(classfile.ACC_PUBLIC, "f", OBJECT_DESC)
        c.field(classfile.ACC_PUBLIC, "state", OBJECT_DESC)
        var init = classfile.new_code(c.pool, 3)
        init.load(4, 0)
        init.invokespecial(OBJECT, "<init>", "()V")
        init.load(4, 0)
        init.load(4, 1)
        init.putfield(class_name, "f", OBJECT_DESC)
        init.load(4, 0)
        init.load(4, 2)
        init.putfield(class_name, "state", OBJECT_DESC)
        init.return_value(5)
        c.method(classfile.ACC_PUBLIC, "<init>", "(Ljava/lang/Object;Ljava/lang/Object;)V", init)
        var sig = checker.FnSig{params: [], ret: checker.Type.Void, fallible: false}
        var iface = self.fn_interface(sig)
        var code = classfile.new_code(c.pool, 1)
        var start = code.new_label()
        var end = code.new_label()
        var handler = code.new_label()
        var done = code.new_label()
        code.load(4, 0)
        code.getfield(class_name, "state", OBJECT_DESC)
        self.runtime_in(code, "__jrt_task_begin")
        code.bind(start)
        code.load(4, 0)
        code.getfield(class_name, "f", OBJECT_DESC)
        code.checkcast(iface)
        code.invokeinterface(iface, "call", "()V")
        code.bind(end)
        code.goto(done)
        code.handler(start, end, handler, "")
        code.bind(handler)
        self.runtime_in(code, "__jrt_crash")
        code.bind(done)
        code.load(4, 0)
        code.getfield(class_name, "state", OBJECT_DESC)
        self.runtime_in(code, "__jrt_task_end")
        code.return_value(5)
        c.method(classfile.ACC_PUBLIC, "run", "()V", code)
    }

    // ---- built-in functions ----

    fn builtin(self, e: ast.Expr, name: string, args: [ast.Expr]) {
        var code = self.code
        var ty = self.ty(e)
        if name == "print" || name == "eprint" {
            self.line(args)
            self.runtime("__jrt_" + name)
            return
        }
        if name == "str" {
            self.to_str(args[0])
            return
        }
        if name == "int" {
            self.expr(args[0])
            if self.desc(self.ty(args[0])) == "D" {
                code.op(D2L, 0)
            }
            return
        }
        if name == "float" {
            self.expr(args[0])
            if self.desc(self.ty(args[0])) == "J" {
                code.op(L2D, 0)
            }
            return
        }
        if name == "abs" || name == "min" || name == "max" {
            var d = self.desc(ty)
            for a in args {
                self.expr(a)
                self.convert(self.ty(a), ty)
            }
            code.invokestatic("java/lang/Math", name, "(" + d.repeat(args.len()) + ")" + d)
            return
        }
        if name == "sqrt" || name == "pow" || name == "floor" || name == "ceil" || name == "round" {
            for a in args {
                self.expr(a)
                self.convert(self.ty(a), checker.Type.Float)
            }
            if name == "round" {
                code.invokestatic("java/lang/Math", "round", "(D)J")
            } else {
                code.invokestatic("java/lang/Math", name, "(" + "D".repeat(args.len()) + ")D")
                if name == "floor" || name == "ceil" {
                    code.op(D2L, 0)
                }
            }
            return
        }
        if name == "bit_and" || name == "bit_or" || name == "bit_xor" || name == "shift_left" || name == "shift_right" {
            self.expr(args[0])
            self.expr(args[1])
            if name == "bit_and" {
                code.op(LAND, -2)
            } else if name == "bit_or" {
                code.op(LOR, -2)
            } else if name == "bit_xor" {
                code.op(LXOR, -2)
            } else {
                // The JVM shifts by the low 6 bits of the count, as the
                // other targets do.
                code.op(L2I, -1)
                if name == "shift_left" {
                    code.op(LSHL, -1)
                } else {
                    code.op(LSHR, -1)
                }
            }
            return
        }
        if name == "bit_not" {
            self.expr(args[0])
            code.lconst(-1)
            code.op(LXOR, -2)
            return
        }
        if name == "float_bits" {
            self.expr(args[0])
            code.invokestatic("java/lang/Double", "doubleToRawLongBits", "(D)J")
            return
        }
        if name == "float_from_bits" {
            self.expr(args[0])
            code.invokestatic("java/lang/Double", "longBitsToDouble", "(J)D")
            return
        }
        if name == "now" {
            code.invokestatic("java/lang/System", "currentTimeMillis", "()J")
            return
        }
        if name == "random" {
            code.invokestatic("java/lang/Math", "random", "()D")
            return
        }
        if name == "sleep" {
            self.expr(args[0])
            if self.an.has_forks {
                self.runtime("__jrt_task_sleep")
            } else {
                self.runtime("__jrt_flush")
                code.invokestatic("java/lang/Thread", "sleep", "(J)V")
            }
            return
        }
        if name == "__fork" {
            // `fork { ... }`, which capture.ox made a lambda.
            self.ensure_task_class()
            self.expr(args[0])
            self.convert(self.ty(args[0]), checker.Type.Object)
            self.runtime("__jrt_fork")
            return
        }
        if name == "expect" {
            var loc = errors.locate(self.sources, e.start)
            // The name of the file, without its folders.
            var parts = loc.file.split("/")
            parts = parts[parts.len() - 1].split("\\")
            var place = parts[parts.len() - 1] + ":" + str(loc.line)
            var ok = code.new_label()
            self.jump_if(args[0], ok)
            code.sconst(place)
            self.throw_new(EXPECT)
            code.bind(ok)
            return
        }
        if name == "panic" {
            self.expr(args[0])
            self.throw_new(PANIC)
            return
        }
        if name == "weak" {
            if args.len() == 0 {
                code.aconst_null()
            } else {
                self.expr(args[0])
                self.convert(self.ty(args[0]), checker.Type.Object)
            }
            self.runtime("__jrt_weak")
            return
        }
        if name == "__tag" {
            match self.ty(args[0]) {
                Enum(enum_name) {
                    self.expr(args[0])
                    code.getfield(self.ensure_enum(enum_name), "v", "I")
                    code.op(I2L, 1)
                    return
                }
                else {
                }
            }
        }
        if name == "__field" {
            match self.ty(args[0]) {
                Enum(enum_name) {
                    self.expr(args[0])
                    code.getfield(self.ensure_enum(enum_name), "f", LIST_DESC)
                    self.expr(args[1])
                    code.op(L2I, -1)
                    code.invokevirtual(LIST, "get", "(I)Ljava/lang/Object;")
                    self.convert(checker.Type.Object, ty)
                    return
                }
                else {
                }
            }
        }
        if name == "__jvm" {
            self.jvm(e, args)
            return
        }
        // The others are functions of the runtime, of the same name with
        // `__jrt_` in front.
        var helper = "__jrt_" + name
        if self.items.has(checker.fn_key(helper)) {
            self.call_runtime(helper, args, e)
            return
        }
        self.unsupported(e.start, e.end, "the built-in function `{name}`")
        self.dummy(ty)
    }

    // The line that `print` writes: the texts of its arguments, with a
    // space between them.
    fn line(self, args: [ast.Expr]) {
        var code = self.code
        if args.len() == 0 {
            code.sconst("")
            return
        }
        if args.len() == 1 {
            self.to_str(args[0])
            return
        }
        code.new_object(BUILDER)
        code.op(DUP, 1)
        code.invokespecial(BUILDER, "<init>", "()V")
        for i in 0..args.len() {
            if i > 0 {
                code.sconst(" ")
                append(code, STRING_DESC)
            }
            self.append_value(args[i])
        }
        code.invokevirtual(BUILDER, "toString", "()Ljava/lang/String;")
    }

    // ---- methods of the built-in types ----

    fn builtin_method(self, e: ast.Expr, recv: checker.Recv, name: string, obj: ast.Expr, args: [ast.Expr]) {
        var code = self.code
        var values = [obj]
        for a in args {
            values.push(a)
        }
        match recv {
            Str {
                if name == "len" {
                    self.expr(obj)
                    code.invokevirtual(STRING, "length", "()I")
                    code.op(I2L, 1)
                    return
                }
                if name == "upper" || name == "lower" {
                    self.expr(obj)
                    code.getstatic("java/util/Locale", "ROOT", "Ljava/util/Locale;")
                    if name == "upper" {
                        code.invokevirtual(STRING, "toUpperCase", "(Ljava/util/Locale;)Ljava/lang/String;")
                    } else {
                        code.invokevirtual(STRING, "toLowerCase", "(Ljava/util/Locale;)Ljava/lang/String;")
                    }
                    return
                }
                if name == "contains" || name == "starts_with" || name == "ends_with" || name == "index_of" || name == "replace" {
                    self.expr(obj)
                    for a in args {
                        self.expr(a)
                    }
                    if name == "contains" {
                        code.invokevirtual(STRING, "contains", "(Ljava/lang/CharSequence;)Z")
                    } else if name == "starts_with" {
                        code.invokevirtual(STRING, "startsWith", "(Ljava/lang/String;)Z")
                    } else if name == "ends_with" {
                        code.invokevirtual(STRING, "endsWith", "(Ljava/lang/String;)Z")
                    } else if name == "index_of" {
                        code.invokevirtual(STRING, "indexOf", "(Ljava/lang/String;)I")
                        code.op(I2L, 1)
                    } else {
                        code.invokevirtual(STRING, "replace", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Ljava/lang/String;")
                    }
                    return
                }
                // trim, split, slice, chars, repeat
                self.call_runtime("__jrt_str_" + name, values, e)
                return
            }
            List {
                if name == "len" {
                    self.expr(obj)
                    code.invokevirtual(LIST, "size", "()I")
                    code.op(I2L, 1)
                    return
                }
                if name == "push" {
                    self.expr(obj)
                    self.expr(args[0])
                    self.convert(self.ty(args[0]), checker.Type.Object)
                    code.invokevirtual(LIST, "add", "(Ljava/lang/Object;)Z")
                    code.op(POP, -1)
                    return
                }
                if name == "clear" {
                    self.expr(obj)
                    code.invokevirtual(LIST, "clear", "()V")
                    return
                }
                if name == "map" || name == "filter" || name == "sort_by" {
                    self.transform(e, name, obj, args[0])
                    return
                }
                // pop, first, last, contains, index_of, reverse, slice,
                // insert, remove, join, sort
                self.call_runtime("__jrt_list_" + name, values, e)
                return
            }
            Map {
                if name == "len" {
                    self.expr(obj)
                    code.getfield(self.ensure_struct(MAP_STRUCT), "size", "J")
                    return
                }
                self.expr(obj)
                for a in args {
                    self.expr(a)
                    self.convert(self.ty(a), checker.Type.Object)
                }
                var method = name
                if name == "keys" || name == "values" {
                    method = name + "_list"
                }
                var f = self.request(checker.method_key(MAP_STRUCT, method))
                code.invokevirtual(f.class_name, f.name, self.fn_desc(f))
                self.convert(f.ret, self.ty(e))
                return
            }
            Weak {
                self.call_runtime("__jrt_weak_get", values, e)
                return
            }
            Chan {
                if name == "close" {
                    self.call_runtime("__jrt_chan_close", values, e)
                    return
                }
            }
        }
        self.unsupported(e.start, e.end, "the method `{name}`")
        self.dummy(self.ty(e))
    }

    // `list.map(f)`, `list.filter(f)` and `list.sort_by(f)`: a loop that
    // calls `f` on each element.
    fn transform(self, e: ast.Expr, name: string, obj: ast.Expr, f: ast.Expr) {
        var code = self.code
        var sig = checker.FnSig{params: [checker.Type.Unknown], ret: checker.Type.Unknown, fallible: false}
        match self.ty(f) {
            Fn(s) {
                sig = s
            }
            else {
            }
        }
        var iface = self.fn_interface(sig)
        var call = self.method_desc(sig.params, sig.ret)
        var object = checker.Type.Object
        self.push_scope()
        self.expr(obj)
        var list = self.slot_of_desc(LIST_DESC)
        code.store(4, list)
        self.expr(f)
        var function = self.slot_of_desc(OBJECT_DESC)
        code.store(4, function)
        var out = self.slot_of_desc(LIST_DESC)
        code.new_object(LIST)
        code.op(DUP, 1)
        code.invokespecial(LIST, "<init>", "()V")
        code.store(4, out)
        var index = self.slot_for(checker.Type.Int)
        code.lconst(0)
        code.store(1, index)
        var item = self.slot_of_desc(OBJECT_DESC)
        var top = code.new_label()
        var next = code.new_label()
        var end = code.new_label()
        code.bind(top)
        code.load(1, index)
        code.load(4, list)
        code.invokevirtual(LIST, "size", "()I")
        code.op(I2L, 1)
        code.op(LCMP, -3)
        code.if_zero(IFGE, end)
        code.load(4, list)
        code.load(1, index)
        code.op(L2I, -1)
        code.invokevirtual(LIST, "get", "(I)Ljava/lang/Object;")
        code.store(4, item)
        if name == "filter" {
            code.load(4, function)
            code.load(4, item)
            self.convert(object, sig.params[0])
            code.invokeinterface(iface, "call", call)
            self.yield_point()
            code.if_zero(IFEQ, next)
            code.load(4, out)
            code.load(4, item)
        } else {
            // map: the results; sort_by: the keys.
            code.load(4, out)
            code.load(4, function)
            code.load(4, item)
            self.convert(object, sig.params[0])
            code.invokeinterface(iface, "call", call)
            self.yield_point()
            self.convert(sig.ret, object)
        }
        code.invokevirtual(LIST, "add", "(Ljava/lang/Object;)Z")
        code.op(POP, -1)
        code.bind(next)
        self.add_to(index, 1)
        code.goto(top)
        code.bind(end)
        if name == "sort_by" {
            code.load(4, list)
            code.load(4, out)
            self.runtime("__jrt_list_sort_by")
        } else {
            code.load(4, out)
        }
        self.yield_point()
        self.pop_scope()
    }

    // ---- `__jvm`: Java, for the runtime ----

    fn jvm(self, e: ast.Expr, args: [ast.Expr]) {
        var code = self.code
        var operation = checker.jvm_operation(args)
        var values = args.slice(1, args.len())
        var object = checker.Type.Object
        if operation == "null" {
            code.aconst_null()
            return
        }
        if operation == "same" {
            self.expr(values[0])
            self.convert(self.ty(values[0]), object)
            self.expr(values[1])
            self.convert(self.ty(values[1]), object)
            var yes = code.new_label()
            var done = code.new_label()
            code.if_acmp(IF_ACMPEQ, yes)
            code.iconst(0)
            code.goto(done)
            code.bind(yes)
            code.iconst(1)
            code.bind(done)
            return
        }
        var space = operation.index_of(" ")
        var kind = operation.slice(0, space)
        var fallible = kind.ends_with("!")
        kind = kind.replace("!", "")
        var rest = operation.slice(space + 1, operation.len())
        if kind == "is" {
            if rest.starts_with("onyx/S$") {
                // A struct of the runtime: its class must exist.
                self.ensure_struct(rest.slice(7, rest.len()))
            }
            self.expr(values[0])
            self.convert(self.ty(values[0]), object)
            code.instance_of(rest)
            return
        }
        if kind == "get" {
            var dot = rest.index_of(".")
            var colon = rest.index_of(":")
            var d = rest.slice(colon + 1, rest.len())
            code.getstatic(rest.slice(0, dot), rest.slice(dot + 1, colon), d)
            convert_in(code, d, jvm_value(d))
            return
        }
        var paren = rest.index_of("(")
        if rest.starts_with("onyx/Keyed") {
            self.ensure_keyed_class()
        }
        if kind == "new" {
            // The arguments first, kept aside, so that nothing is computed
            // while the new object is on the stack.
            var owner = rest.slice(0, paren)
            var descriptor = rest.slice(paren, rest.len()) + "V"
            var params = classfile.parameters_of(descriptor)
            self.push_scope()
            var slots: [int] = []
            for i in 0..params.len() {
                self.expr(values[i])
                convert_in(code, self.desc(self.ty(values[i])), params[i])
                var slot = self.slot_of_desc(params[i])
                code.store(kind_of(params[i]), slot)
                slots.push(slot)
            }
            var start = code.new_label()
            var end = code.new_label()
            code.bind(start)
            code.new_object(owner)
            code.op(DUP, 1)
            for i in 0..params.len() {
                code.load(kind_of(params[i]), slots[i])
            }
            code.invokespecial(owner, "<init>", descriptor)
            code.bind(end)
            if fallible {
                self.java_failures(start, end)
            }
            self.pop_scope()
            return
        }
        var dot = rest.index_of(".")
        var owner = rest.slice(0, dot)
        var method = rest.slice(dot + 1, paren)
        var descriptor = rest.slice(paren, rest.len())
        var params = classfile.parameters_of(descriptor)
        var i = 0
        if kind != "static" {
            self.expr(values[0])
            convert_in(code, self.desc(self.ty(values[0])), "L" + owner + ";")
            i = 1
        }
        for p in params {
            self.expr(values[i])
            convert_in(code, self.desc(self.ty(values[i])), p)
            i += 1
        }
        var start = code.new_label()
        var end = code.new_label()
        code.bind(start)
        if kind == "static" {
            code.invokestatic(owner, method, descriptor)
        } else if kind == "interface" {
            code.invokeinterface(owner, method, descriptor)
        } else {
            code.invokevirtual(owner, method, descriptor)
        }
        code.bind(end)
        if fallible {
            self.java_failures(start, end)
        }
        var result = classfile.return_of(descriptor)
        convert_in(code, result, jvm_value(result))
    }

    // What Java throws from `start` to `end` becomes an Onyx error.
    fn java_failures(self, start: int, end: int) {
        var code = self.code
        var handler = code.new_label()
        var after = code.new_label()
        code.goto(after)
        code.handler(start, end, handler, "java/lang/Exception")
        code.bind(handler)
        self.runtime("__jrt_failure_of")
        code.checkcast(FAILURE)
        code.athrow()
        code.bind(after)
    }
}

// ---- free helpers ----

fn is_comparison(op: ast.BinOp) -> bool {
    return op == ast.BinOp.Eq || op == ast.BinOp.NotEq || op == ast.BinOp.Lt || op == ast.BinOp.Le || op == ast.BinOp.Gt || op == ast.BinOp.Ge
}

// The jump taken when the result of LCMP (or DCMPx, or compareTo) says
// that the comparison holds.
fn zero_jump(op: ast.BinOp) -> int {
    match op {
        Eq {
            return IFEQ
        }
        NotEq {
            return IFNE
        }
        Lt {
            return IFLT
        }
        Le {
            return IFLE
        }
        Gt {
            return IFGT
        }
        else {
            return IFGE
        }
    }
}

fn arith(code: classfile.Code, op: ast.BinOp, float: bool) {
    var opcode = LADD
    match op {
        Add {
            opcode = LADD
        }
        Sub {
            opcode = LSUB
        }
        Mul {
            opcode = LMUL
        }
        Div {
            opcode = LDIV
        }
        else {
            opcode = LREM
        }
    }
    if float {
        // Each double instruction comes right after its long one.
        opcode += 2
    }
    code.op(opcode, -2)
}

// The descriptor of the Onyx value that a Java value of descriptor `d`
// becomes: the small numbers grow to `long` and `double`.
fn jvm_value(d: string) -> string {
    if d == "I" || d == "S" || d == "B" || d == "C" {
        return "J"
    }
    if d == "F" {
        return "D"
    }
    return d
}

// Turns the value on the stack, of descriptor `a`, into one of descriptor
// `b`: a number put in a box or taken out of it, a number of another size,
// an object checked for its class where it may not be of it.
fn convert_in(code: classfile.Code, a: string, b: string) {
    if a == b || b == "V" || a == "V" {
        return
    }
    if is_primitive(a) && !is_primitive(b) {
        box_in(code, a)
        return
    }
    if !is_primitive(a) && is_primitive(b) {
        unbox_in(code, b)
        return
    }
    if is_primitive(a) {
        if a == "J" {
            if b == "D" {
                code.op(L2D, 0)
            } else if b == "F" {
                code.op(0x89, -1)       // l2f
            } else if b != "Z" {
                code.op(L2I, -1)
            }
        } else if a == "D" {
            if b == "F" {
                code.op(D2F, -1)
            } else if b == "J" {
                code.op(D2L, 0)
            }
        } else if a == "F" {
            if b == "D" {
                code.op(F2D, 1)
            }
        } else if b == "J" {
            code.op(I2L, 1)
        } else if b == "D" {
            code.op(0x87, 1)            // i2d
        }
        return
    }
    if b == OBJECT_DESC {
        return
    }
    if a == OBJECT_DESC || a.starts_with("Lonyx/I$") || a.starts_with("Lonyx/F$") || a == "Lonyx/Value;" || a == "Lonyx/Fn;" {
        code.checkcast(class_in(b))
    }
}

// Puts the number (or truth value) on the stack in a box.
fn box_in(code: classfile.Code, d: string) {
    if d == "J" {
        code.invokestatic("java/lang/Long", "valueOf", "(J)Ljava/lang/Long;")
    } else if d == "D" {
        code.invokestatic("java/lang/Double", "valueOf", "(D)Ljava/lang/Double;")
    } else if d == "Z" {
        code.invokestatic("java/lang/Boolean", "valueOf", "(Z)Ljava/lang/Boolean;")
    } else if d == "F" {
        code.op(F2D, 1)
        code.invokestatic("java/lang/Double", "valueOf", "(D)Ljava/lang/Double;")
    } else {
        code.op(I2L, 1)
        code.invokestatic("java/lang/Long", "valueOf", "(J)Ljava/lang/Long;")
    }
}

// Takes the number (or truth value) out of the box on the stack.
fn unbox_in(code: classfile.Code, d: string) {
    if d == "Z" {
        code.checkcast("java/lang/Boolean")
        code.invokevirtual("java/lang/Boolean", "booleanValue", "()Z")
        return
    }
    code.checkcast("java/lang/Number")
    if d == "J" {
        code.invokevirtual("java/lang/Number", "longValue", "()J")
    } else if d == "D" {
        code.invokevirtual("java/lang/Number", "doubleValue", "()D")
    } else if d == "F" {
        code.invokevirtual("java/lang/Number", "floatValue", "()F")
    } else {
        code.invokevirtual("java/lang/Number", "intValue", "()I")
    }
}
