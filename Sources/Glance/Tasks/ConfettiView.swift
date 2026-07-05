import SwiftUI

/// One confetti burst at a canvas point. Particles are precomputed at init;
/// every frame is a pure function of elapsed time (TimelineView drives the
/// clock — no timers, nothing retained).
struct ConfettiBurst: Identifiable {
    let id = UUID()
    let origin: CGPoint
    let startedAt = Date()
    let particles: [Particle]

    /// Seconds since the burst fired.
    var age: TimeInterval { Date().timeIntervalSince(startedAt) }

    struct Particle {
        let velocity: CGVector     // initial pt/s
        let hue: Color
        let size: CGFloat
        let spin: Double           // rad/s
        let life: TimeInterval
    }

    init(origin: CGPoint) {
        self.origin = origin
        // Mostly-upward fan; gravity brings the pieces back down.
        let palette: [Color] = [DS.accent, DS.success,
                                Color(hexRGB: "F59E0B")!, Color(hexRGB: "5B8DEF")!]
        particles = (0..<30).map { i in
            let angle = Double.pi * (0.15 + 0.7 * Double(i) / 29) // 27°…153°
            let speed = Double(220 + (i * 37) % 240)              // deterministic spread
            return Particle(
                velocity: CGVector(dx: cos(angle) * speed, dy: -sin(angle) * speed),
                hue: palette[i % palette.count],
                size: CGFloat(4 + (i * 13) % 5),
                spin: Double((i % 7) - 3) * 2.4,
                life: 0.55 + Double((i * 17) % 30) / 100          // 0.55…0.85s
            )
        }
    }
}

/// Draws all live bursts. Mounted as a non-hit-testable overlay on the canvas.
struct ConfettiOverlay: View {
    let bursts: [ConfettiBurst]

    private static let gravity: Double = 1000 // pt/s²

    var body: some View {
        TimelineView(.animation(paused: bursts.isEmpty)) { timeline in
            Canvas { ctx, _ in
                let now = timeline.date
                for burst in bursts {
                    let t = now.timeIntervalSince(burst.startedAt)
                    guard t >= 0 else { continue }
                    for p in burst.particles where t < p.life {
                        let progress = t / p.life
                        let x = burst.origin.x + p.velocity.dx * t
                        let y = burst.origin.y + p.velocity.dy * t
                            + 0.5 * Self.gravity * t * t
                        let rect = CGRect(x: -p.size / 2, y: -p.size / 2,
                                          width: p.size, height: p.size * 0.7)
                        var piece = ctx
                        piece.translateBy(x: x, y: y)
                        piece.rotate(by: .radians(p.spin * t))
                        piece.opacity = 1 - progress * progress // ease-out fade
                        piece.fill(Path(roundedRect: rect, cornerRadius: 1),
                                   with: .color(p.hue))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
