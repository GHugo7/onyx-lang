// Files, arguments, the environment, the clock and the keyboard.
// Run by tests/suite.rs with a directory, two more arguments and some input.

struct Entry {
    name: string
    score: int
}

fn load(path: string) -> [Entry]! {
    var out: [Entry] = []
    for line in read_file(path)?.split("\n") {
        if line.trim() == "" {
            continue
        }
        var cells = line.split(",")
        out.push(Entry{name: cells[0], score: parse_int(cells[1])?})
    }
    return out
}

fn main() -> void! {
    var dir = args()[0]
    print(args().len(), args().slice(1, 10))
    var path = dir + "/scores.csv"
    print(file_exists(path), file_exists(dir), file_exists(dir + "/nope"))
    write_file(path, "ada,36\ngrace,45\n")?
    append_file(path, "linus,28\n")?
    append_file(path, "héloïse,31\n")?
    print(file_exists(path), read_file(path)?.len())
    var entries = load(path)?
    print(entries.sort_by(fn(e: Entry) -> int {
        return -e.score
    }))
    write_file(path, "short")?
    print(read_file(path)?)
    print(read_file(dir + "/missing.txt") or "no file")
    read_file(dir + "/missing.txt") catch err {
        print(err.message.ends_with("no such file or directory"), err.message.starts_with("cannot read "))
    }
    read_file(dir) catch err {
        print(err.message.ends_with("is a directory"))
    }
    write_file(dir + "/no/such/dir/x", "x") catch err {
        print(err.message.ends_with("no such file or directory"), err.message.starts_with("cannot write "))
    }
    write_file(dir + "/bad.csv", "x,notanumber\n")?
    print(load(dir + "/bad.csv") or [])
    // a big file, to go through several reads
    var big = ""
    for i in 0..20000 {
        big += "line {i}\n"
    }
    write_file(dir + "/big.txt", big)?
    var back = read_file(dir + "/big.txt")?
    print(back.len(), back == big, back.split("\n").len())
    print(env("ONYX_TEST_VALUE") or "unset", env("ONYX_NOT_SET_ANYWHERE") or "unset", env("ONYX_TEST") or "unset", env("") or "unset")
    var started = now()
    sleep(30)
    var waited = now() - started
    print(started > 1700000000000, waited >= 29, waited < 2000)
    var name = input("name? ")
    var age = parse_int(input("age? ")) or 0
    print("hello {name}, next year you are {age + 1}")
    var rest: [string] = []
    var line = input("")
    while line != "" {
        rest.push(line)
        line = input("")
    }
    print(rest, input("more? ") == "")
    print(load(dir + "/missing.csv") or [])
}
