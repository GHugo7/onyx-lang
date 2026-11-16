enum Token {
    Number(int)
    Plus
    Times
    Open
    Close
}

enum _Hidden {
    Nothing
}

fn scan(text: string) -> [Token] {
    var out: [Token] = []
    var digits = ""
    for c in text + " " {
        if "0123456789".contains(c) {
            digits += c
            continue
        }
        if digits != "" {
            out.push(Token.Number(parse_int(digits) or 0))
            digits = ""
        }
        match c {
            "+" {
                out.push(Token.Plus)
            }
            "*" {
                out.push(Token.Times)
            }
            "(" {
                out.push(Token.Open)
            }
            ")" {
                out.push(Token.Close)
            }
            else {
            }
        }
    }
    return out
}
