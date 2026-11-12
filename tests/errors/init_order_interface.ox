// error: E0118
interface Source {
    fn value(self) -> int
}

struct Fixed {
    fn value(self) -> int {
        return limit
    }
}

fn read(s: Source) -> int {
    return s.value()
}

var start = read(Fixed{})
var limit = 3

fn main() {
    print(start)
}
