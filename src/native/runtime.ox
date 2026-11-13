// The Onyx native runtime, written in Onyx.
//
// It is compiled together with every native program; only the functions a
// program really needs end up in its executable. They are called by the code
// the compiler generates, and are built on a handful of low-level operations
// that only this file may use:
//
//   __syscall(n, a, b, c, d, e, f)        call the Linux kernel
//   __load8 / __load32 / __load64(addr)   read 1, 4 (signed) or 8 bytes
//   __store8 / __store32 / __store64(addr, v)
//   __copy(dst, src, n)                   copy n bytes
//   __and(a, b)                           bitwise and
//   __state()                             address of the runtime's private memory
//   __str_ptr(s) / __ptr_str(p)           view a string as an address and back
//   __td_string()                         type descriptor of `string`
//
// OBJECTS
//
// Every value that lives on the heap (string, list, struct) starts with an
// 8-byte header:
//
//   +0   reference count (32 bits): how many variables, fields and list slots
//        point here. A negative count marks a constant that is never released.
//   +4   address of the type descriptor (32 bits), a table written by the
//        compiler (see below)
//
//   string:  +8 length in bytes (32 bits)   +12 capacity (32 bits)
//            +16 the UTF-8 bytes
//   list:    +8 length   +16 capacity   +24 address of the elements (8 bytes each)
//   struct:  +8 first field, +16 second field, ...
//   map:     see "maps" below
//
// TYPE DESCRIPTORS (8-byte words)
//
//   +0 kind:  0 int   1 bool   2 float   3 string   4 list   5 struct   6 interface
//             7 map
//   list:     +8 descriptor of the elements
//   map:      +8 descriptor of the keys   +16 descriptor of the values
//   struct:   +8 name   +16 number of fields   +24 method table
//             then for each field: its name, its descriptor
//   method table: +0 count, then for each method: its name, its address
//
// Kinds 3 and above are references. An interface value is the object itself;
// its real type is read from the object's header.
//
// OWNERSHIP
//
// A function only borrows its parameters: the caller keeps them alive for the
// duration of the call. A returned reference belongs to the caller. The
// functions below say so when they deviate (a value that moves into a list,
// a string that is given away to be extended).

// ---- layout constants ----

const __KIND_STRING = 3
const __KIND_LIST = 4
const __KIND_MAP = 7

// The runtime's private memory, at __state():
const __S_END = 8          // end of the current chunk (its next free byte is at +0)
const __S_LIVE = 16        // number of live objects
const __S_OUT = 24         // address of the output buffer
const __S_OUT_USED = 32    // bytes waiting in it
const __S_TERMINAL = 40    // 1 when standard output is a terminal, 2 when it is not
const __S_CHARS = 48       // address of the 128 one-character ASCII strings, once made
const __S_FREE = 56        // free blocks of n bytes are chained from __S_FREE + n

const __S_SCRATCH = 1088   // address of the working memory of float conversions, once made
const __S_RANDOM = 1096    // state of the random number generator

const __SMALL = 1024       // blocks up to this size come from chunks
const __CHUNK = 1048576
const __OUT_SIZE = 65536

// ---- memory ----
//
// Blocks carry no header: whoever frees one says how big it was. Sizes are
// rounded up to 8 bytes. Small blocks are carved from 1 MiB chunks and
// recycled through one free list per size; big ones get their own mapping
// and go back to the kernel.

fn __rt_map(size: int) -> int {
    // mmap(NULL, size, READ | WRITE, PRIVATE | ANONYMOUS, -1, 0)
    var p = __syscall(9, 0, size, 3, 34, -1, 0)
    if p < 0 && p > -4096 {
        __rt_fatal("out of memory")
    }
    return p
}

// The real size of a block that holds `size` bytes.
fn __rt_round(size: int) -> int {
    if size <= __SMALL {
        return (size + 7) / 8 * 8
    }
    return (size + 4095) / 4096 * 4096
}

// A block that no free list could provide: big ones get their own mapping,
// small ones are carved from the current chunk.
fn __rt_carve(size: int) -> int {
    if size > __SMALL {
        return __rt_map((size + 4095) / 4096 * 4096)
    }
    var state = __state()
    var block = __load64(state)
    if block + size > __load64(state + __S_END) {
        block = __rt_map(__CHUNK)
        __store64(state + __S_END, block + __CHUNK)
    }
    __store64(state, block + size)
    return block
}

// `size` must be a multiple of 8, or bigger than __SMALL.
fn __rt_alloc(size: int) -> int {
    if size <= __SMALL {
        // Reuse a freed block; its first word links to the next free one.
        var slot = __state() + __S_FREE + size
        var block = __load64(slot)
        if block != 0 {
            __store64(slot, __load64(block))
            return block
        }
    }
    return __rt_carve(size)
}

// `size` is what was given to __rt_alloc.
fn __rt_free(p: int, size: int) {
    if size > __SMALL {
        __syscall(11, p, (size + 4095) / 4096 * 4096, 0, 0, 0, 0)    // munmap
        return
    }
    var slot = __state() + __S_FREE + size
    __store64(p, __load64(slot))
    __store64(slot, p)
}

// ---- objects and reference counting ----

// Allocates an object of `size` bytes (header included), owned by the caller.
// This is __rt_alloc plus the header, in one function because every object
// goes through here.
fn __rt_new(td: int, size: int) -> int {
    var state = __state()
    var p = 0
    if size <= __SMALL {
        var slot = state + __S_FREE + size
        p = __load64(slot)
        if p != 0 {
            __store64(slot, __load64(p))
        }
    }
    if p == 0 {
        p = __rt_carve(size)
    }
    __store32(p, 1)
    __store32(p + 4, td)
    __store64(state + __S_LIVE, __load64(state + __S_LIVE) + 1)
    return p
}

fn __rt_retain(p: int) {
    var count = __load32(p)
    if count >= 0 {
        __store32(p, count + 1)
    }
}

fn __rt_release(p: int) {
    var count = __load32(p)
    if count > 1 {
        __store32(p, count - 1)
    } else if count == 1 {
        __rt_destroy(p)
    }
}

// Called when the last reference to an object goes away: lets go of what the
// object holds, then frees it.
fn __rt_destroy(p: int) {
    var td = __load32(p + 4)
    var kind = __load64(td)
    var size = 0
    if kind == __KIND_STRING {
        size = 16 + __load32(p + 12)
    } else if kind == __KIND_LIST {
        var data = __load64(p + 24)
        if data != 0 {
            if __load64(__load64(td + 8)) >= 3 {
                var n = __load64(p + 8)
                var i = 0
                while i < n {
                    __rt_release(__load64(data + i * 8))
                    i += 1
                }
            }
            __rt_free(data, __load64(p + 16) * 8)
        }
        size = 32
    } else if kind == __KIND_MAP {
        __rt_map_clear(p)
        if __load64(p + 32) != 0 {
            __rt_free(__load64(p + 32), __load64(p + 24) * 24)
            __rt_free(__load64(p + 48), __load64(p + 40) * 8)
        }
        size = 56
    } else {
        var n = __load64(td + 16)
        var i = 0
        while i < n {
            if __load64(__load64(td + 40 + i * 16)) >= 3 {
                __rt_release(__load64(p + 8 + i * 8))
            }
            i += 1
        }
        size = 8 + n * 8
    }
    var state = __state()
    __store64(state + __S_LIVE, __load64(state + __S_LIVE) - 1)
    if size <= __SMALL {
        // The block goes to the front of the free list of its size.
        var slot = state + __S_FREE + size
        __store64(p, __load64(slot))
        __store64(slot, p)
    } else {
        __rt_free(p, size)
    }
}

// Used by `--leak-check`: every object must have been released by now.
fn __rt_leak_check() {
    var live = __load64(__state() + __S_LIVE)
    if live != 0 {
        __rt_flush()
        __rt_write(2, "leak check: " + __rt_int_str(live) + " object(s) were never released\n")
        __rt_exit(3)
    }
}

// The address of the method called `name` (a constant string, compared by
// address) of the object's type.
fn __rt_find_method(obj: int, name: int) -> int {
    var table = __load64(__load32(obj + 4) + 24)
    var n = __load64(table)
    var i = 0
    while i < n {
        if __load64(table + 8 + i * 16) == name {
            return __load64(table + 16 + i * 16)
        }
        i += 1
    }
    __rt_fatal("method not found")
    return 0
}

// ---- strings ----

// A new string with room for `len` bytes; its content is left to the caller.
fn __rt_new_str(len: int) -> int {
    if len > 2000000000 {
        __rt_fatal("string too long")
    }
    var total = (len + 23) / 8 * 8
    if total > __SMALL {
        total = __rt_round(total)
    }
    var p = __rt_new(__td_string(), total)
    __store32(p + 8, len)
    __store32(p + 12, total - 16)
    return p
}

fn __rt_concat(a: string, b: string) -> string {
    var pa = __str_ptr(a)
    var pb = __str_ptr(b)
    var la = __load32(pa + 8)
    var lb = __load32(pb + 8)
    var p = __rt_new_str(la + lb)
    __copy(p + 16, pa + 16, la)
    __copy(p + 16 + la, pb + 16, lb)
    return __ptr_str(p)
}

// Joins `n` strings whose addresses sit on the stack, the last one at
// `pieces` and the first one at `pieces + 8 * (n - 1)`.
fn __rt_concat_n(pieces: int, n: int) -> string {
    var total = 0
    var i = 0
    while i < n {
        total += __load32(__load64(pieces + i * 8) + 8)
        i += 1
    }
    var p = __rt_new_str(total)
    var at = p + 16
    i = n - 1
    while i >= 0 {
        var piece = __load64(pieces + i * 8)
        var len = __load32(piece + 8)
        __copy(at, piece + 16, len)
        at += len
        i -= 1
    }
    return __ptr_str(p)
}

// `a + b` for `a += b`: the caller gives `a` away and gets the result back.
// When nobody else holds `a` and it has room left, `b` is copied at its end
// and no memory is allocated. Otherwise the new string gets twice the room
// it needs, so that a long series of appends stays cheap.
fn __rt_append(a: int, b: int) -> int {
    var la = __load32(a + 8)
    var lb = __load32(b + 8)
    var total = la + lb
    if __load32(a) == 1 && total <= __load32(a + 12) {
        __copy(a + 16 + la, b + 16, lb)
        __store32(a + 8, total)
        return a
    }
    var room = la * 2
    if room < total {
        room = total
    }
    var p = __rt_new_str(room)
    __store32(p + 8, total)
    __copy(p + 16, a + 16, la)
    __copy(p + 16 + la, b + 16, lb)
    __rt_release(a)
    return p
}

// ---- characters ----
//
// Positions and lengths are counted in characters, not bytes. In UTF-8 a
// character takes one to four bytes: the first one tells how many, and the
// following ones all look like 10xxxxxx.

// Number of characters in the `n` bytes at `at`.
fn __rt_chars_in(at: int, n: int) -> int {
    var i = 0
    // Eight bytes at a time while they are all plain ASCII (high bit clear):
    // -9187201950435737472 is 0x8080808080808080.
    while i + 8 <= n && __and(__load64(at + i), -9187201950435737472) == 0 {
        i += 8
    }
    var count = i
    while i < n {
        var byte = __load8(at + i)
        if byte < 128 || byte >= 192 {
            count += 1
        }
        i += 1
    }
    return count
}

fn __rt_str_len(s: string) -> int {
    var p = __str_ptr(s)
    return __rt_chars_in(p + 16, __load32(p + 8))
}

// Bytes taken by the character whose first byte is `lead`.
fn __rt_char_size(lead: int) -> int {
    if lead < 192 {
        return 1
    }
    if lead < 224 {
        return 2
    }
    if lead < 240 {
        return 3
    }
    return 4
}

// Bytes taken by the first `count` characters of the `n` bytes at `at`;
// -1 when there are fewer characters than that.
fn __rt_skip(at: int, n: int, count: int) -> int {
    var i = 0
    var left = count
    while left >= 8 && i + 8 <= n && __and(__load64(at + i), -9187201950435737472) == 0 {
        i += 8
        left -= 8
    }
    while left > 0 {
        if i >= n {
            return -1
        }
        i += __rt_char_size(__load8(at + i))
        left -= 1
    }
    if i > n {
        return n
    }
    return i
}

// A new string made of the bytes `from` to `to` of the string at `p`.
fn __rt_str_part(p: int, from: int, to: int) -> int {
    var out = __rt_new_str(to - from)
    __copy(out + 16, p + 16 + from, to - from)
    return out
}

// The character that starts at byte `at` of the string at `p`, as a string.
// The 128 ASCII characters are constants made once, on first use, so walking
// through ordinary text allocates nothing.
fn __rt_char_at(p: int, at: int) -> int {
    var byte = __load8(p + 16 + at)
    if byte >= 128 {
        var to = at + __rt_char_size(byte)
        if to > __load32(p + 8) {
            to = __load32(p + 8)
        }
        return __rt_str_part(p, at, to)
    }
    var state = __state()
    var table = __load64(state + __S_CHARS)
    if table == 0 {
        table = __rt_alloc(3072)
        var c = 0
        while c < 128 {
            var entry = table + c * 24
            __store32(entry, -1)
            __store32(entry + 4, __td_string())
            __store32(entry + 8, 1)
            __store32(entry + 12, 8)
            __store64(entry + 16, c)
            c += 1
        }
        __store64(state + __S_CHARS, table)
    }
    return table + byte * 24
}

// `s[i]`
fn __rt_str_index(s: string, i: int) -> string {
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    var at = -1
    if i >= 0 {
        at = __rt_skip(p + 16, n, i)
    }
    if at < 0 || at >= n {
        __rt_panic("index out of bounds: index " + __rt_int_str(i) + ", length " + __rt_int_str(__rt_str_len(s)))
    }
    return __ptr_str(__rt_char_at(p, at))
}

// ---- string methods ----

fn __rt_str_slice(s: string, from: int, to: int) -> string {
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    var count = __rt_chars_in(p + 16, n)
    var start = __rt_clamp_index(from, count)
    var end = __rt_clamp_index(to, count)
    if end <= start {
        return ""
    }
    if start == 0 && end == count {
        return s
    }
    if count != n {
        // Some characters take several bytes: find where these two start.
        var first = __rt_skip(p + 16, n, start)
        end = first + __rt_skip(p + 16 + first, n - first, end - start)
        start = first
    }
    return __ptr_str(__rt_str_part(p, start, end))
}

// Whether the `n` bytes at `a` and at `b` are the same.
fn __rt_same(a: int, b: int, n: int) -> bool {
    var i = 0
    while i + 8 <= n && __load64(a + i) == __load64(b + i) {
        i += 8
    }
    while i < n {
        if __load8(a + i) != __load8(b + i) {
            return false
        }
        i += 1
    }
    return true
}

// Where the `m` bytes at `q` first appear in the `n` bytes at `at`, looking
// from byte `start` on; -1 when they do not.
fn __rt_find(at: int, n: int, q: int, m: int, start: int) -> int {
    if m == 0 {
        return start
    }
    var first = __load8(q)
    var last = n - m
    var i = start
    while i <= last {
        if __load8(at + i) == first && __rt_same(at + i, q, m) {
            return i
        }
        i += 1
    }
    return -1
}

fn __rt_str_index_of(s: string, needle: string) -> int {
    var p = __str_ptr(s)
    var q = __str_ptr(needle)
    var at = __rt_find(p + 16, __load32(p + 8), q + 16, __load32(q + 8), 0)
    if at <= 0 {
        return at
    }
    return __rt_chars_in(p + 16, at)
}

fn __rt_str_contains(s: string, needle: string) -> bool {
    var p = __str_ptr(s)
    var q = __str_ptr(needle)
    return __rt_find(p + 16, __load32(p + 8), q + 16, __load32(q + 8), 0) >= 0
}

fn __rt_str_starts(s: string, prefix: string) -> bool {
    var p = __str_ptr(s)
    var q = __str_ptr(prefix)
    var m = __load32(q + 8)
    return m <= __load32(p + 8) && __rt_same(p + 16, q + 16, m)
}

fn __rt_str_ends(s: string, suffix: string) -> bool {
    var p = __str_ptr(s)
    var q = __str_ptr(suffix)
    var n = __load32(p + 8)
    var m = __load32(q + 8)
    return m <= n && __rt_same(p + 16 + n - m, q + 16, m)
}

// Every occurrence of `old` becomes `with`. An empty `old` matches between
// all characters and at both ends.
fn __rt_str_replace(s: string, old: string, with: string) -> string {
    var p = __str_ptr(s)
    var q = __str_ptr(old)
    var r = __str_ptr(with)
    var n = __load32(p + 8)
    var m = __load32(q + 8)
    var k = __load32(r + 8)
    if m == 0 {
        var out = __rt_new_str(n + (__rt_chars_in(p + 16, n) + 1) * k)
        var to = out + 16
        __copy(to, r + 16, k)
        to += k
        var i = 0
        while i < n {
            var size = __rt_char_size(__load8(p + 16 + i))
            if i + size > n {
                size = n - i
            }
            __copy(to, p + 16 + i, size)
            to += size
            i += size
            __copy(to, r + 16, k)
            to += k
        }
        return __ptr_str(out)
    }
    // Count first, so that the result is allocated once at its exact size.
    var count = 0
    var at = __rt_find(p + 16, n, q + 16, m, 0)
    while at >= 0 {
        count += 1
        at = __rt_find(p + 16, n, q + 16, m, at + m)
    }
    if count == 0 {
        return s
    }
    var out = __rt_new_str(n + count * (k - m))
    var to = out + 16
    var from = 0
    at = __rt_find(p + 16, n, q + 16, m, 0)
    while at >= 0 {
        __copy(to, p + 16 + from, at - from)
        to += at - from
        __copy(to, r + 16, k)
        to += k
        from = at + m
        at = __rt_find(p + 16, n, q + 16, m, from)
    }
    __copy(to, p + 16 + from, n - from)
    return __ptr_str(out)
}

// The pieces of `s` between the occurrences of `separator`, as a list whose
// descriptor is `td`. An empty separator gives the characters.
fn __rt_str_split(s: string, separator: string, td: int) -> int {
    var p = __str_ptr(s)
    var q = __str_ptr(separator)
    var n = __load32(p + 8)
    var m = __load32(q + 8)
    var out = __rt_list_new(td, 0)
    if m == 0 {
        var i = 0
        while i < n {
            var piece = __rt_char_at(p, i)
            __rt_list_push(out, piece)
            i += __load32(piece + 8)
        }
        return out
    }
    var from = 0
    var at = __rt_find(p + 16, n, q + 16, m, 0)
    while at >= 0 {
        __rt_list_push(out, __rt_str_part(p, from, at))
        from = at + m
        at = __rt_find(p + 16, n, q + 16, m, from)
    }
    __rt_list_push(out, __rt_str_part(p, from, n))
    return out
}

fn __rt_str_chars(s: string, td: int) -> int {
    return __rt_str_split(s, "", td)
}

fn __rt_str_repeat(s: string, times: int) -> string {
    if times < 0 {
        __rt_panic("repeat count cannot be negative")
    }
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    if times == 0 || n == 0 {
        return ""
    }
    if times == 1 {
        return s
    }
    if times > 2000000000 / n {
        __rt_fatal("string too long")
    }
    var out = __rt_new_str(n * times)
    var i = 0
    while i < times {
        __copy(out + 16 + i * n, p + 16, n)
        i += 1
    }
    return __ptr_str(out)
}

// Bytes taken by the white-space character at `at`, where `n` bytes are
// left; 0 when it is something else. Besides the ASCII ones, Unicode has a
// few spaces of two and three bytes.
fn __rt_space_size(at: int, n: int) -> int {
    var c = __load8(at)
    if c == 32 || (c >= 9 && c <= 13) {
        return 1
    }
    if c < 194 || n < 2 {
        return 0
    }
    var d = __load8(at + 1)
    if c == 194 && d == 160 {
        return 2    // U+00A0, the no-break space
    }
    if n < 3 {
        return 0
    }
    var e = __load8(at + 2)
    if c == 226 && d == 128 && ((e >= 128 && e <= 138) || e == 168 || e == 169 || e == 175) {
        return 3    // U+2000 to U+200A, U+2028, U+2029, U+202F
    }
    if (c == 225 && d == 154 && e == 128) || (c == 226 && d == 129 && e == 159) {
        return 3    // U+1680, U+205F
    }
    if (c == 227 && d == 128 && e == 128) || (c == 239 && d == 187 && e == 191) {
        return 3    // U+3000, U+FEFF
    }
    return 0
}

fn __rt_str_trim(s: string) -> string {
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    var from = 0
    while from < n {
        var size = __rt_space_size(p + 16 + from, n - from)
        if size == 0 {
            break
        }
        from += size
    }
    var to = n
    while to > from {
        // Step back to the first byte of the last character.
        var at = to - 1
        while at > from && __and(__load8(p + 16 + at), 192) == 128 {
            at -= 1
        }
        if __rt_space_size(p + 16 + at, to - at) != to - at {
            break
        }
        to = at
    }
    if from == 0 && to == n {
        return s
    }
    return __ptr_str(__rt_str_part(p, from, to))
}

// Upper- and lower-case forms are known for the letters that take one or two
// bytes: the Latin alphabet with its accents, Greek and Cyrillic. They are
// given as character numbers (code points); other characters stay as they are.

fn __rt_upper_code(c: int) -> int {
    if c < 256 {
        if c == 181 {
            return 924          // the micro sign becomes a Greek capital mu
        }
        if c == 255 {
            return 376          // y with diaeresis
        }
        if c >= 224 && c != 247 {
            return c - 32       // a-grave to thorn, except the division sign
        }
        return c
    }
    if c < 384 {
        // Latin Extended-A: capital and small letters alternate.
        if c == 305 {
            return 73           // dotless i
        }
        if c == 383 {
            return 83           // long s
        }
        if c == 312 || c == 329 {
            return c
        }
        if c < 312 || (c >= 330 && c < 376) {
            return c - c % 2    // the small letter is the odd one
        }
        if c % 2 == 0 && c != 376 {
            return c - 1        // the small letter is the even one
        }
        return c
    }
    if c >= 940 && c <= 974 {
        // Greek
        if c == 940 {
            return 902
        }
        if c <= 943 {
            return c - 37
        }
        if c == 944 {
            return c
        }
        if c == 962 {
            return 931          // final sigma
        }
        if c <= 971 {
            return c - 32
        }
        if c == 972 {
            return 908
        }
        return c - 63
    }
    if c >= 1072 && c <= 1103 {
        return c - 32           // Cyrillic
    }
    if c >= 1104 && c <= 1119 {
        return c - 80
    }
    return c
}

fn __rt_lower_code(c: int) -> int {
    if c < 256 {
        if c >= 192 && c <= 222 && c != 215 {
            return c + 32       // A-grave to Thorn, except the multiplication sign
        }
        return c
    }
    if c < 384 {
        if c == 304 || c == 329 || c == 383 {
            return c
        }
        if c == 376 {
            return 255
        }
        if c < 312 || (c >= 330 && c < 376) {
            return c + 1 - c % 2
        }
        if c % 2 == 1 {
            return c + 1
        }
        return c
    }
    if c >= 902 && c <= 939 {
        // Greek
        if c == 902 {
            return 940
        }
        if c >= 904 && c <= 906 {
            return c + 37
        }
        if c == 908 {
            return 972
        }
        if c == 910 || c == 911 {
            return c + 63
        }
        if c >= 913 && c != 930 {
            return c + 32
        }
        return c
    }
    if c >= 1024 && c <= 1039 {
        return c + 80           // Cyrillic
    }
    if c >= 1040 && c <= 1071 {
        return c + 32
    }
    return c
}

fn __rt_str_case(s: string, upper: bool) -> string {
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    // No supported letter grows when its case changes; a few shrink.
    var out = __rt_new_str(n)
    var to = out + 16
    var i = 0
    while i < n {
        var c = __load8(p + 16 + i)
        if c < 128 {
            if upper {
                if c >= 97 && c <= 122 {
                    c -= 32
                }
            } else if c >= 65 && c <= 90 {
                c += 32
            }
            __store8(to, c)
            to += 1
            i += 1
        } else if c >= 194 && c < 224 && i + 1 < n {
            var code = (c - 192) * 64 + __load8(p + 16 + i + 1) - 128
            i += 2
            if upper && code == 223 {
                // The German sharp s becomes two letters.
                __store8(to, 83)
                __store8(to + 1, 83)
                to += 2
            } else {
                if upper {
                    code = __rt_upper_code(code)
                } else {
                    code = __rt_lower_code(code)
                }
                if code < 128 {
                    __store8(to, code)
                    to += 1
                } else {
                    __store8(to, 192 + code / 64)
                    __store8(to + 1, 128 + code % 64)
                    to += 2
                }
            }
        } else {
            var size = __rt_char_size(c)
            if i + size > n {
                size = n - i
            }
            __copy(to, p + 16 + i, size)
            to += size
            i += size
        }
    }
    __store32(out + 8, to - out - 16)
    return __ptr_str(out)
}

fn __rt_str_upper(s: string) -> string {
    return __rt_str_case(s, true)
}

fn __rt_str_lower(s: string) -> string {
    return __rt_str_case(s, false)
}

// Compares two strings byte by byte: negative, zero or positive, like a - b.
fn __rt_bytes_cmp(pa: int, pb: int) -> int {
    var la = __load32(pa + 8)
    var lb = __load32(pb + 8)
    var n = la
    if lb < n {
        n = lb
    }
    // Skip the common start eight bytes at a time.
    var i = 0
    while i + 8 <= n && __load64(pa + 16 + i) == __load64(pb + 16 + i) {
        i += 8
    }
    while i < n {
        var d = __load8(pa + 16 + i) - __load8(pb + 16 + i)
        if d != 0 {
            return d
        }
        i += 1
    }
    return la - lb
}

fn __rt_str_cmp(a: string, b: string) -> int {
    return __rt_bytes_cmp(__str_ptr(a), __str_ptr(b))
}

fn __rt_str_eq(a: string, b: string) -> bool {
    var pa = __str_ptr(a)
    var pb = __str_ptr(b)
    if pa == pb {
        return true
    }
    if __load32(pa + 8) != __load32(pb + 8) {
        return false
    }
    return __rt_bytes_cmp(pa, pb) == 0
}

// Writes `n` in decimal so that its last character is just before `end`;
// returns the address of its first character. Digits are produced two at a
// time, from a table of the hundred two-digit numbers.
fn __rt_int_write(end: int, n: int) -> int {
    var pairs = "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"
    var table = __str_ptr(pairs) + 16
    var at = end
    // Work on the negative side: every int has a negative form, but the
    // smallest one has no positive form.
    var v = n
    if v > 0 {
        v = -v
    }
    while v <= -100 {
        var q = v / 100
        var pair = table + (q * 100 - v) * 2
        at -= 2
        __store8(at, __load8(pair))
        __store8(at + 1, __load8(pair + 1))
        v = q
    }
    if v <= -10 {
        var pair = table - v * 2
        at -= 2
        __store8(at, __load8(pair))
        __store8(at + 1, __load8(pair + 1))
    } else {
        at -= 1
        __store8(at, 48 - v)
    }
    if n < 0 {
        at -= 1
        __store8(at, 45)
    }
    return at
}

fn __rt_int_str(n: int) -> string {
    // No int needs more than 20 characters: write it at the end of that
    // room, then move it to the front.
    var p = __rt_new_str(20)
    var end = p + 36
    var first = __rt_int_write(end, n)
    __copy(p + 16, first, end - first)
    __store32(p + 8, end - first)
    return __ptr_str(p)
}

// The text of `n` as a temporary string built inside `buffer` (40 bytes that
// the caller owns, on its stack), so that showing a number allocates nothing.
// The digits are written at the end of the buffer and the string's header
// right before them; it is marked as a constant, so it is never released.
fn __rt_int_into(buffer: int, n: int) -> int {
    var end = buffer + 40
    var first = __rt_int_write(end, n)
    var s = first - 16
    __store32(s, -1)
    __store32(s + 8, end - first)
    return s
}

// Reads a whole number, with an optional sign and spaces around it.
fn __rt_parse_int(s: string) -> int! {
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    var i = 0
    while i < n {
        var size = __rt_space_size(p + 16 + i, n - i)
        if size == 0 {
            break
        }
        i += size
    }
    var negative = false
    if i < n {
        var sign = __load8(p + 16 + i)
        if sign == 45 || sign == 43 {
            negative = sign == 45
            i += 1
        }
    }
    // The number is built on the negative side, where the smallest int fits.
    var value = 0
    var digits = 0
    var fits = true
    while i < n {
        var c = __load8(p + 16 + i)
        if c < 48 || c > 57 {
            break
        }
        var digit = c - 48
        if value < -922337203685477580 || (value == -922337203685477580 && digit > 8) {
            fits = false
        } else {
            value = value * 10 - digit
        }
        digits += 1
        i += 1
    }
    while i < n {
        var size = __rt_space_size(p + 16 + i, n - i)
        if size == 0 {
            break
        }
        i += size
    }
    if !negative && value == -9223372036854775807 - 1 {
        fits = false
    }
    if digits == 0 || i < n || !fits {
        fail "cannot convert " + __rt_quote(p) + " to int"
    }
    if negative {
        return value
    }
    return -value
}

// A string, between double quotes and with special characters escaped.
fn __rt_quote(p: int) -> string {
    var n = __load32(p + 8)
    var extra = 0
    var i = 0
    while i < n {
        var c = __load8(p + 16 + i)
        if c == 34 || c == 92 || c == 10 || c == 9 || c == 13 {
            extra += 1
        }
        i += 1
    }
    var out = __rt_new_str(n + extra + 2)
    var w = out + 16
    __store8(w, 34)
    w += 1
    i = 0
    while i < n {
        var c = __load8(p + 16 + i)
        var escaped = 0
        if c == 34 || c == 92 {
            escaped = c
        } else if c == 10 {
            escaped = 110    // n
        } else if c == 9 {
            escaped = 116    // t
        } else if c == 13 {
            escaped = 114    // r
        }
        if escaped != 0 {
            __store8(w, 92)
            __store8(w + 1, escaped)
            w += 2
        } else {
            __store8(w, c)
            w += 1
        }
        i += 1
    }
    __store8(w, 34)
    return __ptr_str(out)
}

// ---- floats ----
//
// A float is 64 bits: a sign, 11 bits of exponent and 52 bits of fraction
// (IEEE 754). `__bits` and `__float` give access to them.

fn __rt_floor(x: float) -> int {
    var whole = int(x)
    if float(whole) > x {
        return whole - 1
    }
    return whole
}

fn __rt_ceil(x: float) -> int {
    var whole = int(x)
    if float(whole) < x {
        return whole + 1
    }
    return whole
}

// The nearest int; halves go up.
fn __rt_round_float(x: float) -> int {
    var down = __rt_floor(x)
    if x - float(down) >= 0.5 {
        return down + 1
    }
    return down
}

fn __rt_float_min(a: float, b: float) -> float {
    if a != a {
        return a
    }
    if b != b || b < a {
        return b
    }
    if a < b {
        return a
    }
    // Equal: of the two zeros, the negative one is the smaller.
    if __bits(a) < 0 {
        return a
    }
    return b
}

fn __rt_float_max(a: float, b: float) -> float {
    if a != a {
        return a
    }
    if b != b || b > a {
        return b
    }
    if a > b {
        return a
    }
    if __bits(a) < 0 {
        return b
    }
    return a
}

// Random numbers: the generator "xorshift", started from 8 random bytes
// that the kernel gives (system call 318, getrandom).
fn __rt_random_bits() -> int {
    var slot = __state() + __S_RANDOM
    var x = __load64(slot)
    if x == 0 {
        __syscall(318, slot, 8, 0, 0, 0, 0)
        x = __load64(slot)
        if x == 0 {
            x = 88172645463325252
        }
    }
    x = __xor(x, __shl(x, 13))
    x = __xor(x, __shr(x, 7))
    x = __xor(x, __shl(x, 17))
    __store64(slot, x)
    return x
}

// Between 0 (included) and 1 (excluded): 53 random bits over 2^53.
fn __rt_random() -> float {
    return float(__shr(__rt_random_bits(), 11)) / 9007199254740992.0
}

fn __rt_random_int(lo: int, hi: int) -> int {
    return lo + __rt_floor(__rt_random() * float(hi - lo + 1))
}

// ---- big numbers ----
//
// Writing a float in decimal and reading one back have to be exact, and
// 64 bits are not enough for that: 1e300 has a thousand bits. A big number
// is a count followed by that many "limbs" of 32 bits, lowest first, each in
// an 8-byte word. They live in a working area that is allocated once.

const __BIG_SIZE = 1160     // room for 144 limbs

fn __rt_big(i: int) -> int {
    var slot = __state() + __S_SCRATCH
    var area = __load64(slot)
    if area == 0 {
        area = __rt_alloc(8192)
        __store64(slot, area)
    }
    return area + i * __BIG_SIZE
}

// a = v, which is not negative
fn __big_set(a: int, v: int) {
    var n = 0
    while v > 0 {
        __store64(a + 8 + n * 8, __and(v, 4294967295))
        v = __shr(v, 32)
        n += 1
    }
    __store64(a, n)
}

fn __big_copy(to: int, from: int) {
    __copy(to, from, 8 + __load64(from) * 8)
}

// a = a * k + extra, for k up to 2^31 and extra below 2^31
fn __big_mul(a: int, k: int, extra: int) {
    var n = __load64(a)
    var carry = extra
    var i = 0
    while i < n {
        var at = a + 8 + i * 8
        var v = __load64(at) * k + carry
        __store64(at, __and(v, 4294967295))
        carry = __shr(v, 32)
        i += 1
    }
    if carry > 0 {
        __store64(a + 8 + n * 8, carry)
        __store64(a, n + 1)
    }
}

// a = a * 2^bits
fn __big_shl(a: int, bits: int) {
    if __load64(a) == 0 {
        return
    }
    var rest = bits % 32
    if rest > 0 {
        __big_mul(a, __shl(1, rest), 0)
    }
    var words = bits / 32
    if words > 0 {
        var n = __load64(a)
        var i = n - 1
        while i >= 0 {
            __store64(a + 8 + (i + words) * 8, __load64(a + 8 + i * 8))
            i -= 1
        }
        i = 0
        while i < words {
            __store64(a + 8 + i * 8, 0)
            i += 1
        }
        __store64(a, n + words)
    }
}

// a = a * 10^n
fn __big_pow10(a: int, n: int) {
    while n >= 9 {
        __big_mul(a, 1000000000, 0)
        n -= 9
    }
    var k = 1
    while n > 0 {
        k *= 10
        n -= 1
    }
    if k > 1 {
        __big_mul(a, k, 0)
    }
}

// Negative, zero or positive, like a - b.
fn __big_cmp(a: int, b: int) -> int {
    var n = __load64(a)
    if n != __load64(b) {
        return n - __load64(b)
    }
    var i = n - 1
    while i >= 0 {
        var d = __load64(a + 8 + i * 8) - __load64(b + 8 + i * 8)
        if d != 0 {
            return d
        }
        i -= 1
    }
    return 0
}

// a = a + b
fn __big_add(a: int, b: int) {
    var n = __load64(a)
    var m = __load64(b)
    var carry = 0
    var i = 0
    while i < m || carry > 0 {
        var v = carry
        if i < n {
            v += __load64(a + 8 + i * 8)
        }
        if i < m {
            v += __load64(b + 8 + i * 8)
        }
        __store64(a + 8 + i * 8, __and(v, 4294967295))
        carry = __shr(v, 32)
        i += 1
    }
    if i > n {
        __store64(a, i)
    }
}

// a = a - b, where a is not smaller than b
fn __big_sub(a: int, b: int) {
    var n = __load64(a)
    var m = __load64(b)
    var borrow = 0
    var i = 0
    while i < n {
        var v = __load64(a + 8 + i * 8) - borrow
        if i < m {
            v -= __load64(b + 8 + i * 8)
        }
        borrow = 0
        if v < 0 {
            v += 4294967296
            borrow = 1
        }
        __store64(a + 8 + i * 8, v)
        i += 1
    }
    while n > 0 && __load64(a + 8 + (n - 1) * 8) == 0 {
        n -= 1
    }
    __store64(a, n)
}

// Number of bits of a: 0 for zero, 3 for 5 (101 in binary).
fn __big_bits(a: int) -> int {
    var n = __load64(a)
    if n == 0 {
        return 0
    }
    var top = __load64(a + 8 + (n - 1) * 8)
    var bits = (n - 1) * 32
    while top > 0 {
        bits += 1
        top = __shr(top, 1)
    }
    return bits
}

// ---- floats as text ----

// Finds the shortest series of decimal digits that no other float is nearer
// to: the float 0.1 is really 0.1000000000000000055511151231257827..., but
// "1" (with an exponent of 0) is enough to tell it from its neighbours.
// `bits` are those of a positive, finite float. The digits are written at
// `out` (17 at most); returns their count plus 100 * (n + 1000), where n
// places the decimal point: the value is 0.DIGITS * 10^n.
//
// This is the algorithm of Steele & White and of Burger & Dybvig ("Printing
// Floating-Point Numbers Quickly and Accurately", 1996), which works with
// exact fractions r / s and the half-distances to the neighbours, m+ and m-.
fn __rt_float_digits(bits: int, out: int) -> int {
    var fraction = __and(bits, 4503599627370495)
    var exponent = __and(__shr(bits, 52), 2047)
    // The float is f * 2^e, with a whole number f.
    var f = fraction
    var e = -1074
    if exponent > 0 {
        f = fraction + 4503599627370496
        e = exponent - 1075
    }
    var even = f % 2 == 0
    var r = __rt_big(0)
    var s = __rt_big(1)
    var above = __rt_big(2)
    var below = __rt_big(3)
    var t = __rt_big(4)
    __big_set(r, f)
    __big_set(s, 1)
    __big_set(above, 1)
    __big_set(below, 1)
    if e >= 0 {
        __big_shl(r, e + 1)
        __big_shl(s, 1)
        __big_shl(above, e)
        __big_shl(below, e)
    } else {
        __big_shl(r, 1)
        __big_shl(s, 1 - e)
    }
    if fraction == 0 && exponent > 1 {
        // At a power of two, the float below is twice as near as the one above.
        __big_shl(r, 1)
        __big_shl(s, 1)
        __big_shl(above, 1)
    }

    // The decimal exponent, estimated from the number of bits (log10(2) is
    // 0.30103); the estimate is right or one too small.
    var length = 0
    var probe = f
    while probe > 0 {
        length += 1
        probe = __shr(probe, 1)
    }
    var k = __rt_ceil(float(e + length - 1) * 0.30102999566398114 - 0.69)
    if k >= 0 {
        __big_pow10(s, k)
    } else {
        __big_pow10(r, -k)
        __big_pow10(above, -k)
        __big_pow10(below, -k)
    }
    __big_copy(t, r)
    __big_add(t, above)
    var c = __big_cmp(t, s)
    if c > 0 || (c == 0 && even) {
        k += 1
    } else {
        __big_mul(r, 10, 0)
        __big_mul(above, 10, 0)
        __big_mul(below, 10, 0)
    }

    var count = 0
    while true {
        // The next digit is r / s, which is below 10.
        var digit = 0
        while __big_cmp(r, s) >= 0 {
            __big_sub(r, s)
            digit += 1
        }
        // Can we stop here, rounding down or up, without leaving the range
        // of numbers that read back as this float?
        c = __big_cmp(r, below)
        var down = c < 0 || (c == 0 && even)
        __big_copy(t, r)
        __big_add(t, above)
        c = __big_cmp(t, s)
        var up = c > 0 || (c == 0 && even)
        if !down && !up {
            __store8(out + count, 48 + digit)
            count += 1
            __big_mul(r, 10, 0)
            __big_mul(above, 10, 0)
            __big_mul(below, 10, 0)
            continue
        }
        if down && up {
            // Both would do: take the nearer, and the even digit when the
            // number is exactly in the middle.
            __big_copy(t, r)
            __big_shl(t, 1)
            c = __big_cmp(t, s)
            if c > 0 || (c == 0 && digit % 2 == 1) {
                digit += 1
            }
        } else if up {
            digit += 1
        }
        __store8(out + count, 48 + digit)
        count += 1
        break
    }
    return (k + 1000) * 100 + count
}

// The text of a float: "2.0", "0.1", "-12.5", "1.5e-7", "1e+21", "NaN",
// "Infinity". Digits are the shortest that read back as the same float; a
// whole number keeps a ".0" so that it still looks like a float.
fn __rt_float_str(x: float) -> string {
    if x != x {
        return "NaN"
    }
    var bits = __bits(x)
    var magnitude = __and(bits, 9223372036854775807)
    if magnitude == 9218868437227405312 {
        if bits < 0 {
            return "-Infinity"
        }
        return "Infinity"
    }
    if magnitude == 0 {
        return "0.0"
    }
    // Whole numbers that fit in an int are the common case, and an easy one.
    if magnitude < 4845873199050653696 {
        var whole = int(x)
        if float(whole) == x {
            return __rt_int_str(whole) + ".0"
        }
    }
    var digits = __rt_big(5)
    var packed = __rt_float_digits(magnitude, digits)
    var count = packed % 100
    var n = packed / 100 - 1000
    var out = __rt_new_str(32)
    var w = out + 16
    if bits < 0 {
        __store8(w, 45)
        w += 1
    }
    if n > 0 && n <= 21 {
        // 12.5 or 1250000.0
        var i = 0
        while i < n {
            var c = 48
            if i < count {
                c = __load8(digits + i)
            }
            __store8(w, c)
            w += 1
            i += 1
        }
        __store8(w, 46)
        w += 1
        if count <= n {
            __store8(w, 48)
            w += 1
        }
        while i < count {
            __store8(w, __load8(digits + i))
            w += 1
            i += 1
        }
    } else if n > -6 && n <= 0 {
        // 0.00125
        __store8(w, 48)
        __store8(w + 1, 46)
        w += 2
        var zeros = -n
        while zeros > 0 {
            __store8(w, 48)
            w += 1
            zeros -= 1
        }
        __copy(w, digits, count)
        w += count
    } else {
        // 1.25e-7 or 1e+21
        __store8(w, __load8(digits))
        w += 1
        if count > 1 {
            __store8(w, 46)
            __copy(w + 1, digits + 1, count - 1)
            w += count
        }
        __store8(w, 101)
        var power = n - 1
        if power < 0 {
            __store8(w + 1, 45)
            power = -power
        } else {
            __store8(w + 1, 43)
        }
        w += 2
        if power >= 100 {
            __store8(w, 48 + power / 100)
            w += 1
        }
        if power >= 10 {
            __store8(w, 48 + power / 10 % 10)
            w += 1
        }
        __store8(w, 48 + power % 10)
        w += 1
    }
    __store32(out + 8, w - out - 16)
    return __ptr_str(out)
}

// Reads a float: an optional sign, digits with an optional point, an
// optional exponent ("12", "-0.5", ".5", "6.02e23"). The result is the float
// nearest to the number that was written, whatever its number of digits.
fn __rt_parse_float(s: string) -> float! {
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    var at = p + 16
    var i = 0
    while i < n {
        var size = __rt_space_size(at + i, n - i)
        if size == 0 {
            break
        }
        i += size
    }
    var negative = false
    if i < n && (__load8(at + i) == 45 || __load8(at + i) == 43) {
        negative = __load8(at + i) == 45
        i += 1
    }

    // The number is DIGITS * 10^power. The digits are gathered twice: the
    // first 18 in an int, for the easy cases, and all of them (up to 770,
    // more cannot change the result) in a big number, nine at a time.
    var big = __rt_big(0)
    __big_set(big, 0)
    var chunk = 0
    var chunk_digits = 0
    var chunk_scale = 1
    var small = 0
    var count = 0           // digits kept, without the zeros in front
    var seen = 0            // digits read, of any kind
    var power = 0
    var after_point = false
    var lost = false        // a non-zero digit was left out
    while i < n {
        var c = __load8(at + i)
        if c == 46 && !after_point {
            after_point = true
            i += 1
            continue
        }
        if c < 48 || c > 57 {
            break
        }
        seen += 1
        i += 1
        if count == 0 && c == 48 {
            // A zero in front only moves the point.
            if after_point {
                power -= 1
            }
            continue
        }
        if count >= 770 {
            if c != 48 {
                lost = true
            }
            if !after_point {
                power += 1
            }
            continue
        }
        if count < 18 {
            small = small * 10 + (c - 48)
        }
        count += 1
        if after_point {
            power -= 1
        }
        chunk = chunk * 10 + (c - 48)
        chunk_digits += 1
        chunk_scale *= 10
        if chunk_digits == 9 {
            __big_mul(big, chunk_scale, chunk)
            chunk = 0
            chunk_digits = 0
            chunk_scale = 1
        }
    }
    var valid = seen > 0
    if valid && i < n && (__load8(at + i) == 101 || __load8(at + i) == 69) {
        i += 1
        var minus = false
        if i < n && (__load8(at + i) == 45 || __load8(at + i) == 43) {
            minus = __load8(at + i) == 45
            i += 1
        }
        var exponent = 0
        var exponent_digits = 0
        while i < n && __load8(at + i) >= 48 && __load8(at + i) <= 57 {
            if exponent < 100000 {
                exponent = exponent * 10 + (__load8(at + i) - 48)
            }
            exponent_digits += 1
            i += 1
        }
        valid = exponent_digits > 0
        if minus {
            power -= exponent
        } else {
            power += exponent
        }
    }
    while i < n {
        var size = __rt_space_size(at + i, n - i)
        if size == 0 {
            break
        }
        i += size
    }
    if !valid || i < n {
        fail "cannot convert " + __rt_quote(p) + " to float"
    }

    var sign = 0
    if negative {
        sign = -9223372036854775807 - 1
    }
    if count == 0 || count + power < -323 {
        return __float(sign)                        // zero, or too small to be anything else
    }
    if count + power > 309 {
        return __float(__or(sign, 9218868437227405312))     // infinity
    }
    if count <= 15 && power >= -22 && power <= 22 {
        // The digits fit exactly in a float, and so does the power of ten:
        // one multiplication or division gives the nearest float.
        var scale = 1.0
        var steps = power
        if steps < 0 {
            steps = -steps
        }
        while steps > 0 {
            scale *= 10.0
            steps -= 1
        }
        var value = float(small)
        if power < 0 {
            value /= scale
        } else {
            value *= scale
        }
        if negative {
            return -value
        }
        return value
    }

    // The general case, exactly: the number is the fraction top / bottom.
    if chunk_digits > 0 {
        __big_mul(big, chunk_scale, chunk)
    }
    if lost {
        // What was left out only matters as "a little more than this".
        __big_mul(big, 10, 1)
        power -= 1
    }
    var top = big
    var bottom = __rt_big(1)
    __big_set(bottom, 1)
    if power >= 0 {
        __big_pow10(top, power)
    } else {
        __big_pow10(bottom, -power)
    }
    // Scale by a power of two so that top / bottom has 55 or 56 bits: enough
    // for the 53 of a float, plus what decides the rounding.
    var shift = __big_bits(bottom) + 55 - __big_bits(top)
    if shift >= 0 {
        __big_shl(top, shift)
    } else {
        __big_shl(bottom, -shift)
    }
    __big_shl(bottom, 56)
    var q = 0
    var step = 0
    while step < 57 {
        q = q * 2
        if __big_cmp(top, bottom) >= 0 {
            __big_sub(top, bottom)
            q += 1
        }
        __big_shl(top, 1)
        step += 1
    }
    var inexact = __load64(top) > 0
    // The number is (q + a fraction) * 2^-shift.
    var length = 0
    var probe = q
    while probe > 0 {
        length += 1
        probe = __shr(probe, 1)
    }
    var highest = length - 1 - shift        // the exponent of its first bit
    var keep = 53
    if highest < -1022 {
        keep = highest + 1075               // the smallest floats have fewer bits
    }
    if keep < 0 {
        return __float(sign)
    }
    var drop = length - keep
    var m = __shr(q, drop)
    var rest = q - __shl(m, drop)
    var half = __shl(1, drop - 1)
    // Round to the nearest; exactly halfway goes to the even one.
    if rest > half || (rest == half && (inexact || m % 2 == 1)) {
        m += 1
    }
    if keep < 53 {
        // m * 2^-1074: for these floats, the bits are simply m.
        return __float(__or(sign, m))
    }
    var lowest = drop - shift
    if m == 9007199254740992 {
        m = 4503599627370496
        lowest += 1
    }
    var exponent_bits = lowest + 1075
    if exponent_bits >= 2047 {
        return __float(__or(sign, 9218868437227405312))
    }
    return __float(__or(sign, __or(__shl(exponent_bits, 52), m - 4503599627370496)))
}

// ---- powers ----
//
// `pow` follows the method of fdlibm, the "Freely Distributable LIBM" of
// Sun Microsystems (e_pow.c, 1993-2004): log2(x) is computed with extra
// precision as n + a correction, it is multiplied by y, and 2 is raised to
// the result. The numbers below are the coefficients of its polynomials.
// The result is within one unit in the last place of the exact one.

// The upper and lower 32 bits of a float (the upper ones as a signed number).
fn __hi(x: float) -> int {
    return __sar(__bits(x), 32)
}

fn __lo(x: float) -> int {
    return __and(__bits(x), 4294967295)
}

fn __with_hi(x: float, hi: int) -> float {
    return __float(__or(__shl(hi, 32), __and(__bits(x), 4294967295)))
}

// `x` with its lower 32 bits cleared.
fn __no_lo(x: float) -> float {
    return __float(__and(__bits(x), -4294967296))
}

// x * 2^n
fn __rt_scalbn(x: float, n: int) -> float {
    var hx = __hi(x)
    var k = __sar(__and(hx, 2146435072), 20)
    if k == 0 {
        if __and(__bits(x), 9223372036854775807) == 0 {
            return x
        }
        x *= 18014398509481984.0
        hx = __hi(x)
        k = __sar(__and(hx, 2146435072), 20) - 54
        if n < -50000 {
            return 1e-300 * x
        }
    }
    if k == 2047 {
        return x + x
    }
    k = k + n
    var huge = 1e300
    var tiny = 1e-300
    if hx < 0 {
        huge = -huge
        tiny = -tiny
    }
    if k > 2046 {
        return 1e300 * huge
    }
    if k > 0 {
        return __with_hi(x, __or(__and(hx, 2148532223), __shl(k, 20)))
    }
    if k <= -54 {
        if n > 50000 {
            return 1e300 * huge
        }
        return 1e-300 * tiny
    }
    k += 54
    x = __with_hi(x, __or(__and(hx, 2148532223), __shl(k, 20)))
    return x * 5.55111512312578270212e-17
}

fn __rt_pow(x: float, y: float) -> float {
    var hx = __hi(x)
    var lx = __lo(x)
    var hy = __hi(y)
    var ly = __lo(y)
    var ix = __and(hx, 2147483647)
    var iy = __and(hy, 2147483647)

    if iy == 0 && ly == 0 {
        return 1.0                              // anything to the power 0
    }
    if ix > 2146435072 || (ix == 2146435072 && lx != 0) || iy > 2146435072 || (iy == 2146435072 && ly != 0) {
        return x + y                            // not a number
    }

    // For a negative x: is y an odd whole number (1), an even one (2), or not whole (0)?
    var whole = 0
    if hx < 0 {
        if iy >= 1128267776 {
            whole = 2
        } else if iy >= 1072693248 {
            var bits = __sar(iy, 20) - 1023
            if bits > 20 {
                var j = __shr(ly, 52 - bits)
                if __shl(j, 52 - bits) == ly {
                    whole = 2 - __and(j, 1)
                }
            } else if ly == 0 {
                var j = __sar(iy, 20 - bits)
                if __shl(j, 20 - bits) == iy {
                    whole = 2 - __and(j, 1)
                }
            }
        }
    }

    if ly == 0 {
        if iy == 2146435072 {
            // y is infinite
            if ix == 1072693248 && lx == 0 {
                return y - y
            }
            if ix >= 1072693248 {
                if hy >= 0 {
                    return y
                }
                return 0.0
            }
            if hy < 0 {
                return -y
            }
            return 0.0
        }
        if iy == 1072693248 {
            if hy < 0 {
                return 1.0 / x
            }
            return x
        }
        if hy == 1073741824 {
            return x * x
        }
        if hy == 1071644672 && hx >= 0 {
            return sqrt(x)
        }
    }

    var ax = abs(x)
    if lx == 0 && (ix == 2146435072 || ix == 0 || ix == 1072693248) {
        // x is zero, infinite or 1 (with either sign)
        var special = ax
        if hy < 0 {
            special = 1.0 / special
        }
        if hx < 0 {
            if ix == 1072693248 && whole == 0 {
                special = (special - special) / (special - special)
            } else if whole == 1 {
                special = -special
            }
        }
        return special
    }

    if hx < 0 && whole == 0 {
        return (x - x) / (x - x)                // a negative number to a power that is not whole
    }
    var sign = 1.0
    if hx < 0 && whole == 1 {
        sign = -1.0
    }

    // log2(|x|) = t1 + t2, where t1 holds the first bits and t2 the rest.
    var t1 = 0.0
    var t2 = 0.0
    if iy > 1105199104 {
        // |y| is huge: unless x is very close to 1, the result is 0 or infinite.
        if iy > 1139802112 {
            if ix <= 1072693247 {
                if hy < 0 {
                    return 1e300 * 1e300
                }
                return 1e-300 * 1e-300
            }
            if ix >= 1072693248 {
                if hy > 0 {
                    return 1e300 * 1e300
                }
                return 1e-300 * 1e-300
            }
        }
        if ix < 1072693247 {
            if hy < 0 {
                return sign * 1e300 * 1e300
            }
            return sign * 1e-300 * 1e-300
        }
        if ix > 1072693248 {
            if hy > 0 {
                return sign * 1e300 * 1e300
            }
            return sign * 1e-300 * 1e-300
        }
        var d = ax - 1.0
        var w = (d * d) * (0.5 - d * (0.3333333333333333333333 - d * 0.25))
        var u = 1.44269502162933349609e+00 * d
        var v = d * 1.92596299112661746302e-08 - w * 1.44269504088896338700e+00
        t1 = __no_lo(u + v)
        t2 = v - (t1 - u)
    } else {
        var n = 0
        if ix < 1048576 {
            ax *= 9007199254740992.0
            n -= 53
            ix = __hi(ax)
        }
        n += __sar(ix, 20) - 1023
        var j = __and(ix, 1048575)
        // Bring |x| between sqrt(3)/2 and sqrt(3), near 1 or near 1.5.
        ix = __or(j, 1072693248)
        var near = 1.0
        var log_h = 0.0
        var log_l = 0.0
        var k = 0
        if j <= 235662 {
            k = 0
        } else if j < 767610 {
            k = 1
            near = 1.5
            log_h = 5.84962487220764160156e-01
            log_l = 1.35003920212974897128e-08
        } else {
            n += 1
            ix -= 1048576
        }
        ax = __with_hi(ax, ix)

        var u = ax - near
        var v = 1.0 / (ax + near)
        var ss = u * v
        var s_h = __no_lo(ss)
        var t_h = __with_hi(0.0, __or(__sar(ix, 1), 536870912) + 524288 + __shl(k, 18))
        var t_l = ax - (t_h - near)
        var s_l = v * ((u - s_h * t_h) - s_h * t_l)
        var s2 = ss * ss
        var r = s2 * s2 * (5.99999999999994648725e-01 + s2 * (4.28571428578550184252e-01 + s2 * (3.33333329818377432918e-01 + s2 * (2.72728123808534006489e-01 + s2 * (2.30660745775561754067e-01 + s2 * 2.06975017800338417784e-01)))))
        r += s_l * (s_h + ss)
        s2 = s_h * s_h
        t_h = __no_lo(3.0 + s2 + r)
        t_l = r - ((t_h - 3.0) - s2)
        u = s_h * t_h
        v = s_l * t_h + t_l * ss
        var p_h = __no_lo(u + v)
        var p_l = v - (p_h - u)
        var z_h = 9.61796700954437255859e-01 * p_h
        var z_l = -7.02846165095275826516e-09 * p_h + p_l * 9.61796693925975554329e-01 + log_l
        var t = float(n)
        t1 = __no_lo(((z_h + z_l) + log_h) + t)
        t2 = z_l - (((t1 - t) - log_h) - z_h)
    }

    // y * log2(|x|), again as a first part and a rest.
    var y1 = __no_lo(y)
    var e_l = (y - y1) * t1 + y * t2
    var e_h = y1 * t1
    var z = e_l + e_h
    var j = __hi(z)
    var i = __lo(z)
    if j >= 1083179008 {
        // 1024 or more: too big
        if j != 1083179008 || i != 0 {
            return sign * 1e300 * 1e300
        }
        if e_l + 8.0085662595372944372e-17 > z - e_h {
            return sign * 1e300 * 1e300
        }
    } else if __and(j, 2147483647) >= 1083231232 {
        // -1075 or less: too small
        if j != -1064252416 || i != 0 {
            return sign * 1e-300 * 1e-300
        }
        if e_l <= z - e_h {
            return sign * 1e-300 * 1e-300
        }
    }

    // 2^(e_h + e_l): the whole part n of the exponent is set aside.
    i = __and(j, 2147483647)
    var k = __sar(i, 20) - 1023
    var n = 0
    if i > 1071644672 {
        n = j + __sar(1048576, k + 1)
        k = __sar(__and(n, 2147483647), 20) - 1023
        var t = __with_hi(0.0, __and(n, -1 - __sar(1048575, k)))
        n = __sar(__or(__and(n, 1048575), 1048576), 20 - k)
        if j < 0 {
            n = -n
        }
        e_h -= t
    }
    var t = __no_lo(e_l + e_h)
    var u = t * 6.93147182464599609375e-01
    var v = (e_l - (t - e_h)) * 6.93147180559945286227e-01 + t * -1.90465429995776804525e-09
    z = u + v
    var w = v - (z - u)
    t = z * z
    t1 = z - t * (1.66666666666666019037e-01 + t * (-2.77777777770155933842e-03 + t * (6.61375632143793436117e-05 + t * (-1.65339022054652515390e-06 + t * 4.13813679705723846039e-08))))
    var r = (z * t1) / (t1 - 2.0) - (w + z * w)
    z = 1.0 - (r - z)
    j = __hi(z) + __shl(n, 20)
    if __sar(j, 20) <= 0 {
        z = __rt_scalbn(z, n)                   // the result is one of the smallest floats
    } else {
        z = __with_hi(z, j)
    }
    return sign * z
}

// ---- generic operations, driven by type descriptors ----

// The text form of a value. Strings nested in a list or a struct are quoted.
fn __rt_repr(v: int, td: int, quoted: bool) -> string {
    var kind = __load64(td)
    if kind == 0 {
        return __rt_int_str(v)
    }
    if kind == 2 {
        return __rt_float_str(__float(v))
    }
    if kind == 1 {
        if v != 0 {
            return "true"
        }
        return "false"
    }
    if kind == __KIND_STRING {
        if quoted {
            return __rt_quote(v)
        }
        __rt_retain(v)
        return __ptr_str(v)
    }
    if kind == 6 {
        return __rt_repr(v, __load32(v + 4), quoted)
    }
    if kind == 9 {
        return "fn"
    }
    if kind == __KIND_LIST {
        var elem = __load64(td + 8)
        var count = __load64(v + 8)
        var data = __load64(v + 24)
        var items = "["
        var k = 0
        while k < count {
            if k > 0 {
                items += ", "
            }
            items += __rt_repr(__load64(data + k * 8), elem, true)
            k += 1
        }
        items += "]"
        return items
    }
    if kind == __KIND_MAP {
        var keys = __load64(td + 8)
        var values = __load64(td + 16)
        var used = __load64(v + 16)
        var entries = __load64(v + 32)
        var text = "\{"
        var shown = 0
        var e = 0
        while e < used {
            var entry = entries + e * 24
            if __load64(entry) >= 0 {
                if shown > 0 {
                    text += ", "
                }
                shown += 1
                text += __rt_repr(__load64(entry + 8), keys, true)
                text += ": "
                text += __rt_repr(__load64(entry + 16), values, true)
            }
            e += 1
        }
        text += "\}"
        return text
    }
    var out = __ptr_str(__load64(td + 8)) + "\{"
    var n = __load64(td + 16)
    var i = 0
    while i < n {
        if i > 0 {
            out += ", "
        }
        out += __ptr_str(__load64(td + 32 + i * 16))
        out += ": "
        out += __rt_repr(__load64(v + 8 + i * 8), __load64(td + 40 + i * 16), true)
        i += 1
    }
    out += "\}"
    return out
}

// Structural equality.
fn __rt_eq(a: int, b: int, td: int) -> bool {
    var kind = __load64(td)
    if kind == 2 {
        // Not the same as equal bits: 0.0 equals -0.0, and NaN equals nothing.
        return __float(a) == __float(b)
    }
    if kind < 3 || a == b {
        return a == b
    }
    if kind == __KIND_STRING {
        return __load32(a + 8) == __load32(b + 8) && __rt_bytes_cmp(a, b) == 0
    }
    if kind == 6 {
        var real = __load32(a + 4)
        if real != __load32(b + 4) {
            return false
        }
        return __rt_eq(a, b, real)
    }
    if kind == __KIND_LIST {
        var count = __load64(a + 8)
        if count != __load64(b + 8) {
            return false
        }
        var elem = __load64(td + 8)
        var da = __load64(a + 24)
        var db = __load64(b + 24)
        var k = 0
        while k < count {
            if !__rt_eq(__load64(da + k * 8), __load64(db + k * 8), elem) {
                return false
            }
            k += 1
        }
        return true
    }
    if kind == __KIND_MAP {
        // Same keys with equal values, whatever the order.
        if __load64(a + 8) != __load64(b + 8) {
            return false
        }
        var keys = __load64(td + 8)
        var values = __load64(td + 16)
        var used = __load64(a + 16)
        var entries = __load64(a + 32)
        var e = 0
        while e < used {
            var entry = entries + e * 24
            if __load64(entry) >= 0 {
                var twin = __rt_map_find(b, __load64(entry + 8), __load64(entry))
                if twin == 0 || !__rt_eq(__load64(entry + 16), __load64(twin + 16), values) {
                    return false
                }
            }
            e += 1
        }
        return true
    }
    var n = __load64(td + 16)
    var i = 0
    while i < n {
        if !__rt_eq(__load64(a + 8 + i * 8), __load64(b + 8 + i * 8), __load64(td + 40 + i * 16)) {
            return false
        }
        i += 1
    }
    return true
}

// ---- maps ----
//
// A map keeps its entries in the order they were added:
//
//   +8   number of entries
//   +16  number of entry slots used (removed entries keep their slot)
//   +24  number of entry slots
//   +32  address of the entries, 24 bytes each:
//          +0 hash of the key (-1 once removed)   +8 key   +16 value
//   +40  size of the index (a power of two, at least twice the entry slots)
//   +48  address of the index: for each position, an entry number + 1, or 0
//
// A key is looked up by hashing it to a position in the index and walking
// forward from there until its entry, or an empty position, is found.
//
// A key shown to these functions is only borrowed; the map retains the keys
// it stores. A value given to __rt_map_set moves into the map.

fn __rt_map_new(td: int) -> int {
    var m = __rt_new(td, 56)
    __store64(m + 8, 0)
    __store64(m + 16, 0)
    __store64(m + 24, 0)
    __store64(m + 32, 0)
    __store64(m + 40, 0)
    __store64(m + 48, 0)
    return m
}

// A number between 0 and 2^31 - 1 that depends on every bit of the key.
fn __rt_hash(key: int, td: int) -> int {
    var h = key
    if __load64(td) == __KIND_STRING {
        var n = __load32(key + 8)
        h = n
        var i = 0
        while i + 8 <= n {
            h = h * 31 + __load64(key + 16 + i)
            i += 8
        }
        while i < n {
            h = h * 31 + __load8(key + 16 + i)
            i += 1
        }
    }
    // Multiplying by a large odd number spreads the key over all 64 bits;
    // the high ones are the best mixed.
    return __and(h * -7046029254386353131 / 65536 / 65536, 2147483647)
}

// The address of the entry that holds `key`, or 0.
fn __rt_map_find(m: int, key: int, hash: int) -> int {
    var slots = __load64(m + 40)
    if slots == 0 {
        return 0
    }
    var index = __load64(m + 48)
    var entries = __load64(m + 32)
    var strings = __load64(__load64(__load32(m + 4) + 8)) == __KIND_STRING
    var at = __and(hash, slots - 1)
    while true {
        var number = __load64(index + at * 8)
        if number == 0 {
            return 0
        }
        var entry = entries + (number - 1) * 24
        if __load64(entry) == hash {
            var other = __load64(entry + 8)
            if other == key {
                return entry
            }
            if strings && __load32(other + 8) == __load32(key + 8) && __rt_bytes_cmp(other, key) == 0 {
                return entry
            }
        }
        at = __and(at + 1, slots - 1)
    }
    return 0
}

// Records in the index that the entry `number - 1` has this hash.
fn __rt_map_index(index: int, slots: int, hash: int, number: int) {
    var at = __and(hash, slots - 1)
    while __load64(index + at * 8) != 0 {
        at = __and(at + 1, slots - 1)
    }
    __store64(index + at * 8, number)
}

// Gives the map room for `capacity` entries, leaving the removed ones behind.
fn __rt_map_resize(m: int, capacity: int) {
    var old = __load64(m + 32)
    var used = __load64(m + 16)
    if old != 0 {
        __rt_free(__load64(m + 48), __load64(m + 40) * 8)
    }
    var slots = 16
    while slots < capacity * 2 {
        slots = slots * 2
    }
    var index = __rt_alloc(slots * 8)
    var i = 0
    while i < slots {
        __store64(index + i * 8, 0)
        i += 1
    }
    var entries = __rt_alloc(capacity * 24)
    var count = 0
    i = 0
    while i < used {
        var from = old + i * 24
        var hash = __load64(from)
        if hash >= 0 {
            var to = entries + count * 24
            __store64(to, hash)
            __store64(to + 8, __load64(from + 8))
            __store64(to + 16, __load64(from + 16))
            count += 1
            __rt_map_index(index, slots, hash, count)
        }
        i += 1
    }
    if old != 0 {
        __rt_free(old, __load64(m + 24) * 24)
    }
    __store64(m + 16, count)
    __store64(m + 24, capacity)
    __store64(m + 32, entries)
    __store64(m + 40, slots)
    __store64(m + 48, index)
}

fn __rt_map_set(m: int, key: int, value: int) {
    var td = __load32(m + 4)
    var hash = __rt_hash(key, __load64(td + 8))
    var entry = __rt_map_find(m, key, hash)
    if entry != 0 {
        var old = __load64(entry + 16)
        __store64(entry + 16, value)
        if __load64(__load64(td + 16)) >= 3 {
            __rt_release(old)
        }
        return
    }
    var used = __load64(m + 16)
    if used == __load64(m + 24) {
        var capacity = __load64(m + 8) * 2
        if capacity < 8 {
            capacity = 8
        }
        __rt_map_resize(m, capacity)
        used = __load64(m + 16)
    }
    var to = __load64(m + 32) + used * 24
    __store64(to, hash)
    __store64(to + 8, key)
    __store64(to + 16, value)
    if __load64(__load64(td + 8)) >= 3 {
        __rt_retain(key)
    }
    __rt_map_index(__load64(m + 48), __load64(m + 40), hash, used + 1)
    __store64(m + 16, used + 1)
    __store64(m + 8, __load64(m + 8) + 1)
}

fn __rt_map_entry(m: int, key: int) -> int {
    return __rt_map_find(m, key, __rt_hash(key, __load64(__load32(m + 4) + 8)))
}

// `m[key]`: the value, for which the caller gets its own reference.
fn __rt_map_at(m: int, key: int) -> int {
    var td = __load32(m + 4)
    var entry = __rt_map_entry(m, key)
    if entry == 0 {
        __rt_panic("key not found in map: " + __rt_repr(key, __load64(td + 8), true))
    }
    var value = __load64(entry + 16)
    if __load64(__load64(td + 16)) >= 3 {
        __rt_retain(value)
    }
    return value
}

// `m.get(key)`: like `m[key]`, but a missing key is an error to handle.
fn __rt_map_get(m: int, key: int) -> int! {
    var td = __load32(m + 4)
    var entry = __rt_map_entry(m, key)
    if entry == 0 {
        fail "key not found: " + __rt_repr(key, __load64(td + 8), true)
    }
    var value = __load64(entry + 16)
    if __load64(__load64(td + 16)) >= 3 {
        __rt_retain(value)
    }
    return value
}

fn __rt_map_has(m: int, key: int) -> bool {
    return __rt_map_entry(m, key) != 0
}

// Lets go of what an entry holds and marks it as removed.
fn __rt_map_drop(m: int, entry: int) {
    var td = __load32(m + 4)
    if __load64(__load64(td + 8)) >= 3 {
        __rt_release(__load64(entry + 8))
    }
    if __load64(__load64(td + 16)) >= 3 {
        __rt_release(__load64(entry + 16))
    }
    __store64(entry, -1)
}

fn __rt_map_remove(m: int, key: int) {
    var entry = __rt_map_entry(m, key)
    if entry != 0 {
        __rt_map_drop(m, entry)
        __store64(m + 8, __load64(m + 8) - 1)
    }
}

fn __rt_map_clear(m: int) {
    var used = __load64(m + 16)
    var entries = __load64(m + 32)
    var i = 0
    while i < used {
        if __load64(entries + i * 24) >= 0 {
            __rt_map_drop(m, entries + i * 24)
        }
        i += 1
    }
    var index = __load64(m + 48)
    var slots = __load64(m + 40)
    i = 0
    while i < slots {
        __store64(index + i * 8, 0)
        i += 1
    }
    __store64(m + 8, 0)
    __store64(m + 16, 0)
}

// The number of the first entry at or after `from` that was not removed, or -1.
fn __rt_map_next(m: int, from: int) -> int {
    var used = __load64(m + 16)
    var entries = __load64(m + 32)
    var i = from
    while i < used {
        if __load64(entries + i * 24) >= 0 {
            return i
        }
        i += 1
    }
    return -1
}

// The key (`which` = 8) or the value (`which` = 16) of entry number `i`.
fn __rt_map_part(m: int, i: int, which: int) -> int {
    return __load64(__load64(m + 32) + i * 24 + which)
}

// A new list (of type `td`) of the keys or of the values, in order.
fn __rt_map_list(m: int, td: int, which: int) -> int {
    var out = __rt_list_new(td, __load64(m + 8))
    var refs = __load64(__load64(td + 8)) >= 3
    var i = __rt_map_next(m, 0)
    while i >= 0 {
        var v = __rt_map_part(m, i, which)
        if refs {
            __rt_retain(v)
        }
        __rt_list_push(out, v)
        i = __rt_map_next(m, i + 1)
    }
    return out
}

// ---- lists ----
//
// A value given to push / insert moves into the list; a value returned by
// `remove` moves out of it.

fn __rt_list_new(td: int, capacity: int) -> int {
    var list = __rt_new(td, 32)
    var data = 0
    if capacity > 0 {
        data = __rt_alloc(capacity * 8)
    }
    __store64(list + 8, 0)
    __store64(list + 16, capacity)
    __store64(list + 24, data)
    return list
}

fn __rt_list_holds_refs(list: int) -> bool {
    return __load64(__load64(__load32(list + 4) + 8)) >= 3
}

fn __rt_index_panic(list: int, i: int) {
    __rt_panic("index out of bounds: index " + __rt_int_str(i) + ", length " + __rt_int_str(__load64(list + 8)))
}

// Doubles the storage of a full list.
fn __rt_list_grow(list: int) {
    var n = __load64(list + 16)
    var capacity = n * 2
    if capacity < 4 {
        capacity = 4
    }
    var bigger = __rt_alloc(capacity * 8)
    var data = __load64(list + 24)
    if data != 0 {
        __copy(bigger, data, n * 8)
        __rt_free(data, n * 8)
    }
    __store64(list + 16, capacity)
    __store64(list + 24, bigger)
}

fn __rt_list_push(list: int, v: int) {
    var n = __load64(list + 8)
    if n == __load64(list + 16) {
        __rt_list_grow(list)
    }
    __store64(__load64(list + 24) + n * 8, v)
    __store64(list + 8, n + 1)
}

fn __rt_list_insert(list: int, i: int, v: int) {
    var n = __load64(list + 8)
    if i < 0 || i > n {
        __rt_index_panic(list, i)
    }
    __rt_list_push(list, v)
    // Shift the tail one slot to the right, from the end.
    var data = __load64(list + 24)
    var k = n
    while k > i {
        __store64(data + k * 8, __load64(data + (k - 1) * 8))
        k -= 1
    }
    __store64(data + i * 8, v)
}

fn __rt_list_remove(list: int, i: int) -> int {
    var n = __load64(list + 8)
    if i < 0 || i >= n {
        __rt_index_panic(list, i)
    }
    var data = __load64(list + 24)
    var removed = __load64(data + i * 8)
    var k = i
    while k < n - 1 {
        __store64(data + k * 8, __load64(data + (k + 1) * 8))
        k += 1
    }
    __store64(list + 8, n - 1)
    return removed
}

// The last element, which moves out of the list.
fn __rt_list_pop(list: int) -> int! {
    var n = __load64(list + 8)
    if n == 0 {
        fail "the list is empty"
    }
    __store64(list + 8, n - 1)
    return __load64(__load64(list + 24) + (n - 1) * 8)
}

// An element of a list that must not be empty; the caller gets its own
// reference to it.
fn __rt_list_edge(list: int, last: bool) -> int! {
    var n = __load64(list + 8)
    if n == 0 {
        fail "the list is empty"
    }
    var position = 0
    if last {
        position = n - 1
    }
    var v = __load64(__load64(list + 24) + position * 8)
    if __rt_list_holds_refs(list) {
        __rt_retain(v)
    }
    return v
}

fn __rt_list_first(list: int) -> int! {
    return __rt_list_edge(list, false)?
}

fn __rt_list_last(list: int) -> int! {
    return __rt_list_edge(list, true)?
}

fn __rt_list_clear(list: int) {
    if __rt_list_holds_refs(list) {
        var n = __load64(list + 8)
        var data = __load64(list + 24)
        var i = 0
        while i < n {
            __rt_release(__load64(data + i * 8))
            i += 1
        }
    }
    __store64(list + 8, 0)
}

fn __rt_list_index_of(list: int, v: int) -> int {
    var elem = __load64(__load32(list + 4) + 8)
    var n = __load64(list + 8)
    var data = __load64(list + 24)
    var i = 0
    while i < n {
        if __rt_eq(__load64(data + i * 8), v, elem) {
            return i
        }
        i += 1
    }
    return -1
}

fn __rt_list_contains(list: int, v: int) -> bool {
    return __rt_list_index_of(list, v) >= 0
}

// A new list holding elements [from, to) of `list`.
fn __rt_list_copy(list: int, from: int, to: int) -> int {
    var count = to - from
    var out = __rt_list_new(__load32(list + 4), count)
    if count > 0 {
        var source = __load64(list + 24) + from * 8
        __copy(__load64(out + 24), source, count * 8)
        __store64(out + 8, count)
        if __rt_list_holds_refs(list) {
            var i = 0
            while i < count {
                __rt_retain(__load64(source + i * 8))
                i += 1
            }
        }
    }
    return out
}

// Turns a slice bound into a valid position: negative counts from the end.
fn __rt_clamp_index(i: int, n: int) -> int {
    if i < 0 {
        i += n
        if i < 0 {
            return 0
        }
    }
    if i > n {
        return n
    }
    return i
}

fn __rt_list_slice(list: int, from: int, to: int) -> int {
    var n = __load64(list + 8)
    var start = __rt_clamp_index(from, n)
    var end = __rt_clamp_index(to, n)
    if end < start {
        end = start
    }
    return __rt_list_copy(list, start, end)
}

fn __rt_list_reverse(list: int) -> int {
    var n = __load64(list + 8)
    var out = __rt_list_copy(list, 0, n)
    var data = __load64(out + 24)
    var i = 0
    var j = n - 1
    while i < j {
        var tmp = __load64(data + i * 8)
        __store64(data + i * 8, __load64(data + j * 8))
        __store64(data + j * 8, tmp)
        i += 1
        j -= 1
    }
    return out
}

fn __rt_list_join(list: int, separator: string) -> string {
    var elem = __load64(__load32(list + 4) + 8)
    var n = __load64(list + 8)
    var data = __load64(list + 24)
    var out = ""
    var i = 0
    while i < n {
        if i > 0 {
            out += separator
        }
        out += __rt_repr(__load64(data + i * 8), elem, false)
        i += 1
    }
    return out
}

// The three methods below run a function of the program, `f`, on every
// element. `__call1` calls it; the element is held for the time of the call,
// since the function may well change the list.

fn __rt_list_map(list: int, f: int, td: int) -> int {
    var out = __rt_list_new(td, __load64(list + 8))
    var refs = __rt_list_holds_refs(list)
    var i = 0
    while i < __load64(list + 8) {
        var item = __load64(__load64(list + 24) + i * 8)
        if refs {
            __rt_retain(item)
        }
        __rt_list_push(out, __call1(f, item))
        if refs {
            __rt_release(item)
        }
        i += 1
    }
    return out
}

fn __rt_list_filter(list: int, f: int, td: int) -> int {
    var out = __rt_list_new(__load32(list + 4), 0)
    var refs = __rt_list_holds_refs(list)
    var i = 0
    while i < __load64(list + 8) {
        var item = __load64(__load64(list + 24) + i * 8)
        if refs {
            __rt_retain(item)
        }
        if __call1(f, item) != 0 {
            __rt_list_push(out, item)
        } else if refs {
            __rt_release(item)
        }
        i += 1
    }
    return out
}

// A copy sorted by the key that `f` gives for each element (an int, a float
// or a string, as `td` says). Elements with equal keys keep their order.
fn __rt_list_sort_by(list: int, f: int, td: int) -> int {
    var kind = __load64(td)
    var refs = __rt_list_holds_refs(list)
    // Keys first, each computed once; the elements are held meanwhile.
    var room = 4
    var keys = __rt_alloc(room * 8)
    var items = __rt_alloc(room * 8)
    var n = 0
    while n < __load64(list + 8) {
        if n == room {
            var more_keys = __rt_alloc(room * 16)
            var more_items = __rt_alloc(room * 16)
            __copy(more_keys, keys, room * 8)
            __copy(more_items, items, room * 8)
            __rt_free(keys, room * 8)
            __rt_free(items, room * 8)
            keys = more_keys
            items = more_items
            room = room * 2
        }
        var item = __load64(__load64(list + 24) + n * 8)
        if refs {
            __rt_retain(item)
        }
        __store64(items + n * 8, item)
        __store64(keys + n * 8, __call1(f, item))
        n += 1
    }
    // A merge sort on the two arrays together.
    var keys2 = __rt_alloc(room * 8)
    var items2 = __rt_alloc(room * 8)
    var width = 1
    while width < n {
        var lo = 0
        while lo < n {
            var mid = lo + width
            if mid > n {
                mid = n
            }
            var hi = mid + width
            if hi > n {
                hi = n
            }
            var a = lo
            var b = mid
            var k = lo
            while a < mid && b < hi {
                var x = __load64(keys + a * 8)
                var y = __load64(keys + b * 8)
                var take_left = x <= y
                if kind == __KIND_STRING {
                    take_left = __rt_bytes_cmp(x, y) <= 0
                } else if kind == 2 {
                    take_left = !(__float(y) < __float(x))
                }
                if take_left {
                    __store64(keys2 + k * 8, x)
                    __store64(items2 + k * 8, __load64(items + a * 8))
                    a += 1
                } else {
                    __store64(keys2 + k * 8, y)
                    __store64(items2 + k * 8, __load64(items + b * 8))
                    b += 1
                }
                k += 1
            }
            __copy(keys2 + k * 8, keys + a * 8, (mid - a) * 8)
            __copy(items2 + k * 8, items + a * 8, (mid - a) * 8)
            k += mid - a
            __copy(keys2 + k * 8, keys + b * 8, (hi - b) * 8)
            __copy(items2 + k * 8, items + b * 8, (hi - b) * 8)
            lo = hi
        }
        var swap = keys
        keys = keys2
        keys2 = swap
        swap = items
        items = items2
        items2 = swap
        width = width * 2
    }
    var out = __rt_list_new(__load32(list + 4), n)
    var i = 0
    while i < n {
        __rt_list_push(out, __load64(items + i * 8))
        if kind == __KIND_STRING {
            __rt_release(__load64(keys + i * 8))
        }
        i += 1
    }
    __rt_free(keys, room * 8)
    __rt_free(items, room * 8)
    __rt_free(keys2, room * 8)
    __rt_free(items2, room * 8)
    return out
}

// A sorted copy (stable merge sort). Works on ints and strings.
fn __rt_list_sort(list: int) -> int {
    var n = __load64(list + 8)
    var out = __rt_list_copy(list, 0, n)
    if n < 2 {
        return out
    }
    var strings = __rt_list_holds_refs(list)
    var floats = __load64(__load64(__load32(list + 4) + 8)) == 2
    var src = __load64(out + 24)
    var dst = __rt_alloc(n * 8)
    var width = 1
    while width < n {
        var lo = 0
        while lo < n {
            var mid = lo + width
            if mid > n {
                mid = n
            }
            var hi = mid + width
            if hi > n {
                hi = n
            }
            // Merge src[lo, mid) and src[mid, hi) into dst[lo, hi).
            var a = lo
            var b = mid
            var k = lo
            while a < mid && b < hi {
                var x = __load64(src + a * 8)
                var y = __load64(src + b * 8)
                var take_left = x <= y
                if strings {
                    take_left = __rt_bytes_cmp(x, y) <= 0
                } else if floats {
                    take_left = !(__float(y) < __float(x))
                }
                if take_left {
                    __store64(dst + k * 8, x)
                    a += 1
                } else {
                    __store64(dst + k * 8, y)
                    b += 1
                }
                k += 1
            }
            __copy(dst + k * 8, src + a * 8, (mid - a) * 8)
            k += mid - a
            __copy(dst + k * 8, src + b * 8, (hi - b) * 8)
            lo = hi
        }
        var swap = src
        src = dst
        dst = swap
        width *= 2
    }
    // `src` holds the sorted elements; it becomes the list's storage.
    __store64(out + 24, src)
    __rt_free(dst, n * 8)
    return out
}

// ---- output ----
//
// Standard output goes through a buffer. It is written out when it is full,
// when the program ends, and after every line when the output is a terminal.

fn __rt_write_all(fd: int, p: int, n: int) {
    var done = 0
    while done < n {
        var written = __syscall(1, fd, p + done, n - done, 0, 0, 0)
        if written > 0 {
            done += written
        } else if written != -4 {    // -4: interrupted, try again
            return
        }
    }
}

fn __rt_out_init() -> int {
    var state = __state()
    var buffer = __rt_map(__OUT_SIZE)
    __store64(state + __S_OUT, buffer)
    // ioctl(1, TCGETS, scratch) only succeeds on a terminal. The buffer is
    // still empty, so it can serve as scratch space.
    var kind = 2
    if __syscall(16, 1, 21505, buffer, 0, 0, 0) == 0 {
        kind = 1
    }
    __store64(state + __S_TERMINAL, kind)
    return buffer
}

fn __rt_flush() {
    var state = __state()
    var used = __load64(state + __S_OUT_USED)
    if used > 0 {
        __store64(state + __S_OUT_USED, 0)
        __rt_write_all(1, __load64(state + __S_OUT), used)
    }
}

fn __rt_out(source: int, n: int) {
    var state = __state()
    var buffer = __load64(state + __S_OUT)
    if buffer == 0 {
        buffer = __rt_out_init()
    }
    var used = __load64(state + __S_OUT_USED)
    if used + n > __OUT_SIZE {
        __rt_flush()
        used = 0
        if n > __OUT_SIZE {
            __rt_write_all(1, source, n)
            return
        }
    }
    __copy(buffer + used, source, n)
    __store64(state + __S_OUT_USED, used + n)
}

// `print`: writes the strings whose addresses sit on the stack (laid out as
// for __rt_concat_n), then a line break.
fn __rt_print_pieces(pieces: int, n: int) {
    var i = n - 1
    while i >= 0 {
        var piece = __load64(pieces + i * 8)
        __rt_out(piece + 16, __load32(piece + 8))
        i -= 1
    }
    var newline = "\n"
    __rt_out(__str_ptr(newline) + 16, 1)
    if __load64(__state() + __S_TERMINAL) == 1 {
        __rt_flush()
    }
}

// Writes a string right away, without the buffer (used for error messages).
fn __rt_write(fd: int, s: string) {
    var p = __str_ptr(s)
    __rt_write_all(fd, p + 16, __load32(p + 8))
}

fn __rt_exit(code: int) {
    __rt_flush()
    __syscall(231, code, 0, 0, 0, 0, 0)
}

fn __rt_panic(message: string) {
    __rt_flush()
    __rt_write(2, "panic: ")
    __rt_write(2, message)
    __rt_write(2, "\n")
    __syscall(231, 2, 0, 0, 0, 0, 0)
}

// `main` returned an error that nobody handled.
fn __rt_main_failed(message: string) {
    __rt_flush()
    __rt_write(2, "error: ")
    __rt_write(2, message)
    __rt_write(2, "\n")
    __syscall(231, 1, 0, 0, 0, 0, 0)
}

fn __rt_fatal(message: string) {
    __rt_write(2, "fatal: ")
    __rt_write(2, message)
    __rt_write(2, "\n")
    __syscall(231, 2, 0, 0, 0, 0, 0)
}
