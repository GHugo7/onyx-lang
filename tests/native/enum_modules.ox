// Enums from another file, and a small calculator built on them.

import "lib/tokens"

struct Parser {
    tokens: [tokens.Token]
    at: int

    fn peek(self) -> tokens.Token! {
        if self.at >= self.tokens.len() {
            fail "unexpected end"
        }
        return self.tokens[self.at]
    }

    // sum = product ("+" product)*
    fn sum(self) -> int! {
        var value = self.product()?
        while self.at < self.tokens.len() && self.tokens[self.at] == tokens.Token.Plus {
            self.at += 1
            value += self.product()?
        }
        return value
    }

    fn product(self) -> int! {
        var value = self.atom()?
        while self.at < self.tokens.len() && self.tokens[self.at] == tokens.Token.Times {
            self.at += 1
            value *= self.atom()?
        }
        return value
    }

    fn atom(self) -> int! {
        var token = self.peek()?
        self.at += 1
        match token {
            Number(n) {
                return n
            }
            Open {
                var inside = self.sum()?
                match self.peek()? {
                    tokens.Token.Close {
                        self.at += 1
                    }
                    else {
                        fail "expected )"
                    }
                }
                return inside
            }
            else {
                fail "unexpected {token}"
            }
        }
    }
}

fn calc(text: string) -> int! {
    var p = Parser{tokens: tokens.scan(text), at: 0}
    var value = p.sum()?
    if p.at < p.tokens.len() {
        fail "left over: {p.tokens[p.at]}"
    }
    return value
}

fn main() {
    print(tokens.scan("12 + (3*4)"))
    for text in ["1 + 2 * 3", "(1 + 2) * 3", "2 * (3 + 4) * 5 + 1", "7", "2 +", "(1 + 2", "1 2", "* 3"] {
        var value = calc(text) catch err {
            print(text, "->", err)
            continue
        }
        print(text, "=", value)
    }
    var t: tokens.Token = tokens.Token.Number(4)
    print(t, t == tokens.Token.Number(4), tokens.Token.Plus)
}
