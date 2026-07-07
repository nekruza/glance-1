import SwiftUI

/// Flat cartoon "employee photo" for an agent profile. The look (skin, hair
/// style + colour, shirt) is derived deterministically from the profile id,
/// so every agent — built-in or user-created — gets a stable face with no
/// bundled assets.
struct AgentAvatarView: View {
    let agent: AgentProfile
    var size: CGFloat = 36

    private var look: Look { Look(seed: agent.id) }

    var body: some View {
        Canvas { ctx, sz in
            let s = min(sz.width, sz.height)
            let look = self.look

            // Background disc — soft tint of the shirt colour.
            ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s)),
                     with: .color(look.shirt.opacity(0.18)))

            // Everything below is clipped to the disc so shoulders/hair crop.
            ctx.clip(to: Path(ellipseIn: CGRect(x: 0, y: 0, width: s, height: s)))

            // Neck.
            ctx.fill(Path(roundedRect: CGRect(x: 0.44 * s, y: 0.58 * s,
                                              width: 0.12 * s, height: 0.18 * s),
                          cornerRadius: 0.03 * s),
                     with: .color(look.skin))

            // Shoulders / shirt.
            ctx.fill(Path(ellipseIn: CGRect(x: 0.14 * s, y: 0.72 * s,
                                            width: 0.72 * s, height: 0.55 * s)),
                     with: .color(look.shirt))

            // Head.
            let headRect = CGRect(x: 0.24 * s, y: 0.16 * s,
                                  width: 0.52 * s, height: 0.52 * s)
            ctx.fill(Path(ellipseIn: headRect), with: .color(look.skin))

            // Hair.
            look.hairStyle.draw(in: &ctx, headRect: headRect, color: look.hair, s: s)

            // Eyes.
            let eyeR = 0.028 * s
            for dx in [-0.095, 0.095] {
                let cx = (0.5 + dx) * s
                ctx.fill(Path(ellipseIn: CGRect(x: cx - eyeR, y: 0.42 * s - eyeR,
                                                width: eyeR * 2, height: eyeR * 2)),
                         with: .color(Color(hexRGB: "2B2B33")!))
            }

            // Smile.
            var smile = Path()
            smile.addArc(center: CGPoint(x: 0.5 * s, y: 0.49 * s),
                         radius: 0.075 * s,
                         startAngle: .degrees(25), endAngle: .degrees(155),
                         clockwise: false)
            ctx.stroke(smile, with: .color(Color(hexRGB: "2B2B33")!),
                       style: StrokeStyle(lineWidth: max(1, 0.028 * s), lineCap: .round))
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(DS.border, lineWidth: 1))
        .accessibilityLabel("\(agent.humanName ?? agent.name) avatar")
    }

    // MARK: - Deterministic look

    struct Look {
        let skin: Color
        let hair: Color
        let shirt: Color
        let hairStyle: HairStyle

        init(seed: UUID) {
            // FNV-1a over the uuid string — stable across launches.
            var h: UInt64 = 0xcbf29ce484222325
            for byte in seed.uuidString.utf8 {
                h ^= UInt64(byte)
                h = h &* 0x100000001b3
            }
            let skins = ["FFDBB4", "F1C27D", "E0AC69", "C68642", "8D5524"]
            let hairs = ["2C222B", "5A3825", "B55239", "D6B370", "4A4E69"]
            let shirts = ["4C6EF5", "12B886", "E8590C", "7048E8", "1098AD", "D6336C"]
            skin = Color(hexRGB: skins[Int(h % UInt64(skins.count))])!
            hair = Color(hexRGB: hairs[Int((h >> 8) % UInt64(hairs.count))])!
            shirt = Color(hexRGB: shirts[Int((h >> 16) % UInt64(shirts.count))])!
            hairStyle = HairStyle.allCases[Int((h >> 24) % UInt64(HairStyle.allCases.count))]
        }
    }

    enum HairStyle: CaseIterable {
        case crop, sidePart, bob, curly, bun

        func draw(in ctx: inout GraphicsContext, headRect: CGRect, color: Color, s: CGFloat) {
            let cx = headRect.midX
            let topY = headRect.minY
            let w = headRect.width

            // Common cap: upper half of the head, slightly larger.
            var cap = Path()
            cap.addArc(center: CGPoint(x: cx, y: headRect.midY),
                       radius: w / 2 + 0.012 * s,
                       startAngle: .degrees(180), endAngle: .degrees(360),
                       clockwise: false)
            cap.closeSubpath()

            switch self {
            case .crop:
                ctx.fill(cap, with: .color(color))
            case .sidePart:
                ctx.fill(cap, with: .color(color))
                // Fringe sweeping to one side.
                ctx.fill(Path(roundedRect: CGRect(x: cx - w * 0.5, y: headRect.midY - 0.02 * s,
                                                  width: w * 0.34, height: 0.09 * s),
                              cornerRadius: 0.03 * s),
                         with: .color(color))
            case .bob:
                ctx.fill(cap, with: .color(color))
                // Sides falling to the jaw.
                for x in [headRect.minX - 0.015 * s, headRect.maxX - w * 0.16 + 0.015 * s] {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: headRect.midY - 0.04 * s,
                                                      width: w * 0.16, height: w * 0.52),
                                  cornerRadius: 0.04 * s),
                             with: .color(color))
                }
            case .curly:
                ctx.fill(cap, with: .color(color))
                // Bumps along the hairline.
                let r = 0.075 * s
                for dx in [-0.16, 0.0, 0.16] {
                    let bx = cx + CGFloat(dx) * s
                    ctx.fill(Path(ellipseIn: CGRect(x: bx - r, y: topY - r * 0.7,
                                                    width: r * 2, height: r * 2)),
                             with: .color(color))
                }
            case .bun:
                ctx.fill(cap, with: .color(color))
                let r = 0.085 * s
                ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: topY - r * 1.1,
                                                width: r * 2, height: r * 2)),
                         with: .color(color))
            }
        }
    }
}
