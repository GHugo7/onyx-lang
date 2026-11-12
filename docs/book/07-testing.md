# 7. Testing

Tests live next to the code, in `check` blocks. `expect` verifies a condition.

```onyx
fn clamp(n: int, lo: int, hi: int) -> int {
    return max(lo, min(n, hi))
}

fn main() {
    print(clamp(15, 0, 10))
}

check "clamp keeps values in range" {
    expect(clamp(5, 0, 10) == 5)
    expect(clamp(-3, 0, 10) == 0)
    expect(clamp(15, 0, 10) == 10)
}

check "clamp accepts equal bounds" {
    expect(clamp(7, 3, 3) == 3)
}
```

```bash
onyx test clamp.ox
```

```text
running 2 checks
  ok    clamp keeps values in range
  ok    clamp accepts equal bounds

2 passed, 0 failed
```

`check` blocks are ignored by `onyx run` and `onyx build`. A failing `expect`
reports the file and line, and `onyx test` exits with code 1.

To test a function that can fail, handle the error like anywhere else:

```onyx
fn half(n: int) -> int! {
    if n % 2 != 0 { fail "odd" }
    return n / 2
}

fn main() {
    print(half(4) or 0)
}

check "half rejects odd numbers" {
    expect((half(3) or -1) == -1)
    expect((half(8) or -1) == 4)
}
```

Next: [Modules](08-modules.md)
