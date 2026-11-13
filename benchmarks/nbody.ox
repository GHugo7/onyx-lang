// Five bodies attracting each other for 200 000 steps: float arithmetic,
// square roots, fields of structs in lists.

struct Body {
    x: float
    y: float
    z: float
    vx: float
    vy: float
    vz: float
    mass: float
}

fn energy(bodies: [Body]) -> float {
    var e = 0.0
    for i in 0..bodies.len() {
        var b = bodies[i]
        e += 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
        for j in i + 1..bodies.len() {
            var c = bodies[j]
            var dx = b.x - c.x
            var dy = b.y - c.y
            var dz = b.z - c.z
            e -= b.mass * c.mass / sqrt(dx * dx + dy * dy + dz * dz)
        }
    }
    return e
}

fn advance(bodies: [Body], dt: float) {
    var n = bodies.len()
    for i in 0..n {
        var b = bodies[i]
        for j in i + 1..n {
            var c = bodies[j]
            var dx = b.x - c.x
            var dy = b.y - c.y
            var dz = b.z - c.z
            var d2 = dx * dx + dy * dy + dz * dz
            var mag = dt / (d2 * sqrt(d2))
            b.vx -= dx * c.mass * mag
            b.vy -= dy * c.mass * mag
            b.vz -= dz * c.mass * mag
            c.vx += dx * b.mass * mag
            c.vy += dy * b.mass * mag
            c.vz += dz * b.mass * mag
        }
    }
    for b in bodies {
        b.x += dt * b.vx
        b.y += dt * b.vy
        b.z += dt * b.vz
    }
}

fn main() {
    var bodies = [
        Body{x: 0, y: 0, z: 0, vx: 0, vy: 0, vz: 0, mass: 39.47841760435743},
        Body{x: 4.84143144246472090, y: -1.16032004402742839, z: -0.103622044471123109, vx: 0.606326392995832, vy: 2.81198684491626, vz: -0.02521836165988763, mass: 0.03769367487038949},
        Body{x: 8.34336671824457987, y: 4.12479856412430479, z: -0.403523417114321381, vx: -1.0107743461787924, vy: 1.8256623712304119, vz: 0.008415761376584154, mass: 0.011286326131968767},
        Body{x: 12.8943695621391310, y: -15.1111514016986312, z: -0.223307578892655734, vx: 1.0827910064415354, vy: 0.8687130181696082, vz: -0.010832637401363636, mass: 0.0017237240570597112},
        Body{x: 15.3796971148509165, y: -25.9193146099879641, z: 0.179258772950371181, vx: 0.979090732243898, vy: 0.5946989986476762, vz: -0.034755955504078104, mass: 0.0020336868699246304}
    ]
    print(energy(bodies))
    for step in 0..200000 {
        advance(bodies, 0.01)
    }
    print(energy(bodies))
}
