// The functions that deal with the system around the program: folders,
// files, other programs, the terminal.

fn shown(message: string, base: string) -> string {
    return message.replace(base, "<dir>")
}

fn main() -> void! {
    var base = (env("TMPDIR") or "/tmp") + "/onyx-system-test"
    // What a run that stopped half-way may have left.
    for name in ["a.txt", "b.txt", "sub/c.txt"] {
        remove_file(base + "/" + name) catch err {
        }
    }

    make_dir(base + "/sub")?
    make_dir(base + "/sub")?
    print(is_dir(base), is_dir(base + "/sub"), is_dir(base + "/nothing"))
    write_file(base + "/b.txt", "b")?
    write_file(base + "/a.txt", "a")?
    write_file(base + "/sub/c.txt", "c")?
    print(list_dir(base)?, list_dir(base + "/sub")?)
    print(is_dir(base + "/a.txt"), file_exists(base + "/a.txt"))
    remove_file(base + "/a.txt")?
    print(list_dir(base)?, file_exists(base + "/a.txt"))

    remove_file(base + "/a.txt") catch err {
        print(shown(err.message, base))
    }
    make_dir(base + "/b.txt") catch err {
        print(shown(err.message, base))
    }
    list_dir(base + "/b.txt") catch err {
        print(shown(err.message, base))
    }
    remove_dir(base + "/sub") catch err {
        print(shown(err.message, base))
    }

    print("before the program")
    print(run_program("sh", ["-c", "echo from sh; exit 3"])?)
    print(run_program("true", [])?)
    print(run_program("sh", ["-c", "kill -9 $$"])?)
    run_program("no-such-program-anywhere", []) catch err {
        print(err.message)
    }
    run_program(base + "/b.txt", []) catch err {
        print(shown(err.message, base))
    }

    eprint("this line goes to the error output,", 42)
    print(stdout_is_terminal(), stderr_is_terminal())

    remove_file(base + "/b.txt")?
    remove_file(base + "/sub/c.txt")?
    remove_dir(base + "/sub")?
    remove_dir(base)?
    print(is_dir(base))
}
