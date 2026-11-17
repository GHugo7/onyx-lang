// The ways of writing a number.
fn main() {
    print(42, -7, 1_000_000, 0xFF, 0x7fff_ffff, 0b1010, 0b1000_0000)
    print(0xFFFFFFFFFFFFFFFF, 0x8000_0000_0000_0000 < 0, 0x00ff & 0x0f0, 0b1 << 40)
    print(3.14, 1.5e3, 2.5e-1, 6.02e23 > 1.0e23, 1_000.5)
}
