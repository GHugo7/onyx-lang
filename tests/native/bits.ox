// Operations on bits, characters as numbers, strings and files as bytes.

fn hex(n: int) -> string {
    var digits = "0123456789abcdef"
    if n == 0 {
        return "0"
    }
    var out = ""
    var rest = n
    while rest > 0 {
        out = digits[rest & 15] + out
        rest = rest >> 4
    }
    return out
}

// The checksum CRC-32, bit by bit.
fn crc32(data: [int]) -> int {
    var crc = 4294967295
    for byte in data {
        crc = crc ^ byte
        for i in 0..8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 3988292384
            } else {
                crc = crc >> 1
            }
        }
    }
    return crc ^ 4294967295
}

fn little_endian(n: int, size: int) -> [int] {
    var out: [int] = []
    for i in 0..size {
        out.push((n >> (8 * i)) & 255)
    }
    return out
}

fn main() {
    var a = 12
    var b = 10
    print(a & b, a | b, a ^ b, ~a, a << 3, a >> 2, -a >> 1, 1 << 40)
    print(a & 3 + 1, a | 1 << 4, 2 + 3 & 4, a ^ b ^ b, (a | b) & ~b, 5 & -2, -1 ^ 0)
    print(6 & 3 == 2, 1 | 2 == 3, a >> 1 > 5, 1 << 2 + 1, 255 & 15 << 4)
    print(hex(255), hex(4096), hex(3735928559), hex(0), hex(1 << 52))
    print(bit_and(12, 10), shift_left(1, 10), shift_right(-16, 2), bit_not(0))
    var flags = 0
    for bit in [0, 3, 5] {
        flags = flags | 1 << bit
    }
    print(flags, flags & 8 != 0, flags & 4 != 0, flags >> 3 & 1)

    // characters
    print(ord("A"), ord("é"), ord("日"), ord("abc"), chr(97), chr(233), chr(26085), ord(chr(128512)))
    var shifted = ""
    for c in "Hello, World" {
        var code = ord(c)
        if code >= 97 && code <= 122 {
            shifted += chr(97 + (code - 97 + 13) % 26)
        } else if code >= 65 && code <= 90 {
            shifted += chr(65 + (code - 65 + 13) % 26)
        } else {
            shifted += c
        }
    }
    print(shifted, chr(ord("x") + 1), ord(chr(8364)) == 8364)

    // bytes
    print(bytes("abc"), bytes("é日"), bytes(""), bytes("hé").len())
    print(crc32(bytes("123456789")), hex(crc32(bytes("123456789"))), crc32(bytes("")))
    print(little_endian(258, 4), little_endian(-1, 2), little_endian(1 << 32, 8))

    // binary files
    var path = "/tmp/onyx-bits-test.bin"
    var data = [0, 255, 10, 13, 127, 128, 200, 65]
    write_bytes(path, data) catch err {
        print("cannot write:", err)
        return
    }
    var back = read_bytes(path) or []
    print(back, back == data, (read_file(path) or "").len() > 0)
    write_bytes(path, [72, 105, 10]) catch err {
        print(err)
    }
    print(read_file(path) or "?", read_bytes("/no/such/file") or [-1])
}
