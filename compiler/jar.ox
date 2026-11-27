// Writes .jar files: ZIP archives (here with their files stored as they
// are, without compression) whose META-INF/MANIFEST.MF says what to run.

// ---- CRC-32, the checksum ZIP keeps for each file ----

fn crc_table() -> [int] {
    var table: [int] = []
    for n in 0..256 {
        var c = n
        for _ in 0..8 {
            if c & 1 == 1 {
                c = 0xEDB88320 ^ c >> 1
            } else {
                c = c >> 1
            }
        }
        table.push(c)
    }
    return table
}

fn crc32(data: [int]) -> int {
    var table = crc_table()
    var c = 0xFFFFFFFF
    for b in data {
        c = table[(c ^ b) & 0xFF] ^ c >> 8
    }
    return c ^ 0xFFFFFFFF
}

// ---- little-endian numbers, as ZIP writes them ----

fn put_le2(out: [int], v: int) {
    out.push(v & 0xFF)
    out.push(v >> 8 & 0xFF)
}

fn put_le4(out: [int], v: int) {
    out.push(v & 0xFF)
    out.push(v >> 8 & 0xFF)
    out.push(v >> 16 & 0xFF)
    out.push(v >> 24 & 0xFF)
}

struct JarFile {
    name: string
    data: [int]
}

struct Jar {
    files: [JarFile]

    fn add(self, name: string, data: [int]) {
        self.files.push(JarFile{name: name, data: data})
    }

    // The archive. Every file gets the same date (1 January 1980), so that
    // the same program always gives the same bytes.
    fn bytes(self) -> [int] {
        var out: [int] = []
        var directory: [int] = []
        for f in self.files {
            var name = bytes(f.name)
            var crc = crc32(f.data)
            var offset = out.len()
            // The local header, then the data.
            put_le4(out, 0x04034B50)
            put_le2(out, 10)            // version needed: 1.0
            put_le2(out, 0x0800)        // the name is in UTF-8
            put_le2(out, 0)             // stored
            put_le2(out, 0)             // time
            put_le2(out, 0x21)          // date: 1980-01-01
            put_le4(out, crc)
            put_le4(out, f.data.len())
            put_le4(out, f.data.len())
            put_le2(out, name.len())
            put_le2(out, 0)
            for b in name {
                out.push(b)
            }
            for b in f.data {
                out.push(b)
            }
            // Its entry in the central directory.
            put_le4(directory, 0x02014B50)
            put_le2(directory, 20)      // made by: 2.0
            put_le2(directory, 10)
            put_le2(directory, 0x0800)
            put_le2(directory, 0)
            put_le2(directory, 0)
            put_le2(directory, 0x21)
            put_le4(directory, crc)
            put_le4(directory, f.data.len())
            put_le4(directory, f.data.len())
            put_le2(directory, name.len())
            put_le2(directory, 0)       // extra field
            put_le2(directory, 0)       // comment
            put_le2(directory, 0)       // disk
            put_le2(directory, 0)       // internal attributes
            put_le4(directory, 0)       // external attributes
            put_le4(directory, offset)
            for b in name {
                directory.push(b)
            }
        }
        var start = out.len()
        for b in directory {
            out.push(b)
        }
        put_le4(out, 0x06054B50)
        put_le2(out, 0)
        put_le2(out, 0)
        put_le2(out, self.files.len())
        put_le2(out, self.files.len())
        put_le4(out, directory.len())
        put_le4(out, start)
        put_le2(out, 0)
        return out
    }
}

// A jar whose program starts in the class `main_class` (`a/b/Main`).
fn new_jar(main_class: string) -> Jar {
    var jar = Jar{files: []}
    var manifest = "Manifest-Version: 1.0\r\nMain-Class: " + main_class.replace("/", ".") + "\r\nCreated-By: Onyx\r\n\r\n"
    jar.add("META-INF/MANIFEST.MF", bytes(manifest))
    return jar
}
