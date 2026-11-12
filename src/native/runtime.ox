// The Onyx native runtime, written in Onyx.
//
// It is compiled together with every native program. The functions here are
// called by the code the compiler generates; they are built on a handful of
// low-level operations that only this file may use:
//
//   __syscall(n, a, b, c, d, e, f)        call the Linux kernel
//   __load8(addr) / __store8(addr, v)     read / write one byte
//   __load64(addr) / __store64(addr, v)   read / write 8 bytes
//   __state()                             address of the runtime's private memory
//   __str_ptr(s) / __ptr_str(p)           view a string as an address and back
//   __td_string()                         type descriptor of `string`
//
// OBJECTS
//
// Every value that lives on the heap (string, list, struct) starts with:
//
//   +0   reference count: how many variables, fields or list slots point here.
//        A negative count marks a constant that is never released.
//   +8   type descriptor: a table written by the compiler (see below)
//
//   string:  +16 length in bytes      +24 the UTF-8 bytes
//   list:    +16 length  +24 capacity +32 address of the elements (8 bytes each)
//   struct:  +16 first field, +24 second field, ...
//
// TYPE DESCRIPTORS
//
//   +0 kind:  0 int   1 bool   2 float   3 string   4 list   5 struct   6 interface
//   list:     +8 descriptor of the elements
//   struct:   +8 name   +16 number of fields   +24 method table
//             then for each field: its name, its descriptor
//   method table: +0 count, then for each method: its name, its address
//
// Kinds 3 and above are references: copying one retains it, dropping one
// releases it. An interface value is the object itself; its real type is read
// from the object's header.
//
// OWNERSHIP
//
// A function owns its parameters and releases them when it returns, and a
// returned reference belongs to the caller. This is automatic for parameters
// typed `string`. Parameters typed `int` that hold an address are only
// borrowed: the function must not release them unless it says so.

// ---- memory ----
//
// state +0   next free address of the current chunk
//       +8   end of the current chunk
//       +16  number of live objects
//       +24  64 free lists, one per block size (16, 32, ... 1024 bytes)
//
// Each block is preceded by its total size. Small blocks are carved from
// 1 MiB chunks and recycled through the free lists; big ones get their own
// mapping and are returned to the kernel.

fn __rt_map(size: int) -> int {
    // mmap(NULL, size, READ | WRITE, PRIVATE | ANONYMOUS, -1, 0)
    var p = __syscall(9, 0, size, 3, 34, -1, 0)
    if p < 0 && p > -4096 {
        __rt_fatal("out of memory")
    }
    return p
}

fn __rt_alloc(size: int) -> int {
    var total = (size + 8 + 15) / 16 * 16
    if total > 1024 {
        var pages = (total + 4095) / 4096 * 4096
        var big = __rt_map(pages)
        __store64(big, pages)
        return big + 8
    }
    var state = __state()
    var slot = state + 24 + (total / 16 - 1) * 8
    var block = __load64(slot)
    if block != 0 {
        // Reuse a freed block; its first word links to the next free one.
        __store64(slot, __load64(block))
    } else {
        block = __load64(state)
        if block + total > __load64(state + 8) {
            block = __rt_map(1048576)
            __store64(state + 8, block + 1048576)
        }
        __store64(state, block + total)
    }
    __store64(block, total)
    return block + 8
}

fn __rt_free(p: int) {
    var block = p - 8
    var total = __load64(block)
    if total > 1024 {
        __syscall(11, block, total, 0, 0, 0, 0)    // munmap
        return
    }
    var slot = __state() + 24 + (total / 16 - 1) * 8
    __store64(block, __load64(slot))
    __store64(slot, block)
}

fn __rt_copy(dst: int, src: int, n: int) {
    var i = 0
    while i < n {
        __store8(dst + i, __load8(src + i))
        i += 1
    }
}

// ---- objects and reference counting ----

// Allocates an object with `size` bytes after its header, owned by the caller.
fn __rt_new(td: int, size: int) -> int {
    var p = __rt_alloc(16 + size)
    __store64(p, 1)
    __store64(p + 8, td)
    var state = __state()
    __store64(state + 16, __load64(state + 16) + 1)
    return p
}

fn __rt_retain(p: int) {
    var count = __load64(p)
    if count >= 0 {
        __store64(p, count + 1)
    }
}

fn __rt_release(p: int) {
    var count = __load64(p)
    if count < 0 {
        return
    }
    if count > 1 {
        __store64(p, count - 1)
        return
    }
    // That was the last reference: let go of what the object holds, then free it.
    var td = __load64(p + 8)
    var kind = __load64(td)
    if kind == 4 {
        var data = __load64(p + 32)
        if __load64(__load64(td + 8)) >= 3 {
            var n = __load64(p + 16)
            var i = 0
            while i < n {
                __rt_release(__load64(data + i * 8))
                i += 1
            }
        }
        if data != 0 {
            __rt_free(data)
        }
    } else if kind == 5 {
        var n = __load64(td + 16)
        var i = 0
        while i < n {
            if __load64(__load64(td + 40 + i * 16)) >= 3 {
                __rt_release(__load64(p + 16 + i * 8))
            }
            i += 1
        }
    }
    __rt_free(p)
    var state = __state()
    __store64(state + 16, __load64(state + 16) - 1)
}

// Used by `--leak-check`: every object must have been released by now.
fn __rt_leak_check() {
    var live = __load64(__state() + 16)
    if live != 0 {
        __rt_write(2, "leak check: " + __rt_int_str(live) + " object(s) were never released\n")
        __rt_exit(3)
    }
}

fn __rt_find_method(obj: int, name: int) -> int {
    var table = __load64(__load64(obj + 8) + 24)
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

fn __rt_new_str(len: int) -> int {
    var p = __rt_new(__td_string(), 8 + len)
    __store64(p + 16, len)
    return p
}

fn __rt_concat(a: string, b: string) -> string {
    var pa = __str_ptr(a)
    var pb = __str_ptr(b)
    var la = __load64(pa + 16)
    var lb = __load64(pb + 16)
    var p = __rt_new_str(la + lb)
    __rt_copy(p + 24, pa + 24, la)
    __rt_copy(p + 24 + la, pb + 24, lb)
    return __ptr_str(p)
}

// Number of characters (not bytes): UTF-8 continuation bytes look like 10xxxxxx.
fn __rt_str_len(s: string) -> int {
    var p = __str_ptr(s)
    var n = __load64(p + 16)
    var count = 0
    var i = 0
    while i < n {
        var byte = __load8(p + 24 + i)
        if byte < 128 || byte >= 192 {
            count += 1
        }
        i += 1
    }
    return count
}

// Compares two borrowed strings: negative, zero or positive, like a - b.
fn __rt_bytes_cmp(pa: int, pb: int) -> int {
    var la = __load64(pa + 16)
    var lb = __load64(pb + 16)
    var i = 0
    while i < la && i < lb {
        var d = __load8(pa + 24 + i) - __load8(pb + 24 + i)
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
    return __rt_bytes_cmp(__str_ptr(a), __str_ptr(b)) == 0
}

fn __rt_int_str(n: int) -> string {
    if n == 0 {
        return "0"
    }
    // Digits are produced from the last one, into a 24-byte scratch area.
    var tmp = __rt_alloc(24)
    var i = 24
    var v = n
    while v != 0 {
        var digit = v % 10
        if digit < 0 {
            digit = -digit
        }
        i -= 1
        __store8(tmp + i, 48 + digit)
        v = v / 10
    }
    if n < 0 {
        i -= 1
        __store8(tmp + i, 45)
    }
    var p = __rt_new_str(24 - i)
    __rt_copy(p + 24, tmp + i, 24 - i)
    __rt_free(tmp)
    return __ptr_str(p)
}

fn __rt_bool_str(b: bool) -> string {
    if b {
        return "true"
    }
    return "false"
}

// A borrowed string, between double quotes and with special characters escaped.
fn __rt_quote(p: int) -> string {
    var n = __load64(p + 16)
    var extra = 0
    var i = 0
    while i < n {
        var c = __load8(p + 24 + i)
        if c == 34 || c == 92 || c == 10 || c == 9 || c == 13 {
            extra += 1
        }
        i += 1
    }
    var out = __rt_new_str(n + extra + 2)
    var w = out + 24
    __store8(w, 34)
    w += 1
    i = 0
    while i < n {
        var c = __load8(p + 24 + i)
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

// The text form of a borrowed value. Strings nested in a list or a struct are quoted.
fn __rt_repr(v: int, td: int, quoted: bool) -> string {
    var kind = __load64(td)
    if kind == 0 {
        return __rt_int_str(v)
    }
    if kind == 1 {
        return __rt_bool_str(v != 0)
    }
    if kind == 3 {
        if quoted {
            return __rt_quote(v)
        }
        __rt_retain(v)
        return __ptr_str(v)
    }
    if kind == 6 {
        return __rt_repr(v, __load64(v + 8), quoted)
    }
    if kind == 4 {
        var elem = __load64(td + 8)
        var n = __load64(v + 16)
        var data = __load64(v + 32)
        var items = "["
        var i = 0
        while i < n {
            if i > 0 {
                items += ", "
            }
            items += __rt_repr(__load64(data + i * 8), elem, true)
            i += 1
        }
        return items + "]"
    }
    var out = __ptr_str(__load64(td + 8)) + "\{"
    var n = __load64(td + 16)
    var i = 0
    while i < n {
        if i > 0 {
            out += ", "
        }
        out += __ptr_str(__load64(td + 32 + i * 16)) + ": "
        out += __rt_repr(__load64(v + 16 + i * 8), __load64(td + 40 + i * 16), true)
        i += 1
    }
    return out + "\}"
}

// Like __rt_repr, but takes ownership of the value.
fn __rt_str_of(v: int, td: int) -> string {
    var s = __rt_repr(v, td, false)
    if __load64(td) >= 3 {
        __rt_release(v)
    }
    return s
}

// Structural equality of two borrowed values.
fn __rt_eq(a: int, b: int, td: int) -> bool {
    var kind = __load64(td)
    if kind < 3 || a == b {
        return a == b
    }
    if kind == 3 {
        return __rt_bytes_cmp(a, b) == 0
    }
    if kind == 6 {
        var real = __load64(a + 8)
        if real != __load64(b + 8) {
            return false
        }
        return __rt_eq(a, b, real)
    }
    if kind == 4 {
        var n = __load64(a + 16)
        if n != __load64(b + 16) {
            return false
        }
        var elem = __load64(td + 8)
        var i = 0
        while i < n {
            if !__rt_eq(__load64(__load64(a + 32) + i * 8), __load64(__load64(b + 32) + i * 8), elem) {
                return false
            }
            i += 1
        }
        return true
    }
    var n = __load64(td + 16)
    var i = 0
    while i < n {
        if !__rt_eq(__load64(a + 16 + i * 8), __load64(b + 16 + i * 8), __load64(td + 40 + i * 16)) {
            return false
        }
        i += 1
    }
    return true
}

// Like __rt_eq, but takes ownership of both values.
fn __rt_equals(a: int, b: int, td: int) -> bool {
    var same = __rt_eq(a, b, td)
    if __load64(td) >= 3 {
        __rt_release(a)
        __rt_release(b)
    }
    return same
}

// ---- lists ----
//
// These functions borrow the list. A value given to push / insert / set moves
// into the list; a value returned by `remove` moves out of it. `get` returns
// the element without retaining it.

fn __rt_list_new(td: int, capacity: int) -> int {
    var list = __rt_new(td, 24)
    var data = 0
    if capacity > 0 {
        data = __rt_alloc(capacity * 8)
    }
    __store64(list + 16, 0)
    __store64(list + 24, capacity)
    __store64(list + 32, data)
    return list
}

fn __rt_list_holds_refs(list: int) -> bool {
    return __load64(__load64(__load64(list + 8) + 8)) >= 3
}

fn __rt_list_len(list: int) -> int {
    return __load64(list + 16)
}

fn __rt_list_check(list: int, i: int, limit: int) {
    if i < 0 || i >= limit {
        __rt_panic("index out of bounds: index " + __rt_int_str(i) + ", length " + __rt_int_str(__load64(list + 16)))
    }
}

fn __rt_list_push(list: int, v: int) {
    var n = __load64(list + 16)
    var data = __load64(list + 32)
    if n == __load64(list + 24) {
        var capacity = n * 2
        if capacity < 4 {
            capacity = 4
        }
        var bigger = __rt_alloc(capacity * 8)
        if data != 0 {
            __rt_copy(bigger, data, n * 8)
            __rt_free(data)
        }
        data = bigger
        __store64(list + 24, capacity)
        __store64(list + 32, data)
    }
    __store64(data + n * 8, v)
    __store64(list + 16, n + 1)
}

fn __rt_list_get(list: int, i: int) -> int {
    __rt_list_check(list, i, __load64(list + 16))
    return __load64(__load64(list + 32) + i * 8)
}

fn __rt_list_set(list: int, i: int, v: int) {
    __rt_list_check(list, i, __load64(list + 16))
    var slot = __load64(list + 32) + i * 8
    var old = __load64(slot)
    __store64(slot, v)
    if __rt_list_holds_refs(list) {
        __rt_release(old)
    }
}

fn __rt_list_insert(list: int, i: int, v: int) {
    var n = __load64(list + 16)
    __rt_list_check(list, i, n + 1)
    __rt_list_push(list, v)
    // Shift the tail one slot to the right, from the end.
    var data = __load64(list + 32)
    var k = n
    while k > i {
        __store64(data + k * 8, __load64(data + (k - 1) * 8))
        k -= 1
    }
    __store64(data + i * 8, v)
}

fn __rt_list_remove(list: int, i: int) -> int {
    var n = __load64(list + 16)
    __rt_list_check(list, i, n)
    var data = __load64(list + 32)
    var removed = __load64(data + i * 8)
    var k = i
    while k < n - 1 {
        __store64(data + k * 8, __load64(data + (k + 1) * 8))
        k += 1
    }
    __store64(list + 16, n - 1)
    return removed
}

fn __rt_list_clear(list: int) {
    if __rt_list_holds_refs(list) {
        var n = __load64(list + 16)
        var data = __load64(list + 32)
        var i = 0
        while i < n {
            __rt_release(__load64(data + i * 8))
            i += 1
        }
    }
    __store64(list + 16, 0)
}

fn __rt_list_index_of(list: int, v: int) -> int {
    var elem = __load64(__load64(list + 8) + 8)
    var n = __load64(list + 16)
    var data = __load64(list + 32)
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
    var out = __rt_list_new(__load64(list + 8), to - from)
    var refs = __rt_list_holds_refs(list)
    var data = __load64(list + 32)
    var i = from
    while i < to {
        var v = __load64(data + i * 8)
        if refs {
            __rt_retain(v)
        }
        __rt_list_push(out, v)
        i += 1
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
    var n = __load64(list + 16)
    var start = __rt_clamp_index(from, n)
    var end = __rt_clamp_index(to, n)
    if end < start {
        end = start
    }
    return __rt_list_copy(list, start, end)
}

fn __rt_list_reverse(list: int) -> int {
    var n = __load64(list + 16)
    var out = __rt_list_copy(list, 0, n)
    var data = __load64(out + 32)
    var i = 0
    while i < n / 2 {
        var tmp = __load64(data + i * 8)
        __store64(data + i * 8, __load64(data + (n - 1 - i) * 8))
        __store64(data + (n - 1 - i) * 8, tmp)
        i += 1
    }
    return out
}

fn __rt_list_join(list: int, separator: int) -> string {
    var elem = __load64(__load64(list + 8) + 8)
    var n = __load64(list + 16)
    var data = __load64(list + 32)
    var out = ""
    var i = 0
    while i < n {
        if i > 0 {
            out += __rt_repr(separator, __td_string(), false)
        }
        out += __rt_repr(__load64(data + i * 8), elem, false)
        i += 1
    }
    return out
}

// A sorted copy (stable merge sort). Works on ints and strings.
fn __rt_list_sort(list: int) -> int {
    var n = __load64(list + 16)
    var out = __rt_list_copy(list, 0, n)
    if n < 2 {
        return out
    }
    var strings = __rt_list_holds_refs(list)
    var src = __load64(out + 32)
    var dst = __rt_alloc(n * 8)
    var width = 1
    while width < n {
        var lo = 0
        while lo < n {
            var mid = lo + width
            if mid > n {
                mid = n
            }
            var hi = lo + 2 * width
            if hi > n {
                hi = n
            }
            // Merge src[lo, mid) and src[mid, hi) into dst[lo, hi).
            var a = lo
            var b = mid
            var k = lo
            while k < hi {
                var take_left = b >= hi
                if a < mid && b < hi {
                    var x = __load64(src + a * 8)
                    var y = __load64(src + b * 8)
                    if strings {
                        take_left = __rt_bytes_cmp(x, y) <= 0
                    } else {
                        take_left = x <= y
                    }
                }
                if take_left {
                    __store64(dst + k * 8, __load64(src + a * 8))
                    a += 1
                } else {
                    __store64(dst + k * 8, __load64(src + b * 8))
                    b += 1
                }
                k += 1
            }
            lo += 2 * width
        }
        var swap = src
        src = dst
        dst = swap
        width *= 2
    }
    // `src` now holds the sorted elements; keep it as the list's storage.
    __store64(out + 32, src)
    __store64(out + 24, n)
    __rt_free(dst)
    return out
}

// ---- output ----

fn __rt_write(fd: int, s: string) {
    var p = __str_ptr(s)
    var n = __load64(p + 16)
    var done = 0
    while done < n {
        var written = __syscall(1, fd, p + 24 + done, n - done, 0, 0, 0)
        if written <= 0 {
            return
        }
        done += written
    }
}

fn __rt_print(s: string) {
    __rt_write(1, s + "\n")
}

fn __rt_exit(code: int) {
    __syscall(231, code, 0, 0, 0, 0, 0)
}

fn __rt_panic(message: string) {
    __rt_write(2, "panic: " + message + "\n")
    __rt_exit(2)
}

fn __rt_fatal(message: string) {
    __rt_write(2, "fatal: ")
    __rt_write(2, message)
    __rt_write(2, "\n")
    __rt_exit(2)
}
