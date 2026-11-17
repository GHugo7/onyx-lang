import "../a/util"

fn main() {
    print(util._secret, util._hidden(), util.nothing, util.Point)
    var p: util.Nope = util.make(1)
    var q: nomod.Point = util.make(1)
    var r = util.Ghost{x: 1}
    print(util.Kind.One)
}
