// Checks of the code generator's arithmetic helpers. They need exact 64-bit
// integers: run them on the native target,
//
//     onyx test --target native compiler/gen.ox

check "unsigned division" {
    expect(udiv(100, 7) == 14 && urem(100, 7) == 2)
    // 2^63 and 2^64 - 1, read as unsigned numbers.
    expect(udiv(0x8000000000000000, 3) == 0x2AAAAAAAAAAAAAAA)
    expect(urem(0x8000000000000000, 3) == 2)
    expect(udiv(-1, 10) == 0x1999999999999999 && urem(-1, 10) == 5)
    expect(udiv(-1, -1) == 1 && udiv(5, -1) == 0)
    expect(below(1, -1) && !below(-1, 1))
}

// The magic numbers of Hacker's Delight, "Signed division by constants".
check "division by constants" {
    expect(magic_number(3) == [0x5555555555555556, 0])
    expect(magic_number(5) == [0x6666666666666667, 1])
    expect(magic_number(7) == [0x4924924924924925, 1])
    expect(magic_number(10) == [0x6666666666666667, 2])
    expect(magic_number(1000) == [0x20C49BA5E353F7CF, 7])
    expect(magic_number(-5) == [0x9999999999999999, 1])
    expect(magic_number(-7) == [0xB6DB6DB6DB6DB6DB, 1])
    expect(magic_number(641) == [0x663D80FF99C27F01, 8])
    expect(magic_number(123456789) == [0x8B282D5413070D29, 26])
    expect(magic_number(2147483647) == [0x8000000100000003, 30])
}

check "bits" {
    expect(as_i32(0xFFFFFFFF) == -1 && as_i32(0x1_0000_0005) == 5 && as_i32(-3) == -3)
    expect(is_power_of_two(64) && !is_power_of_two(96) && is_power_of_two(0x8000000000000000))
    expect(trailing_zeros(1) == 0 && trailing_zeros(48) == 4 && trailing_zeros(0x8000000000000000) == 63)
}
