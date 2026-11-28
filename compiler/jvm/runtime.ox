// The runtime of the JVM target, written in Onyx: what the code generator
// (compiler/jvm.ox) calls for the built-in functions that take more than a
// few instructions, for maps, and for comparing and showing values.
//
// It reaches Java through `__jvm`, which only the runtime may use (see
// checker.ox): `__jvm("static java/lang/Long.toString(J)Ljava/lang/String;", n)`.
// `__object` is any Java object; every value converts to it and back.
//
// Only the functions that a program uses are compiled into it. Its
// top-level variables get their values before those of the program.
//
// Inside the runtime, `list[i]` and the other operations of the language
// may themselves call functions of the runtime: those functions must not
// use the operation they implement (`__jrt_list_at` uses `__jvm`, not
// `list[i]`).

// ---- output ----

var __jrt_utf8 = __jvm("get java/nio/charset/StandardCharsets.UTF_8:Ljava/nio/charset/Charset;")

// Standard output, through a buffer, in UTF-8 whatever the system's language.
var __jrt_stdout = __jvm("new java/io/BufferedOutputStream(Ljava/io/OutputStream;I)", __jvm("new java/io/FileOutputStream(Ljava/io/FileDescriptor;)", __jvm("get java/io/FileDescriptor.out:Ljava/io/FileDescriptor;")), 65536)

// On a terminal, each line shows up as soon as it is printed.
var __jrt_interactive = __jrt_is_terminal(1)

fn __jrt_bytes_of(text: string) -> __object {
    return __jvm("virtual java/lang/String.getBytes(Ljava/nio/charset/Charset;)[B", text, __jrt_utf8)
}

fn __jrt_print(line: string) {
    __jvm("virtual java/io/OutputStream.write([B)V", __jrt_stdout, __jrt_bytes_of(line + "\n"))
    if __jrt_interactive {
        __jrt_flush()
    }
}

fn __jrt_flush() {
    __jvm("virtual java/io/OutputStream.flush()V", __jrt_stdout)
}

// Errors go out right away, after what was printed before.
fn __jrt_eprint(line: string) {
    __jrt_flush()
    var err = __jvm("get java/lang/System.err:Ljava/io/PrintStream;")
    __jvm("virtual java/io/PrintStream.write([B)V", err, __jrt_bytes_of(line + "\n"))
    __jvm("virtual java/io/PrintStream.flush()V", err)
}

fn __jrt_exit(code: int) {
    __jrt_flush()
    __jvm("static java/lang/System.exit(I)V", code)
}

// The program is done.
fn __jrt_finish() {
    __jrt_flush()
}

// `main` has returned, in a program with tasks: they run until none of them
// can go on.
fn __jrt_run_tasks() {
    if __jrt_tasks_on {
        __jrt_main_done = true
        if __jrt_ready.len() > 0 || __jrt_timers.len() > 0 {
            __jrt_schedule(__jrt_current_task)
        }
    }
}

// Is this file descriptor (1 or 2) a terminal? On Linux, the file it
// stands for says so; elsewhere, Java's console does.
fn __jrt_is_terminal(fd: int) -> bool {
    var link = __jvm("new java/io/File(Ljava/lang/String;)", "/proc/self/fd/{fd}")
    var target = __jvm("static! java/nio/file/Files.readSymbolicLink(Ljava/nio/file/Path;)Ljava/nio/file/Path;", __jvm("virtual java/io/File.toPath()Ljava/nio/file/Path;", link)) catch err {
        return __jvm("is java/io/Console", __jvm("static java/lang/System.console()Ljava/io/Console;"))
    }
    var name = __jvm("virtual java/lang/Object.toString()Ljava/lang/String;", target)
    return name.starts_with("/dev/pts/") || name.starts_with("/dev/tty")
}

// ---- what ends a program ----

fn __jrt_message(problem: __object) -> string {
    var message = __jvm("virtual java/lang/Throwable.getMessage()Ljava/lang/String;", problem)
    if __jvm("same", message, __jvm("null")) {
        return ""
    }
    return message
}

// What ends the program when nothing handled it: an error that `main`
// returned, or a bug found on the way.
fn __jrt_crash(problem: __object) {
    if __jvm("is java/io/IOException", problem) && __jrt_message(problem).contains("Broken pipe") {
        // The reader of the output went away (`... | head`): stop quietly.
        __jvm("static java/lang/System.exit(I)V", 0)
    }
    if __jvm("is onyx/Failure", problem) {
        __jrt_eprint("error: " + __jrt_message(problem))
        __jrt_exit(1)
    }
    __jrt_eprint("panic: " + __jrt_why(problem))
    __jrt_exit(2)
}

// What a bug is, in words.
fn __jrt_why(problem: __object) -> string {
    if __jvm("is onyx/Panic", problem) {
        return __jrt_message(problem)
    }
    if __jvm("is onyx/ExpectFail", problem) {
        return "expectation failed at " + __jrt_message(problem)
    }
    if __jvm("is java/lang/ArithmeticException", problem) {
        return "division by zero"
    }
    if __jvm("is java/lang/StackOverflowError", problem) {
        return "stack overflow (infinite recursion?)"
    }
    if __jvm("is java/lang/OutOfMemoryError", problem) {
        return "out of memory"
    }
    return "internal error: " + __jvm("virtual java/lang/Object.toString()Ljava/lang/String;", problem)
}

// A Java exception, as an Onyx error: problems with files get the words
// the other targets use.
fn __jrt_failure_of(problem: __object) -> __object {
    if __jvm("is onyx/Failure", problem) {
        return problem
    }
    // What went wrong on another thread comes wrapped.
    if __jvm("is java/util/concurrent/ExecutionException", problem) || __jvm("is java/util/concurrent/CompletionException", problem) {
        var cause = __jvm("virtual java/lang/Throwable.getCause()Ljava/lang/Throwable;", problem)
        if !__jrt_is_null(cause) {
            return __jrt_failure_of(cause)
        }
    }
    return __jvm("new onyx/Failure(Ljava/lang/String;)", __jrt_reason(problem))
}

fn __jrt_reason(problem: __object) -> string {
    var message = __jrt_message(problem)
    if __jvm("is java/nio/file/NoSuchFileException", problem) || message.contains("No such file") || message.contains("error=2,") {
        return "no such file or directory"
    }
    if __jvm("is java/nio/file/AccessDeniedException", problem) || message.contains("Permission denied") || message.contains("error=13,") {
        return "permission denied"
    }
    if __jvm("is java/nio/file/FileAlreadyExistsException", problem) {
        return "file exists"
    }
    if __jvm("is java/nio/file/DirectoryNotEmptyException", problem) {
        return "directory not empty"
    }
    if __jvm("is java/nio/file/NotDirectoryException", problem) || message.contains("Not a directory") {
        return "not a directory"
    }
    if message.contains("Is a directory") {
        return "is a directory"
    }
    if message.contains("No space left") {
        return "no space left on device"
    }
    if message.contains("error=8,") {
        return "exec format error"
    }
    if __jvm("is java/net/ConnectException", problem) {
        return "connection refused"
    }
    if __jvm("is java/net/UnknownHostException", problem) {
        return "unknown host"
    }
    if __jvm("is java/net/http/HttpTimeoutException", problem) {
        return "timed out"
    }
    if message == "" {
        return __jvm("virtual java/lang/Object.toString()Ljava/lang/String;", problem)
    }
    return message
}

// ---- checks (`onyx test`) ----

var __jrt_checks_failed = 0

fn __jrt_tests_begin(count: int) {
    var s = "s"
    if count == 1 {
        s = ""
    }
    __jrt_print("running {count} check{s}")
}

// A check is done: `problem` is what stopped it, if anything did.
fn __jrt_test_done(name: string, problem: __object) {
    if __jvm("same", problem, __jvm("null")) {
        __jrt_print("  ok    " + name)
        return
    }
    __jrt_checks_failed += 1
    var why = "panic: " + __jrt_why(problem)
    if __jvm("is onyx/ExpectFail", problem) {
        why = "expectation failed at " + __jrt_message(problem)
    } else if __jvm("is onyx/Failure", problem) {
        why = "error: " + __jrt_message(problem)
    }
    __jrt_print("  FAIL  " + name + " (" + why + ")")
}

fn __jrt_tests_end(count: int) {
    __jrt_print("")
    __jrt_print("{count - __jrt_checks_failed} passed, {__jrt_checks_failed} failed")
    if __jrt_checks_failed > 0 {
        __jrt_exit(1)
    }
}

// ---- comparing and showing values ----

fn __jrt_is_null(v: __object) -> bool {
    return __jvm("same", v, __jvm("null"))
}

// `a == b`, for values of any type: lists, maps, structs and enums are
// equal when what they hold is.
fn __jrt_eq(a: __object, b: __object) -> bool {
    if __jvm("is java/lang/Double", a) {
        if !__jvm("is java/lang/Double", b) {
            return false
        }
        // As numbers, even when they are the same object: NaN is not equal
        // to itself, -0.0 is 0.0.
        var x: float = a
        var y: float = b
        return x == y
    }
    if __jvm("same", a, b) {
        return true
    }
    if __jrt_is_null(a) || __jrt_is_null(b) {
        return false
    }
    if __jvm("is java/lang/Long", a) || __jvm("is java/lang/String", a) || __jvm("is java/lang/Boolean", a) {
        return __jvm("virtual java/lang/Object.equals(Ljava/lang/Object;)Z", a, b)
    }
    if __jvm("is java/util/ArrayList", a) {
        if !__jvm("is java/util/ArrayList", b) {
            return false
        }
        var xs: [__object] = a
        var ys: [__object] = b
        if xs.len() != ys.len() {
            return false
        }
        for i in 0..xs.len() {
            if !__jrt_eq(xs[i], ys[i]) {
                return false
            }
        }
        return true
    }
    if __jvm("is onyx/S$__JrtMap", a) {
        if !__jvm("is onyx/S$__JrtMap", b) {
            return false
        }
        var m: __JrtMap = a
        var n: __JrtMap = b
        if m.size != n.size {
            return false
        }
        var i = m.next(0)
        while i >= 0 {
            var at = n.find(m.keys[i])
            if at < 0 || !__jrt_eq(m.values[i], n.values[at]) {
                return false
            }
            i = m.next(i + 1)
        }
        return true
    }
    if __jvm("is onyx/S$__JrtWeak", a) {
        // Two weak references are equal when they point to the same object.
        if !__jvm("is onyx/S$__JrtWeak", b) {
            return false
        }
        var w: __JrtWeak = a
        var v: __JrtWeak = b
        return __jvm("same", w.target, v.target)
    }
    if __jvm("is onyx/Failure", a) {
        return __jvm("is onyx/Failure", b) && __jrt_message(a) == __jrt_message(b)
    }
    if __jvm("is onyx/S$__JrtChan", a) {
        // A channel is only equal to itself.
        return false
    }
    if __jvm("is onyx/Value", a) {
        return __jvm("interface onyx/Value.v$eq(Ljava/lang/Object;)Z", a, b)
    }
    return false
}

// The text of a value as `print` shows it: a string as it is, anything
// else as in a list.
fn __jrt_str(v: __object) -> string {
    if __jvm("is java/lang/String", v) {
        return v
    }
    return __jrt_repr(v)
}

// The text of a value as it appears in a list: strings in quotes.
fn __jrt_repr(v: __object) -> string {
    if __jrt_is_null(v) {
        return "void"
    }
    if __jvm("is java/lang/String", v) {
        return __jrt_quote(v)
    }
    if __jvm("is java/lang/Long", v) {
        var n: int = v
        return str(n)
    }
    if __jvm("is java/lang/Double", v) {
        var x: float = v
        return __jrt_float_str(x)
    }
    if __jvm("is java/lang/Boolean", v) {
        var b: bool = v
        return str(b)
    }
    if __jvm("is java/util/ArrayList", v) {
        var items: [__object] = v
        var parts: [string] = []
        for item in items {
            parts.push(__jrt_repr(item))
        }
        return "[" + parts.join(", ") + "]"
    }
    if __jvm("is onyx/S$__JrtMap", v) {
        var m: __JrtMap = v
        var parts: [string] = []
        var i = m.next(0)
        while i >= 0 {
            parts.push(__jrt_repr(m.keys[i]) + ": " + __jrt_repr(m.values[i]))
            i = m.next(i + 1)
        }
        return "\{" + parts.join(", ") + "}"
    }
    if __jvm("is onyx/S$__JrtWeak", v) {
        return "weak"
    }
    if __jvm("is onyx/S$__JrtChan", v) {
        return "chan"
    }
    if __jvm("is onyx/Failure", v) {
        return __jrt_message(v)
    }
    if __jvm("is onyx/Value", v) {
        return __jvm("interface onyx/Value.v$repr()Ljava/lang/String;", v)
    }
    if __jvm("is onyx/Fn", v) {
        return "fn"
    }
    return __jvm("virtual java/lang/Object.toString()Ljava/lang/String;", v)
}

// The text of a value of an enum: its name, then what it carries.
fn __jrt_variant(name: string, carried: __object) -> string {
    if __jrt_is_null(carried) {
        return name
    }
    var items: [__object] = carried
    var parts: [string] = []
    for item in items {
        parts.push(__jrt_repr(item))
    }
    return name + "(" + parts.join(", ") + ")"
}

// ---- numbers as text ----

// The text of a float, as the other targets write it: JavaScript's rules,
// with `.0` after a whole number. Java finds the shortest digits that read
// back as the same float; they only have to be laid out.
fn __jrt_float_str(x: float) -> string {
    if x != x {
        return "NaN"
    }
    if x == __jvm("get java/lang/Double.POSITIVE_INFINITY:D") {
        return "Infinity"
    }
    if x == __jvm("get java/lang/Double.NEGATIVE_INFINITY:D") {
        return "-Infinity"
    }
    if x == 0.0 {
        return "0.0"
    }
    var sign = ""
    var magnitude = x
    if x < 0.0 {
        sign = "-"
        magnitude = -x
    }
    // Java writes "123.456" or "1.5E-7": the digits, and where the point goes.
    var java = __jvm("static java/lang/Double.toString(D)Ljava/lang/String;", magnitude)
    var exponent = 0
    var e = java.index_of("E")
    if e >= 0 {
        exponent = parse_int(java.slice(e + 1, java.len())) or 0
        java = java.slice(0, e)
    }
    var point = java.index_of(".")
    var digits = java.replace(".", "")
    // The number is 0.digits * 10^n.
    var n = point + exponent
    while digits.len() > 1 && digits[0] == "0" {
        digits = digits.slice(1, digits.len())
        n -= 1
    }
    while digits.len() > 1 && digits[digits.len() - 1] == "0" {
        digits = digits.slice(0, digits.len() - 1)
    }
    // Java writes at least two digits ("4.9E-324" for 5e-324), and older
    // versions sometimes more than needed: fewer are kept when they read
    // back as the same float.
    var k = digits.len()
    while k > 1 {
        var shorter = parse_int(digits.slice(0, k - 1)) or 0
        if (parse_int(digits[k - 1]) or 0) >= 5 {
            shorter += 1
        }
        var text = str(shorter)
        var at = n
        if text.len() > k - 1 {
            // 99 rounds up to 100: one more digit before the point.
            at += 1
        }
        var back = __jvm("static java/lang/Double.parseDouble(Ljava/lang/String;)D", "0." + text + "e" + str(at))
        if back != magnitude {
            break
        }
        digits = text
        n = at
        while digits.len() > 1 && digits[digits.len() - 1] == "0" {
            digits = digits.slice(0, digits.len() - 1)
        }
        k = digits.len()
    }
    if k <= n && n <= 21 {
        return sign + digits + "0".repeat(n - k) + ".0"
    }
    if 0 < n && n <= 21 {
        return sign + digits.slice(0, n) + "." + digits.slice(n, k)
    }
    if -6 < n && n <= 0 {
        return sign + "0." + "0".repeat(-n) + digits
    }
    var out = sign + digits[0]
    if k > 1 {
        out += "." + digits.slice(1, k)
    }
    var power = n - 1
    if power >= 0 {
        return out + "e+" + str(power)
    }
    return out + "e" + str(power)
}

// A string in quotes, as messages show it.
fn __jrt_quote(text: string) -> string {
    var out = "\""
    for c in text {
        var code = ord(c)
        if c == "\"" || c == "\\" {
            out += "\\" + c
        } else if c == "\n" {
            out += "\\n"
        } else if c == "\t" {
            out += "\\t"
        } else if c == "\r" {
            out += "\\r"
        } else if code == 8 {
            out += "\\b"
        } else if code == 12 {
            out += "\\f"
        } else if code < 0x20 {
            out += "\\u00" + "0123456789abcdef"[code >> 4] + "0123456789abcdef"[code & 15]
        } else {
            out += c
        }
    }
    return out + "\""
}

fn __jrt_is_digit(c: string) -> bool {
    return c >= "0" && c <= "9"
}

fn __jrt_parse_int(text: string) -> int! {
    var s = __jrt_str_trim(text)
    var i = 0
    if s.len() > 0 && (s[0] == "+" || s[0] == "-") {
        i = 1
    }
    var valid = i < s.len()
    for j in i..s.len() {
        if !__jrt_is_digit(s[j]) {
            valid = false
        }
    }
    if valid {
        var value = __jvm("static! java/lang/Long.parseLong(Ljava/lang/String;)J", s.replace("+", "")) catch err {
            fail "cannot convert " + __jrt_quote(text) + " to int"
        }
        return value
    }
    fail "cannot convert " + __jrt_quote(text) + " to int"
}

fn __jrt_parse_float(text: string) -> float! {
    var s = __jrt_str_trim(text)
    // [+-]? (digits [. digits?] | . digits) ([eE] [+-]? digits)?
    var i = 0
    if i < s.len() && (s[i] == "+" || s[i] == "-") {
        i += 1
    }
    var before = 0
    while i < s.len() && __jrt_is_digit(s[i]) {
        i += 1
        before += 1
    }
    var after = 0
    if i < s.len() && s[i] == "." {
        i += 1
        while i < s.len() && __jrt_is_digit(s[i]) {
            i += 1
            after += 1
        }
    }
    var valid = before + after > 0
    if valid && i < s.len() && (s[i] == "e" || s[i] == "E") {
        i += 1
        if i < s.len() && (s[i] == "+" || s[i] == "-") {
            i += 1
        }
        var power = 0
        while i < s.len() && __jrt_is_digit(s[i]) {
            i += 1
            power += 1
        }
        valid = power > 0
    }
    if !valid || i != s.len() {
        fail "cannot convert " + __jrt_quote(text) + " to float"
    }
    return __jvm("static java/lang/Double.parseDouble(Ljava/lang/String;)D", s)
}

// ---- strings ----
//
// Positions and lengths count characters, as on the native target. A Java
// string is made of UTF-16 units, and a character above U+FFFF (most
// emoji) takes two of them. Few strings hold such characters, and Java
// tells at once that a string has none when all its characters are among
// the first 256. The last string whose positions were looked for is kept
// with what is known of it: a loop that goes through a string with `s[i]`
// finds each character from the one before.

var __jrt_at_text = __jvm("null")
// Its number of characters, and whether each one is a single unit.
var __jrt_at_count = 0
var __jrt_at_plain = true
// A character of it, and the unit where that character starts.
var __jrt_at_char = 0
var __jrt_at_unit = 0

// The number of UTF-16 units of a string.
fn __jrt_units(s: string) -> int {
    return __jvm("virtual java/lang/String.length()I", s)
}

// Makes `s` the string whose positions are looked for.
fn __jrt_look_at(s: string) {
    if __jvm("same", s, __jrt_at_text) {
        return
    }
    var units = __jrt_units(s)
    var count = __jvm("virtual java/lang/String.codePointCount(II)I", s, 0, units)
    __jrt_at_text = s
    __jrt_at_count = count
    __jrt_at_plain = count == units
    __jrt_at_char = 0
    __jrt_at_unit = 0
}

// `s.len()`: its number of characters.
fn __jrt_str_len(s: string) -> int {
    __jrt_look_at(s)
    return __jrt_at_count
}

// The unit where the character number `i` of `s` starts (0 <= i <= its
// length).
fn __jrt_unit_of(s: string, i: int) -> int {
    __jrt_look_at(s)
    if __jrt_at_plain {
        return i
    }
    if i < __jrt_at_char {
        __jrt_at_char = 0
        __jrt_at_unit = 0
    }
    __jrt_at_unit = __jvm("virtual java/lang/String.offsetByCodePoints(II)I", s, __jrt_at_unit, i - __jrt_at_char)
    __jrt_at_char = i
    return __jrt_at_unit
}

// Whether each character of `s` is a single unit.
fn __jrt_plain(s: string) -> bool {
    var units = __jrt_units(s)
    return __jvm("virtual java/lang/String.codePointCount(II)I", s, 0, units) == units
}

// `s[i]`: the character number `i`.
fn __jrt_char_at(s: string, i: int) -> string {
    var n = __jrt_str_len(s)
    if i < 0 || i >= n {
        panic("index out of bounds: index {i}, length {n}")
    }
    var at = __jrt_unit_of(s, i)
    var width = 1
    if !__jrt_at_plain {
        width = __jvm("static java/lang/Character.charCount(I)I", __jvm("virtual java/lang/String.codePointAt(I)I", s, at))
    }
    return __jvm("virtual java/lang/String.substring(II)Ljava/lang/String;", s, at, at + width)
}

// `s.index_of(needle)`: the character where `needle` starts, or -1.
fn __jrt_str_index_of(s: string, needle: string) -> int {
    var at = __jvm("virtual java/lang/String.indexOf(Ljava/lang/String;)I", s, needle)
    if at <= 0 || __jrt_plain(s) {
        return at
    }
    return __jvm("virtual java/lang/String.codePointCount(II)I", s, 0, at)
}

// How two strings compare, by their characters, as on the native target:
// below 0, 0 or above 0. Java compares UTF-16 units, which only differs
// where a character above U+FFFF meets one from U+E000 to U+FFFF.
fn __jrt_str_compare(a: string, b: string) -> int {
    var r = __jvm("virtual java/lang/String.compareTo(Ljava/lang/String;)I", a, b)
    if r == 0 || (__jrt_plain(a) && __jrt_plain(b)) {
        return r
    }
    var na = __jrt_units(a)
    var nb = __jrt_units(b)
    var i = 0
    var j = 0
    while i < na && j < nb {
        var x = __jvm("virtual java/lang/String.codePointAt(I)I", a, i)
        var y = __jvm("virtual java/lang/String.codePointAt(I)I", b, j)
        if x != y {
            return x - y
        }
        i += __jvm("static java/lang/Character.charCount(I)I", x)
        j += __jvm("static java/lang/Character.charCount(I)I", y)
    }
    return (na - i) - (nb - j)
}

fn __jrt_unit(s: string, i: int) -> int {
    return __jvm("virtual java/lang/String.charAt(I)C", s, i)
}

// The spaces that JavaScript's `trim` removes.
fn __jrt_is_blank(c: int) -> bool {
    return (c >= 9 && c <= 13) || c == 32 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000 || c == 0xFEFF
}

fn __jrt_str_trim(s: string) -> string {
    var start = 0
    var end = __jrt_units(s)
    while start < end && __jrt_is_blank(__jrt_unit(s, start)) {
        start += 1
    }
    while end > start && __jrt_is_blank(__jrt_unit(s, end - 1)) {
        end -= 1
    }
    return __jvm("virtual java/lang/String.substring(II)Ljava/lang/String;", s, start, end)
}

fn __jrt_str_split(s: string, sep: string) -> [string] {
    if sep == "" {
        return __jrt_str_chars(s)
    }
    var out: [string] = []
    var start = 0
    while true {
        var at = __jvm("virtual java/lang/String.indexOf(Ljava/lang/String;I)I", s, sep, start)
        if at < 0 {
            break
        }
        out.push(__jvm("virtual java/lang/String.substring(II)Ljava/lang/String;", s, start, at))
        start = at + __jrt_units(sep)
    }
    out.push(__jvm("virtual java/lang/String.substring(I)Ljava/lang/String;", s, start))
    return out
}

fn __jrt_str_chars(s: string) -> [string] {
    var out: [string] = []
    for c in s {
        out.push(c)
    }
    return out
}

// A position for `slice`: from the end when negative, kept within 0..n.
fn __jrt_clamp(i: int, n: int) -> int {
    if i < 0 {
        return max(n + i, 0)
    }
    return min(i, n)
}

fn __jrt_str_slice(s: string, from: int, to: int) -> string {
    var n = __jrt_str_len(s)
    var a = __jrt_clamp(from, n)
    var b = __jrt_clamp(to, n)
    if a >= b {
        return ""
    }
    var start = __jrt_unit_of(s, a)
    return __jvm("virtual java/lang/String.substring(II)Ljava/lang/String;", s, start, __jrt_unit_of(s, b))
}

fn __jrt_str_repeat(s: string, n: int) -> string {
    if n < 0 {
        panic("repeat count cannot be negative")
    }
    return __jvm("virtual java/lang/String.repeat(I)Ljava/lang/String;", s, n)
}

fn __jrt_ord(s: string) -> int {
    if s.len() == 0 {
        panic("ord of an empty string")
    }
    return __jvm("virtual java/lang/String.codePointAt(I)I", s, 0)
}

fn __jrt_chr(n: int) -> string {
    if n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF) {
        panic("chr: {n} is not a character")
    }
    return __jvm("static java/lang/Character.toString(I)Ljava/lang/String;", n)
}

// The bytes of a Java byte array, as ints from 0 to 255.
fn __jrt_byte_list(raw: __object) -> [int] {
    var buffer = __jvm("static java/nio/ByteBuffer.wrap([B)Ljava/nio/ByteBuffer;", raw)
    var n = __jvm("virtual java/nio/ByteBuffer.limit()I", buffer)
    var out: [int] = []
    for i in 0..n {
        out.push(__jvm("virtual java/nio/ByteBuffer.get(I)B", buffer, i) & 255)
    }
    return out
}

// A Java byte array of these bytes.
fn __jrt_byte_array(list: [int]) -> __object {
    var buffer = __jvm("static java/nio/ByteBuffer.allocate(I)Ljava/nio/ByteBuffer;", list.len())
    for b in list {
        __jvm("virtual java/nio/ByteBuffer.put(B)Ljava/nio/ByteBuffer;", buffer, b)
    }
    return __jvm("virtual java/nio/ByteBuffer.array()[B", buffer)
}

fn __jrt_bytes(s: string) -> [int] {
    return __jrt_byte_list(__jrt_bytes_of(s))
}

fn __jrt_from_bytes(list: [int]) -> string {
    return __jvm("new java/lang/String([BLjava/nio/charset/Charset;)", __jrt_byte_array(list), __jrt_utf8)
}

// ---- lists ----

fn __jrt_out_of_bounds(i: int, n: int) {
    panic("index out of bounds: index {i}, length {n}")
}

fn __jrt_list_at(list: [__object], i: int) -> __object {
    var n = list.len()
    if i < 0 || i >= n {
        __jrt_out_of_bounds(i, n)
    }
    return __jvm("virtual java/util/ArrayList.get(I)Ljava/lang/Object;", list, i)
}

fn __jrt_list_set(list: [__object], i: int, value: __object) {
    var n = list.len()
    if i < 0 || i >= n {
        __jrt_out_of_bounds(i, n)
    }
    __jvm("virtual java/util/ArrayList.set(ILjava/lang/Object;)Ljava/lang/Object;", list, i, value)
}

fn __jrt_list_pop(list: [__object]) -> __object! {
    var n = list.len()
    if n == 0 {
        fail "the list is empty"
    }
    return __jvm("virtual java/util/ArrayList.remove(I)Ljava/lang/Object;", list, n - 1)
}

fn __jrt_list_first(list: [__object]) -> __object! {
    if list.len() == 0 {
        fail "the list is empty"
    }
    return list[0]
}

fn __jrt_list_last(list: [__object]) -> __object! {
    if list.len() == 0 {
        fail "the list is empty"
    }
    return list[list.len() - 1]
}

fn __jrt_list_contains(list: [__object], value: __object) -> bool {
    for item in list {
        if __jrt_eq(item, value) {
            return true
        }
    }
    return false
}

fn __jrt_list_index_of(list: [__object], value: __object) -> int {
    for i in 0..list.len() {
        if __jrt_eq(list[i], value) {
            return i
        }
    }
    return -1
}

fn __jrt_list_reverse(list: [__object]) -> [__object] {
    var out: [__object] = []
    var i = list.len() - 1
    while i >= 0 {
        out.push(list[i])
        i -= 1
    }
    return out
}

fn __jrt_list_slice(list: [__object], from: int, to: int) -> [__object] {
    var n = list.len()
    var out: [__object] = []
    for i in __jrt_clamp(from, n)..__jrt_clamp(to, n) {
        out.push(list[i])
    }
    return out
}

fn __jrt_list_insert(list: [__object], i: int, value: __object) {
    var n = list.len()
    if i < 0 || i > n {
        __jrt_out_of_bounds(i, n)
    }
    __jvm("virtual java/util/ArrayList.add(ILjava/lang/Object;)V", list, i, value)
}

fn __jrt_list_remove(list: [__object], i: int) -> __object {
    var n = list.len()
    if i < 0 || i >= n {
        __jrt_out_of_bounds(i, n)
    }
    return __jvm("virtual java/util/ArrayList.remove(I)Ljava/lang/Object;", list, i)
}

fn __jrt_list_join(list: [__object], separator: string) -> string {
    var out = __jvm("new java/lang/StringBuilder()")
    for i in 0..list.len() {
        if i > 0 {
            __jvm("virtual java/lang/StringBuilder.append(Ljava/lang/String;)Ljava/lang/StringBuilder;", out, separator)
        }
        __jvm("virtual java/lang/StringBuilder.append(Ljava/lang/String;)Ljava/lang/StringBuilder;", out, __jrt_str(list[i]))
    }
    return __jvm("virtual java/lang/Object.toString()Ljava/lang/String;", out)
}

// How two keys compare, as `<` sees them: below 0, 0 or above 0.
fn __jrt_compare(a: __object, b: __object) -> int {
    if __jvm("is java/lang/Long", a) && __jvm("is java/lang/Long", b) {
        return __jvm("static java/lang/Long.compare(JJ)I", a, b)
    }
    if __jvm("is java/lang/String", a) {
        return __jrt_str_compare(a, b)
    }
    var x: float = a
    var y: float = b
    if x < y {
        return -1
    }
    if y < x {
        return 1
    }
    return 0
}

// The items, in the order of their keys; items with equal keys keep their
// order. Java sorts pairs (`onyx.Keyed`, which the code generator writes),
// comparing their keys with `__jrt_compare`.
fn __jrt_list_sort_by(items: [__object], keys: [__object]) -> [__object] {
    var pairs: [__object] = []
    for i in 0..items.len() {
        pairs.push(__jvm("new onyx/Keyed(Ljava/lang/Object;Ljava/lang/Object;)", keys[i], items[i]))
    }
    __jvm("virtual java/util/ArrayList.sort(Ljava/util/Comparator;)V", pairs, __jvm("null"))
    var out: [__object] = []
    for pair in pairs {
        out.push(__jvm("virtual onyx/Keyed.item()Ljava/lang/Object;", pair))
    }
    return out
}

fn __jrt_list_sort(list: [__object]) -> [__object] {
    // Java's own order is that of `<` for ints, and for strings whose
    // characters are each a single unit. Floats (-0.0 is 0.0 for `<`) and
    // the other strings are compared by `__jrt_compare`.
    var own = true
    for item in list {
        if __jvm("is java/lang/Double", item) || (__jvm("is java/lang/String", item) && !__jrt_plain(item)) {
            own = false
            break
        }
    }
    if !own {
        return __jrt_list_sort_by(list, list)
    }
    var out: [__object] = __jvm("new java/util/ArrayList(Ljava/util/Collection;)", list)
    __jvm("virtual java/util/ArrayList.sort(Ljava/util/Comparator;)V", out, __jvm("null"))
    return out
}

// ---- maps ----

// What stands in the place of a removed key.
var __jrt_hole = __jvm("new java/lang/Object()")

// A map: its entries in the order they were added (with holes where some
// were removed), and an index that finds the entry of a key. A loop over
// it goes through the entries by their positions: it sees the entries
// added during the loop, and skips those removed.
struct __JrtMap {
    // A java.util.HashMap: key -> position of its entry.
    index: __object
    keys: [__object]
    values: [__object]
    size: int
    holes: int

    // The position of the entry of `key`, or -1.
    fn find(self, key: __object) -> int {
        var at = __jvm("virtual java/util/HashMap.get(Ljava/lang/Object;)Ljava/lang/Object;", self.index, key)
        if __jrt_is_null(at) {
            return -1
        }
        var position: int = at
        return position
    }

    fn set(self, key: __object, value: __object) {
        var at = self.find(key)
        if at >= 0 {
            self.values[at] = value
            return
        }
        if self.holes > 16 && self.holes > self.size {
            self.compact()
        }
        __jvm("virtual java/util/HashMap.put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", self.index, key, self.keys.len())
        self.keys.push(key)
        self.values.push(value)
        self.size += 1
    }

    // Leaves the holes behind.
    fn compact(self) {
        var keys: [__object] = []
        var values: [__object] = []
        __jvm("virtual java/util/HashMap.clear()V", self.index)
        for i in 0..self.keys.len() {
            var key = self.keys[i]
            if !__jvm("same", key, __jrt_hole) {
                __jvm("virtual java/util/HashMap.put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", self.index, key, keys.len())
                keys.push(key)
                values.push(self.values[i])
            }
        }
        self.keys = keys
        self.values = values
        self.holes = 0
    }

    // `m[key]`
    fn at(self, key: __object) -> __object {
        var i = self.find(key)
        if i < 0 {
            panic("key not found in map: " + __jrt_repr(key))
        }
        return self.values[i]
    }

    fn get(self, key: __object) -> __object! {
        var i = self.find(key)
        if i < 0 {
            fail "key not found: " + __jrt_repr(key)
        }
        return self.values[i]
    }

    fn has(self, key: __object) -> bool {
        return self.find(key) >= 0
    }

    fn remove(self, key: __object) {
        var i = self.find(key)
        if i >= 0 {
            __jvm("virtual java/util/HashMap.remove(Ljava/lang/Object;)Ljava/lang/Object;", self.index, key)
            self.keys[i] = __jrt_hole
            self.values[i] = __jvm("null")
            self.size -= 1
            self.holes += 1
        }
    }

    fn clear(self) {
        __jvm("virtual java/util/HashMap.clear()V", self.index)
        var keys: [__object] = []
        var values: [__object] = []
        self.keys = keys
        self.values = values
        self.size = 0
        self.holes = 0
    }

    fn keys_list(self) -> [__object] {
        var out: [__object] = []
        for key in self.keys {
            if !__jvm("same", key, __jrt_hole) {
                out.push(key)
            }
        }
        return out
    }

    fn values_list(self) -> [__object] {
        var out: [__object] = []
        for i in 0..self.keys.len() {
            if !__jvm("same", self.keys[i], __jrt_hole) {
                out.push(self.values[i])
            }
        }
        return out
    }

    // The position of the first entry at or after `from`, or -1.
    fn next(self, from: int) -> int {
        var i = from
        var n = self.keys.len()
        while i < n {
            if !__jvm("same", self.keys[i], __jrt_hole) {
                return i
            }
            i += 1
        }
        return -1
    }

    fn key(self, at: int) -> __object {
        return self.keys[at]
    }
}

fn __jrt_map_new() -> __JrtMap {
    var keys: [__object] = []
    var values: [__object] = []
    return __JrtMap{index: __jvm("new java/util/HashMap()"), keys: keys, values: values, size: 0, holes: 0}
}

// ---- weak references ----

// The JVM frees objects with a garbage collector, which cycles do not
// trouble: as on the JavaScript target, a weak reference simply holds its
// object, and `get` only fails for an empty one (`weak()`).
struct __JrtWeak {
    target: __object
}

fn __jrt_weak(target: __object) -> __JrtWeak {
    return __JrtWeak{target: target}
}

fn __jrt_weak_get(w: __JrtWeak) -> __object! {
    if __jrt_is_null(w.target) {
        fail "the object is gone"
    }
    return w.target
}

// ---- the system ----

fn __jrt_args() -> [string] {
    var all = __jvm("static java/util/Arrays.asList([Ljava/lang/Object;)Ljava/util/List;", __jvm("get onyx/Main.args:[Ljava/lang/String;"))
    var out: [string] = []
    var n = __jvm("interface java/util/List.size()I", all)
    for i in 0..n {
        out.push(__jvm("interface java/util/List.get(I)Ljava/lang/Object;", all, i))
    }
    return out
}

fn __jrt_env(name: string) -> string! {
    var value = __jvm("static java/lang/System.getenv(Ljava/lang/String;)Ljava/lang/String;", name)
    if __jrt_is_null(value) {
        fail "environment variable " + __jrt_quote(name) + " is not set"
    }
    return value
}

fn __jrt_random_int(lo: int, hi: int) -> int {
    return lo + floor(random() * float(hi - lo + 1))
}

fn __jrt_stdout_is_terminal() -> bool {
    return __jrt_is_terminal(1)
}

fn __jrt_stderr_is_terminal() -> bool {
    return __jrt_is_terminal(2)
}

// A line typed by the user, without its end.
fn __jrt_input(prompt: string) -> string {
    if prompt != "" {
        __jvm("virtual java/io/OutputStream.write([B)V", __jrt_stdout, __jrt_bytes_of(prompt))
    }
    __jrt_flush()
    var bytes = __jvm("new java/io/ByteArrayOutputStream()")
    var stdin = __jvm("get java/lang/System.in:Ljava/io/InputStream;")
    while true {
        var b = __jvm("virtual! java/io/InputStream.read()I", stdin) or -1
        if b < 0 || b == 10 {
            break
        }
        __jvm("virtual java/io/ByteArrayOutputStream.write(I)V", bytes, b)
    }
    var line = __jvm("virtual java/io/ByteArrayOutputStream.toString(Ljava/nio/charset/Charset;)Ljava/lang/String;", bytes, __jrt_utf8)
    if line.ends_with("\r") {
        line = line.slice(0, line.len() - 1)
    }
    return line
}

// ---- files ----

fn __jrt_file(path: string) -> __object {
    return __jvm("new java/io/File(Ljava/lang/String;)", path)
}

fn __jrt_path(path: string) -> __object {
    return __jvm("virtual java/io/File.toPath()Ljava/nio/file/Path;", __jrt_file(path))
}

fn __jrt_read_bytes(path: string) -> [int]! {
    var data = __jvm("static! java/nio/file/Files.readAllBytes(Ljava/nio/file/Path;)[B", __jrt_path(path)) catch err {
        fail "cannot read " + __jrt_quote(path) + ": " + err.message
    }
    return __jrt_byte_list(data)
}

fn __jrt_read_file(path: string) -> string! {
    var data = __jvm("static! java/nio/file/Files.readAllBytes(Ljava/nio/file/Path;)[B", __jrt_path(path)) catch err {
        fail "cannot read " + __jrt_quote(path) + ": " + err.message
    }
    return __jvm("new java/lang/String([BLjava/nio/charset/Charset;)", data, __jrt_utf8)
}

// Writes the bytes of a Java byte array to a file, at its end or instead
// of what it held.
fn __jrt_write(path: string, data: __object, at_end: bool) -> void! {
    var out = __jvm("new! java/io/FileOutputStream(Ljava/lang/String;Z)", path, at_end) catch err {
        fail "cannot write " + __jrt_quote(path) + ": " + err.message
    }
    __jvm("virtual! java/io/OutputStream.write([B)V", out, data) catch err {
        fail "cannot write " + __jrt_quote(path) + ": " + err.message
    }
    __jvm("virtual! java/io/OutputStream.close()V", out) catch err {
        fail "cannot write " + __jrt_quote(path) + ": " + err.message
    }
}

fn __jrt_write_file(path: string, text: string) -> void! {
    __jrt_write(path, __jrt_bytes_of(text), false)?
}

fn __jrt_append_file(path: string, text: string) -> void! {
    __jrt_write(path, __jrt_bytes_of(text), true)?
}

fn __jrt_write_bytes(path: string, list: [int]) -> void! {
    __jrt_write(path, __jrt_byte_array(list), false)?
}

fn __jrt_file_exists(path: string) -> bool {
    return __jvm("virtual java/io/File.exists()Z", __jrt_file(path))
}

fn __jrt_is_dir(path: string) -> bool {
    return __jvm("virtual java/io/File.isDirectory()Z", __jrt_file(path))
}

fn __jrt_set_executable(path: string) -> void! {
    var file = __jrt_file(path)
    if !__jvm("virtual java/io/File.exists()Z", file) {
        fail "cannot change " + __jrt_quote(path) + ": no such file or directory"
    }
    if !__jvm("virtual java/io/File.setExecutable(ZZ)Z", file, true, false) {
        fail "cannot change " + __jrt_quote(path) + ": permission denied"
    }
}

fn __jrt_remove_file(path: string) -> void! {
    if __jrt_is_dir(path) {
        fail "cannot remove " + __jrt_quote(path) + ": is a directory"
    }
    __jvm("static! java/nio/file/Files.delete(Ljava/nio/file/Path;)V", __jrt_path(path)) catch err {
        fail "cannot remove " + __jrt_quote(path) + ": " + err.message
    }
}

fn __jrt_remove_dir(path: string) -> void! {
    if __jrt_file_exists(path) && !__jrt_is_dir(path) {
        fail "cannot remove " + __jrt_quote(path) + ": not a directory"
    }
    __jvm("static! java/nio/file/Files.delete(Ljava/nio/file/Path;)V", __jrt_path(path)) catch err {
        fail "cannot remove " + __jrt_quote(path) + ": " + err.message
    }
}

// Makes a directory, and those it is in, unless it is already there.
fn __jrt_make_dir(path: string) -> void! {
    if __jrt_is_dir(path) {
        return
    }
    if __jrt_file_exists(path) {
        fail "cannot create " + __jrt_quote(path) + ": file exists"
    }
    if !__jvm("virtual java/io/File.mkdirs()Z", __jrt_file(path)) {
        fail "cannot create " + __jrt_quote(path) + ": permission denied"
    }
}

// The names in a directory, sorted.
fn __jrt_list_dir(path: string) -> [string]! {
    if !__jrt_file_exists(path) {
        fail "cannot read " + __jrt_quote(path) + ": no such file or directory"
    }
    if !__jrt_is_dir(path) {
        fail "cannot read " + __jrt_quote(path) + ": not a directory"
    }
    var names = __jvm("virtual java/io/File.list()[Ljava/lang/String;", __jrt_file(path))
    if __jrt_is_null(names) {
        fail "cannot read " + __jrt_quote(path) + ": permission denied"
    }
    var all = __jvm("static java/util/Arrays.asList([Ljava/lang/Object;)Ljava/util/List;", names)
    var out: [string] = []
    var n = __jvm("interface java/util/List.size()I", all)
    for i in 0..n {
        out.push(__jvm("interface java/util/List.get(I)Ljava/lang/Object;", all, i))
    }
    // In the order of their characters, which is that of their bytes, as
    // on the other targets.
    return out.sort()
}

// Runs a program, with the same input and output; its exit code.
fn __jrt_run_program(path: string, arguments: [string]) -> int! {
    var command: [string] = [path]
    for a in arguments {
        command.push(a)
    }
    __jrt_flush()
    var builder = __jvm("new java/lang/ProcessBuilder(Ljava/util/List;)", command)
    __jvm("virtual java/lang/ProcessBuilder.inheritIO()Ljava/lang/ProcessBuilder;", builder)
    var process = __jvm("virtual! java/lang/ProcessBuilder.start()Ljava/lang/Process;", builder) catch err {
        fail "cannot run " + __jrt_quote(path) + ": " + err.message
    }
    var code = __jvm("virtual! java/lang/Process.waitFor()I", process) catch err {
        fail "cannot run " + __jrt_quote(path) + ": " + err.message
    }
    // Java gives 128 + n for a program stopped by the signal n; the other
    // targets give -n. (A program that exits with such a code itself is
    // taken for one stopped by a signal.)
    if code > 128 && code <= 192 {
        return 128 - code
    }
    return code
}

// ---- tasks ----
//
// `fork` starts a task. Tasks take turns, as on the other targets: one runs
// until it has to wait (for a channel, for `sleep`) or reaches one of the
// points where it lets the others go first (where the JavaScript target
// has an `await`). It then stands in a line, and the next task that is
// ready goes on. The order in which they take turns is the one of the
// other targets, so that a program prints the same thing everywhere.
//
// How a task is put aside and taken up again depends on the JVM:
//
// 0. Continuations, with Java 21 and later when the .jar was launched with
//    `java -jar` (its manifest asks for them): every task is a
//    continuation, a stack of its own that the JVM puts aside and gives
//    back, all of them on the one thread of the program. Passing the turn
//    takes a fifth of a microsecond.
// 1. Virtual threads, with Java 21 and later otherwise: a thread per task,
//    all of them on one carrier thread; the one whose turn it is runs, the
//    others are parked.
// 2. Threads of the system, as 1, with older versions of Java: passing the
//    turn wakes a thread up, a matter of microseconds.

struct __JrtTask {
    // Its thread (1 and 2), or its continuation (0).
    thread: __object
    cont: __object
    // The value it is sending, or the one it received.
    value: __object
    // Whether a value was handed to it.
    got: bool
    // When it wakes up, if it sleeps (in nanoseconds of the JVM's clock:
    // two tasks that fall asleep in the same millisecond still wake up in
    // the right order).
    wake: int
}

fn __jrt_new_task(thread: __object) -> __JrtTask {
    return __JrtTask{thread: thread, cont: __jvm("null"), value: __jvm("null"), got: false, wake: 0}
}

// Whether the program has started tasks.
var __jrt_tasks_on = false
var __jrt_main_task = __jrt_new_task(__jvm("static java/lang/Thread.currentThread()Ljava/lang/Thread;"))
var __jrt_current_task = __jrt_main_task
// The tasks that can go on, in the order they will.
var __jrt_ready: [__JrtTask] = []
// The tasks that sleep, in the order they wake up.
var __jrt_timers: [__JrtTask] = []
var __jrt_main_done = false
// The task whose turn it is, as every thread sees it (1 and 2).
var __jrt_turn = __jvm("new java/util/concurrent/atomic/AtomicReference(Ljava/lang/Object;)", __jrt_main_task)
// How tasks take turns: 0, 1 or 2, as above.
var __jrt_switching = __jrt_switching_mode()
// The scope of the continuations (0).
var __jrt_scope = __jvm("null")

fn __jrt_switching_mode() -> int {
    var version = __jvm("virtual java/lang/Runtime$Version.feature()I", __jvm("static java/lang/Runtime.version()Ljava/lang/Runtime$Version;"))
    // ONYX_JVM_SWITCHING=1 or 2 asks for a slower way, to test it.
    var asked = parse_int(env("ONYX_JVM_SWITCHING") or "0") or 0
    if version < 21 || asked == 2 {
        return 2
    }
    // Continuations are the JVM's own (jdk.internal.vm): they may be used
    // when the JVM lets the program reach them.
    var base = __jvm("virtual java/lang/Class.getModule()Ljava/lang/Module;", __jvm("virtual java/lang/Object.getClass()Ljava/lang/Class;", __jvm("new java/lang/Object()")))
    var mine = __jvm("virtual java/lang/Class.getModule()Ljava/lang/Module;", __jvm("virtual java/lang/Object.getClass()Ljava/lang/Class;", __jrt_new_task(__jvm("null"))))
    if asked == 0 && __jvm("virtual java/lang/Module.isExported(Ljava/lang/String;Ljava/lang/Module;)Z", base, "jdk.internal.vm", mine) {
        return 0
    }
    // Virtual threads pass the turn fastest when they share one carrier.
    var key = "jdk.virtualThreadScheduler.parallelism"
    if __jrt_is_null(__jvm("static java/lang/System.getProperty(Ljava/lang/String;)Ljava/lang/String;", key)) {
        __jvm("static java/lang/System.setProperty(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", key, "1")
    }
    return 1
}

// A continuation that runs `body`, a java.lang.Runnable (0).
fn __jrt_continuation(body: __object) -> __object {
    if __jrt_is_null(__jrt_scope) {
        __jrt_scope = __jvm("new jdk/internal/vm/ContinuationScope(Ljava/lang/String;)", "onyx")
    }
    return __jvm("new jdk/internal/vm/Continuation(Ljdk/internal/vm/ContinuationScope;Ljava/lang/Runnable;)", __jrt_scope, body)
}

// Runs the program (`body`, a java.lang.Runnable) as the task of `main`.
fn __jrt_start(body: __object) {
    if __jrt_switching != 0 {
        __jvm("interface java/lang/Runnable.run()V", body)
        return
    }
    // The first continuation and the first sleep take the JVM some time to
    // prepare (classes to load and set up): that is done before the program
    // starts, so that its tasks take their turns on time.
    var warm = __jrt_continuation(__jvm("new java/lang/Thread()"))
    __jvm("virtual jdk/internal/vm/Continuation.run()V", warm)
    __jvm("static java/lang/Thread.sleep(J)V", 0)
    __jrt_main_task.cont = __jrt_continuation(body)
    // Each turn, the task whose turn it is runs until it stops.
    while !__jvm("virtual jdk/internal/vm/Continuation.isDone()Z", __jrt_main_task.cont) {
        __jvm("virtual jdk/internal/vm/Continuation.run()V", __jrt_current_task.cont)
    }
}

// Hands the turn to `next`, whose thread then goes on (1 and 2).
fn __jrt_give_turn(next: __JrtTask) {
    __jrt_current_task = next
    __jvm("virtual java/util/concurrent/atomic/AtomicReference.set(Ljava/lang/Object;)V", __jrt_turn, next)
    __jvm("static java/util/concurrent/locks/LockSupport.unpark(Ljava/lang/Thread;)V", next.thread)
}

// Waits until it is the turn of `me` (1 and 2).
fn __jrt_wait_turn(me: __JrtTask) {
    while !__jvm("same", __jvm("virtual java/util/concurrent/atomic/AtomicReference.get()Ljava/lang/Object;", __jrt_turn), me) {
        __jvm("static java/util/concurrent/locks/LockSupport.park()V")
    }
}

// The task that goes on next: the first that is ready, or else the first
// sleeper, once it is its time.
fn __jrt_next_task() -> __JrtTask {
    if __jrt_ready.len() > 0 {
        return __jrt_ready.remove(0)
    }
    if __jrt_timers.len() == 0 {
        if __jrt_main_done {
            // Nothing will happen any more: `main` gets to end the program.
            return __jrt_main_task
        }
        __jrt_eprint("fatal: deadlock: the program is waiting on a channel that nobody will ever use")
        __jvm("static java/lang/System.exit(I)V", 2)
    }
    var sleeper = __jrt_timers.remove(0)
    var wait = sleeper.wake - __jvm("static java/lang/System.nanoTime()J")
    if wait > 0 {
        __jvm("static java/lang/Thread.sleep(JI)V", wait / 1000000, wait % 1000000)
    }
    return sleeper
}

// `next` goes on, and `me` waits for its turn.
fn __jrt_switch(me: __JrtTask, next: __JrtTask) {
    if __jrt_switching == 0 {
        // Back to the loop of `__jrt_start`, which runs `next`.
        __jrt_current_task = next
        __jvm("static jdk/internal/vm/Continuation.yield(Ljdk/internal/vm/ContinuationScope;)Z", __jrt_scope)
        return
    }
    __jrt_give_turn(next)
    __jrt_wait_turn(me)
}

// `me` cannot go on for now (it stands in some line): the next task runs.
// Returns when it is the turn of `me` again.
fn __jrt_schedule(me: __JrtTask) {
    var next = __jrt_next_task()
    if !__jvm("same", next, me) {
        __jrt_switch(me, next)
    }
}

// Lets the tasks that are ready go first, if there are any.
fn __jrt_yield() {
    if __jrt_ready.len() == 0 {
        return
    }
    var me = __jrt_current_task
    __jrt_ready.push(me)
    __jrt_schedule(me)
}

// Starts `f`, a function without parameters, as a new task. The new task
// runs at once, until it first has to wait; the one that started it is the
// next to go on.
fn __jrt_fork(f: __object) {
    __jrt_tasks_on = true
    var me = __jrt_current_task
    var task = __jrt_new_task(__jvm("null"))
    var runner = __jvm("new onyx/Task(Ljava/lang/Object;Ljava/lang/Object;)", f, task)
    __jrt_ready.insert(0, me)
    if __jrt_switching == 0 {
        task.cont = __jrt_continuation(runner)
    } else {
        var thread = __jvm("null")
        if __jrt_switching == 1 {
            thread = __jvm("interface java/lang/Thread$Builder.unstarted(Ljava/lang/Runnable;)Ljava/lang/Thread;", __jvm("static java/lang/Thread.ofVirtual()Ljava/lang/Thread$Builder$OfVirtual;"), runner)
        } else {
            thread = __jvm("new java/lang/Thread(Ljava/lang/ThreadGroup;Ljava/lang/Runnable;Ljava/lang/String;J)", __jvm("null"), runner, "onyx task", 16777216)
            __jvm("virtual java/lang/Thread.setDaemon(Z)V", thread, true)
        }
        task.thread = thread
        __jvm("virtual java/lang/Thread.start()V", thread)
    }
    __jrt_switch(me, task)
}

// A task starts here (its thread waits for its turn).
fn __jrt_task_begin(task: __object) {
    if __jrt_switching != 0 {
        var me: __JrtTask = task
        __jrt_wait_turn(me)
    }
}

// A task is done: the next one goes on.
fn __jrt_task_end(task: __object) {
    var next = __jrt_next_task()
    if __jrt_switching == 0 {
        // Its continuation ends; the loop of `__jrt_start` runs `next`.
        __jrt_current_task = next
        return
    }
    __jrt_give_turn(next)
}

// `sleep` in a program with tasks: the others run meanwhile.
fn __jrt_task_sleep(ms: int) {
    var me = __jrt_current_task
    var wake = __jvm("static java/lang/System.nanoTime()J") + max(ms, 1) * 1000000
    me.wake = wake
    var at = 0
    while at < __jrt_timers.len() && __jrt_timers[at].wake <= wake {
        at += 1
    }
    __jrt_timers.insert(at, me)
    __jrt_schedule(me)
}

// ---- channels ----

struct __JrtChan {
    // How many values it holds without a receiver.
    cap: int
    closed: bool
    buffer: [__object]
    // The tasks waiting for a value, and those waiting to hand one over.
    receivers: [__JrtTask]
    senders: [__JrtTask]
}

fn __jrt_chan_new(capacity: int) -> __JrtChan {
    var buffer: [__object] = []
    var receivers: [__JrtTask] = []
    var senders: [__JrtTask] = []
    return __JrtChan{cap: max(capacity, 0), closed: false, buffer: buffer, receivers: receivers, senders: senders}
}

// `ch <- v`
fn __jrt_chan_send(ch: __JrtChan, v: __object) {
    if ch.closed {
        panic("send on a closed channel")
    }
    if ch.receivers.len() > 0 {
        // Somebody was waiting for it.
        var receiver = ch.receivers.remove(0)
        receiver.value = v
        receiver.got = true
        __jrt_ready.push(receiver)
        __jrt_yield()
        return
    }
    if ch.buffer.len() < ch.cap {
        ch.buffer.push(v)
        __jrt_yield()
        return
    }
    // Nobody yet: wait until a receiver takes it.
    var me = __jrt_current_task
    me.value = v
    ch.senders.push(me)
    __jrt_schedule(me)
}

// Whether the last `__jrt_chan_take` got a value (else the channel was
// closed and empty).
var __jrt_chan_ok = false

// Takes the next value out of the channel, waiting for one if need be.
fn __jrt_chan_take(ch: __JrtChan) -> __object {
    if ch.buffer.len() > 0 {
        var v = ch.buffer.remove(0)
        // That made room for a sender that was waiting.
        if ch.senders.len() > 0 {
            var sender = ch.senders.remove(0)
            ch.buffer.push(sender.value)
            __jrt_ready.push(sender)
        }
        __jrt_yield()
        __jrt_chan_ok = true
        return v
    }
    if ch.senders.len() > 0 {
        var sender = ch.senders.remove(0)
        var v = sender.value
        __jrt_ready.push(sender)
        __jrt_yield()
        __jrt_chan_ok = true
        return v
    }
    if ch.closed {
        __jrt_yield()
        __jrt_chan_ok = false
        return __jvm("null")
    }
    var me = __jrt_current_task
    me.got = false
    me.value = __jvm("null")
    ch.receivers.push(me)
    __jrt_schedule(me)
    __jrt_chan_ok = me.got
    return me.value
}

// `<-ch`
fn __jrt_chan_recv(ch: __JrtChan) -> __object {
    var v = __jrt_chan_take(ch)
    if !__jrt_chan_ok {
        panic("receive from a closed channel")
    }
    __jrt_yield()
    return v
}

// Nothing more will be sent: those who wait for a value are told so.
fn __jrt_chan_close(ch: __JrtChan) {
    ch.closed = true
    while ch.receivers.len() > 0 {
        var receiver = ch.receivers.remove(0)
        receiver.got = false
        __jrt_ready.push(receiver)
    }
}

// ---- the network ----

// The client that `fetch` uses, made the first time.
var __jrt_http = __jvm("null")

// `fetch(url)`: what is at `url`, by HTTP or HTTPS (redirections
// followed). While the answer comes, the other tasks run, as on the
// JavaScript target.
fn __jrt_fetch(url: string) -> string! {
    if __jrt_is_null(__jrt_http) {
        var builder = __jvm("static java/net/http/HttpClient.newBuilder()Ljava/net/http/HttpClient$Builder;")
        __jvm("interface java/net/http/HttpClient$Builder.followRedirects(Ljava/net/http/HttpClient$Redirect;)Ljava/net/http/HttpClient$Builder;", builder, __jvm("get java/net/http/HttpClient$Redirect.NORMAL:Ljava/net/http/HttpClient$Redirect;"))
        __jrt_http = __jvm("interface java/net/http/HttpClient$Builder.build()Ljava/net/http/HttpClient;", builder)
    }
    var uri = __jvm("static! java/net/URI.create(Ljava/lang/String;)Ljava/net/URI;", url) catch err {
        fail "cannot fetch " + __jrt_quote(url) + ": invalid URL"
    }
    var request = __jvm("static! java/net/http/HttpRequest.newBuilder(Ljava/net/URI;)Ljava/net/http/HttpRequest$Builder;", uri) catch err {
        fail "cannot fetch " + __jrt_quote(url) + ": invalid URL"
    }
    var body = __jvm("static java/net/http/HttpResponse$BodyHandlers.ofString()Ljava/net/http/HttpResponse$BodyHandler;")
    var answer = __jvm("virtual java/net/http/HttpClient.sendAsync(Ljava/net/http/HttpRequest;Ljava/net/http/HttpResponse$BodyHandler;)Ljava/util/concurrent/CompletableFuture;", __jrt_http, __jvm("interface java/net/http/HttpRequest$Builder.build()Ljava/net/http/HttpRequest;", request), body)
    while !__jvm("virtual java/util/concurrent/CompletableFuture.isDone()Z", answer) {
        if __jrt_ready.len() > 0 {
            __jrt_yield()
        } else if __jrt_timers.len() > 0 {
            // Wait for the answer, or for the first sleeper to wake up.
            var wait = __jrt_timers[0].wake - __jvm("static java/lang/System.nanoTime()J")
            if wait > 0 {
                __jvm("virtual! java/util/concurrent/CompletableFuture.get(JLjava/util/concurrent/TimeUnit;)Ljava/lang/Object;", answer, wait, __jvm("get java/util/concurrent/TimeUnit.NANOSECONDS:Ljava/util/concurrent/TimeUnit;")) catch err {
                }
            }
            while __jrt_timers.len() > 0 && __jrt_timers[0].wake <= __jvm("static java/lang/System.nanoTime()J") {
                __jrt_ready.push(__jrt_timers.remove(0))
            }
        } else {
            break
        }
    }
    var response = __jvm("virtual! java/util/concurrent/CompletableFuture.get()Ljava/lang/Object;", answer) catch err {
        fail "cannot fetch " + __jrt_quote(url) + ": " + err.message
    }
    var status = __jvm("interface java/net/http/HttpResponse.statusCode()I", response)
    if status < 200 || status > 299 {
        fail "cannot fetch " + __jrt_quote(url) + ": HTTP {status}"
    }
    return __jvm("interface java/net/http/HttpResponse.body()Ljava/lang/Object;", response)
}
