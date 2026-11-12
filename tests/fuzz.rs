//! Differential fuzzing of the native target.
//!
//! Random but valid Onyx programs are generated, then run on both targets.
//! The native executable must print exactly what the JavaScript version
//! prints, and must have released every object when it exits.
//!
//! By default a few dozen programs are tried, which keeps `cargo test` fast.
//! To search harder:
//!
//!     ONYX_FUZZ_SEEDS=5000 cargo test --release --test fuzz
//!     ONYX_FUZZ_START=1234 ONYX_FUZZ_SEEDS=1 cargo test --test fuzz   # replay one seed
//!
//! A failing program is kept in `target/fuzz/` for inspection.
//!
//! The generator keeps programs within what both targets compute exactly:
//! integers stay far below 2^53, loops are bounded, strings cannot grow
//! exponentially, lists are never indexed out of bounds and nothing divides
//! by zero.

#![cfg(all(target_os = "linux", target_arch = "x86_64"))]

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const ONYX: &str = env!("CARGO_BIN_EXE_onyx");

/// Integer variables are kept below this by a `%` after every assignment.
const INT_LIMIT: u64 = 1 << 31;
/// No intermediate integer may go beyond this.
const BIG: u64 = 1 << 50;
/// Values whose text may be longer than this are not embedded in other strings.
const EMBED_LIMIT: u64 = 2000;
/// Size given to strings and lists that can grow while the program runs.
const GROWING: u64 = 100_000;

const PRELUDE: &str = r#"struct Point {
    x: int
    y: int
    name: string

    fn sum(self) -> int {
        return self.x + self.y
    }

    fn scaled(self, k: int) -> Point {
        return Point{x: self.x * k % 100000, y: self.y * k % 100000, name: self.name + "*"}
    }

    fn nudge(self, d: int) {
        self.x += d
        self.y -= d
    }

    fn label(self) -> string {
        return "{self.name}({self.x},{self.y})"
    }
}

interface Shape {
    fn area(self) -> int
    fn kind(self) -> string
}

struct Square {
    side: int

    fn area(self) -> int {
        return self.side * self.side
    }

    fn kind(self) -> string {
        return "square"
    }
}

struct Rect {
    w: int
    h: int
    tag: string

    fn area(self) -> int {
        return self.w * self.h
    }

    fn kind(self) -> string {
        return "rect:" + self.tag
    }
}

struct Team {
    name: string
    members: [Point]
    scores: [int]

    fn total(self) -> int {
        var sum = 0
        for s in self.scores {
            sum = (sum + s) % 1000003
        }
        return sum
    }
}

fn at(xs: [int], i: int) -> int {
    if xs.len() == 0 {
        return -1
    }
    return xs[abs(i) % xs.len()]
}

fn pick(ps: [Point], i: int) -> Point {
    if ps.len() == 0 {
        return Point{x: 0, y: 0, name: "none"}
    }
    return ps[abs(i) % ps.len()]
}

fn fact(n: int) -> int {
    if n <= 1 {
        return 1
    }
    return n * fact(n - 1) % 1000003
}

fn half(n: int) -> int! {
    if n % 2 != 0 {
        fail "{n} is odd"
    }
    return n / 2
}

fn pos_label(n: int) -> string! {
    if n < 0 {
        fail "negative"
    }
    return "n{n % 1000}"
}

var g_ages: map<string, int> = {"a": 1}
var g_ids: map<int, string> = {}
var g_count = 0
var g_text = "g"
var g_list: [int] = [3, 1, 2]
var g_names: [string] = ["b", "a"]
var g_point = Point{x: 1, y: 2, name: "origin"}
var team = Team{name: "team", members: [], scores: [5, 1, 4]}
var shapes: [Shape] = []
"#;

struct Rng(u64);

impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ 0xD1B5_4A32_D192_ED03)
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    fn below(&mut self, n: usize) -> usize {
        ((self.next() >> 11) % n as u64) as usize
    }
    fn chance(&mut self, percent: u64) -> bool {
        (self.next() >> 11) % 100 < percent
    }
    fn between(&mut self, lo: i64, hi: i64) -> i64 {
        lo + ((self.next() >> 11) % (hi - lo + 1) as u64) as i64
    }
    fn pick<T: Copy>(&mut self, items: &[T]) -> T {
        items[self.below(items.len())]
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Ty {
    Int,
    Bool,
    Str,
    Ints,
    Strs,
    Point,
    Points,
    Shape,
}

impl Ty {
    fn name(self) -> &'static str {
        match self {
            Ty::Int => "int",
            Ty::Bool => "bool",
            Ty::Str => "string",
            Ty::Ints => "[int]",
            Ty::Strs => "[string]",
            Ty::Point => "Point",
            Ty::Points => "[Point]",
            Ty::Shape => "Shape",
        }
    }
}

#[derive(Clone)]
struct Var {
    name: String,
    ty: Ty,
    /// An upper bound: the magnitude of an int, the length of a string, the
    /// number of elements of a list, the length of a point's name.
    size: u64,
    /// Loop variables cannot be assigned.
    assignable: bool,
    /// A string that is extended with `+=` (and so can get long).
    accumulator: bool,
}

struct Function {
    name: String,
    params: Vec<Ty>,
    ret: Option<Ty>,
    /// Declared with `!`: every call has to say what happens on failure.
    fallible: bool,
}

struct Gen {
    rng: Rng,
    out: String,
    indent: usize,
    scopes: Vec<Vec<Var>>,
    counter: usize,
    functions: Vec<Function>,
    /// How many of `functions` the code being generated may call.
    callable: usize,
    /// Return type of the function being generated (`None` in `main`).
    returns: Option<Option<Ty>>,
    loops: usize,
    max_loops: usize,
    budget: i32,
    /// While set, expressions do not call generated functions (which could
    /// change a list between the moment its length is checked and its use).
    calm: bool,
    /// The function being generated can fail, so `?` and `fail` are allowed.
    can_try: bool,
    /// Inside a loop over a map, which must not change meanwhile.
    frozen_maps: bool,
}

const TEXTS: &[&str] = &[
    "\"\"",
    "\"a\"",
    "\"onyx\"",
    "\"héllo\"",
    "\"x y z\"",
    "\"UPPER\"",
    "\"say \\\"hi\\\"\"",
    "\"tab\\there\"",
    "\"brace \\{\\}\"",
    "\"back\\\\slash\"",
    "\"two\\nlines\"",
    "\"zz\"",
    "\"ab\"",
    "\"abc\"",
];

const DIVISORS: &[i64] = &[
    1, -1, 2, -2, 3, -3, 4, 5, 6, 7, -7, 8, -8, 9, 10, -10, 11, 13, 16, 25, 60, 100, -100, 127, 128, 255, 256, 1000, 1024,
    4096, 65535, 65536, 99999, 1000003, 1 << 20, 3 << 10, 2147483647, -2147483648,
];

const MODULI: &[i64] = &[1000, 65536, 1000003, 2147483647, 999983, 4096];

fn text_len(literal: &str) -> u64 {
    literal.chars().count() as u64
}

impl Gen {
    fn fresh(&mut self, prefix: &str) -> String {
        self.counter += 1;
        format!("{prefix}{}", self.counter)
    }

    fn line(&mut self, text: &str) {
        for _ in 0..self.indent {
            self.out.push_str("    ");
        }
        self.out.push_str(text);
        self.out.push('\n');
    }

    /// The variables that can be named here, innermost first, without the hidden ones.
    fn visible(&self) -> Vec<Var> {
        let mut seen: Vec<&str> = Vec::new();
        let mut vars = Vec::new();
        for scope in self.scopes.iter().rev() {
            for var in scope.iter().rev() {
                if !seen.contains(&var.name.as_str()) {
                    seen.push(&var.name);
                    vars.push(var.clone());
                }
            }
        }
        vars
    }

    fn some_var(&mut self, ty: Ty) -> Option<Var> {
        let vars: Vec<Var> = self.visible().into_iter().filter(|v| v.ty == ty).collect();
        if vars.is_empty() {
            None
        } else {
            Some(vars[self.rng.below(vars.len())].clone())
        }
    }

    fn assignable_var(&mut self, ty: Ty) -> Option<Var> {
        let vars: Vec<Var> = self.visible().into_iter().filter(|v| v.ty == ty && v.assignable).collect();
        if vars.is_empty() {
            None
        } else {
            Some(vars[self.rng.below(vars.len())].clone())
        }
    }

    fn add_var(&mut self, name: &str, ty: Ty, size: u64) {
        let var = Var { name: name.to_string(), ty, size, assignable: true, accumulator: false };
        self.scopes.last_mut().unwrap().push(var);
    }

    /// A name for a new variable: usually new, sometimes one that hides a
    /// variable of an enclosing block.
    fn new_name(&mut self) -> String {
        if self.scopes.len() > 2 && self.rng.chance(8) {
            let current: Vec<String> = self.scopes.last().unwrap().iter().map(|v| v.name.clone()).collect();
            let outer: Vec<String> = self.scopes[1..self.scopes.len() - 1]
                .iter()
                .flatten()
                .filter(|v| v.name.starts_with('v') && !current.contains(&v.name))
                .map(|v| v.name.clone())
                .collect();
            if !outer.is_empty() {
                return outer[self.rng.below(outer.len())].clone();
            }
        }
        self.fresh("v")
    }

    // ---- integers ----

    fn literal(&mut self) -> (String, u64) {
        let v: i64 = match self.rng.below(8) {
            0..=2 => self.rng.between(-9, 9),
            3 | 4 => self.rng.between(-1000, 1000),
            5 => {
                let power = 1i64 << self.rng.between(1, 30);
                (power + self.rng.between(-1, 1)) * self.rng.pick(&[1, -1])
            }
            6 => self.rng.pick(&[2147483647, -2147483648, 1000003, 65535, 65536, 255, 256, 1023, 1024, 4095, 4096, 99999]),
            _ => self.rng.between(-100000, 100000),
        };
        (v.to_string(), v.unsigned_abs())
    }

    fn wrap(&mut self, e: String, size: u64, limit: u64) -> (String, u64) {
        if size <= limit {
            (e, size)
        } else {
            let m = self.rng.pick(MODULI);
            (format!("({e} % {m})"), m as u64)
        }
    }

    /// An int that fits in a variable.
    fn bounded_int(&mut self, depth: u32) -> String {
        let (e, size) = self.int(depth);
        self.wrap(e, size, INT_LIMIT).0
    }

    fn int(&mut self, depth: u32) -> (String, u64) {
        let choice = if depth == 0 { self.rng.below(4) } else { self.rng.below(27) };
        let (e, size) = match choice {
            0 | 1 => self.literal(),
            2 | 3 => match self.some_var(Ty::Int) {
                Some(v) => (v.name, v.size),
                None => self.literal(),
            },
            4 | 5 => {
                let (a, sa) = self.int(depth - 1);
                let (b, sb) = self.int(depth - 1);
                (format!("({a} + {b})"), sa + sb)
            }
            6 => {
                let (a, sa) = self.int(depth - 1);
                let (b, sb) = self.int(depth - 1);
                (format!("({a} - {b})"), sa + sb)
            }
            7 | 8 => {
                let (a, sa) = self.int(depth - 1);
                let (b, sb) = self.int(depth - 1);
                if sa.saturating_mul(sb) > BIG {
                    (format!("(({a} % 1000) * ({b} % 1000))"), 1_000_000)
                } else {
                    (format!("({a} * {b})"), sa * sb)
                }
            }
            9 | 10 => {
                let (a, sa) = self.int(depth - 1);
                let d = self.rng.pick(DIVISORS);
                (format!("({a} / {d})"), sa)
            }
            11 | 12 => {
                let (a, sa) = self.int(depth - 1);
                let d = self.rng.pick(DIVISORS);
                (format!("({a} % {d})"), sa.min(d.unsigned_abs()))
            }
            13 => {
                // A divisor that is only known when the program runs, never zero.
                let (a, sa) = self.int(depth - 1);
                let (b, _) = self.int(depth - 1);
                let op = self.rng.pick(&["/", "%"]);
                (format!("({a} {op} ({b} % 13 + 14))"), sa)
            }
            14 => {
                let (a, sa) = self.int(depth - 1);
                (format!("(-{a})"), sa)
            }
            15 => {
                let (a, sa) = self.int(depth - 1);
                let (b, sb) = self.int(depth - 1);
                match self.rng.below(3) {
                    0 => (format!("abs({a})"), sa),
                    1 => (format!("min({a}, {b})"), sa.max(sb)),
                    _ => (format!("max({a}, {b})"), sa.max(sb)),
                }
            }
            16 => {
                let (s, _) = self.string(depth - 1);
                (format!("{s}.len()"), 1 << 24)
            }
            17 => match self.rng.below(4) {
                0 => {
                    let (xs, _) = self.ints(depth - 1);
                    (format!("{xs}.len()"), 1 << 24)
                }
                1 => {
                    let (xs, _) = self.ints(depth - 1);
                    let i = self.bounded_int(depth - 1);
                    (format!("at({xs}, {i})"), 1 << 40)
                }
                2 => {
                    let (xs, _) = self.ints(depth - 1);
                    let v = self.bounded_int(depth - 1);
                    (format!("{xs}.index_of({v})"), 1 << 24)
                }
                _ => {
                    let (ss, _) = self.strs(depth - 1);
                    (format!("{ss}.len()"), 1 << 24)
                }
            },
            18 => {
                let (p, _) = self.point(depth - 1);
                match self.rng.below(3) {
                    0 => (format!("{p}.x"), 1 << 40),
                    1 => (format!("{p}.y"), 1 << 40),
                    _ => (format!("{p}.sum()"), 1 << 41),
                }
            }
            19 => match self.rng.below(5) {
                0 => ("team.scores.len()".to_string(), 1 << 24),
                1 => ("team.total()".to_string(), 1_000_003),
                2 => ("g_count".to_string(), INT_LIMIT),
                3 => ("team.members.len()".to_string(), 1 << 24),
                _ => {
                    let i = self.bounded_int(depth - 1);
                    (format!("at(team.scores, {i})"), 1 << 40)
                }
            },
            20 => match self.some_var(Ty::Shape) {
                Some(v) => (format!("{}.area()", v.name), 1_000_000),
                None => self.literal(),
            },
            21 => {
                let n = self.bounded_int(depth - 1);
                (format!("fact(abs({n}) % 12)"), 1_000_003)
            }
            22 | 23 => {
                // Something that can fail, handled on the spot or passed on.
                let fallback = self.rng.between(-50, 50);
                let (call, size) = match self.rng.below(6) {
                    0 | 1 => (format!("half({})", self.bounded_int(depth - 1)), INT_LIMIT),
                    2 => (format!("g_ages.get({})", self.short_string().0), 1 << 40),
                    3 => (format!("{}.first()", self.ints(depth - 1).0), 1 << 40),
                    4 => (format!("{}.last()", self.ints(depth - 1).0), 1 << 40),
                    _ => (format!("parse_int({})", self.short_string().0), INT_LIMIT),
                };
                if self.can_try && self.rng.chance(50) {
                    (format!("{call}?"), size)
                } else {
                    (format!("({call} or {fallback})"), size)
                }
            }
            24 => (self.rng.pick(&["g_ages.len()", "g_ids.len()"]).to_string(), 1 << 24),
            _ => match self.call(Ty::Int) {
                Some(call) => (call, INT_LIMIT),
                None => self.literal(),
            },
        };
        self.wrap(e, size, BIG)
    }

    // ---- booleans ----

    fn boolean(&mut self, depth: u32) -> String {
        let choice = if depth == 0 { self.rng.below(3) } else { self.rng.below(15) };
        match choice {
            0 => self.rng.pick(&["true", "false"]).to_string(),
            1 | 2 => match self.some_var(Ty::Bool) {
                Some(v) => v.name,
                None => self.rng.pick(&["true", "false"]).to_string(),
            },
            3..=6 => {
                let (a, _) = self.int(depth - 1);
                let (b, _) = self.int(depth - 1);
                let op = self.rng.pick(&["==", "!=", "<", "<=", ">", ">="]);
                format!("({a} {op} {b})")
            }
            7 => {
                let (a, _) = self.string(depth - 1);
                let (b, _) = self.string(depth - 1);
                let op = self.rng.pick(&["==", "!=", "<", "<=", ">", ">="]);
                format!("({a} {op} {b})")
            }
            8 => format!("(!{})", self.boolean(depth - 1)),
            9 => format!("({} && {})", self.boolean(depth - 1), self.boolean(depth - 1)),
            10 => format!("({} || {})", self.boolean(depth - 1), self.boolean(depth - 1)),
            11 => {
                if self.rng.chance(60) {
                    let (xs, _) = self.ints(depth - 1);
                    let v = self.bounded_int(depth - 1);
                    format!("{xs}.contains({v})")
                } else {
                    let (ss, _) = self.strs(depth - 1);
                    let (s, _) = self.short_string();
                    format!("{ss}.contains({s})")
                }
            }
            13 => match self.rng.below(3) {
                0 => format!("g_ages.has({})", self.short_string().0),
                1 => format!("g_ids.has({})", self.bounded_int(depth - 1)),
                _ => format!("(g_ids.len() {} {})", self.rng.pick(&["<", ">=", "=="]), self.rng.between(0, 5)),
            },
            12 => {
                let op = self.rng.pick(&["==", "!="]);
                match self.rng.below(4) {
                    0 => format!("({} {op} {})", self.ints(depth - 1).0, self.ints(depth - 1).0),
                    1 => format!("({} {op} {})", self.point(depth - 1).0, self.point(depth - 1).0),
                    2 => format!("({} {op} {})", self.strs(depth - 1).0, self.strs(depth - 1).0),
                    _ => format!("({} {op} {})", self.boolean(depth - 1), self.boolean(depth - 1)),
                }
            }
            _ => match self.call(Ty::Bool) {
                Some(call) => call,
                None => "true".to_string(),
            },
        }
    }

    // ---- strings ----

    /// A string made of constants and numbers only: at most 60 characters.
    fn short_string(&mut self) -> (String, u64) {
        match self.rng.below(4) {
            0 | 1 => {
                let text = self.rng.pick(TEXTS);
                (text.to_string(), text_len(text))
            }
            2 => (format!("str({})", self.bounded_int(1)), 21),
            _ => {
                let a = self.bounded_int(1);
                let b = self.boolean(1);
                let sep = self.rng.pick(&["-", ":", " ", "", "é"]);
                (format!("\"{{{a}}}{sep}{{{b}}}\""), 30)
            }
        }
    }

    /// An expression of any type whose text form stays short, for use inside a string.
    fn embedded(&mut self, depth: u32) -> (String, u64) {
        match self.rng.below(7) {
            0 | 1 => (self.int(depth).0, 21),
            2 => (self.boolean(depth), 5),
            3 | 4 => {
                let (e, size) = self.string(depth);
                if size <= EMBED_LIMIT {
                    (e, size)
                } else {
                    self.short_string()
                }
            }
            5 => {
                let (e, count) = self.ints(depth);
                if count * 22 <= EMBED_LIMIT {
                    (e, count * 22)
                } else {
                    ("[1, 2]".to_string(), 6)
                }
            }
            _ => {
                let (e, name) = self.point(depth);
                if name <= EMBED_LIMIT {
                    (e, name + 60)
                } else {
                    ("Point{x: 1, y: 2, name: \"p\"}".to_string(), 70)
                }
            }
        }
    }

    fn interpolation(&mut self, depth: u32) -> (String, u64) {
        let mut text = String::from("\"");
        let mut size = 0;
        for _ in 0..1 + self.rng.below(4) {
            if self.rng.chance(40) {
                text.push_str(self.rng.pick(&["a", " ", "=", ", ", "x: ", "[", "]", "é", "\\{", "\\}", "\\t", "#", "\\\""]));
                size += 3;
            } else {
                let (e, s) = self.embedded(depth.saturating_sub(1));
                text.push_str(&format!("{{{e}}}"));
                size += s;
            }
        }
        text.push('"');
        (text, size)
    }

    fn string(&mut self, depth: u32) -> (String, u64) {
        let choice = if depth == 0 { self.rng.below(4) } else { self.rng.below(16) };
        match choice {
            0 | 1 => {
                let text = self.rng.pick(TEXTS);
                (text.to_string(), text_len(text))
            }
            2 | 3 => match self.some_var(Ty::Str) {
                Some(v) => (v.name, v.size),
                None => self.short_string(),
            },
            4..=6 => self.interpolation(depth),
            7 | 8 => {
                let (a, sa) = self.string(depth - 1);
                let (b, sb) = self.string(depth - 1);
                (format!("({a} + {b})"), sa + sb)
            }
            9 => (format!("str({})", self.int(depth - 1).0), 21),
            10 => {
                let (p, name) = self.point(depth - 1);
                if self.rng.chance(50) {
                    (format!("{p}.name"), name)
                } else {
                    (format!("{p}.label()"), name + 50)
                }
            }
            11 => {
                let sep = self.rng.pick(&["\", \"", "\"\"", "\"-\"", "\" | \""]);
                if self.rng.chance(50) {
                    let (xs, count) = self.ints(depth - 1);
                    (format!("{xs}.join({sep})"), count * 24)
                } else {
                    let (ss, count) = self.strs(depth - 1);
                    (format!("{ss}.join({sep})"), count * 64)
                }
            }
            12 => match self.some_var(Ty::Shape) {
                Some(v) => (format!("{}.kind()", v.name), 80),
                None => self.short_string(),
            },
            13 => match self.rng.below(3) {
                0 => ("g_text".to_string(), GROWING),
                1 => ("team.name".to_string(), GROWING),
                _ => ("g_point.name".to_string(), GROWING),
            },
            14 => {
                let call = if self.rng.chance(60) {
                    format!("pos_label({})", self.bounded_int(depth - 1))
                } else {
                    format!("g_ids.get({})", self.bounded_int(depth - 1))
                };
                if self.can_try && self.rng.chance(50) {
                    (format!("{call}?"), GROWING)
                } else {
                    (format!("({call} or {})", self.rng.pick(TEXTS)), GROWING)
                }
            }
            _ => match self.call(Ty::Str) {
                Some(call) => (call, GROWING),
                None => self.short_string(),
            },
        }
    }

    // ---- lists and structs ----

    fn ints(&mut self, depth: u32) -> (String, u64) {
        let choice = if depth == 0 { self.rng.below(4) } else { self.rng.below(10) };
        match choice {
            0 | 1 => {
                let n = 1 + self.rng.below(4);
                let items: Vec<String> = (0..n).map(|_| self.bounded_int(depth.min(1))).collect();
                (format!("[{}]", items.join(", ")), n as u64)
            }
            2 | 3 => match self.some_var(Ty::Ints) {
                Some(v) => (v.name, v.size),
                None => ("[4, 5, 6]".to_string(), 3),
            },
            4 => {
                let (xs, _) = self.ints(depth - 1);
                let from = self.rng.between(-2, 3);
                let to = from + self.rng.between(-1, 4);
                (format!("{xs}.slice({from}, {to})"), 6)
            }
            5 => {
                let (xs, count) = self.ints(depth - 1);
                (format!("{xs}.reverse()"), count)
            }
            6 => {
                let (xs, count) = self.ints(depth - 1);
                (format!("{xs}.sort()"), count)
            }
            7 => (self.rng.pick(&["g_list", "team.scores"]).to_string(), GROWING),
            _ => match self.call(Ty::Ints) {
                Some(call) => (call, GROWING),
                None => ("[7]".to_string(), 1),
            },
        }
    }

    fn strs(&mut self, depth: u32) -> (String, u64) {
        let choice = if depth == 0 { self.rng.below(4) } else { self.rng.below(8) };
        match choice {
            0 | 1 => {
                let n = 1 + self.rng.below(3);
                let items: Vec<String> = (0..n).map(|_| self.short_string().0).collect();
                (format!("[{}]", items.join(", ")), n as u64)
            }
            2 | 3 => match self.some_var(Ty::Strs) {
                Some(v) => (v.name, v.size),
                None => ("[\"k\"]".to_string(), 1),
            },
            4 => {
                let (ss, _) = self.strs(depth - 1);
                let from = self.rng.between(-2, 3);
                let to = from + self.rng.between(-1, 4);
                (format!("{ss}.slice({from}, {to})"), 6)
            }
            5 => {
                let (ss, count) = self.strs(depth - 1);
                (format!("{ss}.reverse()"), count)
            }
            6 => {
                let (ss, count) = self.strs(depth - 1);
                (format!("{ss}.sort()"), count)
            }
            _ => ("g_names".to_string(), GROWING),
        }
    }

    fn point(&mut self, depth: u32) -> (String, u64) {
        let choice = if depth == 0 { self.rng.below(4) } else { self.rng.below(9) };
        match choice {
            0 | 1 => {
                let x = self.bounded_int(depth.min(1));
                let y = self.bounded_int(depth.min(1));
                let (name, size) = self.short_string();
                (format!("Point{{x: {x}, y: {y}, name: {name}}}"), size)
            }
            2 | 3 => match self.some_var(Ty::Point) {
                Some(v) => (v.name, v.size),
                None => ("Point{x: 1, y: 1, name: \"p\"}".to_string(), 1),
            },
            4 => {
                let (p, name) = self.point(depth - 1);
                let k = self.rng.between(-50, 50);
                (format!("{p}.scaled({k})"), name + 1)
            }
            5 => {
                let (ps, _) = self.points(depth - 1);
                let i = self.bounded_int(depth - 1);
                (format!("pick({ps}, {i})"), GROWING)
            }
            6 => ("g_point".to_string(), GROWING),
            7 => {
                let i = self.bounded_int(depth - 1);
                (format!("pick(team.members, {i})"), GROWING)
            }
            _ => match self.call(Ty::Point) {
                Some(call) => (call, GROWING),
                None => ("Point{x: 0, y: 0, name: \"z\"}".to_string(), 1),
            },
        }
    }

    fn points(&mut self, depth: u32) -> (String, u64) {
        let choice = if depth == 0 { self.rng.below(4) } else { self.rng.below(7) };
        match choice {
            0 | 1 => {
                let n = 1 + self.rng.below(2);
                let items: Vec<String> = (0..n).map(|_| self.point(depth.min(1)).0).collect();
                (format!("[{}]", items.join(", ")), n as u64)
            }
            2 | 3 => match self.some_var(Ty::Points) {
                Some(v) => (v.name, v.size),
                None => ("[Point{x: 2, y: 3, name: \"q\"}]".to_string(), 1),
            },
            4 => {
                let (ps, _) = self.points(depth - 1);
                let from = self.rng.between(-1, 2);
                let to = from + self.rng.between(0, 3);
                (format!("{ps}.slice({from}, {to})"), 3)
            }
            5 => {
                let (ps, count) = self.points(depth - 1);
                (format!("{ps}.reverse()"), count)
            }
            _ => ("team.members".to_string(), GROWING),
        }
    }

    fn shape(&mut self) -> String {
        match self.rng.below(4) {
            0 => match self.some_var(Ty::Shape) {
                Some(v) => v.name,
                None => "Square{side: 3}".to_string(),
            },
            1 => {
                let w = self.bounded_int(1);
                let h = self.bounded_int(1);
                let (tag, _) = self.short_string();
                format!("Rect{{w: ({w} % 1000), h: ({h} % 1000), tag: {tag}}}")
            }
            _ => {
                let side = self.bounded_int(1);
                format!("Square{{side: ({side} % 1000)}}")
            }
        }
    }

    fn expr(&mut self, ty: Ty, depth: u32) -> String {
        match ty {
            Ty::Int => self.bounded_int(depth),
            Ty::Bool => self.boolean(depth),
            Ty::Str => self.string(depth).0,
            Ty::Ints => self.ints(depth).0,
            Ty::Strs => self.strs(depth).0,
            Ty::Point => self.point(depth).0,
            Ty::Points => self.points(depth).0,
            Ty::Shape => self.shape(),
        }
    }

    /// A call to one of the generated functions that returns `ty`.
    fn call(&mut self, ty: Ty) -> Option<String> {
        if self.calm {
            return None;
        }
        let candidates: Vec<usize> = (0..self.callable).filter(|&i| self.functions[i].ret == Some(ty)).collect();
        if candidates.is_empty() {
            return None;
        }
        let index = candidates[self.rng.below(candidates.len())];
        let call = self.call_text(index);
        if !self.functions[index].fallible {
            return Some(call);
        }
        Some(if self.can_try && self.rng.chance(50) {
            format!("{call}?")
        } else if ty == Ty::Int {
            format!("({call} or {})", self.rng.between(-9, 9))
        } else {
            format!("({call} or {})", self.rng.pick(TEXTS))
        })
    }

    fn call_text(&mut self, index: usize) -> String {
        let params = self.functions[index].params.clone();
        let args: Vec<String> = params.iter().map(|&ty| self.expr(ty, 1)).collect();
        format!("{}({})", self.functions[index].name, args.join(", "))
    }

    /// Generates something without calls to generated functions.
    fn calmly<T>(&mut self, f: impl FnOnce(&mut Self) -> T) -> T {
        let saved = std::mem::replace(&mut self.calm, true);
        let result = f(self);
        self.calm = saved;
        result
    }

    // ---- statements ----

    fn block(&mut self, statements: usize) {
        self.indent += 1;
        self.scopes.push(Vec::new());
        for _ in 0..statements {
            if self.budget <= 0 {
                break;
            }
            self.stmt();
        }
        self.scopes.pop();
        self.indent -= 1;
    }

    fn stmt(&mut self) {
        self.budget -= 1;
        match self.rng.below(31) {
            26 | 27 => self.catch_stmt(),
            28..=30 => self.map_op(),
            0..=4 => self.declare(),
            5..=7 => self.assign_int(),
            8 => self.assign_other(),
            9 | 10 => self.print(),
            11 | 12 => self.if_stmt(),
            13 => self.while_loop(),
            14 | 15 => self.for_range(),
            16 => self.for_list(),
            17 | 18 => self.list_op(),
            19 => self.point_op(),
            20 => self.team_op(),
            21 => self.shape_op(),
            22 => self.call_stmt(),
            23 => {
                self.line("{");
                let n = 1 + self.rng.below(3);
                self.block(n);
                self.line("}");
            }
            _ => self.jump(),
        }
    }

    fn declare(&mut self) {
        let ty = self.rng.pick(&[
            Ty::Int,
            Ty::Int,
            Ty::Int,
            Ty::Bool,
            Ty::Str,
            Ty::Str,
            Ty::Ints,
            Ty::Ints,
            Ty::Strs,
            Ty::Point,
            Ty::Points,
            Ty::Shape,
        ]);
        let name = self.new_name();
        let annotate = self.rng.chance(30);
        let typed = if annotate || ty == Ty::Shape { format!(": {}", ty.name()) } else { String::new() };
        let mut size = INT_LIMIT;
        let mut accumulator = false;
        let init = match ty {
            Ty::Int => self.bounded_int(3),
            Ty::Bool => self.boolean(3),
            Ty::Str => {
                let (e, s) = self.string(3);
                accumulator = self.rng.chance(40);
                size = if accumulator { GROWING } else { s.max(60) };
                e
            }
            Ty::Ints | Ty::Strs | Ty::Points => {
                size = GROWING;
                if self.rng.chance(20) {
                    // An empty list needs its type written.
                    self.line(&format!("var {name}: {} = []", ty.name()));
                    self.add_var(&name, ty, size);
                    return;
                }
                self.expr(ty, 2)
            }
            Ty::Point => {
                size = GROWING;
                self.point(2).0
            }
            Ty::Shape => self.shape(),
        };
        self.line(&format!("var {name}{typed} = {init}"));
        self.add_var(&name, ty, size);
        self.scopes.last_mut().unwrap().last_mut().unwrap().accumulator = accumulator;
    }

    fn assign_int(&mut self) {
        let Some(var) = self.assignable_var(Ty::Int) else {
            return self.declare();
        };
        let v = &var.name;
        let m = self.rng.pick(MODULI);
        match self.rng.below(7) {
            0 | 1 => {
                let e = self.bounded_int(3);
                self.line(&format!("{v} = {e}"));
            }
            2 => {
                let e = self.bounded_int(2);
                self.line(&format!("{v} += {e}"));
                self.line(&format!("{v} = {v} % {m}"));
            }
            3 => {
                let e = self.bounded_int(2);
                self.line(&format!("{v} -= {e}"));
                self.line(&format!("{v} = {v} % {m}"));
            }
            4 => {
                let k = self.rng.between(-9, 9);
                self.line(&format!("{v} *= {k}"));
                self.line(&format!("{v} = {v} % {m}"));
            }
            5 => {
                let d = self.rng.pick(DIVISORS);
                self.line(&format!("{v} /= {d}"));
            }
            _ => {
                let k = self.rng.between(-3, 3);
                self.line(&format!("{v} += {k}"));
                self.line(&format!("{v} = {v} % {m}"));
            }
        }
    }

    fn assign_other(&mut self) {
        let ty = self.rng.pick(&[Ty::Str, Ty::Str, Ty::Bool, Ty::Ints, Ty::Strs, Ty::Point, Ty::Points, Ty::Shape]);
        let Some(var) = self.assignable_var(ty) else {
            return self.print();
        };
        let v = &var.name;
        match ty {
            Ty::Str => {
                // Strings only ever grow by a short constant piece, or are
                // replaced by a short fresh one: no exponential growth.
                let (piece, _) = self.short_string();
                if var.accumulator {
                    if self.rng.chance(70) {
                        self.line(&format!("{v} += {piece}"));
                    } else {
                        self.line(&format!("{v} = {v} + {piece}"));
                    }
                } else {
                    self.line(&format!("{v} = {piece}"));
                }
            }
            Ty::Bool => {
                let e = self.boolean(3);
                self.line(&format!("{v} = {e}"));
            }
            _ => {
                let e = self.expr(ty, 2);
                self.line(&format!("{v} = {e}"));
            }
        }
    }

    fn print(&mut self) {
        let n = 1 + self.rng.below(4);
        let mut args = Vec::new();
        for _ in 0..n {
            // Inside loops only short values are printed, to keep the output small.
            let arg = if self.loops > 0 {
                match self.rng.below(4) {
                    0 | 1 => self.int(2).0,
                    2 => self.boolean(2),
                    _ => self.embedded(1).0,
                }
            } else {
                let ty = self.rng.pick(&[
                    Ty::Int,
                    Ty::Int,
                    Ty::Bool,
                    Ty::Str,
                    Ty::Str,
                    Ty::Ints,
                    Ty::Strs,
                    Ty::Point,
                    Ty::Points,
                ]);
                match ty {
                    Ty::Int => self.int(3).0,
                    _ => self.expr(ty, 3),
                }
            };
            args.push(arg);
        }
        self.line(&format!("print({})", args.join(", ")));
    }

    fn if_stmt(&mut self) {
        let cond = self.boolean(3);
        self.line(&format!("if {cond} {{"));
        let n = 1 + self.rng.below(3);
        self.block(n);
        match self.rng.below(4) {
            0 => {
                self.line("} else {");
                let n = 1 + self.rng.below(3);
                self.block(n);
            }
            1 => {
                let cond = self.boolean(2);
                self.line(&format!("}} else if {cond} {{"));
                let n = 1 + self.rng.below(2);
                self.block(n);
                if self.rng.chance(50) {
                    self.line("} else {");
                    let n = 1 + self.rng.below(2);
                    self.block(n);
                }
            }
            _ => {}
        }
        self.line("}");
    }

    fn while_loop(&mut self) {
        if self.loops >= self.max_loops {
            return self.print();
        }
        let counter = self.fresh("w");
        let limit = self.rng.between(1, 6);
        self.line(&format!("var {counter} = 0"));
        let extra = if self.rng.chance(40) { format!(" && {}", self.boolean(2)) } else { String::new() };
        self.line(&format!("while {counter} < {limit}{extra} {{"));
        // The counter moves first, so that `continue` cannot loop forever.
        self.indent += 1;
        self.line(&format!("{counter} += 1"));
        self.indent -= 1;
        self.loops += 1;
        let n = 1 + self.rng.below(4);
        self.block(n);
        self.loops -= 1;
        self.line("}");
    }

    fn for_range(&mut self) {
        if self.loops >= self.max_loops {
            return self.assign_int();
        }
        let var = self.fresh("i");
        let lo = self.rng.between(-2, 3);
        let hi = if self.rng.chance(70) {
            (lo + self.rng.between(0, 6)).to_string()
        } else {
            let e = self.bounded_int(1);
            format!("({e} % 4 + 4)")
        };
        self.line(&format!("for {var} in {lo}..{hi} {{"));
        self.loops += 1;
        self.indent += 1;
        self.scopes.push(vec![Var { name: var, ty: Ty::Int, size: 16, assignable: false, accumulator: false }]);
        let n = 1 + self.rng.below(4);
        for _ in 0..n {
            if self.budget > 0 {
                self.stmt();
            }
        }
        self.scopes.pop();
        self.indent -= 1;
        self.loops -= 1;
        self.line("}");
    }

    fn for_list(&mut self) {
        if self.loops >= self.max_loops {
            return self.list_op();
        }
        let (list, item_ty, item_size) = match self.rng.below(5) {
            0 | 1 => (self.ints(2).0, Ty::Int, 1 << 40),
            2 => (self.strs(2).0, Ty::Str, GROWING),
            3 => (self.points(2).0, Ty::Point, GROWING),
            _ => ("shapes".to_string(), Ty::Shape, 0),
        };
        let guard = self.fresh("n");
        let item = self.fresh("x");
        self.line(&format!("var {guard} = 0"));
        self.line(&format!("for {item} in {list} {{"));
        self.loops += 1;
        self.indent += 1;
        // The body may add elements to the list it walks: stop after a while.
        self.line(&format!("{guard} += 1"));
        self.line(&format!("if {guard} > 12 {{"));
        self.line("    break");
        self.line("}");
        self.scopes.push(vec![Var { name: item, ty: item_ty, size: item_size, assignable: false, accumulator: false }]);
        let n = 1 + self.rng.below(4);
        for _ in 0..n {
            if self.budget > 0 {
                self.stmt();
            }
        }
        self.scopes.pop();
        self.indent -= 1;
        self.loops -= 1;
        self.line("}");
    }

    fn list_op(&mut self) {
        match self.rng.below(3) {
            0 => {
                let xs = match self.some_var(Ty::Ints) {
                    Some(v) => v.name,
                    None => self.rng.pick(&["g_list", "team.scores"]).to_string(),
                };
                let k = self.rng.between(0, 4);
                let e = self.bounded_int(2);
                let calm = self.calmly(|g| g.bounded_int(2));
                let small = self.rng.between(-999, 999);
                match self.rng.below(11) {
                    0..=2 => self.line(&format!("{xs}.push({e})")),
                    3 => self.line(&format!("{xs}.insert(0, {e})")),
                    4 => self.line(&format!("{xs}.insert({xs}.len(), {calm})")),
                    5 => {
                        self.line(&format!("if {xs}.len() > {k} {{"));
                        if self.rng.chance(50) {
                            self.line(&format!("    {xs}.remove({k})"));
                        } else {
                            self.line(&format!("    g_count = {xs}.remove({k}) % 1000"));
                        }
                        self.line("}");
                    }
                    6 => {
                        self.line(&format!("if {xs}.len() > {k} {{"));
                        self.line(&format!("    {xs}[{k}] = {calm}"));
                        self.line("}");
                    }
                    7 => {
                        let op = self.rng.pick(&["+=", "-="]);
                        self.line(&format!("if {xs}.len() > {k} {{"));
                        self.line(&format!("    {xs}[{k}] {op} {small}"));
                        self.line("}");
                    }
                    8 => {
                        let i = self.calmly(|g| g.bounded_int(1));
                        let op = self.rng.pick(&["=", "+=", "-="]);
                        self.line(&format!("if {xs}.len() > 0 {{"));
                        self.line(&format!("    {xs}[abs({i}) % {xs}.len()] {op} {small}"));
                        self.line("}");
                    }
                    9 => {
                        if self.rng.chance(15) {
                            self.line(&format!("{xs}.clear()"));
                        } else {
                            self.line(&format!("{xs}.push({xs}.len())"));
                        }
                    }
                    _ => {
                        let i = self.rng.between(0, 3);
                        self.line(&format!("if {xs}.len() > {i} {{"));
                        self.line(&format!("    g_count = ({xs}[{i}] + g_count) % 65536"));
                        self.line("}");
                    }
                }
            }
            1 => {
                let ss = match self.some_var(Ty::Strs) {
                    Some(v) => v.name,
                    None => "g_names".to_string(),
                };
                let (s, _) = self.calmly(|g| g.short_string());
                let k = self.rng.between(0, 3);
                match self.rng.below(6) {
                    0..=2 => self.line(&format!("{ss}.push({s})")),
                    3 => {
                        self.line(&format!("if {ss}.len() > {k} {{"));
                        self.line(&format!("    {ss}[{k}] = {s}"));
                        self.line("}");
                    }
                    4 => {
                        self.line(&format!("if {ss}.len() > {k} && {ss}[{k}].len() < 40 {{"));
                        self.line(&format!("    {ss}[{k}] += {s}"));
                        self.line("}");
                    }
                    _ => {
                        self.line(&format!("if {ss}.len() > {k} {{"));
                        self.line(&format!("    g_text += {ss}.remove({k})"));
                        self.line("}");
                    }
                }
            }
            _ => {
                let ps = match self.some_var(Ty::Points) {
                    Some(v) => v.name,
                    None => "team.members".to_string(),
                };
                let p = self.calmly(|g| g.point(2).0);
                let k = self.rng.between(0, 3);
                let small = self.rng.between(-99, 99);
                match self.rng.below(7) {
                    0..=2 => self.line(&format!("{ps}.push({p})")),
                    3 => {
                        self.line(&format!("if {ps}.len() > {k} {{"));
                        self.line(&format!("    {ps}[{k}].x += {small}"));
                        self.line(&format!("    {ps}[{k}].nudge({small})"));
                        self.line("}");
                    }
                    4 => {
                        self.line(&format!("if {ps}.len() > {k} {{"));
                        self.line(&format!("    {ps}[{k}] = {p}"));
                        self.line("}");
                    }
                    5 => {
                        self.line(&format!("if {ps}.len() > {k} && {ps}[{k}].name.len() < 30 {{"));
                        self.line(&format!("    {ps}[{k}].name += \"!\""));
                        self.line("}");
                    }
                    _ => {
                        self.line(&format!("if {ps}.len() > {k} {{"));
                        self.line(&format!("    g_point = {ps}.remove({k})"));
                        self.line("}");
                    }
                }
            }
        }
    }

    fn point_op(&mut self) {
        let p = match self.some_var(Ty::Point) {
            Some(v) => v.name,
            None => "g_point".to_string(),
        };
        let small = self.rng.between(-99, 99);
        match self.rng.below(7) {
            0 => {
                let e = self.bounded_int(2);
                self.line(&format!("{p}.x = {e}"));
            }
            1 => self.line(&format!("{p}.x += {small}")),
            2 => self.line(&format!("{p}.y -= {small}")),
            3 => {
                self.line(&format!("if {p}.name.len() < 30 {{"));
                self.line(&format!("    {p}.name += \"+\""));
                self.line("}");
            }
            4 => {
                let (s, _) = self.short_string();
                self.line(&format!("{p}.name = {s}"));
            }
            5 => self.line(&format!("{p}.nudge({small})")),
            _ => {
                let k = self.rng.between(-9, 9);
                self.line(&format!("{p}.y = {p}.y * {k} % 100000"));
            }
        }
    }

    fn team_op(&mut self) {
        let k = self.rng.between(0, 3);
        let small = self.rng.between(-99, 99);
        match self.rng.below(8) {
            0 => {
                let p = self.point(2).0;
                self.line(&format!("team.members.push({p})"));
            }
            1 => {
                let e = self.bounded_int(2);
                self.line(&format!("team.scores.push({e})"));
            }
            2 => {
                self.line(&format!("if team.scores.len() > {k} {{"));
                self.line(&format!("    team.scores[{k}] += {small}"));
                self.line("}");
            }
            3 => {
                self.line(&format!("if team.members.len() > {k} {{"));
                self.line(&format!("    team.members[{k}].x += {small}"));
                self.line(&format!("    team.members[{k}].y = team.members[{k}].x - {small}"));
                self.line("}");
            }
            4 => {
                let (s, _) = self.short_string();
                self.line(&format!("team.name = {s}"));
            }
            5 => {
                let (s, _) = self.short_string();
                let e = self.bounded_int(1);
                self.line(&format!("team = Team{{name: {s}, members: team.members, scores: [{e}]}}"));
            }
            6 => {
                self.line("if team.name.len() < 30 {");
                self.line("    team.name += \"~\"");
                self.line("}");
            }
            _ => self.line("print(team.name, team.members.len(), team.scores.len(), team.total())"),
        }
    }

    fn shape_op(&mut self) {
        let s = self.shape();
        match self.rng.below(4) {
            0 | 1 => self.line(&format!("shapes.push({s})")),
            2 => {
                self.line("if shapes.len() > 0 {");
                self.line("    print(shapes[0].kind(), shapes[shapes.len() - 1].area())");
                self.line("}");
            }
            _ => match self.assignable_var(Ty::Shape) {
                Some(v) => self.line(&format!("{} = {s}", v.name)),
                None => self.line(&format!("print({s}.area())")),
            },
        }
    }

    /// What a `catch` block does before giving a value or leaving.
    fn catch_body(&mut self) -> String {
        match self.rng.below(4) {
            0 => "print(\"caught\", err)".to_string(),
            1 => "g_count = (g_count + err.message.len()) % 1000".to_string(),
            2 => "g_text += \"!\"".to_string(),
            _ => "var note = \"<\" + err.message + \">\"".to_string(),
        }
    }

    /// A way for a `catch` block to leave instead of giving a value.
    fn catch_exit(&mut self) -> Option<String> {
        if self.loops > 0 && self.rng.chance(60) {
            return Some(self.rng.pick(&["continue", "break"]).to_string());
        }
        match self.returns {
            Some(Some(ty)) => Some(format!("return {}", self.calmly(|g| g.expr(ty, 1)))),
            Some(None) => Some("return".to_string()),
            None => None,
        }
    }

    fn catch_stmt(&mut self) {
        let fallback = self.rng.between(-9, 9);
        let call = match self.rng.below(4) {
            0 | 1 => format!("half({})", self.bounded_int(2)),
            2 => format!("g_ages.get({})", self.short_string().0),
            _ => format!("parse_int({})", self.short_string().0),
        };
        let body = self.catch_body();
        match self.rng.below(7) {
            0 | 1 => {
                // The block gives a value, or leaves.
                let name = self.fresh("c");
                self.line(&format!("var {name} = {call} catch err {{"));
                self.line(&format!("    {body}"));
                match self.catch_exit() {
                    Some(exit) if self.rng.chance(40) => self.line(&format!("    {exit}")),
                    _ => self.line(&format!("    {fallback}")),
                }
                self.line("}");
                self.line(&format!("{name} = {name} % 1000003"));
                self.add_var(&name, Ty::Int, INT_LIMIT);
            }
            2 => match self.assignable_var(Ty::Int) {
                Some(var) => {
                    self.line(&format!("{} = {call} catch err {{", var.name));
                    self.line(&format!("    {body}"));
                    self.line(&format!("    {fallback}"));
                    self.line("}");
                    self.line(&format!("{0} = {0} % 1000003", var.name));
                }
                None => self.print(),
            },
            3 => {
                self.line(&format!("{call} catch err {{"));
                self.line(&format!("    {body}"));
                self.line("}");
            }
            4 => {
                // Into an element or a field: the target is prepared first.
                let k = self.rng.between(0, 3);
                let op = self.rng.pick(&["=", "+=", "-="]);
                let value = format!("half({}) catch err {{ {fallback} }}", self.calmly(|g| g.bounded_int(1)));
                match self.rng.below(3) {
                    0 => {
                        self.line(&format!("if g_list.len() > {k} {{"));
                        self.line(&format!("    g_list[{k}] {op} {value}"));
                        self.line(&format!("    g_list[{k}] = g_list[{k}] % 1000003"));
                        self.line("}");
                    }
                    1 => {
                        self.line(&format!("g_point.x {op} {value}"));
                        self.line("g_point.x = g_point.x % 1000003");
                    }
                    _ => {
                        self.line(&format!("if team.scores.len() > {k} {{"));
                        self.line(&format!("    team.scores[{k}] {op} {value}"));
                        self.line(&format!("    team.scores[{k}] = team.scores[{k}] % 1000003"));
                        self.line("}");
                    }
                }
            }
            5 => {
                // A string value.
                let name = self.fresh("c");
                let text = self.rng.pick(TEXTS);
                let n = self.bounded_int(2);
                self.line(&format!("var {name} = pos_label({n}) catch err {{"));
                self.line(&format!("    {body}"));
                self.line(&format!("    {text} + err.message"));
                self.line("}");
                self.add_var(&name, Ty::Str, 80);
            }
            _ => match self.returns {
                // `return call() catch ...` in a function that returns an int.
                Some(Some(Ty::Int)) if self.rng.chance(50) => {
                    let cond = self.boolean(1);
                    self.line(&format!("if {cond} {{"));
                    self.line(&format!("    return {call} catch err {{"));
                    self.line(&format!("        {body}"));
                    self.line(&format!("        {fallback}"));
                    self.line("    }");
                    self.line("}");
                }
                _ => {
                    self.line(&format!("{call} catch err {{"));
                    self.line("    print(err.message)");
                    self.line("}");
                }
            },
        }
    }

    fn map_op(&mut self) {
        // Keys are computed without calls, so that two uses of the same key
        // expression in a statement give the same key.
        let key = self.calmly(|g| g.short_string().0);
        let id = self.calmly(|g| g.bounded_int(1));
        let small = self.rng.between(-99, 99);
        if self.frozen_maps {
            // Reading only.
            match self.rng.below(3) {
                0 => self.line(&format!("g_count = (g_count + (g_ages.get({key}) or {small})) % 1000")),
                1 => self.line(&format!("print(g_ages.has({key}), g_ids.has({id} % 40), g_ages.len())")),
                _ => {
                    self.line(&format!("if g_ids.has({id} % 40) {{"));
                    self.line(&format!("    g_text += g_ids[{id} % 40]"));
                    self.line("}");
                }
            }
            return;
        }
        match self.rng.below(14) {
            0 | 1 => {
                let e = self.bounded_int(2);
                self.line(&format!("g_ages[{key}] = {e}"));
            }
            2 => {
                self.line(&format!("g_ages[{key}] = (g_ages.get({key}) or 0) + {small}"));
            }
            3 => {
                self.line(&format!("if g_ages.has({key}) {{"));
                self.line(&format!("    g_ages[{key}] += {small}"));
                self.line("}");
            }
            4 => self.line(&format!("g_ages.remove({key})")),
            5 | 6 => {
                let (s, _) = self.short_string();
                self.line(&format!("g_ids[{id} % 40] = {s}"));
            }
            7 => {
                self.line(&format!("if g_ids.has({id} % 40) && g_ids[{id} % 40].len() < 30 {{"));
                self.line(&format!("    g_ids[{id} % 40] += \"+\""));
                self.line("}");
            }
            8 => self.line(&format!("g_ids.remove({id} % 40)")),
            9 => {
                if self.loops == 0 {
                    self.line("print(g_ages, g_ids.keys(), g_ids.values(), g_ages.keys().sort())");
                } else {
                    self.line("print(g_ages.len(), g_ids.len())");
                }
            }
            10 => {
                if self.rng.chance(20) {
                    let clear = self.rng.pick(&["g_ages.clear()", "g_ids.clear()"]);
                    self.line(clear);
                } else {
                    self.line(&format!("g_ages[\"k\" + str({id} % 30)] = {small}"));
                }
            }
            11 if self.loops < self.max_loops => {
                // Walking a map: nothing may change it meanwhile.
                let over_ages = self.rng.chance(50);
                let key = self.fresh("k");
                let (map, ty, size) = if over_ages { ("g_ages", Ty::Str, 80) } else { ("g_ids", Ty::Int, INT_LIMIT) };
                let guard = self.fresh("n");
                self.line(&format!("var {guard} = 0"));
                self.line(&format!("for {key} in {map} {{"));
                self.loops += 1;
                self.indent += 1;
                self.line(&format!("{guard} += 1"));
                self.line(&format!("if {guard} > 8 {{"));
                self.line("    break");
                self.line("}");
                self.line(&format!("g_count = (g_count + {guard}) % 1000"));
                if over_ages {
                    self.line(&format!("if {key}.len() > 3 && {map}[{key}] > 0 || {key} == \"a\" {{"));
                    self.line(&format!("    g_text += {key}"));
                    self.line("}");
                } else {
                    self.line(&format!("g_count = (g_count + {key} + {map}[{key}].len()) % 1000"));
                }
                let (calm, frozen) = (self.calm, self.frozen_maps);
                self.calm = true;
                self.frozen_maps = true;
                self.scopes.push(vec![Var { name: key, ty, size, assignable: false, accumulator: false }]);
                let n = 1 + self.rng.below(3);
                for _ in 0..n {
                    if self.budget > 0 {
                        self.stmt();
                    }
                }
                self.scopes.pop();
                self.calm = calm;
                self.frozen_maps = frozen;
                self.indent -= 1;
                self.loops -= 1;
                self.line("}");
            }
            12 => {
                self.line(&format!("var copy_{0} = g_ages", self.counter + 1));
                self.counter += 1;
                self.line(&format!("print(copy_{0} == g_ages, g_ages.len() == g_ages.keys().len(), g_ids == g_ids)", self.counter));
            }
            _ => {
                self.line(&format!("if g_ages.has({key}) {{"));
                self.line(&format!("    g_count = g_ages[{key}] % 1000"));
                self.line("}");
            }
        }
    }

    fn call_stmt(&mut self) {
        if self.callable == 0 || self.calm {
            return self.print();
        }
        let index = self.rng.below(self.callable);
        let call = self.call_text(index);
        if self.functions[index].fallible {
            // The failure is handled here, by a block that may leave.
            let name = self.fresh("r");
            let body = self.catch_body();
            let default = match self.functions[index].ret {
                Some(Ty::Int) => self.rng.between(-9, 9).to_string(),
                _ => self.rng.pick(TEXTS).to_string(),
            };
            self.line(&format!("var {name} = {call} catch err {{"));
            self.line(&format!("    {body}"));
            match self.catch_exit() {
                Some(exit) if self.rng.chance(40) => self.line(&format!("    {exit}")),
                _ => self.line(&format!("    {default}")),
            }
            self.line("}");
            let ty = self.functions[index].ret.unwrap();
            self.add_var(&name, ty, if ty == Ty::Int { INT_LIMIT } else { GROWING });
            return;
        }
        match self.functions[index].ret {
            Some(ty) if self.rng.chance(60) => {
                let name = self.fresh("r");
                self.line(&format!("var {name} = {call}"));
                let size = if ty == Ty::Int { INT_LIMIT } else { GROWING };
                self.add_var(&name, ty, size);
            }
            // The result, if any, is dropped.
            _ => self.line(&call),
        }
    }

    fn jump(&mut self) {
        let cond = self.boolean(2);
        if self.loops > 0 && self.rng.chance(70) {
            let word = self.rng.pick(&["break", "continue"]);
            self.line(&format!("if {cond} {{"));
            self.line(&format!("    {word}"));
            self.line("}");
        } else if self.can_try && self.rng.chance(40) {
            let detail = self.calmly(|g| g.bounded_int(1));
            self.line(&format!("if {cond} {{"));
            self.line(&format!("    fail \"gave up at {{{detail}}}\""));
            self.line("}");
        } else if let Some(ret) = self.returns {
            self.line(&format!("if {cond} {{"));
            match ret {
                Some(ty) => {
                    let e = self.expr(ty, 2);
                    self.line(&format!("    return {e}"));
                }
                None => self.line("    return"),
            }
            self.line("}");
        } else {
            self.print();
        }
    }

    // ---- whole program ----

    fn function(&mut self, index: usize) {
        let all = [Ty::Int, Ty::Int, Ty::Bool, Ty::Str, Ty::Ints, Ty::Strs, Ty::Point, Ty::Points, Ty::Shape];
        let params: Vec<Ty> = (0..self.rng.below(5)).map(|_| self.rng.pick(&all)).collect();
        let ret = if self.rng.chance(85) {
            Some(self.rng.pick(&[Ty::Int, Ty::Int, Ty::Bool, Ty::Str, Ty::Ints, Ty::Point]))
        } else {
            None
        };
        let fallible = matches!(ret, Some(Ty::Int | Ty::Str)) && self.rng.chance(35);
        let name = format!("f{index}");
        let mut scope = Vec::new();
        let mut header = Vec::new();
        for (i, &ty) in params.iter().enumerate() {
            let param = format!("p{i}");
            header.push(format!("{param}: {}", ty.name()));
            let size = if ty == Ty::Int { INT_LIMIT } else { GROWING };
            scope.push(Var { name: param, ty, size, assignable: true, accumulator: ty == Ty::Str });
        }
        let arrow = ret.map(|ty| format!(" -> {}{}", ty.name(), if fallible { "!" } else { "" })).unwrap_or_default();
        self.line(&format!("fn {name}({}){arrow} {{", header.join(", ")));

        // The first functions call nobody; the later ones may call the first ones.
        self.callable = if index < 3 { 0 } else { 3.min(self.functions.len()) };
        self.returns = Some(ret);
        self.can_try = fallible;
        self.max_loops = 2;
        self.budget = 14;
        self.indent += 1;
        self.scopes.push(scope);
        let n = 3 + self.rng.below(8);
        for _ in 0..n {
            if self.budget > 0 {
                self.stmt();
            }
        }
        if let Some(ty) = ret {
            let e = self.expr(ty, 3);
            self.line(&format!("return {e}"));
        }
        self.scopes.pop();
        self.indent -= 1;
        self.line("}");
        self.line("");
        self.can_try = false;
        self.functions.push(Function { name, params, ret, fallible });
    }

    fn program(seed: u64) -> String {
        let mut g = Gen {
            rng: Rng::new(seed),
            out: format!("// Generated by tests/fuzz.rs, seed {seed}.\n\n{PRELUDE}\n"),
            indent: 0,
            scopes: Vec::new(),
            counter: 0,
            functions: Vec::new(),
            callable: 0,
            returns: None,
            loops: 0,
            max_loops: 2,
            budget: 0,
            calm: false,
            can_try: false,
            frozen_maps: false,
        };
        // The top-level variables of the prelude.
        g.scopes.push(vec![
            Var { name: "g_count".into(), ty: Ty::Int, size: INT_LIMIT, assignable: false, accumulator: false },
            Var { name: "g_text".into(), ty: Ty::Str, size: GROWING, assignable: true, accumulator: true },
            Var { name: "g_list".into(), ty: Ty::Ints, size: GROWING, assignable: true, accumulator: false },
            Var { name: "g_names".into(), ty: Ty::Strs, size: GROWING, assignable: true, accumulator: false },
            Var { name: "g_point".into(), ty: Ty::Point, size: GROWING, assignable: true, accumulator: false },
        ]);
        let count = 3 + g.rng.below(5);
        for index in 0..count {
            g.function(index);
        }

        g.line("fn main() {");
        g.callable = g.functions.len();
        g.returns = None;
        g.max_loops = 3;
        g.budget = 45;
        g.indent += 1;
        g.scopes.push(Vec::new());
        let n = 12 + g.rng.below(25);
        for _ in 0..n {
            if g.budget > 0 {
                g.stmt();
            }
        }
        // Every function is called at least once, and the final state is shown.
        for index in 0..g.functions.len() {
            let call = g.call_text(index);
            match g.functions[index].ret {
                Some(Ty::Int) if g.functions[index].fallible => g.line(&format!("print({call} or -1)")),
                Some(_) if g.functions[index].fallible => g.line(&format!("print({call} or \"it failed\")")),
                Some(_) => g.line(&format!("print({call})")),
                None => g.line(&call),
            }
        }
        g.line("print(g_count, g_text, g_list, g_names, g_point)");
        g.line("print(g_ages, g_ids)");
        g.line("print(team.name, team.members.len(), team.scores, team.total())");
        g.line("print(team)");
        g.line("var shown = 0");
        g.line("for s in shapes {");
        g.line("    shown += 1");
        g.line("    if shown > 20 {");
        g.line("        break");
        g.line("    }");
        g.line("    print(s.kind(), s.area())");
        g.line("}");
        g.scopes.pop();
        g.indent -= 1;
        g.line("}");
        g.out
    }
}

struct Outcome {
    code: Option<i32>,
    stdout: Vec<u8>,
    stderr: String,
    timed_out: bool,
}

/// Runs `onyx` with a time limit; its output goes through files so that a
/// large output cannot block it.
fn run(args: &[&str], file: &Path, dir: &Path, tag: &str) -> Outcome {
    let out_path = dir.join(format!("{tag}.out"));
    let err_path = dir.join(format!("{tag}.err"));
    let mut child = Command::new(ONYX)
        .args(args)
        .arg(file)
        .stdin(Stdio::null())
        .stdout(std::fs::File::create(&out_path).unwrap())
        .stderr(std::fs::File::create(&err_path).unwrap())
        .spawn()
        .unwrap();
    let start = Instant::now();
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break Some(status);
        }
        if start.elapsed() > Duration::from_secs(60) {
            timed_out = true;
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(2));
    };
    Outcome {
        code: status.and_then(|s| s.code()),
        stdout: std::fs::read(&out_path).unwrap_or_default(),
        stderr: String::from_utf8_lossy(&std::fs::read(&err_path).unwrap_or_default()).into_owned(),
        timed_out,
    }
}

/// Returns a description of what went wrong with this seed, if anything.
fn check_seed(seed: u64, dir: &Path) -> Option<String> {
    let source = Gen::program(seed);
    let file = dir.join(format!("seed_{seed}.ox"));
    std::fs::write(&file, &source).unwrap();
    let tag = format!("seed_{seed}");

    let js = run(&["run"], &file, dir, &format!("{tag}_js"));
    if js.timed_out {
        return Some(format!("seed {seed}: the JavaScript run did not finish ({})", file.display()));
    }
    if js.code != Some(0) {
        return Some(format!(
            "seed {seed}: the generated program is not valid or failed on JavaScript ({})\n{}",
            file.display(),
            js.stderr.lines().take(12).collect::<Vec<_>>().join("\n")
        ));
    }
    let native = run(&["run", "--target", "native", "--leak-check"], &file, dir, &format!("{tag}_native"));
    if native.timed_out {
        return Some(format!("seed {seed}: the native run did not finish ({})", file.display()));
    }
    if native.code != Some(0) {
        return Some(format!(
            "seed {seed}: the native run failed with {:?} ({})\n{}",
            native.code,
            file.display(),
            native.stderr.lines().take(12).collect::<Vec<_>>().join("\n")
        ));
    }
    if native.stdout != js.stdout {
        let js_text = String::from_utf8_lossy(&js.stdout);
        let native_text = String::from_utf8_lossy(&native.stdout);
        let line = js_text.lines().zip(native_text.lines()).position(|(a, b)| a != b);
        let detail = match line {
            Some(i) => format!(
                "first difference at output line {}:\n  javascript: {}\n  native:     {}",
                i + 1,
                js_text.lines().nth(i).unwrap_or("").chars().take(300).collect::<String>(),
                native_text.lines().nth(i).unwrap_or("").chars().take(300).collect::<String>()
            ),
            None => format!("one output is a prefix of the other ({} vs {} bytes)", js.stdout.len(), native.stdout.len()),
        };
        return Some(format!("seed {seed}: outputs differ ({})\n{detail}", file.display()));
    }
    // Everything matched: no need to keep the files.
    for suffix in ["_js.out", "_js.err", "_native.out", "_native.err"] {
        let _ = std::fs::remove_file(dir.join(format!("{tag}{suffix}")));
    }
    let _ = std::fs::remove_file(&file);
    None
}

fn env_number(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

#[test]
fn native_matches_javascript_on_random_programs() {
    let start = env_number("ONYX_FUZZ_START", 1);
    let count = env_number("ONYX_FUZZ_SEEDS", 40);
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target").join("fuzz");
    std::fs::create_dir_all(&dir).unwrap();

    let next = AtomicU64::new(start);
    let failures: Mutex<Vec<String>> = Mutex::new(Vec::new());
    let workers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(2);
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| loop {
                let seed = next.fetch_add(1, Ordering::Relaxed);
                if seed >= start + count || failures.lock().unwrap().len() >= 5 {
                    break;
                }
                if let Some(failure) = check_seed(seed, &dir) {
                    failures.lock().unwrap().push(failure);
                }
            });
        }
    });

    let failures = failures.into_inner().unwrap();
    assert!(failures.is_empty(), "{} seed(s) failed:\n\n{}", failures.len(), failures.join("\n\n"));
}
