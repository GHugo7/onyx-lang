import "lib/tools"

fn basket_of(prices: [float]) -> Basket {
    var p = Basket{items: []}
    for x in prices {
        p.add(Item{name: "a", price: x})
    }
    return p
}

check "the total adds the prices" {
    expect(basket_of([1.5, 2.25]).total() == 3.75)
}

check "private functions are visible" {
    expect(_rounded(1.006) == 1.01)
    expect(tools.double(4) == 8)
}

check "this one fails" {
    var p = basket_of([1.0])
    expect(p.total() == 2.0)
    print("not reached")
}

check "a panic is caught" {
    var xs = [1, 2]
    print(xs[5])
}

check "the checks after a failure still run" {
    var count = 0
    var more = fn() {
        count += 1
    }
    more()
    more()
    expect(count == 2)
    expect((parse_int("x") or 7) == 7)
}
