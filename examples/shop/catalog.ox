// The items on sale. Prices are in cents.

struct Item {
    name: string
    price: int
}

const _ITEMS = [
    Item{name: "keyboard", price: 4900},
    Item{name: "mouse", price: 2500},
    Item{name: "screen", price: 19900},
]

fn find(name: string) -> Item! {
    for item in _ITEMS {
        if item.name == name {
            return item
        }
    }
    fail "no item named {name}"
}

fn format_price(cents: int) -> string {
    var rest = cents % 100
    var padding = ""
    if rest < 10 {
        padding = "0"
    }
    return "{cents / 100}.{padding}{rest} EUR"
}
