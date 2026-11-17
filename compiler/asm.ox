// A minimal x86-64 assembler: just the instructions the code generator
// uses. Code and read-only data share one buffer; labels are positions in
// it and every code reference is RIP-relative.
//
// Naming: `load` reads memory into a register, `store` writes a register to
// memory, `[base + disp]` is the only addressing mode besides
// `[base + index * 8]`. Unless said otherwise, operations are 64 bits wide.
//
// Follows src/native/asm.rs: both must write the same bytes.

// ---- registers ----

const RAX = 0
const RCX = 1
const RDX = 2
const RBX = 3
const RSP = 4
const RBP = 5
const RSI = 6
const RDI = 7
const R8 = 8
const R9 = 9
const R10 = 10
const R11 = 11
const R12 = 12
const R13 = 13
const R14 = 14
const R15 = 15

// The registers that hold floating-point numbers while they are computed.
const XMM0 = 0
const XMM1 = 1

// ---- two-operand arithmetic ----
// The value is the `/digit` of the immediate form; the register forms are
// derived from it.

const ALU_ADD = 0
const ALU_OR = 1
const ALU_AND = 4
const ALU_SUB = 5
const ALU_XOR = 6
const ALU_CMP = 7

// Opcode of `op r/m64, r64`.
fn alu_to_rm(op: int) -> int {
    return op * 8 + 1
}

// Opcode of `op r64, r/m64`.
fn alu_from_rm(op: int) -> int {
    return op * 8 + 3
}

// ---- shifts by a constant: the `/digit` of `C1 /digit ib` ----

const SHIFT_LEFT = 4
// Logical right shift: fills with zeros.
const SHIFT_RIGHT = 5
// Arithmetic right shift: keeps the sign.
const SHIFT_RIGHT_SIGNED = 7

// ---- condition codes, as used by `jcc` and `setcc` ----

// Unsigned below.
const CC_B = 0x2
// Unsigned above or equal.
const CC_AE = 0x3
const CC_E = 0x4
const CC_NE = 0x5
// Unsigned below or equal.
const CC_BE = 0x6
// Unsigned above.
const CC_A = 0x7
// Parity: after comparing floats, one of them is not a number.
const CC_P = 0xA
const CC_NP = 0xB
const CC_L = 0xC
const CC_GE = 0xD
const CC_LE = 0xE
const CC_G = 0xF

// The opposite condition: they come in pairs that differ by the last bit.
fn cc_negate(cc: int) -> int {
    return cc ^ 1
}

// The condition to test after the two compared operands were exchanged.
fn cc_swap(cc: int) -> int {
    if cc == CC_L {
        return CC_G
    }
    if cc == CC_G {
        return CC_L
    }
    if cc == CC_LE {
        return CC_GE
    }
    if cc == CC_GE {
        return CC_LE
    }
    return cc
}

// ---- operations on 64-bit floats: the opcode byte after `F2 0F` ----

const SSE_MOV = 0x10
const SSE_SQRT = 0x51
const SSE_ADD = 0x58
const SSE_MUL = 0x59
const SSE_SUB = 0x5C
const SSE_DIV = 0x5E

fn fits_i8(v: int) -> bool {
    return v >= -128 && v <= 127
}

fn fits_i32(v: int) -> bool {
    return v >= -2147483648 && v <= 2147483647
}

// A reference to a label, to fill in when the label is bound.
struct Fixup {
    // Where the value goes.
    at: int
    label: int
    // 4 for a RIP-relative distance; 8 or 4 for an absolute address.
    size: int
}

struct Asm {
    buf: [int]
    // Where each label is bound (-1: not yet).
    labels: [int]
    // RIP-relative 32-bit distances.
    fixups: [Fixup]
    // Absolute addresses.
    abs_fixups: [Fixup]

    fn new_label(self) -> int {
        self.labels.push(-1)
        return self.labels.len() - 1
    }

    fn bind(self, label: int) {
        self.labels[label] = self.buf.len()
    }

    fn is_bound(self, label: int) -> bool {
        return self.labels[label] >= 0
    }

    fn pos(self) -> int {
        return self.buf.len()
    }

    // ---- encoding helpers ----

    fn byte(self, b: int) {
        self.buf.push(b & 0xFF)
    }

    fn imm32(self, v: int) {
        self.buf.push(v & 0xFF)
        self.buf.push(v >> 8 & 0xFF)
        self.buf.push(v >> 16 & 0xFF)
        self.buf.push(v >> 24 & 0xFF)
    }

    fn rel32(self, label: int) {
        self.fixups.push(Fixup{at: self.buf.len(), label: label, size: 4})
        self.imm32(0)
    }

    // REX prefix with W set (64-bit operation).
    fn rex_w(self, reg: int, index: int, base: int) {
        self.buf.push(0x48 | (reg >> 3 & 1) << 2 | (index >> 3 & 1) << 1 | base >> 3 & 1)
    }

    // REX prefix for a 32-bit operation: only needed for registers r8-r15.
    fn rex_opt(self, reg: int, index: int, base: int) {
        var bits = (reg >> 3 & 1) << 2 | (index >> 3 & 1) << 1 | base >> 3 & 1
        if bits != 0 {
            self.buf.push(0x40 | bits)
        }
    }

    // ModRM for two registers.
    fn rr(self, reg: int, rm: int) {
        self.buf.push(0xC0 | (reg & 7) << 3 | rm & 7)
    }

    // ModRM (+ SIB, + displacement) for `[base + disp]`, using the shortest form.
    fn mem(self, reg: int, base: int, disp: int) {
        var mode = 0x80
        var size = 4
        if disp == 0 && base & 7 != 5 {
            mode = 0x00
            size = 0
        } else if fits_i8(disp) {
            mode = 0x40
            size = 1
        }
        self.buf.push(mode | (reg & 7) << 3 | base & 7)
        if base & 7 == 4 {
            self.buf.push(0x24)
        }
        if size == 1 {
            self.byte(disp)
        } else if size == 4 {
            self.imm32(disp)
        }
    }

    // ModRM + SIB for `[base + index * 8]`. `base` must not be RBP or R13.
    fn indexed(self, reg: int, base: int, index: int) {
        self.buf.push((reg & 7) << 3 | 4)
        self.buf.push(3 << 6 | (index & 7) << 3 | base & 7)
    }

    // An immediate operand of an `83` / `81` style instruction.
    fn imm8_or_32(self, v: int) {
        if fits_i8(v) {
            self.byte(v)
        } else {
            self.imm32(v)
        }
    }

    // ---- moves ----

    // `dst = v`. Does not change the flags.
    fn mov_imm(self, dst: int, v: int) {
        if v >= 0 && v <= 0xFFFFFFFF {
            // mov r32, imm32 clears the upper half.
            self.rex_opt(0, 0, dst)
            self.buf.push(0xB8 + (dst & 7))
            self.imm32(v)
        } else if fits_i32(v) {
            self.rex_w(0, 0, dst)
            self.buf.push(0xC7)
            self.rr(0, dst)
            self.imm32(v)
        } else {
            self.rex_w(0, 0, dst)
            self.buf.push(0xB8 + (dst & 7))
            self.word(v)
        }
    }

    // `dst = v` with a fixed-size encoding, so the value can be patched
    // later. Returns the position of the 32-bit value.
    fn mov_imm32_patchable(self, dst: int, v: int) -> int {
        self.rex_w(0, 0, dst)
        self.buf.push(0xC7)
        self.rr(0, dst)
        self.imm32(v)
        return self.buf.len() - 4
    }

    fn mov(self, dst: int, src: int) {
        if dst != src {
            self.rex_w(src, 0, dst)
            self.buf.push(0x89)
            self.rr(src, dst)
        }
    }

    // `dst = [base + disp]`
    fn load(self, dst: int, base: int, disp: int) {
        self.rex_w(dst, 0, base)
        self.buf.push(0x8B)
        self.mem(dst, base, disp)
    }

    // `[base + disp] = src`
    fn store(self, base: int, disp: int, src: int) {
        self.rex_w(src, 0, base)
        self.buf.push(0x89)
        self.mem(src, base, disp)
    }

    // `[base + disp] = v`
    fn store_imm(self, base: int, disp: int, v: int) {
        self.rex_w(0, 0, base)
        self.buf.push(0xC7)
        self.mem(0, base, disp)
        self.imm32(v)
    }

    // `dst = 32 bits at [base + disp]`, sign-extended.
    fn load32(self, dst: int, base: int, disp: int) {
        self.rex_w(dst, 0, base)
        self.buf.push(0x63)
        self.mem(dst, base, disp)
    }

    // `32 bits at [base + disp] = low half of src`
    fn store32(self, base: int, disp: int, src: int) {
        self.rex_opt(src, 0, base)
        self.buf.push(0x89)
        self.mem(src, base, disp)
    }

    // `dst = byte at [base + disp]`, zero-extended.
    fn load8(self, dst: int, base: int, disp: int) {
        self.rex_w(dst, 0, base)
        self.buf.push(0x0F)
        self.buf.push(0xB6)
        self.mem(dst, base, disp)
    }

    // `byte at [base + disp] = low byte of src`
    fn store8(self, base: int, disp: int, src: int) {
        // The prefix is always emitted: it makes SIL and DIL addressable.
        self.buf.push(0x40 | (src >> 3 & 1) << 2 | base >> 3 & 1)
        self.buf.push(0x88)
        self.mem(src, base, disp)
    }

    // `dst = [base + index * 8]`
    fn load_indexed(self, dst: int, base: int, index: int) {
        self.rex_w(dst, index, base)
        self.buf.push(0x8B)
        self.indexed(dst, base, index)
    }

    // `[base + index * 8] = src`
    fn store_indexed(self, base: int, index: int, src: int) {
        self.rex_w(src, index, base)
        self.buf.push(0x89)
        self.indexed(src, base, index)
    }

    // `dst = [base + index + disp]`, 8 bytes or (`wide` unset) 4 bytes.
    // `base` must not be RBP or R13.
    fn load_at(self, dst: int, base: int, index: int, disp: int, wide: bool) {
        if wide {
            self.rex_w(dst, index, base)
        } else {
            self.rex_opt(dst, index, base)
        }
        self.buf.push(0x8B)
        self.at(dst, base, index, disp)
    }

    // `[base + index + disp] = src`, 8 bytes or (`wide` unset) 4 bytes.
    fn store_at(self, base: int, index: int, disp: int, src: int, wide: bool) {
        if wide {
            self.rex_w(src, index, base)
        } else {
            self.rex_opt(src, index, base)
        }
        self.buf.push(0x89)
        self.at(src, base, index, disp)
    }

    // ModRM + SIB + disp8 for `[base + index + disp]`.
    fn at(self, reg: int, base: int, index: int, disp: int) {
        self.buf.push(0x40 | (reg & 7) << 3 | 4)
        self.buf.push((index & 7) << 3 | base & 7)
        self.byte(disp)
    }

    // `dst = address of label`
    fn lea(self, dst: int, label: int) {
        self.rex_w(dst, 0, 0)
        self.buf.push(0x8D)
        self.buf.push((dst & 7) << 3 | 5)
        self.rel32(label)
    }

    // `dst = base + disp`
    fn lea_mem(self, dst: int, base: int, disp: int) {
        self.rex_w(dst, 0, base)
        self.buf.push(0x8D)
        self.mem(dst, base, disp)
    }

    // ---- stack ----

    fn push(self, r: int) {
        self.rex_opt(0, 0, r)
        self.buf.push(0x50 + (r & 7))
    }

    fn pop(self, r: int) {
        self.rex_opt(0, 0, r)
        self.buf.push(0x58 + (r & 7))
    }

    fn push_imm(self, v: int) {
        if fits_i8(v) {
            self.buf.push(0x6A)
            self.byte(v)
        } else {
            self.buf.push(0x68)
            self.imm32(v)
        }
    }

    // Pushes `[base + disp]`.
    fn push_mem(self, base: int, disp: int) {
        self.rex_opt(0, 0, base)
        self.buf.push(0xFF)
        self.mem(6, base, disp)
    }

    // ---- arithmetic ----

    // `dst = dst op src`
    fn alu(self, op: int, dst: int, src: int) {
        self.rex_w(src, 0, dst)
        self.buf.push(alu_to_rm(op))
        self.rr(src, dst)
    }

    // `dst = dst op [base + disp]`
    fn alu_load(self, op: int, dst: int, base: int, disp: int) {
        self.rex_w(dst, 0, base)
        self.buf.push(alu_from_rm(op))
        self.mem(dst, base, disp)
    }

    // `[base + disp] = [base + disp] op src`
    fn alu_store(self, op: int, base: int, disp: int, src: int) {
        self.rex_w(src, 0, base)
        self.buf.push(alu_to_rm(op))
        self.mem(src, base, disp)
    }

    // `dst = dst op v`
    fn alu_imm(self, op: int, dst: int, v: int) {
        self.rex_w(0, 0, dst)
        if fits_i8(v) {
            self.buf.push(0x83)
        } else {
            self.buf.push(0x81)
        }
        self.rr(op, dst)
        self.imm8_or_32(v)
    }

    // `[base + disp] = [base + disp] op v`
    fn alu_store_imm(self, op: int, base: int, disp: int, v: int) {
        self.rex_w(0, 0, base)
        if fits_i8(v) {
            self.buf.push(0x83)
        } else {
            self.buf.push(0x81)
        }
        self.mem(op, base, disp)
        self.imm8_or_32(v)
    }

    // `dst = dst op v`, always with a 32-bit immediate so it can be patched.
    // Returns the position of the immediate.
    fn alu_imm32_patchable(self, op: int, dst: int, v: int) -> int {
        self.rex_w(0, 0, dst)
        self.buf.push(0x81)
        self.rr(op, dst)
        self.imm32(v)
        return self.buf.len() - 4
    }

    // Sets the flags from `a & b`.
    fn test(self, a: int, b: int) {
        self.rex_w(b, 0, a)
        self.buf.push(0x85)
        self.rr(b, a)
    }

    // Compares the 32 bits at `[base + disp]` with a small constant.
    fn cmp32_mem(self, base: int, disp: int, v: int) {
        self.rex_opt(0, 0, base)
        self.buf.push(0x83)
        self.mem(7, base, disp)
        self.byte(v)
    }

    // Adds one to the 32 bits at `[base + disp]`.
    fn inc32_mem(self, base: int, disp: int) {
        self.rex_opt(0, 0, base)
        self.buf.push(0xFF)
        self.mem(0, base, disp)
    }

    // Subtracts one from the 32 bits at `[base + disp]`.
    fn dec32_mem(self, base: int, disp: int) {
        self.rex_opt(0, 0, base)
        self.buf.push(0xFF)
        self.mem(1, base, disp)
    }

    // `dst = dst * src`
    fn imul(self, dst: int, src: int) {
        self.rex_w(dst, 0, src)
        self.buf.push(0x0F)
        self.buf.push(0xAF)
        self.rr(dst, src)
    }

    // `dst = dst * [base + disp]`
    fn imul_load(self, dst: int, base: int, disp: int) {
        self.rex_w(dst, 0, base)
        self.buf.push(0x0F)
        self.buf.push(0xAF)
        self.mem(dst, base, disp)
    }

    // `dst = src * v`
    fn imul_imm(self, dst: int, src: int, v: int) {
        self.rex_w(dst, 0, src)
        if fits_i8(v) {
            self.buf.push(0x6B)
        } else {
            self.buf.push(0x69)
        }
        self.rr(dst, src)
        self.imm8_or_32(v)
    }

    // `RDX:RAX = RAX * src` (signed, full 128-bit result).
    fn imul_wide(self, src: int) {
        self.rex_w(0, 0, src)
        self.buf.push(0xF7)
        self.rr(5, src)
    }

    fn neg(self, r: int) {
        self.rex_w(0, 0, r)
        self.buf.push(0xF7)
        self.rr(3, r)
    }

    // Sign-extends RAX into RDX:RAX, as `idiv` expects.
    fn cqo(self) {
        self.buf.push(0x48)
        self.buf.push(0x99)
    }

    // Signed division of RDX:RAX by `r`: quotient in RAX, remainder in RDX.
    fn idiv(self, r: int) {
        self.rex_w(0, 0, r)
        self.buf.push(0xF7)
        self.rr(7, r)
    }

    fn shift(self, kind: int, r: int, count: int) {
        self.rex_w(0, 0, r)
        self.buf.push(0xC1)
        self.rr(kind, r)
        self.byte(count)
    }

    // Shifts `r` by the number of bits in CL.
    fn shift_cl(self, kind: int, r: int) {
        self.rex_w(0, 0, r)
        self.buf.push(0xD3)
        self.rr(kind, r)
    }

    // ---- floats ----
    //
    // A float travels through the generated code as its 64 bits, in the
    // ordinary registers. It moves to an XMM register to be computed with.

    // `dst = the float whose bits are in src`
    fn movq_in(self, dst: int, src: int) {
        self.buf.push(0x66)
        self.rex_w(dst, 0, src)
        self.buf.push(0x0F)
        self.buf.push(0x6E)
        self.rr(dst, src)
    }

    // `dst = the bits of the float in src`
    fn movq_out(self, dst: int, src: int) {
        self.buf.push(0x66)
        self.rex_w(src, 0, dst)
        self.buf.push(0x0F)
        self.buf.push(0x7E)
        self.rr(src, dst)
    }

    // `dst = dst op src` (`dst = src` for `Mov`, `dst = sqrt(src)` for `Sqrt`)
    fn sse(self, op: int, dst: int, src: int) {
        if op == SSE_MOV {
            // A copy of the whole register (movaps): copying only the low
            // half would make the result depend on what `dst` held before.
            self.buf.push(0x0F)
            self.buf.push(0x28)
        } else {
            self.buf.push(0xF2)
            self.buf.push(0x0F)
            self.buf.push(op)
        }
        self.rr(dst, src)
    }

    // `dst = dst op [base + disp]`
    fn sse_load(self, op: int, dst: int, base: int, disp: int) {
        self.buf.push(0xF2)
        self.rex_opt(dst, 0, base)
        self.buf.push(0x0F)
        self.buf.push(op)
        self.mem(dst, base, disp)
    }

    // `[base + disp] = src`
    fn sse_store(self, base: int, disp: int, src: int) {
        self.buf.push(0xF2)
        self.rex_opt(src, 0, base)
        self.buf.push(0x0F)
        self.buf.push(0x11)
        self.mem(src, base, disp)
    }

    // Compares two floats. The flags come out as for unsigned integers
    // (`A`, `AE`, `B`, `BE`, `E`), with `P` set when one is not a number.
    fn ucomisd(self, a: int, b: int) {
        self.buf.push(0x66)
        self.buf.push(0x0F)
        self.buf.push(0x2E)
        self.rr(a, b)
    }

    // `dst = src as a float`
    fn cvtsi2sd(self, dst: int, src: int) {
        self.buf.push(0xF2)
        self.rex_w(dst, 0, src)
        self.buf.push(0x0F)
        self.buf.push(0x2A)
        self.rr(dst, src)
    }

    // `dst = src without its decimals`
    fn cvttsd2si(self, dst: int, src: int) {
        self.buf.push(0xF2)
        self.rex_w(dst, 0, src)
        self.buf.push(0x0F)
        self.buf.push(0x2C)
        self.rr(dst, src)
    }

    // `dst = dst xor src`, on all the bits of the registers.
    fn pxor(self, dst: int, src: int) {
        self.buf.push(0x66)
        self.buf.push(0x0F)
        self.buf.push(0xEF)
        self.rr(dst, src)
    }

    // `rax = condition ? 1 : 0`, using the flags of the previous comparison.
    fn setcc(self, cc: int) {
        // setcc al
        self.buf.push(0x0F)
        self.buf.push(0x90 | cc)
        self.buf.push(0xC0)
        // movzx eax, al
        self.buf.push(0x0F)
        self.buf.push(0xB6)
        self.buf.push(0xC0)
    }

    // ---- control flow ----

    fn jmp(self, label: int) {
        self.buf.push(0xE9)
        self.rel32(label)
    }

    fn jcc(self, cc: int, label: int) {
        self.buf.push(0x0F)
        self.buf.push(0x80 | cc)
        self.rel32(label)
    }

    // A conditional jump over a few instructions (at most 127 bytes).
    // Returns where its distance goes, for `bind_short`.
    fn jcc_short(self, cc: int) -> int {
        self.buf.push(0x70 | cc)
        self.buf.push(0)
        return self.buf.len() - 1
    }

    // An unconditional jump over a few instructions (at most 127 bytes).
    fn jmp_short(self) -> int {
        self.buf.push(0xEB)
        self.buf.push(0)
        return self.buf.len() - 1
    }

    // A conditional jump back to `target`, a position at most 126 bytes before.
    fn jcc_back(self, cc: int, target: int) {
        var distance = self.buf.len() + 2 - target
        if distance > 128 {
            panic("short jump back over {distance} bytes")
        }
        self.buf.push(0x70 | cc)
        self.byte(-distance)
    }

    // Makes a short jump land here.
    fn bind_short(self, jump: int) {
        var distance = self.buf.len() - (jump + 1)
        if distance > 127 {
            panic("short jump over {distance} bytes")
        }
        self.buf[jump] = distance
    }

    fn call(self, label: int) {
        self.buf.push(0xE8)
        self.rel32(label)
    }

    // Calls the function whose address is in `r`.
    fn call_reg(self, r: int) {
        self.rex_opt(0, 0, r)
        self.buf.push(0xFF)
        self.rr(2, r)
    }

    // Calls the function whose address is stored at `[base + disp]`.
    fn call_mem(self, base: int, disp: int) {
        self.rex_opt(0, 0, base)
        self.buf.push(0xFF)
        self.mem(2, base, disp)
    }

    // Jumps to the address stored at `[base + disp]`.
    fn jmp_mem(self, base: int, disp: int) {
        self.rex_opt(0, 0, base)
        self.buf.push(0xFF)
        self.mem(4, base, disp)
    }

    fn ret(self) {
        self.buf.push(0xC3)
    }

    fn syscall(self) {
        self.buf.push(0x0F)
        self.buf.push(0x05)
    }

    // Copies RCX bytes from `[RSI]` to `[RDI]`.
    fn rep_movsb(self) {
        self.buf.push(0xF3)
        self.buf.push(0xA4)
    }

    // ---- data ----

    // Overwrites a previously emitted 32-bit value.
    fn patch32(self, at: int, v: int) {
        self.buf[at] = v & 0xFF
        self.buf[at + 1] = v >> 8 & 0xFF
        self.buf[at + 2] = v >> 16 & 0xFF
        self.buf[at + 3] = v >> 24 & 0xFF
    }

    fn bytes(self, data: [int]) {
        for b in data {
            self.buf.push(b)
        }
    }

    // 8 bytes.
    fn word(self, v: int) {
        for i in 0..8 {
            self.buf.push(v >> (8 * i) & 0xFF)
        }
    }

    // 4 bytes.
    fn half(self, v: int) {
        self.imm32(v)
    }

    // Emits the absolute address of `label` as 8 bytes of data.
    fn address(self, label: int) {
        self.abs_fixups.push(Fixup{at: self.buf.len(), label: label, size: 8})
        self.word(0)
    }

    // Emits the absolute address of `label` as 4 bytes of data.
    fn address32(self, label: int) {
        self.abs_fixups.push(Fixup{at: self.buf.len(), label: label, size: 4})
        self.half(0)
    }

    fn align(self, n: int) {
        while self.buf.len() % n != 0 {
            self.buf.push(0)
        }
    }

    // Resolves every label reference and returns the finished buffer.
    // `base` is the address at which the buffer will be loaded.
    fn finish(self, base: int) -> [int] {
        for f in self.abs_fixups {
            var target = self.labels[f.label]
            if target < 0 {
                panic("unbound label")
            }
            target += base
            for i in 0..f.size {
                self.buf[f.at + i] = target >> (8 * i) & 0xFF
            }
        }
        for f in self.fixups {
            var target = self.labels[f.label]
            if target < 0 {
                panic("unbound label")
            }
            self.patch32(f.at, target - (f.at + 4))
        }
        return self.buf
    }
}

fn new_asm() -> Asm {
    return Asm{buf: [], labels: [], fixups: [], abs_fixups: []}
}
