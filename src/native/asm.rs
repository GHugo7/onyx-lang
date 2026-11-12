//! A minimal x86-64 assembler: just the instructions the code generator uses.
//! Code and read-only data share one buffer; labels are offsets into it and
//! every reference is RIP-relative, so the output is position independent.

pub type Reg = u8;
pub const RAX: Reg = 0;
pub const RCX: Reg = 1;
pub const RDX: Reg = 2;
pub const RSP: Reg = 4;
pub const RBP: Reg = 5;
pub const RSI: Reg = 6;
pub const RDI: Reg = 7;
pub const R8: Reg = 8;
pub const R9: Reg = 9;
pub const R10: Reg = 10;
pub const R15: Reg = 15;

/// Two-operand instructions of the form `op r/m64, r64`.
#[derive(Clone, Copy)]
pub enum Alu {
    Add = 0x01,
    Or = 0x09,
    And = 0x21,
    Sub = 0x29,
    Cmp = 0x39,
    Test = 0x85,
}

/// The `/digit` of `81 /digit imm32`.
#[derive(Clone, Copy)]
pub enum AluImm {
    Add = 0,
    Sub = 5,
    Xor = 6,
    Cmp = 7,
}

/// Condition codes, as used by `jcc` and `setcc`.
#[derive(Clone, Copy)]
pub enum Cc {
    E = 0x4,
    Ne = 0x5,
    L = 0xC,
    Ge = 0xD,
    Le = 0xE,
    G = 0xF,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Label(usize);

#[derive(Default)]
pub struct Asm {
    pub buf: Vec<u8>,
    labels: Vec<Option<usize>>,
    /// (position of a rel32 field, label it refers to)
    fixups: Vec<(usize, Label)>,
    /// (position of a 64-bit absolute address, label it refers to)
    abs_fixups: Vec<(usize, Label)>,
}

fn rex(w: bool, reg: Reg, base: Reg) -> u8 {
    0x40 | (w as u8) << 3 | ((reg >> 3) & 1) << 2 | ((base >> 3) & 1)
}

impl Asm {
    pub fn new_label(&mut self) -> Label {
        self.labels.push(None);
        Label(self.labels.len() - 1)
    }

    pub fn bind(&mut self, label: Label) {
        self.labels[label.0] = Some(self.buf.len());
    }

    pub fn pos(&self) -> usize {
        self.buf.len()
    }

    fn imm32(&mut self, v: i32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    fn rel32(&mut self, label: Label) {
        self.fixups.push((self.buf.len(), label));
        self.imm32(0);
    }

    /// ModRM (+ SIB) for `[base + disp32]`.
    fn mem(&mut self, reg: Reg, base: Reg, disp: i32) {
        self.buf.push(0x80 | (reg & 7) << 3 | (base & 7));
        if base & 7 == 4 {
            self.buf.push(0x24);
        }
        self.imm32(disp);
    }

    pub fn mov_imm(&mut self, dst: Reg, v: i64) {
        if let Ok(small) = i32::try_from(v) {
            self.buf.extend_from_slice(&[rex(true, 0, dst), 0xC7, 0xC0 | (dst & 7)]);
            self.imm32(small);
        } else {
            self.buf.extend_from_slice(&[rex(true, 0, dst), 0xB8 + (dst & 7)]);
            self.buf.extend_from_slice(&v.to_le_bytes());
        }
    }

    pub fn mov(&mut self, dst: Reg, src: Reg) {
        self.buf.extend_from_slice(&[rex(true, src, dst), 0x89, 0xC0 | (src & 7) << 3 | (dst & 7)]);
    }

    /// `dst = [base + disp]` (64 bits)
    pub fn load(&mut self, dst: Reg, base: Reg, disp: i32) {
        self.buf.extend_from_slice(&[rex(true, dst, base), 0x8B]);
        self.mem(dst, base, disp);
    }

    /// `[base + disp] = src` (64 bits)
    pub fn store(&mut self, base: Reg, disp: i32, src: Reg) {
        self.buf.extend_from_slice(&[rex(true, src, base), 0x89]);
        self.mem(src, base, disp);
    }

    /// `dst = zero-extended byte at [base + disp]`
    pub fn load8(&mut self, dst: Reg, base: Reg, disp: i32) {
        self.buf.extend_from_slice(&[rex(true, dst, base), 0x0F, 0xB6]);
        self.mem(dst, base, disp);
    }

    /// `byte at [base + disp] = low byte of src`
    pub fn store8(&mut self, base: Reg, disp: i32, src: Reg) {
        self.buf.extend_from_slice(&[rex(false, src, base), 0x88]);
        self.mem(src, base, disp);
    }

    pub fn push(&mut self, r: Reg) {
        if r >= 8 {
            self.buf.push(0x41);
        }
        self.buf.push(0x50 + (r & 7));
    }

    pub fn pop(&mut self, r: Reg) {
        if r >= 8 {
            self.buf.push(0x41);
        }
        self.buf.push(0x58 + (r & 7));
    }

    pub fn alu(&mut self, op: Alu, dst: Reg, src: Reg) {
        self.buf.extend_from_slice(&[rex(true, src, dst), op as u8, 0xC0 | (src & 7) << 3 | (dst & 7)]);
    }

    pub fn alu_imm(&mut self, op: AluImm, dst: Reg, v: i32) {
        self.buf.extend_from_slice(&[rex(true, 0, dst), 0x81, 0xC0 | (op as u8) << 3 | (dst & 7)]);
        self.imm32(v);
    }

    pub fn imul(&mut self, dst: Reg, src: Reg) {
        self.buf.extend_from_slice(&[rex(true, dst, src), 0x0F, 0xAF, 0xC0 | (dst & 7) << 3 | (src & 7)]);
    }

    pub fn neg(&mut self, r: Reg) {
        self.buf.extend_from_slice(&[rex(true, 0, r), 0xF7, 0xC0 | 3 << 3 | (r & 7)]);
    }

    /// Sign-extends RAX into RDX:RAX, as `idiv` expects.
    pub fn cqo(&mut self) {
        self.buf.extend_from_slice(&[0x48, 0x99]);
    }

    /// Signed division of RDX:RAX by `r`: quotient in RAX, remainder in RDX.
    pub fn idiv(&mut self, r: Reg) {
        self.buf.extend_from_slice(&[rex(true, 0, r), 0xF7, 0xC0 | 7 << 3 | (r & 7)]);
    }

    /// `rax = condition ? 1 : 0`, using the flags of the previous comparison.
    pub fn setcc(&mut self, cc: Cc) {
        self.buf.extend_from_slice(&[0x0F, 0x90 | cc as u8, 0xC0]); // setcc al
        self.buf.extend_from_slice(&[0x0F, 0xB6, 0xC0]); // movzx eax, al
    }

    pub fn jmp(&mut self, label: Label) {
        self.buf.push(0xE9);
        self.rel32(label);
    }

    pub fn jcc(&mut self, cc: Cc, label: Label) {
        self.buf.extend_from_slice(&[0x0F, 0x80 | cc as u8]);
        self.rel32(label);
    }

    pub fn call(&mut self, label: Label) {
        self.buf.push(0xE8);
        self.rel32(label);
    }

    /// Calls the function whose address is in `r`.
    pub fn call_reg(&mut self, r: Reg) {
        if r >= 8 {
            self.buf.push(0x41);
        }
        self.buf.extend_from_slice(&[0xFF, 0xC0 | 2 << 3 | (r & 7)]);
    }

    pub fn ret(&mut self) {
        self.buf.push(0xC3);
    }

    /// `dst = address of label`
    pub fn lea(&mut self, dst: Reg, label: Label) {
        self.buf.extend_from_slice(&[rex(true, dst, 0), 0x8D, (dst & 7) << 3 | 5]);
        self.rel32(label);
    }

    pub fn syscall(&mut self) {
        self.buf.extend_from_slice(&[0x0F, 0x05]);
    }

    /// Overwrites a previously emitted imm32.
    pub fn patch32(&mut self, pos: usize, v: i32) {
        self.buf[pos..pos + 4].copy_from_slice(&v.to_le_bytes());
    }

    pub fn bytes(&mut self, data: &[u8]) {
        self.buf.extend_from_slice(data);
    }

    pub fn word(&mut self, v: u64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    /// Emits the absolute address of `label` as data.
    pub fn address(&mut self, label: Label) {
        self.abs_fixups.push((self.buf.len(), label));
        self.word(0);
    }

    pub fn align(&mut self, n: usize) {
        while self.buf.len() % n != 0 {
            self.buf.push(0);
        }
    }

    /// Resolves every label reference and returns the finished buffer.
    /// `base` is the address at which the buffer will be loaded.
    pub fn finish(mut self, base: u64) -> Vec<u8> {
        for (pos, label) in std::mem::take(&mut self.abs_fixups) {
            let target = base + self.labels[label.0].expect("unbound label") as u64;
            self.buf[pos..pos + 8].copy_from_slice(&target.to_le_bytes());
        }
        for (pos, label) in std::mem::take(&mut self.fixups) {
            let target = self.labels[label.0].expect("unbound label") as i64;
            let rel = target - (pos as i64 + 4);
            self.buf[pos..pos + 4].copy_from_slice(&(rel as i32).to_le_bytes());
        }
        self.buf
    }
}
