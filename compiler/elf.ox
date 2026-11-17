// Writes a static ELF64 executable for Linux x86-64: a header, two program
// headers and one read+execute segment holding the code and its constants.
//
// Follows src/native/elf.rs.

const BASE = 0x40_0000
const EHDR_SIZE = 64
const PHDR_SIZE = 56
const PHDR_COUNT = 2

// Address at which the first byte of the image (right after the headers) is loaded.
const IMAGE_BASE = BASE + EHDR_SIZE + PHDR_SIZE * PHDR_COUNT

// `n` as `size` bytes, lowest first.
fn put(out: [int], n: int, size: int) {
    for i in 0..size {
        out.push(n >> (8 * i) & 0xFF)
    }
}

// `image` is the code buffer; `entry` is the position of the first instruction in it.
fn write(image: [int], entry: int) -> [int] {
    var headers = EHDR_SIZE + PHDR_SIZE * PHDR_COUNT
    var total = headers + image.len()
    var out: [int] = []

    // ELF header: 64-bit, little endian, System V.
    for b in [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] {
        out.push(b)
    }
    put(out, 0, 8)
    put(out, 2, 2)                          // e_type: executable
    put(out, 0x3E, 2)                       // e_machine: x86-64
    put(out, 1, 4)                          // e_version
    put(out, BASE + headers + entry, 8)     // e_entry
    put(out, EHDR_SIZE, 8)                  // e_phoff
    put(out, 0, 8)                          // e_shoff
    put(out, 0, 4)                          // e_flags
    put(out, EHDR_SIZE, 2)                  // e_ehsize
    put(out, PHDR_SIZE, 2)                  // e_phentsize
    put(out, PHDR_COUNT, 2)                 // e_phnum
    put(out, 64, 2)                         // e_shentsize
    put(out, 0, 2)                          // e_shnum
    put(out, 0, 2)                          // e_shstrndx

    // PT_LOAD: the whole file, readable and executable.
    put(out, 1, 4)
    put(out, 5, 4)                          // R + X
    put(out, 0, 8)                          // offset
    put(out, BASE, 8)                       // vaddr
    put(out, BASE, 8)                       // paddr
    put(out, total, 8)                      // filesz
    put(out, total, 8)                      // memsz
    put(out, 0x1000, 8)                     // align

    // PT_GNU_STACK: the stack is not executable.
    put(out, 0x6474_E551, 4)
    put(out, 6, 4)                          // R + W
    put(out, 0, 40)
    put(out, 0x10, 8)

    for b in image {
        out.push(b)
    }
    return out
}
