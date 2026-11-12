// A list of structs updated in place: field reads and writes, method calls.
struct Particle {
    x: int
    y: int
    vx: int
    vy: int

    fn step(self) {
        self.x += self.vx
        self.y += self.vy
        if self.x < 0 || self.x > 100000 {
            self.vx = -self.vx
        }
        if self.y < 0 || self.y > 100000 {
            self.vy = -self.vy
        }
    }
}

fn main() {
    var particles: [Particle] = []
    for i in 0..1000 {
        particles.push(Particle{x: i * 37 % 100000, y: i * 91 % 100000, vx: i % 17 - 8, vy: i % 13 - 6})
    }
    for round in 0..5000 {
        for p in particles {
            p.step()
        }
    }
    var checksum = 0
    for p in particles {
        checksum += p.x + p.y
    }
    print(checksum)
}
