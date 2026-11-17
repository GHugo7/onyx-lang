# Module tests for the compiler written in Onyx

A small project whose files import each other in the awkward ways: two
files with the same name in different folders, paths with `..`, a file
that imports the entry file back, a local variable named like a module.
The files in `e/` each contain one mistake (a private name, an alias that
is not a name, a missing file...).

`cargo test` runs `onyx modules` (the Rust compiler) and `compiler/main.ox
modules` (the compiler written in Onyx) on every file here, and the two
must print the same linked program, or the same errors.
