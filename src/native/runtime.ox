// The Onyx native runtime, written in Onyx.
//
// It is compiled together with every native program. The functions here are
// called by the code the compiler generates; they are built on a handful of
// low-level operations that only this file may use:
//
//   __syscall(n, a, b, c, d, e, f)   call the Linux kernel
//   __load8(addr) / __store8(addr, v)     read / write one byte
//   __load64(addr) / __store64(addr, v)   read / write 8 bytes
//   __state()                        address of the runtime's private memory page
//   __str_ptr(s) / __ptr_str(p)      view a string as an address and back
//
// A string is an address pointing to its length (8 bytes) followed by its
// UTF-8 bytes.

// ---- memory ----
//
// state + 0: next free address      state + 8: end of the current chunk
//
// For now memory is only handed out, never taken back.

fn __rt_alloc(size: int) -> int {
    var state = __state()
    var need = (size + 7) / 8 * 8
    var next = __load64(state)
    if next + need > __load64(state + 8) {
        var chunk = 1048576
        if need > chunk {
            chunk = (need + 4095) / 4096 * 4096
        }
        // mmap(NULL, chunk, READ | WRITE, PRIVATE | ANONYMOUS, -1, 0)
        next = __syscall(9, 0, chunk, 3, 34, -1, 0)
        if next < 0 && next > -4096 {
            __rt_fatal("out of memory")
        }
        __store64(state + 8, next + chunk)
    }
    __store64(state, next + need)
    return next
}

fn __rt_copy(dst: int, src: int, n: int) {
    var i = 0
    while i < n {
        __store8(dst + i, __load8(src + i))
        i += 1
    }
}

// ---- strings ----

fn __rt_new_str(len: int) -> int {
    var p = __rt_alloc(8 + len)
    __store64(p, len)
    return p
}

fn __rt_concat(a: string, b: string) -> string {
    var pa = __str_ptr(a)
    var pb = __str_ptr(b)
    var la = __load64(pa)
    var lb = __load64(pb)
    var p = __rt_new_str(la + lb)
    __rt_copy(p + 8, pa + 8, la)
    __rt_copy(p + 8 + la, pb + 8, lb)
    return __ptr_str(p)
}

// Number of characters (not bytes): UTF-8 continuation bytes look like 10xxxxxx.
fn __rt_str_len(s: string) -> int {
    var p = __str_ptr(s)
    var n = __load64(p)
    var count = 0
    var i = 0
    while i < n {
        var byte = __load8(p + 8 + i)
        if byte < 128 || byte >= 192 {
            count += 1
        }
        i += 1
    }
    return count
}

// Negative, zero or positive, like a - b.
fn __rt_str_cmp(a: string, b: string) -> int {
    var pa = __str_ptr(a)
    var pb = __str_ptr(b)
    var la = __load64(pa)
    var lb = __load64(pb)
    var i = 0
    while i < la && i < lb {
        var d = __load8(pa + 8 + i) - __load8(pb + 8 + i)
        if d != 0 {
            return d
        }
        i += 1
    }
    return la - lb
}

fn __rt_str_eq(a: string, b: string) -> bool {
    if __load64(__str_ptr(a)) != __load64(__str_ptr(b)) {
        return false
    }
    return __rt_str_cmp(a, b) == 0
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
    __rt_copy(p + 8, tmp + i, 24 - i)
    return __ptr_str(p)
}

fn __rt_bool_str(b: bool) -> string {
    if b {
        return "true"
    }
    return "false"
}

// ---- output ----

fn __rt_write(fd: int, s: string) {
    var p = __str_ptr(s)
    var n = __load64(p)
    var done = 0
    while done < n {
        var written = __syscall(1, fd, p + 8 + done, n - done, 0, 0, 0)
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
