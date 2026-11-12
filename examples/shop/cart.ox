import "catalog"

struct Line {
    item: catalog.Item
    quantity: int
}

struct Cart {
    lines: [Line]

    fn add(self, name: string) -> void! {
        var item = catalog.find(name)?
        for line in self.lines {
            if line.item == item {
                line.quantity += 1
                return
            }
        }
        self.lines.push(Line{item: item, quantity: 1})
    }

    fn total(self) -> int {
        var sum = 0
        for line in self.lines {
            sum += line.item.price * line.quantity
        }
        return sum
    }
}

fn new_cart() -> Cart {
    return Cart{lines: []}
}
