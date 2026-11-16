// Problems found in a program, to be shown to its author.

struct Diag {
    code: string
    message: string
    start: int
    end: int
    label: string
    help: string
}

// Where the problems found so far are gathered. The functions of the
// compiler fail with a short word when they find one; the details are here.
struct Report {
    diags: [Diag]

    fn add(self, code: string, message: string, start: int, end: int) -> Diag {
        var d = Diag{code: code, message: message, start: start, end: end, label: "", help: ""}
        self.diags.push(d)
        return d
    }
}

fn new_report() -> Report {
    return Report{diags: []}
}
