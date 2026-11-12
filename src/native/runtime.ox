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
//
// TYPE DESCRIPTORS (8-byte words)
//
//   +0 kind:  0 int   1 bool   2 float   3 string   4 list   5 struct   6 interface
//   list:     +8 descriptor of the elements
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

// The runtime's private memory, at __state():
const __S_END = 8          // end of the current chunk (its next free byte is at +0)
const __S_LIVE = 16        // number of live objects
const __S_OUT = 24         // address of the output buffer
const __S_OUT_USED = 32    // bytes waiting in it
const __S_TERMINAL = 40    // 1 when standard output is a terminal, 2 when it is not
const __S_FREE = 56        // free blocks of n bytes are chained from __S_FREE + n

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

// Number of characters (not bytes): UTF-8 continuation bytes look like 10xxxxxx.
fn __rt_str_len(s: string) -> int {
    var p = __str_ptr(s)
    var n = __load32(p + 8)
    var count = 0
    var i = 0
    // Eight bytes at a time while they are all plain ASCII (high bit clear):
    // -9187201950435737472 is 0x8080808080808080.
    while i + 8 <= n && __and(__load64(p + 16 + i), -9187201950435737472) == 0 {
        count += 8
        i += 8
    }
    while i < n {
        var byte = __load8(p + 16 + i)
        if byte < 128 || byte >= 192 {
            count += 1
        }
        i += 1
    }
    return count
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

// ---- generic operations, driven by type descriptors ----

// The text form of a value. Strings nested in a list or a struct are quoted.
fn __rt_repr(v: int, td: int, quoted: bool) -> string {
    var kind = __load64(td)
    if kind == 0 {
        return __rt_int_str(v)
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

// A sorted copy (stable merge sort). Works on ints and strings.
fn __rt_list_sort(list: int) -> int {
    var n = __load64(list + 8)
    var out = __rt_list_copy(list, 0, n)
    if n < 2 {
        return out
    }
    var strings = __rt_list_holds_refs(list)
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

fn __rt_fatal(message: string) {
    __rt_write(2, "fatal: ")
    __rt_write(2, message)
    __rt_write(2, "\n")
    __syscall(231, 2, 0, 0, 0, 0, 0)
}
