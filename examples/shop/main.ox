// A program split across several files.
//
//     onyx run examples/shop/main.ox

import "catalog"
import "cart"

fn main() {
    var basket = cart.new_cart()
    for name in ["keyboard", "mouse", "mouse", "unicorn"] {
        basket.add(name) catch err {
            print("skipped: {err}")
        }
    }
    for line in basket.lines {
        print("{line.quantity} x {line.item.name}")
    }
    print("total: {catalog.format_price(basket.total())}")
}

check "the total adds up" {
    var basket = cart.new_cart()
    basket.add("mouse") catch err { expect(false) }
    basket.add("mouse") catch err { expect(false) }
    expect(basket.total() == 2 * 2500)
}

check "unknown items are refused" {
    var basket = cart.new_cart()
    var refused = false
    basket.add("unicorn") catch err { refused = true }
    expect(refused)
    expect(basket.lines.len() == 0)
}
