// The encodings of the assembler, checked against the bytes GNU `as`
// produces for each instruction (the same checks as in src/native/asm.rs).

// The bytes one instruction is made of.
fn emit(f: fn(Asm)) -> [int] {
    var a = new_asm()
    f(a)
    return a.buf
}

check "integer instructions" {
    expect(emit(fn(a: Asm) {
        a.mov(RAX, RBX)
    }) == [0x48, 0x89, 0xD8])
    expect(emit(fn(a: Asm) {
        a.mov(R12, RAX)
    }) == [0x49, 0x89, 0xC4])
    expect(emit(fn(a: Asm) {
        a.mov(RAX, RAX)
    }) == [])
    expect(emit(fn(a: Asm) {
        a.mov_imm(RAX, 0)
    }) == [0xB8, 0, 0, 0, 0])
    expect(emit(fn(a: Asm) {
        a.mov_imm(R8, 7)
    }) == [0x41, 0xB8, 7, 0, 0, 0])
    expect(emit(fn(a: Asm) {
        a.mov_imm(RAX, -1)
    }) == [0x48, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF])
    expect(emit(fn(a: Asm) {
        a.mov_imm(RCX, 0x100_0000_0000)
    }) == [0x48, 0xB9, 0, 0, 0, 0, 0, 1, 0, 0])
    expect(emit(fn(a: Asm) {
        a.load(RAX, RBP, -8)
    }) == [0x48, 0x8B, 0x45, 0xF8])
    expect(emit(fn(a: Asm) {
        a.load(RAX, RBP, 0)
    }) == [0x48, 0x8B, 0x45, 0x00])
    expect(emit(fn(a: Asm) {
        a.load(RAX, RAX, 0)
    }) == [0x48, 0x8B, 0x00])
    expect(emit(fn(a: Asm) {
        a.load(RCX, RSP, 8)
    }) == [0x48, 0x8B, 0x4C, 0x24, 0x08])
    expect(emit(fn(a: Asm) {
        a.load(RAX, R12, 0)
    }) == [0x49, 0x8B, 0x04, 0x24])
    expect(emit(fn(a: Asm) {
        a.load(RAX, R13, 0)
    }) == [0x49, 0x8B, 0x45, 0x00])
    expect(emit(fn(a: Asm) {
        a.load(RAX, R15, 4096)
    }) == [0x49, 0x8B, 0x87, 0x00, 0x10, 0x00, 0x00])
    expect(emit(fn(a: Asm) {
        a.store(RBP, -16, RBX)
    }) == [0x48, 0x89, 0x5D, 0xF0])
    expect(emit(fn(a: Asm) {
        a.store_imm(RCX, 8, 5)
    }) == [0x48, 0xC7, 0x41, 0x08, 5, 0, 0, 0])
    expect(emit(fn(a: Asm) {
        a.load32(RCX, RAX, 4)
    }) == [0x48, 0x63, 0x48, 0x04])
    expect(emit(fn(a: Asm) {
        a.store32(RAX, 0, RCX)
    }) == [0x89, 0x08])
    expect(emit(fn(a: Asm) {
        a.load8(RAX, RCX, 0)
    }) == [0x48, 0x0F, 0xB6, 0x01])
    expect(emit(fn(a: Asm) {
        a.store8(RAX, 0, RCX)
    }) == [0x40, 0x88, 0x08])
    expect(emit(fn(a: Asm) {
        a.store8(RAX, 0, RSI)
    }) == [0x40, 0x88, 0x30])
    expect(emit(fn(a: Asm) {
        a.load_indexed(RAX, RCX, RAX)
    }) == [0x48, 0x8B, 0x04, 0xC1])
    expect(emit(fn(a: Asm) {
        a.store_indexed(RCX, RAX, RDX)
    }) == [0x48, 0x89, 0x14, 0xC1])
    expect(emit(fn(a: Asm) {
        a.load_indexed(R8, RCX, RAX)
    }) == [0x4C, 0x8B, 0x04, 0xC1])
    expect(emit(fn(a: Asm) {
        a.push(RBX)
    }) == [0x53])
    expect(emit(fn(a: Asm) {
        a.push(R12)
    }) == [0x41, 0x54])
    expect(emit(fn(a: Asm) {
        a.pop(R14)
    }) == [0x41, 0x5E])
    expect(emit(fn(a: Asm) {
        a.push_imm(3)
    }) == [0x6A, 0x03])
    expect(emit(fn(a: Asm) {
        a.push_imm(1000)
    }) == [0x68, 0xE8, 0x03, 0, 0])
    expect(emit(fn(a: Asm) {
        a.push_mem(RBP, 16)
    }) == [0xFF, 0x75, 0x10])
    expect(emit(fn(a: Asm) {
        a.alu(ALU_ADD, RAX, RCX)
    }) == [0x48, 0x01, 0xC8])
    expect(emit(fn(a: Asm) {
        a.alu(ALU_CMP, RBX, R12)
    }) == [0x4C, 0x39, 0xE3])
    expect(emit(fn(a: Asm) {
        a.alu_load(ALU_SUB, RAX, RBP, -8)
    }) == [0x48, 0x2B, 0x45, 0xF8])
    expect(emit(fn(a: Asm) {
        a.alu_store(ALU_ADD, RBP, -8, RAX)
    }) == [0x48, 0x01, 0x45, 0xF8])
    expect(emit(fn(a: Asm) {
        a.alu_imm(ALU_ADD, RBX, 1)
    }) == [0x48, 0x83, 0xC3, 0x01])
    expect(emit(fn(a: Asm) {
        a.alu_imm(ALU_CMP, RAX, 1000)
    }) == [0x48, 0x81, 0xF8, 0xE8, 0x03, 0, 0])
    expect(emit(fn(a: Asm) {
        a.alu_imm(ALU_AND, RAX, 7)
    }) == [0x48, 0x83, 0xE0, 0x07])
    expect(emit(fn(a: Asm) {
        a.alu_store_imm(ALU_ADD, RBP, -8, 1)
    }) == [0x48, 0x83, 0x45, 0xF8, 0x01])
    expect(emit(fn(a: Asm) {
        a.test(RAX, RAX)
    }) == [0x48, 0x85, 0xC0])
    expect(emit(fn(a: Asm) {
        a.cmp32_mem(RAX, 0, 0)
    }) == [0x83, 0x38, 0x00])
    expect(emit(fn(a: Asm) {
        a.inc32_mem(RAX, 0)
    }) == [0xFF, 0x00])
    expect(emit(fn(a: Asm) {
        a.dec32_mem(RAX, 0)
    }) == [0xFF, 0x08])
    expect(emit(fn(a: Asm) {
        a.inc32_mem(RBX, 0)
    }) == [0xFF, 0x03])
    expect(emit(fn(a: Asm) {
        a.imul(RAX, RCX)
    }) == [0x48, 0x0F, 0xAF, 0xC1])
    expect(emit(fn(a: Asm) {
        a.imul_load(RAX, RBP, -8)
    }) == [0x48, 0x0F, 0xAF, 0x45, 0xF8])
    expect(emit(fn(a: Asm) {
        a.imul_imm(RAX, RAX, 10)
    }) == [0x48, 0x6B, 0xC0, 0x0A])
    expect(emit(fn(a: Asm) {
        a.imul_imm(RAX, RCX, 1000)
    }) == [0x48, 0x69, 0xC1, 0xE8, 0x03, 0, 0])
    expect(emit(fn(a: Asm) {
        a.imul_wide(RCX)
    }) == [0x48, 0xF7, 0xE9])
    expect(emit(fn(a: Asm) {
        a.neg(RAX)
    }) == [0x48, 0xF7, 0xD8])
    expect(emit(fn(a: Asm) {
        a.idiv(RCX)
    }) == [0x48, 0xF7, 0xF9])
    expect(emit(fn(a: Asm) {
        a.shift(SHIFT_LEFT, RAX, 3)
    }) == [0x48, 0xC1, 0xE0, 0x03])
    expect(emit(fn(a: Asm) {
        a.shift(SHIFT_RIGHT, RCX, 61)
    }) == [0x48, 0xC1, 0xE9, 0x3D])
    expect(emit(fn(a: Asm) {
        a.shift(SHIFT_RIGHT_SIGNED, RDX, 2)
    }) == [0x48, 0xC1, 0xFA, 0x02])
    expect(emit(fn(a: Asm) {
        a.call_reg(RAX)
    }) == [0xFF, 0xD0])
    expect(emit(fn(a: Asm) {
        a.call_mem(R15, 8)
    }) == [0x41, 0xFF, 0x57, 0x08])
    expect(emit(fn(a: Asm) {
        a.lea_mem(RCX, RSP, 48)
    }) == [0x48, 0x8D, 0x4C, 0x24, 0x30])
    expect(emit(fn(a: Asm) {
        a.load_at(R9, RSI, RCX, -8, true)
    }) == [0x4C, 0x8B, 0x4C, 0x0E, 0xF8])
    expect(emit(fn(a: Asm) {
        a.store_at(RDI, RCX, -8, R9, true)
    }) == [0x4C, 0x89, 0x4C, 0x0F, 0xF8])
    expect(emit(fn(a: Asm) {
        a.load_at(R9, RSI, RCX, -4, false)
    }) == [0x44, 0x8B, 0x4C, 0x0E, 0xFC])
    expect(emit(fn(a: Asm) {
        a.store_at(RDI, RCX, -4, R9, false)
    }) == [0x44, 0x89, 0x4C, 0x0F, 0xFC])
}

check "float instructions" {
    expect(emit(fn(a: Asm) {
        a.movq_in(XMM0, RAX)
    }) == [0x66, 0x48, 0x0F, 0x6E, 0xC0])
    expect(emit(fn(a: Asm) {
        a.movq_in(XMM1, RCX)
    }) == [0x66, 0x48, 0x0F, 0x6E, 0xC9])
    expect(emit(fn(a: Asm) {
        a.movq_in(XMM1, R12)
    }) == [0x66, 0x49, 0x0F, 0x6E, 0xCC])
    expect(emit(fn(a: Asm) {
        a.movq_out(RAX, XMM0)
    }) == [0x66, 0x48, 0x0F, 0x7E, 0xC0])
    expect(emit(fn(a: Asm) {
        a.movq_out(R8, XMM1)
    }) == [0x66, 0x49, 0x0F, 0x7E, 0xC8])
    expect(emit(fn(a: Asm) {
        a.sse(SSE_ADD, XMM0, XMM1)
    }) == [0xF2, 0x0F, 0x58, 0xC1])
    expect(emit(fn(a: Asm) {
        a.sse(SSE_SUB, XMM0, XMM1)
    }) == [0xF2, 0x0F, 0x5C, 0xC1])
    expect(emit(fn(a: Asm) {
        a.sse(SSE_MUL, XMM0, XMM1)
    }) == [0xF2, 0x0F, 0x59, 0xC1])
    expect(emit(fn(a: Asm) {
        a.sse(SSE_DIV, XMM0, XMM1)
    }) == [0xF2, 0x0F, 0x5E, 0xC1])
    expect(emit(fn(a: Asm) {
        a.sse(SSE_SQRT, XMM0, XMM0)
    }) == [0xF2, 0x0F, 0x51, 0xC0])
    expect(emit(fn(a: Asm) {
        a.sse_load(SSE_ADD, XMM0, RBP, -16)
    }) == [0xF2, 0x0F, 0x58, 0x45, 0xF0])
    expect(emit(fn(a: Asm) {
        a.sse_load(SSE_MUL, XMM0, R15, 4104)
    }) == [0xF2, 0x41, 0x0F, 0x59, 0x87, 0x08, 0x10, 0, 0])
    expect(emit(fn(a: Asm) {
        a.sse_load(SSE_SUB, XMM1, RSP, 0)
    }) == [0xF2, 0x0F, 0x5C, 0x0C, 0x24])
    expect(emit(fn(a: Asm) {
        a.sse_load(SSE_MOV, XMM0, RBP, -8)
    }) == [0xF2, 0x0F, 0x10, 0x45, 0xF8])
    expect(emit(fn(a: Asm) {
        a.sse_store(RBP, -8, XMM0)
    }) == [0xF2, 0x0F, 0x11, 0x45, 0xF8])
    expect(emit(fn(a: Asm) {
        a.sse(SSE_MOV, 3, XMM0)
    }) == [0x0F, 0x28, 0xD8])
    expect(emit(fn(a: Asm) {
        a.ucomisd(XMM0, XMM1)
    }) == [0x66, 0x0F, 0x2E, 0xC1])
    expect(emit(fn(a: Asm) {
        a.ucomisd(XMM1, XMM0)
    }) == [0x66, 0x0F, 0x2E, 0xC8])
    expect(emit(fn(a: Asm) {
        a.cvtsi2sd(XMM0, RAX)
    }) == [0xF2, 0x48, 0x0F, 0x2A, 0xC0])
    expect(emit(fn(a: Asm) {
        a.cvtsi2sd(XMM1, RCX)
    }) == [0xF2, 0x48, 0x0F, 0x2A, 0xC9])
    expect(emit(fn(a: Asm) {
        a.cvttsd2si(RAX, XMM0)
    }) == [0xF2, 0x48, 0x0F, 0x2C, 0xC0])
    expect(emit(fn(a: Asm) {
        a.pxor(XMM0, XMM0)
    }) == [0x66, 0x0F, 0xEF, 0xC0])
    expect(emit(fn(a: Asm) {
        a.shift_cl(SHIFT_LEFT, RAX)
    }) == [0x48, 0xD3, 0xE0])
    expect(emit(fn(a: Asm) {
        a.shift_cl(SHIFT_RIGHT, RAX)
    }) == [0x48, 0xD3, 0xE8])
    expect(emit(fn(a: Asm) {
        a.shift_cl(SHIFT_RIGHT_SIGNED, RAX)
    }) == [0x48, 0xD3, 0xF8])
    expect(emit(fn(a: Asm) {
        a.alu(ALU_OR, RAX, RCX)
    }) == [0x48, 0x09, 0xC8])
}
check "short jumps" {
    var a = new_asm()
    var above = a.jcc_short(CC_A)
    var parity = a.jcc_short(CC_P)
    a.bind_short(parity)
    a.bind_short(above)
    expect(a.buf == [0x77, 0x02, 0x7A, 0x00])

    a = new_asm()
    var jump = a.jcc_short(CC_L)
    a.inc32_mem(RAX, 0)
    a.bind_short(jump)
    expect(a.buf == [0x7C, 0x02, 0xFF, 0x00])

    a = new_asm()
    var top = a.pos()
    a.inc32_mem(RAX, 0)
    a.jcc_back(CC_NE, top)
    expect(a.buf == [0xFF, 0x00, 0x75, 0xFC])
}

check "labels" {
    var a = new_asm()
    var start = a.new_label()
    var end = a.new_label()
    a.bind(start)
    a.jmp(end)
    a.call(start)
    a.bind(end)
    a.address(start)
    a.lea(RAX, end)
    var image = a.finish(0x400078)
    // jmp +5 (to the end), call -10 (back to the start), the address 0x400078,
    // then the distance from the end of `lea` back to `end`.
    expect(image == [0xE9, 5, 0, 0, 0, 0xE8, 0xF6, 0xFF, 0xFF, 0xFF, 0x78, 0, 0x40, 0, 0, 0, 0, 0, 0x48, 0x8D, 0x05, 0xF1, 0xFF, 0xFF, 0xFF])
}
