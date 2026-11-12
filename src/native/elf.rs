//! Writes a static ELF64 executable for Linux x86-64: a header, two program
//! headers and one read+execute segment holding the code and its constants.

const BASE: u64 = 0x40_0000;
const EHDR_SIZE: u64 = 64;
const PHDR_SIZE: u64 = 56;
const PHDR_COUNT: u64 = 2;

/// Address at which the first byte of the image (right after the headers) is loaded.
pub const IMAGE_BASE: u64 = BASE + EHDR_SIZE + PHDR_SIZE * PHDR_COUNT;

/// `image` is the code buffer; `entry` is the offset of the first instruction in it.
pub fn write(image: &[u8], entry: usize) -> Vec<u8> {
    let headers = EHDR_SIZE + PHDR_SIZE * PHDR_COUNT;
    let total = headers + image.len() as u64;
    let mut out = Vec::with_capacity(total as usize);

    // ELF header
    out.extend_from_slice(&[0x7F, b'E', b'L', b'F', 2, 1, 1, 0]); // 64-bit, little endian, SysV
    out.extend_from_slice(&[0; 8]);
    out.extend_from_slice(&2u16.to_le_bytes()); // e_type: executable
    out.extend_from_slice(&0x3Eu16.to_le_bytes()); // e_machine: x86-64
    out.extend_from_slice(&1u32.to_le_bytes()); // e_version
    out.extend_from_slice(&(BASE + headers + entry as u64).to_le_bytes()); // e_entry
    out.extend_from_slice(&EHDR_SIZE.to_le_bytes()); // e_phoff
    out.extend_from_slice(&0u64.to_le_bytes()); // e_shoff
    out.extend_from_slice(&0u32.to_le_bytes()); // e_flags
    out.extend_from_slice(&(EHDR_SIZE as u16).to_le_bytes()); // e_ehsize
    out.extend_from_slice(&(PHDR_SIZE as u16).to_le_bytes()); // e_phentsize
    out.extend_from_slice(&(PHDR_COUNT as u16).to_le_bytes()); // e_phnum
    out.extend_from_slice(&64u16.to_le_bytes()); // e_shentsize
    out.extend_from_slice(&0u16.to_le_bytes()); // e_shnum
    out.extend_from_slice(&0u16.to_le_bytes()); // e_shstrndx

    // PT_LOAD: the whole file, readable and executable
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&5u32.to_le_bytes()); // R + X
    out.extend_from_slice(&0u64.to_le_bytes()); // offset
    out.extend_from_slice(&BASE.to_le_bytes()); // vaddr
    out.extend_from_slice(&BASE.to_le_bytes()); // paddr
    out.extend_from_slice(&total.to_le_bytes()); // filesz
    out.extend_from_slice(&total.to_le_bytes()); // memsz
    out.extend_from_slice(&0x1000u64.to_le_bytes()); // align

    // PT_GNU_STACK: the stack is not executable
    out.extend_from_slice(&0x6474_E551u32.to_le_bytes());
    out.extend_from_slice(&6u32.to_le_bytes()); // R + W
    out.extend_from_slice(&[0; 40]);
    out.extend_from_slice(&0x10u64.to_le_bytes());

    out.extend_from_slice(image);
    out
}
