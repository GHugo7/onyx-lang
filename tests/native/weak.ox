// Weak references: pointing to an object without keeping it alive.

struct Node {
    name: string
    parent: weak<Node>
    children: [Node]

    fn path(self) -> string {
        var up = self.parent.get() catch err {
            return self.name
        }
        return up.path() + "/" + self.name
    }
}

struct Listener {
    id: int
}

struct Hub {
    listeners: [weak<Listener>]

    fn alive(self) -> [int] {
        var ids: [int] = []
        for l in self.listeners {
            var listener = l.get() catch err {
                continue
            }
            ids.push(listener.id)
        }
        return ids
    }
}

interface Named {
    fn title(self) -> string
}

struct Book {
    name: string

    fn title(self) -> string {
        return "<{self.name}>"
    }
}

fn add_child(parent: Node, name: string) -> Node {
    var child = Node{name: name, parent: weak(parent), children: []}
    parent.children.push(child)
    return child
}

fn title_of(w: weak<Named>) -> string {
    var named = w.get() catch err {
        return "nothing: {err}"
    }
    return named.title()
}

fn main() {
    // a tree whose children point back to their parent: no cycle to leak
    var root = Node{name: "root", parent: weak(), children: []}
    var usr = add_child(root, "usr")
    var bin = add_child(usr, "bin")
    add_child(usr, "lib")
    print(bin.path(), usr.path(), root.path(), usr.children.len())
    print((bin.parent.get() or root).name, (root.parent.get() or bin).name)

    // listeners that go away by themselves
    var hub = Hub{listeners: []}
    var first = Listener{id: 1}
    var second = Listener{id: 2}
    hub.listeners.push(weak(first))
    hub.listeners.push(weak(second))
    hub.listeners.push(weak(first))
    print(hub.alive())
    print(hub.listeners[0] == hub.listeners[2], hub.listeners[0] == hub.listeners[1], hub.listeners.len())

    // through an interface, in a map, as text
    var book = Book{name: "Onyx"}
    var named: Named = book
    var table: map<string, weak<Named>> = {}
    table["book"] = weak(named)
    table["none"] = weak()
    print(title_of(table["book"]), title_of(table["none"]), weak(book), [weak(book)])

    // lists and maps can be pointed to as well
    var scores = [1, 2, 3]
    var watch = weak(scores)
    scores.push(4)
    print(watch.get() or [], (watch.get() or []).len())
    var ages = {"a": 1}
    var seen = weak(ages)
    print(seen.get() or {"none": 0})

    // a weak reference in a closure
    var counter = Listener{id: 10}
    var w = weak(counter)
    var bump = fn() -> int {
        var c = w.get() catch err {
            return -1
        }
        c.id += 1
        return c.id
    }
    print(bump(), bump(), counter.id)
}
