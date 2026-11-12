//! A minimal x86-64 assembler: just the instructions the code generator uses.
//! Code and read-only data share one buffer; labels are offsets into it and
//! every code reference is RIP-relative.
//!
//! Naming: `load` reads memory into a register, `store` writes a register to
//! memory, `[base + disp]` is the only addressing mode besides
//! `[base + index * 8]`. Unless said otherwise, operations are 64 bits wide.

pub type Reg = u8;
pub const RAX: Reg = 0;
pub const RCX: Reg = 1;
pub const RDX: Reg = 2;
pub const RBX: Reg = 3;
pub const RSP: Reg = 4;
pub const RBP: Reg = 5;
pub const RSI: Reg = 6;
pub const RDI: Reg = 7;
pub const R8: Reg = 8;
pub const R9: Reg = 9;
pub const R10: Reg = 10;
pub const R12: Reg = 12;
pub const R13: Reg = 13;
pub const R14: Reg = 14;
pub const R15: Reg = 15;

/// Two-operand arithmetic. The value is the `/digit` of the immediate form;
/// the register forms are derived from it.
#[derive(Clone, Copy, PartialEq)]
pub enum Alu {
    Add = 0,
    And = 4,
    Sub = 5,
    Xor = 6,
    Cmp = 7,
}

impl Alu {
    /// Opcode of `op r/m64, r64`.
    fn to_rm(self) -> u8 {
        (self as u8) * 8 + 1
    }
    /// Opcode of `op r64, r/m64`.
    fn from_rm(self) -> u8 {
        (self as u8) * 8 + 3
    }
}

/// Shifts by a constant. The value is the `/digit` of `C1 /digit ib`.
#[derive(Clone, Copy)]
pub enum Shift {
    Left = 4,
    /// Logical right shift: fills with zeros.
    Right = 5,
    /// Arithmetic right shift: keeps the sign.
    RightSigned = 7,
}

/// Condition codes, as used by `jcc` and `setcc`.
#[derive(Clone, Copy, PartialEq)]
pub enum Cc {
    /// Unsigned below.
    B = 0x2,
    /// Unsigned above or equal.
    Ae = 0x3,
    E = 0x4,
    Ne = 0x5,
    L = 0xC,
    Ge = 0xD,
    Le = 0xE,
    G = 0xF,
}

impl Cc {
    /// The opposite condition.
    pub fn negate(self) -> Cc {
        match self {
            Cc::B => Cc::Ae,
            Cc::Ae => Cc::B,
            Cc::E => Cc::Ne,
            Cc::Ne => Cc::E,
            Cc::L => Cc::Ge,
            Cc::Ge => Cc::L,
            Cc::Le => Cc::G,
            Cc::G => Cc::Le,
        }
    }

    /// The condition to test after the two compared operands were exchanged.
    pub fn swap(self) -> Cc {
        match self {
            Cc::L => Cc::G,
            Cc::G => Cc::L,
            Cc::Le => Cc::Ge,
            Cc::Ge => Cc::Le,
            other => other,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Label(usize);

/// A short forward jump whose distance is filled in by `bind_short`.
#[must_use]
pub struct ShortJump(usize);

#[derive(Default)]
pub struct Asm {
    pub buf: Vec<u8>,
    labels: Vec<Option<usize>>,
    /// (position of a rel32 field, label it refers to)
    fixups: Vec<(usize, Label)>,
    /// (position of an absolute address, label it refers to, size in bytes)
    abs_fixups: Vec<(usize, Label, usize)>,
}

impl Asm {
    pub fn new_label(&mut self) -> Label {
        self.labels.push(None);
        Label(self.labels.len() - 1)
    }

    pub fn bind(&mut self, label: Label) {
        self.labels[label.0] = Some(self.buf.len());
    }

    pub fn is_bound(&self, label: Label) -> bool {
        self.labels[label.0].is_some()
    }

    pub fn pos(&self) -> usize {
        self.buf.len()
    }

    // ---- encoding helpers ----

    fn imm32(&mut self, v: i32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    fn rel32(&mut self, label: Label) {
        self.fixups.push((self.buf.len(), label));
        self.imm32(0);
    }

    /// REX prefix with W set (64-bit operation).
    fn rex_w(&mut self, reg: Reg, index: Reg, base: Reg) {
        self.buf.push(0x48 | ((reg >> 3) & 1) << 2 | ((index >> 3) & 1) << 1 | ((base >> 3) & 1));
    }

    /// REX prefix for a 32-bit operation: only needed for registers r8-r15.
    fn rex_opt(&mut self, reg: Reg, index: Reg, base: Reg) {
        let bits = ((reg >> 3) & 1) << 2 | ((index >> 3) & 1) << 1 | ((base >> 3) & 1);
        if bits != 0 {
            self.buf.push(0x40 | bits);
        }
    }

    /// ModRM for two registers.
    fn rr(&mut self, reg: Reg, rm: Reg) {
        self.buf.push(0xC0 | (reg & 7) << 3 | (rm & 7));
    }

    /// ModRM (+ SIB, + displacement) for `[base + disp]`, using the shortest form.
    fn mem(&mut self, reg: Reg, base: Reg, disp: i32) {
        let (mode, size) = if disp == 0 && base & 7 != 5 {
            (0x00, 0)
        } else if i8::try_from(disp).is_ok() {
            (0x40, 1)
        } else {
            (0x80, 4)
        };
        self.buf.push(mode | (reg & 7) << 3 | (base & 7));
        if base & 7 == 4 {
            self.buf.push(0x24);
        }
        match size {
            1 => self.buf.push(disp as i8 as u8),
            4 => self.imm32(disp),
            _ => {}
        }
    }

    /// ModRM + SIB for `[base + index * 8]`. `base` must not be RBP or R13.
    fn indexed(&mut self, reg: Reg, base: Reg, index: Reg) {
        debug_assert!(base & 7 != 5 && index != RSP);
        self.buf.push((reg & 7) << 3 | 4);
        self.buf.push(3 << 6 | (index & 7) << 3 | (base & 7));
    }

    /// An immediate operand of an `83` / `81` style instruction.
    fn imm8_or_32(&mut self, v: i32) {
        match i8::try_from(v) {
            Ok(small) => self.buf.push(small as u8),
            Err(_) => self.imm32(v),
        }
    }

    // ---- moves ----

    /// `dst = v`. Does not change the flags.
    pub fn mov_imm(&mut self, dst: Reg, v: i64) {
        if let Ok(small) = u32::try_from(v) {
            // mov r32, imm32 clears the upper half.
            self.rex_opt(0, 0, dst);
            self.buf.push(0xB8 + (dst & 7));
            self.buf.extend_from_slice(&small.to_le_bytes());
        } else if let Ok(small) = i32::try_from(v) {
            self.rex_w(0, 0, dst);
            self.buf.push(0xC7);
            self.rr(0, dst);
            self.imm32(small);
        } else {
            self.rex_w(0, 0, dst);
            self.buf.push(0xB8 + (dst & 7));
            self.buf.extend_from_slice(&v.to_le_bytes());
        }
    }

    /// `dst = v` with a fixed-size encoding, so the value can be patched later.
    /// Returns the position of the 32-bit value.
    pub fn mov_imm32_patchable(&mut self, dst: Reg, v: i32) -> usize {
        self.rex_w(0, 0, dst);
        self.buf.push(0xC7);
        self.rr(0, dst);
        self.imm32(v);
        self.buf.len() - 4
    }

    pub fn mov(&mut self, dst: Reg, src: Reg) {
        if dst != src {
            self.rex_w(src, 0, dst);
            self.buf.push(0x89);
            self.rr(src, dst);
        }
    }

    /// `dst = [base + disp]`
    pub fn load(&mut self, dst: Reg, base: Reg, disp: i32) {
        self.rex_w(dst, 0, base);
        self.buf.push(0x8B);
        self.mem(dst, base, disp);
    }

    /// `[base + disp] = src`
    pub fn store(&mut self, base: Reg, disp: i32, src: Reg) {
        self.rex_w(src, 0, base);
        self.buf.push(0x89);
        self.mem(src, base, disp);
    }

    /// `[base + disp] = v`
    pub fn store_imm(&mut self, base: Reg, disp: i32, v: i32) {
        self.rex_w(0, 0, base);
        self.buf.push(0xC7);
        self.mem(0, base, disp);
        self.imm32(v);
    }

    /// `dst = 32 bits at [base + disp]`, sign-extended.
    pub fn load32(&mut self, dst: Reg, base: Reg, disp: i32) {
        self.rex_w(dst, 0, base);
        self.buf.push(0x63);
        self.mem(dst, base, disp);
    }

    /// `32 bits at [base + disp] = low half of src`
    pub fn store32(&mut self, base: Reg, disp: i32, src: Reg) {
        self.rex_opt(src, 0, base);
        self.buf.push(0x89);
        self.mem(src, base, disp);
    }

    /// `dst = byte at [base + disp]`, zero-extended.
    pub fn load8(&mut self, dst: Reg, base: Reg, disp: i32) {
        self.rex_w(dst, 0, base);
        self.buf.extend_from_slice(&[0x0F, 0xB6]);
        self.mem(dst, base, disp);
    }

    /// `byte at [base + disp] = low byte of src`
    pub fn store8(&mut self, base: Reg, disp: i32, src: Reg) {
        // The prefix is always emitted: it makes SIL and DIL addressable.
        self.buf.push(0x40 | ((src >> 3) & 1) << 2 | ((base >> 3) & 1));
        self.buf.push(0x88);
        self.mem(src, base, disp);
    }

    /// `dst = [base + index * 8]`
    pub fn load_indexed(&mut self, dst: Reg, base: Reg, index: Reg) {
        self.rex_w(dst, index, base);
        self.buf.push(0x8B);
        self.indexed(dst, base, index);
    }

    /// `[base + index * 8] = src`
    pub fn store_indexed(&mut self, base: Reg, index: Reg, src: Reg) {
        self.rex_w(src, index, base);
        self.buf.push(0x89);
        self.indexed(src, base, index);
    }

    /// `dst = [base + index + disp]`, 8 bytes or (`wide` unset) 4 bytes.
    /// `base` must not be RBP or R13.
    pub fn load_at(&mut self, dst: Reg, base: Reg, index: Reg, disp: i8, wide: bool) {
        if wide {
            self.rex_w(dst, index, base);
        } else {
            self.rex_opt(dst, index, base);
        }
        self.buf.push(0x8B);
        self.at(dst, base, index, disp);
    }

    /// `[base + index + disp] = src`, 8 bytes or (`wide` unset) 4 bytes.
    pub fn store_at(&mut self, base: Reg, index: Reg, disp: i8, src: Reg, wide: bool) {
        if wide {
            self.rex_w(src, index, base);
        } else {
            self.rex_opt(src, index, base);
        }
        self.buf.push(0x89);
        self.at(src, base, index, disp);
    }

    /// ModRM + SIB + disp8 for `[base + index + disp]`.
    fn at(&mut self, reg: Reg, base: Reg, index: Reg, disp: i8) {
        debug_assert!(index != RSP);
        self.buf.push(0x40 | (reg & 7) << 3 | 4);
        self.buf.push((index & 7) << 3 | (base & 7));
        self.buf.push(disp as u8);
    }

    /// `dst = address of label`
    pub fn lea(&mut self, dst: Reg, label: Label) {
        self.rex_w(dst, 0, 0);
        self.buf.extend_from_slice(&[0x8D, (dst & 7) << 3 | 5]);
        self.rel32(label);
    }

    /// `dst = base + disp`
    pub fn lea_mem(&mut self, dst: Reg, base: Reg, disp: i32) {
        self.rex_w(dst, 0, base);
        self.buf.push(0x8D);
        self.mem(dst, base, disp);
    }

    // ---- stack ----

    pub fn push(&mut self, r: Reg) {
        self.rex_opt(0, 0, r);
        self.buf.push(0x50 + (r & 7));
    }

    pub fn pop(&mut self, r: Reg) {
        self.rex_opt(0, 0, r);
        self.buf.push(0x58 + (r & 7));
    }

    pub fn push_imm(&mut self, v: i32) {
        match i8::try_from(v) {
            Ok(small) => self.buf.extend_from_slice(&[0x6A, small as u8]),
            Err(_) => {
                self.buf.push(0x68);
                self.imm32(v);
            }
        }
    }

    /// Pushes `[base + disp]`.
    pub fn push_mem(&mut self, base: Reg, disp: i32) {
        self.rex_opt(0, 0, base);
        self.buf.push(0xFF);
        self.mem(6, base, disp);
    }

    // ---- arithmetic ----

    /// `dst = dst op src`
    pub fn alu(&mut self, op: Alu, dst: Reg, src: Reg) {
        self.rex_w(src, 0, dst);
        self.buf.push(op.to_rm());
        self.rr(src, dst);
    }

    /// `dst = dst op [base + disp]`
    pub fn alu_load(&mut self, op: Alu, dst: Reg, base: Reg, disp: i32) {
        self.rex_w(dst, 0, base);
        self.buf.push(op.from_rm());
        self.mem(dst, base, disp);
    }

    /// `[base + disp] = [base + disp] op src`
    pub fn alu_store(&mut self, op: Alu, base: Reg, disp: i32, src: Reg) {
        self.rex_w(src, 0, base);
        self.buf.push(op.to_rm());
        self.mem(src, base, disp);
    }

    /// `dst = dst op v`
    pub fn alu_imm(&mut self, op: Alu, dst: Reg, v: i32) {
        self.rex_w(0, 0, dst);
        self.buf.push(if i8::try_from(v).is_ok() { 0x83 } else { 0x81 });
        self.rr(op as u8, dst);
        self.imm8_or_32(v);
    }

    /// `[base + disp] = [base + disp] op v`
    pub fn alu_store_imm(&mut self, op: Alu, base: Reg, disp: i32, v: i32) {
        self.rex_w(0, 0, base);
        self.buf.push(if i8::try_from(v).is_ok() { 0x83 } else { 0x81 });
        self.mem(op as u8, base, disp);
        self.imm8_or_32(v);
    }

    /// `dst = dst op v`, always with a 32-bit immediate so it can be patched.
    /// Returns the position of the immediate.
    pub fn alu_imm32_patchable(&mut self, op: Alu, dst: Reg, v: i32) -> usize {
        self.rex_w(0, 0, dst);
        self.buf.push(0x81);
        self.rr(op as u8, dst);
        self.imm32(v);
        self.buf.len() - 4
    }

    /// Sets the flags from `a & b`.
    pub fn test(&mut self, a: Reg, b: Reg) {
        self.rex_w(b, 0, a);
        self.buf.push(0x85);
        self.rr(b, a);
    }

    /// Compares the 32 bits at `[base + disp]` with a small constant.
    pub fn cmp32_mem(&mut self, base: Reg, disp: i32, v: i8) {
        self.rex_opt(0, 0, base);
        self.buf.push(0x83);
        self.mem(7, base, disp);
        self.buf.push(v as u8);
    }

    /// Adds one to the 32 bits at `[base + disp]`.
    pub fn inc32_mem(&mut self, base: Reg, disp: i32) {
        self.rex_opt(0, 0, base);
        self.buf.push(0xFF);
        self.mem(0, base, disp);
    }

    /// Subtracts one from the 32 bits at `[base + disp]`.
    pub fn dec32_mem(&mut self, base: Reg, disp: i32) {
        self.rex_opt(0, 0, base);
        self.buf.push(0xFF);
        self.mem(1, base, disp);
    }

    /// `dst = dst * src`
    pub fn imul(&mut self, dst: Reg, src: Reg) {
        self.rex_w(dst, 0, src);
        self.buf.extend_from_slice(&[0x0F, 0xAF]);
        self.rr(dst, src);
    }

    /// `dst = dst * [base + disp]`
    pub fn imul_load(&mut self, dst: Reg, base: Reg, disp: i32) {
        self.rex_w(dst, 0, base);
        self.buf.extend_from_slice(&[0x0F, 0xAF]);
        self.mem(dst, base, disp);
    }

    /// `dst = src * v`
    pub fn imul_imm(&mut self, dst: Reg, src: Reg, v: i32) {
        self.rex_w(dst, 0, src);
        self.buf.push(if i8::try_from(v).is_ok() { 0x6B } else { 0x69 });
        self.rr(dst, src);
        self.imm8_or_32(v);
    }

    /// `RDX:RAX = RAX * src` (signed, full 128-bit result).
    pub fn imul_wide(&mut self, src: Reg) {
        self.rex_w(0, 0, src);
        self.buf.push(0xF7);
        self.rr(5, src);
    }

    pub fn neg(&mut self, r: Reg) {
        self.rex_w(0, 0, r);
        self.buf.push(0xF7);
        self.rr(3, r);
    }

    /// Sign-extends RAX into RDX:RAX, as `idiv` expects.
    pub fn cqo(&mut self) {
        self.buf.extend_from_slice(&[0x48, 0x99]);
    }

    /// Signed division of RDX:RAX by `r`: quotient in RAX, remainder in RDX.
    pub fn idiv(&mut self, r: Reg) {
        self.rex_w(0, 0, r);
        self.buf.push(0xF7);
        self.rr(7, r);
    }

    pub fn shift(&mut self, kind: Shift, r: Reg, count: u8) {
        self.rex_w(0, 0, r);
        self.buf.push(0xC1);
        self.rr(kind as u8, r);
        self.buf.push(count);
    }

    /// `rax = condition ? 1 : 0`, using the flags of the previous comparison.
    pub fn setcc(&mut self, cc: Cc) {
        self.buf.extend_from_slice(&[0x0F, 0x90 | cc as u8, 0xC0]); // setcc al
        self.buf.extend_from_slice(&[0x0F, 0xB6, 0xC0]); // movzx eax, al
    }

    // ---- control flow ----

    pub fn jmp(&mut self, label: Label) {
        self.buf.push(0xE9);
        self.rel32(label);
    }

    pub fn jcc(&mut self, cc: Cc, label: Label) {
        self.buf.extend_from_slice(&[0x0F, 0x80 | cc as u8]);
        self.rel32(label);
    }

    /// A conditional jump over a few instructions (at most 127 bytes).
    pub fn jcc_short(&mut self, cc: Cc) -> ShortJump {
        self.buf.extend_from_slice(&[0x70 | cc as u8, 0]);
        ShortJump(self.buf.len() - 1)
    }

    /// An unconditional jump over a few instructions (at most 127 bytes).
    pub fn jmp_short(&mut self) -> ShortJump {
        self.buf.extend_from_slice(&[0xEB, 0]);
        ShortJump(self.buf.len() - 1)
    }

    /// A conditional jump back to `target`, a position at most 126 bytes before.
    pub fn jcc_back(&mut self, cc: Cc, target: usize) {
        let distance = self.buf.len() + 2 - target;
        assert!(distance <= 128, "short jump back over {distance} bytes");
        self.buf.extend_from_slice(&[0x70 | cc as u8, (-(distance as i64)) as u8]);
    }

    /// Makes a short jump land here.
    pub fn bind_short(&mut self, jump: ShortJump) {
        let distance = self.buf.len() - (jump.0 + 1);
        assert!(distance <= 127, "short jump over {distance} bytes");
        self.buf[jump.0] = distance as u8;
    }

    pub fn call(&mut self, label: Label) {
        self.buf.push(0xE8);
        self.rel32(label);
    }

    /// Calls the function whose address is in `r`.
    pub fn call_reg(&mut self, r: Reg) {
        self.rex_opt(0, 0, r);
        self.buf.push(0xFF);
        self.rr(2, r);
    }

    /// Calls the function whose address is stored at `[base + disp]`.
    pub fn call_mem(&mut self, base: Reg, disp: i32) {
        self.rex_opt(0, 0, base);
        self.buf.push(0xFF);
        self.mem(2, base, disp);
    }

    pub fn ret(&mut self) {
        self.buf.push(0xC3);
    }

    pub fn syscall(&mut self) {
        self.buf.extend_from_slice(&[0x0F, 0x05]);
    }

    /// Copies RCX bytes from `[RSI]` to `[RDI]`.
    pub fn rep_movsb(&mut self) {
        self.buf.extend_from_slice(&[0xF3, 0xA4]);
    }

    // ---- data ----

    /// Overwrites a previously emitted 32-bit value.
    pub fn patch32(&mut self, pos: usize, v: i32) {
        self.buf[pos..pos + 4].copy_from_slice(&v.to_le_bytes());
    }

    pub fn bytes(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }

    pub fn word(&mut self, v: u64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn half(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    /// Emits the absolute address of `label` as 8 bytes of data.
    pub fn address(&mut self, label: Label) {
        self.abs_fixups.push((self.buf.len(), label, 8));
        self.word(0);
    }

    /// Emits the absolute address of `label` as 4 bytes of data.
    pub fn address32(&mut self, label: Label) {
        self.abs_fixups.push((self.buf.len(), label, 4));
        self.half(0);
    }

    pub fn align(&mut self, n: usize) {
        while self.buf.len() % n != 0 {
            self.buf.push(0);
        }
    }

    /// Resolves every label reference and returns the finished buffer.
    /// `base` is the address at which the buffer will be loaded.
    pub fn finish(mut self, base: u64) -> Vec<u8> {
        for (pos, label, size) in std::mem::take(&mut self.abs_fixups) {
            let target = base + self.labels[label.0].expect("unbound label") as u64;
            self.buf[pos..pos + size].copy_from_slice(&target.to_le_bytes()[..size]);
        }
        for (pos, label) in std::mem::take(&mut self.fixups) {
            let target = self.labels[label.0].expect("unbound label") as i64;
            let rel = target - (pos as i64 + 4);
            self.buf[pos..pos + 4].copy_from_slice(&(rel as i32).to_le_bytes());
        }
        self.buf
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn emit(f: impl FnOnce(&mut Asm)) -> Vec<u8> {
        let mut asm = Asm::default();
        f(&mut asm);
        asm.buf
    }

    /// The expected bytes are what GNU `as` produces for each instruction,
    /// except where noted: there the assembler picks another, equivalent form.
    #[test]
    fn encodings() {
        assert_eq!(emit(|a| a.mov(RAX, RBX)), [0x48, 0x89, 0xD8]);
        assert_eq!(emit(|a| a.mov(R12, RAX)), [0x49, 0x89, 0xC4]);
        assert_eq!(emit(|a| a.mov(RAX, RAX)), []);
        assert_eq!(emit(|a| a.mov_imm(RAX, 0)), [0xB8, 0, 0, 0, 0]);
        assert_eq!(emit(|a| a.mov_imm(R8, 7)), [0x41, 0xB8, 7, 0, 0, 0]);
        assert_eq!(emit(|a| a.mov_imm(RAX, -1)), [0x48, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF]);
        assert_eq!(emit(|a| a.mov_imm(RCX, 1 << 40)), [0x48, 0xB9, 0, 0, 0, 0, 0, 1, 0, 0]);
        assert_eq!(emit(|a| a.load(RAX, RBP, -8)), [0x48, 0x8B, 0x45, 0xF8]);
        assert_eq!(emit(|a| a.load(RAX, RBP, 0)), [0x48, 0x8B, 0x45, 0x00]);
        assert_eq!(emit(|a| a.load(RAX, RAX, 0)), [0x48, 0x8B, 0x00]);
        assert_eq!(emit(|a| a.load(RCX, RSP, 8)), [0x48, 0x8B, 0x4C, 0x24, 0x08]);
        assert_eq!(emit(|a| a.load(RAX, R12, 0)), [0x49, 0x8B, 0x04, 0x24]);
        assert_eq!(emit(|a| a.load(RAX, R13, 0)), [0x49, 0x8B, 0x45, 0x00]);
        assert_eq!(emit(|a| a.load(RAX, R15, 4096)), [0x49, 0x8B, 0x87, 0x00, 0x10, 0x00, 0x00]);
        assert_eq!(emit(|a| a.store(RBP, -16, RBX)), [0x48, 0x89, 0x5D, 0xF0]);
        assert_eq!(emit(|a| a.store_imm(RCX, 8, 5)), [0x48, 0xC7, 0x41, 0x08, 5, 0, 0, 0]);
        assert_eq!(emit(|a| a.load32(RCX, RAX, 4)), [0x48, 0x63, 0x48, 0x04]);
        assert_eq!(emit(|a| a.store32(RAX, 0, RCX)), [0x89, 0x08]);
        assert_eq!(emit(|a| a.load8(RAX, RCX, 0)), [0x48, 0x0F, 0xB6, 0x01]);
        // `as` leaves out the 0x40 prefix here, which is only needed for SIL and DIL.
        assert_eq!(emit(|a| a.store8(RAX, 0, RCX)), [0x40, 0x88, 0x08]);
        assert_eq!(emit(|a| a.store8(RAX, 0, RSI)), [0x40, 0x88, 0x30]);
        assert_eq!(emit(|a| a.load_indexed(RAX, RCX, RAX)), [0x48, 0x8B, 0x04, 0xC1]);
        assert_eq!(emit(|a| a.store_indexed(RCX, RAX, RDX)), [0x48, 0x89, 0x14, 0xC1]);
        assert_eq!(emit(|a| a.load_indexed(R8, RCX, RAX)), [0x4C, 0x8B, 0x04, 0xC1]);
        assert_eq!(emit(|a| a.push(RBX)), [0x53]);
        assert_eq!(emit(|a| a.push(R12)), [0x41, 0x54]);
        assert_eq!(emit(|a| a.pop(R14)), [0x41, 0x5E]);
        assert_eq!(emit(|a| a.push_imm(3)), [0x6A, 0x03]);
        assert_eq!(emit(|a| a.push_imm(1000)), [0x68, 0xE8, 0x03, 0, 0]);
        assert_eq!(emit(|a| a.push_mem(RBP, 16)), [0xFF, 0x75, 0x10]);
        assert_eq!(emit(|a| a.alu(Alu::Add, RAX, RCX)), [0x48, 0x01, 0xC8]);
        assert_eq!(emit(|a| a.alu(Alu::Cmp, RBX, R12)), [0x4C, 0x39, 0xE3]);
        assert_eq!(emit(|a| a.alu_load(Alu::Sub, RAX, RBP, -8)), [0x48, 0x2B, 0x45, 0xF8]);
        assert_eq!(emit(|a| a.alu_store(Alu::Add, RBP, -8, RAX)), [0x48, 0x01, 0x45, 0xF8]);
        assert_eq!(emit(|a| a.alu_imm(Alu::Add, RBX, 1)), [0x48, 0x83, 0xC3, 0x01]);
        // `as` uses the shorter form reserved to RAX (48 3D) for this one.
        assert_eq!(emit(|a| a.alu_imm(Alu::Cmp, RAX, 1000)), [0x48, 0x81, 0xF8, 0xE8, 0x03, 0, 0]);
        assert_eq!(emit(|a| a.alu_imm(Alu::And, RAX, 7)), [0x48, 0x83, 0xE0, 0x07]);
        assert_eq!(emit(|a| a.alu_store_imm(Alu::Add, RBP, -8, 1)), [0x48, 0x83, 0x45, 0xF8, 0x01]);
        assert_eq!(emit(|a| a.test(RAX, RAX)), [0x48, 0x85, 0xC0]);
        assert_eq!(emit(|a| a.cmp32_mem(RAX, 0, 0)), [0x83, 0x38, 0x00]);
        assert_eq!(emit(|a| a.inc32_mem(RAX, 0)), [0xFF, 0x00]);
        assert_eq!(emit(|a| a.dec32_mem(RAX, 0)), [0xFF, 0x08]);
        assert_eq!(emit(|a| a.inc32_mem(RBX, 0)), [0xFF, 0x03]);
        assert_eq!(emit(|a| a.imul(RAX, RCX)), [0x48, 0x0F, 0xAF, 0xC1]);
        assert_eq!(emit(|a| a.imul_load(RAX, RBP, -8)), [0x48, 0x0F, 0xAF, 0x45, 0xF8]);
        assert_eq!(emit(|a| a.imul_imm(RAX, RAX, 10)), [0x48, 0x6B, 0xC0, 0x0A]);
        assert_eq!(emit(|a| a.imul_imm(RAX, RCX, 1000)), [0x48, 0x69, 0xC1, 0xE8, 0x03, 0, 0]);
        assert_eq!(emit(|a| a.imul_wide(RCX)), [0x48, 0xF7, 0xE9]);
        assert_eq!(emit(|a| a.neg(RAX)), [0x48, 0xF7, 0xD8]);
        assert_eq!(emit(|a| a.idiv(RCX)), [0x48, 0xF7, 0xF9]);
        assert_eq!(emit(|a| a.shift(Shift::Left, RAX, 3)), [0x48, 0xC1, 0xE0, 0x03]);
        assert_eq!(emit(|a| a.shift(Shift::Right, RCX, 61)), [0x48, 0xC1, 0xE9, 0x3D]);
        assert_eq!(emit(|a| a.shift(Shift::RightSigned, RDX, 2)), [0x48, 0xC1, 0xFA, 0x02]);
        assert_eq!(emit(|a| a.call_reg(RAX)), [0xFF, 0xD0]);
        assert_eq!(emit(|a| a.call_mem(R15, 8)), [0x41, 0xFF, 0x57, 0x08]);
        assert_eq!(emit(|a| a.lea_mem(RCX, RSP, 48)), [0x48, 0x8D, 0x4C, 0x24, 0x30]);
        assert_eq!(emit(|a| a.load_at(R9, RSI, RCX, -8, true)), [0x4C, 0x8B, 0x4C, 0x0E, 0xF8]);
        assert_eq!(emit(|a| a.store_at(RDI, RCX, -8, R9, true)), [0x4C, 0x89, 0x4C, 0x0F, 0xF8]);
        assert_eq!(emit(|a| a.load_at(R9, RSI, RCX, -4, false)), [0x44, 0x8B, 0x4C, 0x0E, 0xFC]);
        assert_eq!(emit(|a| a.store_at(RDI, RCX, -4, R9, false)), [0x44, 0x89, 0x4C, 0x0F, 0xFC]);
    }

    #[test]
    fn short_jumps() {
        let mut asm = Asm::default();
        let jump = asm.jcc_short(Cc::L);
        asm.inc32_mem(RAX, 0);
        asm.bind_short(jump);
        assert_eq!(asm.buf, [0x7C, 0x02, 0xFF, 0x00]);

        let mut asm = Asm::default();
        let top = asm.pos();
        asm.inc32_mem(RAX, 0);
        asm.jcc_back(Cc::Ne, top);
        assert_eq!(asm.buf, [0xFF, 0x00, 0x75, 0xFC]);
    }
}
