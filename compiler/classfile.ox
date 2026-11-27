// Writes JVM class files: the constant pool, the fields, the methods and
// their bytecode.
//
// The classes are of version 49 (Java 5), which the JVMs of today still
// run: from version 50 on, a method must carry "stack maps", a description
// of the types of everything at each jump target, which this version does
// without. The JVM then works the types out by itself when it loads the class.
//
// Bytecode is written through `Code`, which knows how much each
// instruction pushes on the operand stack and pops from it, so that the
// size of the stack a method needs is counted as it is written.

// ---- bytes ----

fn put_u1(out: [int], v: int) {
    out.push(v & 0xFF)
}

fn put_u2(out: [int], v: int) {
    out.push(v >> 8 & 0xFF)
    out.push(v & 0xFF)
}

fn put_u4(out: [int], v: int) {
    out.push(v >> 24 & 0xFF)
    out.push(v >> 16 & 0xFF)
    out.push(v >> 8 & 0xFF)
    out.push(v & 0xFF)
}

fn put_u8(out: [int], v: int) {
    put_u4(out, v >> 32)
    put_u4(out, v)
}

// The "modified UTF-8" of class files: the character 0 takes two bytes,
// and characters beyond the first 65536 are written as their two UTF-16
// halves, three bytes each.
fn modified_utf8(text: string) -> [int] {
    var out: [int] = []
    for c in text {
        var code = ord(c)
        if code == 0 {
            out.push(0xC0)
            out.push(0x80)
        } else if code < 0x80 {
            out.push(code)
        } else if code < 0x800 {
            out.push(0xC0 | code >> 6)
            out.push(0x80 | code & 0x3F)
        } else if code < 0x10000 {
            out.push(0xE0 | code >> 12)
            out.push(0x80 | code >> 6 & 0x3F)
            out.push(0x80 | code & 0x3F)
        } else {
            var v = code - 0x10000
            for half in [0xD800 | v >> 10, 0xDC00 | v & 0x3FF] {
                out.push(0xE0 | half >> 12)
                out.push(0x80 | half >> 6 & 0x3F)
                out.push(0x80 | half & 0x3F)
            }
        }
    }
    return out
}

// ---- the constant pool ----

const CONSTANT_UTF8 = 1
const CONSTANT_INTEGER = 3
const CONSTANT_LONG = 5
const CONSTANT_DOUBLE = 6
const CONSTANT_CLASS = 7
const CONSTANT_STRING = 8
const CONSTANT_FIELDREF = 9
const CONSTANT_METHODREF = 10
const CONSTANT_INTERFACE_METHODREF = 11
const CONSTANT_NAME_AND_TYPE = 12

struct Pool {
    bytes: [int]
    // The index the next entry gets (entries are numbered from 1; a long
    // or a double takes two numbers).
    next: int
    // Each entry once: what it is, as text, to its index.
    known: map<string, int>

    fn entry(self, key: string, data: [int], slots: int) -> int {
        if self.known.has(key) {
            return self.known[key]
        }
        var index = self.next
        for b in data {
            self.bytes.push(b)
        }
        self.next += slots
        self.known[key] = index
        return index
    }

    fn utf8(self, text: string) -> int {
        var key = "U" + text
        if self.known.has(key) {
            return self.known[key]
        }
        var encoded = modified_utf8(text)
        if encoded.len() > 65535 {
            panic("a constant of more than 65535 bytes in a class file")
        }
        var data = [CONSTANT_UTF8]
        put_u2(data, encoded.len())
        for b in encoded {
            data.push(b)
        }
        return self.entry(key, data, 1)
    }

    fn class(self, name: string) -> int {
        var name_index = self.utf8(name)
        var data = [CONSTANT_CLASS]
        put_u2(data, name_index)
        return self.entry("C" + name, data, 1)
    }

    fn string(self, text: string) -> int {
        var text_index = self.utf8(text)
        var data = [CONSTANT_STRING]
        put_u2(data, text_index)
        return self.entry("S" + text, data, 1)
    }

    fn integer(self, v: int) -> int {
        var data = [CONSTANT_INTEGER]
        put_u4(data, v)
        return self.entry("I" + str(v), data, 1)
    }

    fn long(self, v: int) -> int {
        var data = [CONSTANT_LONG]
        put_u8(data, v)
        return self.entry("J" + str(v), data, 2)
    }

    fn double(self, x: float) -> int {
        var bits = float_bits(x)
        var data = [CONSTANT_DOUBLE]
        put_u8(data, bits)
        return self.entry("D" + str(bits), data, 2)
    }

    fn name_and_type(self, name: string, descriptor: string) -> int {
        var n = self.utf8(name)
        var d = self.utf8(descriptor)
        var data = [CONSTANT_NAME_AND_TYPE]
        put_u2(data, n)
        put_u2(data, d)
        return self.entry("N" + name + " " + descriptor, data, 1)
    }

    fn member(self, tag: int, owner: string, name: string, descriptor: string) -> int {
        var c = self.class(owner)
        var nt = self.name_and_type(name, descriptor)
        var data = [tag]
        put_u2(data, c)
        put_u2(data, nt)
        return self.entry(str(tag) + owner + "." + name + " " + descriptor, data, 1)
    }
}

fn new_pool() -> Pool {
    return Pool{bytes: [], next: 1, known: {}}
}

// ---- descriptors ----

// How many slots (of the operand stack or of the local variables) a
// value of this descriptor takes: 2 for `J` (long) and `D` (double).
fn slots_of(descriptor: string) -> int {
    if descriptor == "J" || descriptor == "D" {
        return 2
    }
    if descriptor == "V" {
        return 0
    }
    return 1
}

// The descriptors of the parameters of a method descriptor `(...)R`.
fn parameters_of(descriptor: string) -> [string] {
    var out: [string] = []
    var i = 1
    while descriptor[i] != ")" {
        var start = i
        while descriptor[i] == "[" {
            i += 1
        }
        if descriptor[i] == "L" {
            while descriptor[i] != ";" {
                i += 1
            }
        }
        i += 1
        out.push(descriptor.slice(start, i))
    }
    return out
}

fn return_of(descriptor: string) -> string {
    return descriptor.slice(descriptor.index_of(")") + 1, descriptor.len())
}

fn argument_slots(descriptor: string) -> int {
    var n = 0
    for p in parameters_of(descriptor) {
        n += slots_of(p)
    }
    return n
}

// ---- bytecode ----

// A jump to fill in once its label is bound.
struct Jump {
    // Where the instruction starts, and where its 2-byte offset is.
    from: int
    at: int
    label: int
}

// An entry of the exception table: the code from `start` to `end` (labels)
// jumps to `handler` when it throws an object of class `catches` (0: any).
struct Handler {
    start: int
    end: int
    handler: int
    catches: int
}

struct Code {
    pool: Pool
    bytes: [int]
    // The depth of the operand stack where the code is, in slots.
    stack: int
    max_stack: int
    max_locals: int
    // Where each label is (-1: not yet), and the depth of the stack there
    // (-1: not known yet).
    labels: [int]
    depths: [int]
    jumps: [Jump]
    handlers: [Handler]
    // After an unconditional jump, a return or a throw, the code that
    // follows is only reached through a label.
    dead: bool

    fn pos(self) -> int {
        return self.bytes.len()
    }

    fn grow(self, slots: int) {
        self.stack += slots
        if self.stack > self.max_stack {
            self.max_stack = self.stack
        }
        if self.stack < 0 {
            panic("bytecode pops more than the stack holds")
        }
    }

    // An instruction: its opcode, then what it does to the stack.
    fn op(self, opcode: int, effect: int) {
        self.bytes.push(opcode)
        self.grow(effect)
    }

    fn u1(self, v: int) {
        put_u1(self.bytes, v)
    }

    fn u2(self, v: int) {
        put_u2(self.bytes, v)
    }

    fn uses_local(self, slot: int, size: int) {
        if slot + size > self.max_locals {
            self.max_locals = slot + size
        }
    }

    // ---- labels and jumps ----

    fn new_label(self) -> int {
        self.labels.push(-1)
        self.depths.push(-1)
        return self.labels.len() - 1
    }

    fn bind(self, label: int) {
        self.labels[label] = self.pos()
        if self.depths[label] >= 0 {
            self.stack = self.depths[label]
            // A handler starts with the exception on the stack.
            if self.stack > self.max_stack {
                self.max_stack = self.stack
            }
        } else {
            self.depths[label] = self.stack
        }
        self.dead = false
    }

    fn note_depth(self, label: int) {
        if self.depths[label] < 0 {
            self.depths[label] = self.stack
        }
    }

    fn jump(self, opcode: int, pops: int, label: int) {
        var from = self.pos()
        self.op(opcode, -pops)
        self.jumps.push(Jump{from: from, at: self.pos(), label: label})
        self.u2(0)
        self.note_depth(label)
    }

    // `goto`: the code after it is dead until a label.
    fn goto(self, label: int) {
        self.jump(0xA7, 0, label)
        self.dead = true
    }

    // Jumps when the int on the stack compares with 0 as `cc` says
    // (IFEQ 0x99, IFNE, IFLT, IFGE, IFGT, IFLE 0x9E).
    fn if_zero(self, opcode: int, label: int) {
        self.jump(opcode, 1, label)
    }

    // Jumps when the two ints on the stack compare as the opcode says
    // (IF_ICMPEQ 0x9F ... IF_ICMPLE 0xA4).
    fn if_icmp(self, opcode: int, label: int) {
        self.jump(opcode, 2, label)
    }

    // IF_ACMPEQ 0xA5, IF_ACMPNE 0xA6, IFNULL 0xC6, IFNONNULL 0xC7.
    fn if_acmp(self, opcode: int, label: int) {
        self.jump(opcode, 2, label)
    }

    fn if_null(self, opcode: int, label: int) {
        self.jump(opcode, 1, label)
    }

    // ---- constants ----

    fn iconst(self, v: int) {
        if v >= -1 && v <= 5 {
            self.op(0x03 + v, 1)
        } else if v >= -128 && v <= 127 {
            self.op(0x10, 1)
            self.u1(v)
        } else if v >= -32768 && v <= 32767 {
            self.op(0x11, 1)
            self.u2(v)
        } else {
            self.ldc(self.pool.integer(v), 1)
        }
    }

    fn lconst(self, v: int) {
        if v == 0 || v == 1 {
            self.op(0x09 + v, 2)
        } else if v >= -32768 && v <= 32767 {
            self.iconst(v)
            self.op(0x85, 1)            // i2l
        } else {
            self.op(0x14, 2)            // ldc2_w
            self.u2(self.pool.long(v))
        }
    }

    fn dconst(self, x: float) {
        if float_bits(x) == 0 {
            self.op(0x0E, 2)            // dconst_0
        } else if x == 1.0 {
            self.op(0x0F, 2)            // dconst_1
        } else {
            self.op(0x14, 2)
            self.u2(self.pool.double(x))
        }
    }

    fn ldc(self, index: int, size: int) {
        if index < 256 {
            self.op(0x12, size)
            self.u1(index)
        } else {
            self.op(0x13, size)
            self.u2(index)
        }
    }

    fn sconst(self, text: string) {
        self.ldc(self.pool.string(text), 1)
    }

    fn aconst_null(self) {
        self.op(0x01, 1)
    }

    // ---- local variables ----
    // `kind`: 0 int, 1 long, 2 float, 3 double, 4 reference, as the JVM
    // numbers them in its load and store instructions.

    fn load(self, kind: int, slot: int) {
        var size = 1
        if kind == 1 || kind == 3 {
            size = 2
        }
        self.uses_local(slot, size)
        if slot <= 3 {
            self.op(0x1A + kind * 4 + slot, size)
        } else if slot <= 255 {
            self.op(0x15 + kind, size)
            self.u1(slot)
        } else {
            self.op(0xC4, size)         // wide
            self.u1(0x15 + kind)
            self.u2(slot)
        }
    }

    fn store(self, kind: int, slot: int) {
        var size = 1
        if kind == 1 || kind == 3 {
            size = 2
        }
        self.uses_local(slot, size)
        if slot <= 3 {
            self.op(0x3B + kind * 4 + slot, -size)
        } else if slot <= 255 {
            self.op(0x36 + kind, -size)
            self.u1(slot)
        } else {
            self.op(0xC4, -size)
            self.u1(0x36 + kind)
            self.u2(slot)
        }
    }

    fn iinc(self, slot: int, by: int) {
        self.uses_local(slot, 1)
        self.op(0x84, 0)
        self.u1(slot)
        self.u1(by)
    }

    // ---- fields and methods ----

    fn getstatic(self, owner: string, name: string, descriptor: string) {
        self.op(0xB2, slots_of(descriptor))
        self.u2(self.pool.member(CONSTANT_FIELDREF, owner, name, descriptor))
    }

    fn putstatic(self, owner: string, name: string, descriptor: string) {
        self.op(0xB3, -slots_of(descriptor))
        self.u2(self.pool.member(CONSTANT_FIELDREF, owner, name, descriptor))
    }

    fn getfield(self, owner: string, name: string, descriptor: string) {
        self.op(0xB4, slots_of(descriptor) - 1)
        self.u2(self.pool.member(CONSTANT_FIELDREF, owner, name, descriptor))
    }

    fn putfield(self, owner: string, name: string, descriptor: string) {
        self.op(0xB5, -slots_of(descriptor) - 1)
        self.u2(self.pool.member(CONSTANT_FIELDREF, owner, name, descriptor))
    }

    fn invokestatic(self, owner: string, name: string, descriptor: string) {
        self.op(0xB8, slots_of(return_of(descriptor)) - argument_slots(descriptor))
        self.u2(self.pool.member(CONSTANT_METHODREF, owner, name, descriptor))
    }

    fn invokevirtual(self, owner: string, name: string, descriptor: string) {
        self.op(0xB6, slots_of(return_of(descriptor)) - argument_slots(descriptor) - 1)
        self.u2(self.pool.member(CONSTANT_METHODREF, owner, name, descriptor))
    }

    fn invokespecial(self, owner: string, name: string, descriptor: string) {
        self.op(0xB7, slots_of(return_of(descriptor)) - argument_slots(descriptor) - 1)
        self.u2(self.pool.member(CONSTANT_METHODREF, owner, name, descriptor))
    }

    fn invokeinterface(self, owner: string, name: string, descriptor: string) {
        var args = argument_slots(descriptor)
        self.op(0xB9, slots_of(return_of(descriptor)) - args - 1)
        self.u2(self.pool.member(CONSTANT_INTERFACE_METHODREF, owner, name, descriptor))
        self.u1(args + 1)
        self.u1(0)
    }

    // ---- objects ----

    fn new_object(self, class: string) {
        self.op(0xBB, 1)
        self.u2(self.pool.class(class))
    }

    fn checkcast(self, class: string) {
        self.op(0xC0, 0)
        self.u2(self.pool.class(class))
    }

    fn instance_of(self, class: string) {
        self.op(0xC1, 0)
        self.u2(self.pool.class(class))
    }

    fn anewarray(self, class: string) {
        self.op(0xBD, 0)
        self.u2(self.pool.class(class))
    }

    // ---- the end of a path ----

    // `kind` as for `load`; 5 for a method that returns nothing.
    fn return_value(self, kind: int) {
        if kind == 5 {
            self.op(0xB1, 0)
        } else if kind == 1 || kind == 3 {
            self.op(0xAC + kind, -2)
        } else {
            self.op(0xAC + kind, -1)
        }
        self.dead = true
        self.stack = 0
    }

    fn athrow(self) {
        self.op(0xBF, -1)
        self.dead = true
        self.stack = 0
    }

    // Code from `start` to `end` that throws an object of class `catches`
    // ("" for any) continues at `handler`, with the object on the stack.
    fn handler(self, start: int, end: int, handler: int, catches: string) {
        var class = 0
        if catches != "" {
            class = self.pool.class(catches)
        }
        self.handlers.push(Handler{start: start, end: end, handler: handler, catches: class})
        self.depths[handler] = 1
    }

    // Fills in the jumps; fails when one is too far for 2 bytes.
    fn finish(self) {
        for j in self.jumps {
            var target = self.labels[j.label]
            if target < 0 {
                panic("jump to a label that was never bound")
            }
            var offset = target - j.from
            if offset < -32768 || offset > 32767 {
                panic("a function is too big for the JVM target")
            }
            self.bytes[j.at] = offset >> 8 & 0xFF
            self.bytes[j.at + 1] = offset & 0xFF
        }
    }

    // The Code attribute, without its name and length.
    fn attribute(self) -> [int] {
        self.finish()
        var out: [int] = []
        put_u2(out, self.max_stack)
        put_u2(out, self.max_locals)
        put_u4(out, self.bytes.len())
        for b in self.bytes {
            out.push(b)
        }
        put_u2(out, self.handlers.len())
        for h in self.handlers {
            put_u2(out, self.labels[h.start])
            put_u2(out, self.labels[h.end])
            put_u2(out, self.labels[h.handler])
            put_u2(out, h.catches)
        }
        put_u2(out, 0)
        return out
    }
}

fn new_code(pool: Pool, locals: int) -> Code {
    return Code{pool: pool, bytes: [], stack: 0, max_stack: 0, max_locals: locals, labels: [], depths: [], jumps: [], handlers: [], dead: false}
}

// ---- classes ----

const ACC_PUBLIC = 0x0001
const ACC_PRIVATE = 0x0002
const ACC_STATIC = 0x0008
const ACC_FINAL = 0x0010
const ACC_SUPER = 0x0020
const ACC_INTERFACE = 0x0200
const ACC_ABSTRACT = 0x0400

struct ClassFile {
    pool: Pool
    name: string
    access: int
    super_name: string
    interfaces: [string]
    // The fields and the methods, encoded.
    fields: [int]
    field_count: int
    methods: [int]
    method_count: int

    fn field(self, access: int, name: string, descriptor: string) {
        put_u2(self.fields, access)
        put_u2(self.fields, self.pool.utf8(name))
        put_u2(self.fields, self.pool.utf8(descriptor))
        put_u2(self.fields, 0)
        self.field_count += 1
    }

    // A method with code.
    fn method(self, access: int, name: string, descriptor: string, code: Code) {
        var body = code.attribute()
        put_u2(self.methods, access)
        put_u2(self.methods, self.pool.utf8(name))
        put_u2(self.methods, self.pool.utf8(descriptor))
        put_u2(self.methods, 1)
        put_u2(self.methods, self.pool.utf8("Code"))
        put_u4(self.methods, body.len())
        for b in body {
            self.methods.push(b)
        }
        self.method_count += 1
    }

    // A method without code, in an interface.
    fn abstract_method(self, name: string, descriptor: string) {
        put_u2(self.methods, ACC_PUBLIC | ACC_ABSTRACT)
        put_u2(self.methods, self.pool.utf8(name))
        put_u2(self.methods, self.pool.utf8(descriptor))
        put_u2(self.methods, 0)
        self.method_count += 1
    }

    fn bytes(self) -> [int] {
        var this_class = self.pool.class(self.name)
        var super_class = self.pool.class(self.super_name)
        var interfaces: [int] = []
        for i in self.interfaces {
            interfaces.push(self.pool.class(i))
        }
        var out: [int] = []
        put_u4(out, 0xCAFEBABE)
        put_u2(out, 0)
        put_u2(out, 49)
        put_u2(out, self.pool.next)
        for b in self.pool.bytes {
            out.push(b)
        }
        put_u2(out, self.access)
        put_u2(out, this_class)
        put_u2(out, super_class)
        put_u2(out, interfaces.len())
        for i in interfaces {
            put_u2(out, i)
        }
        put_u2(out, self.field_count)
        for b in self.fields {
            out.push(b)
        }
        put_u2(out, self.method_count)
        for b in self.methods {
            out.push(b)
        }
        put_u2(out, 0)
        return out
    }
}

fn new_class(name: string, access: int, super_name: string) -> ClassFile {
    return ClassFile{pool: new_pool(), name: name, access: access, super_name: super_name, interfaces: [], fields: [], field_count: 0, methods: [], method_count: 0}
}
