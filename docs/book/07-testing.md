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

## Test files

Tests can also live in a file of their own, next to the file they test:
`basket.test.ox` holds the tests of `basket.ox`.

```text
basket.ox
basket.test.ox
```

```text
// basket.test.ox
check "the total adds the prices" {
    var b = Basket{items: []}
    b.add(Item{name: "apple", price: 2.5})
    expect(b.total() == 2.5)
}
```

A test file is part of the file it tests: it uses its functions and structs
directly, without `import`, including the private ones (those whose name
starts with `_`). It may define helper functions and import other modules.
`onyx run` and `onyx build` never look at it.

```bash
onyx test basket.ox
```

runs the `check` blocks of `basket.ox` and those of `basket.test.ox`
(`onyx test basket.test.ox` does the same). Without a file,

```bash
onyx test
```

goes through the current folder and the folders inside it, and runs the
tests of every file that has some. It exits with code 1 if a check failed
anywhere. `onyx test some/folder` does the same for that folder.

A check that fails does not stop the others: a failed `expect` or a panic
(an index out of bounds, say) is reported, and the next check runs.

```text
running 3 checks
  ok    the total adds the prices
  FAIL  an empty basket is free (expectation failed at basket.test.ox:9)
  ok    items can be removed

2 passed, 1 failed
```

Next: [Modules](08-modules.md)
