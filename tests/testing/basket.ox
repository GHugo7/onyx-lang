import "lib/price"

struct Item {
    name: string
    price: float
}

struct Basket {
    items: [Item]

    fn add(self, a: Item) {
        self.items.push(a)
    }

    fn total(self) -> float {
        var sum = 0.0
        for a in self.items {
            sum += a.price
        }
        return _rounded(sum)
    }
}

fn _rounded(x: float) -> float {
    return round(x * 100) / 100.0
}

fn main() {
    var p = Basket{items: []}
    p.add(Item{name: "apple", price: price.with_tax(2.0)})
    print(p.total())
}

check "an empty basket is worth nothing" {
    expect(Basket{items: []}.total() == 0.0)
}
