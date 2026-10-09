import SwiftUI

/// Activity for browser tabs, in the meter's place. macOS can't measure a single tab's sound, so
/// this is deliberately not a level: drops land at random spots on the bar and send soft waves
/// outward both ways, fading as they spread, like rain on a puddle. Neutral in colour, so it never
/// reads as loudness. With Reduce Motion, each drop just glows and fades where it lands.
struct ActivityRain: View {
    enum Axis { case vertical, horizontal }

    let active: Bool
    var axis: Axis = .vertical

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rain = RainField()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            Canvas { context, size in
                let drops = active ? rain.drops(at: timeline.date, active: true, calm: reduceMotion) : []
                let length = axis == .vertical ? size.height : size.width
                let thickness = axis == .vertical ? size.width : size.height
                for drop in drops {
                    for band in drop.bands {
                        let centre = band.position * length
                        let half = max(band.width * length / 2, thickness)
                        let from = centre - half, to = centre + half
                        let gradient = Gradient(stops: [
                            .init(color: .primary.opacity(0), location: 0),
                            .init(color: .primary.opacity(band.opacity), location: 0.5),
                            .init(color: .primary.opacity(0), location: 1),
                        ])
                        let rect: CGRect
                        let start: CGPoint, end: CGPoint
                        if axis == .vertical {
                            // Position 0 is the bottom of the bar, like a meter.
                            rect = CGRect(x: 0, y: size.height - to, width: size.width, height: to - from)
                            start = CGPoint(x: 0, y: size.height - from)
                            end = CGPoint(x: 0, y: size.height - to)
                        } else {
                            rect = CGRect(x: from, y: 0, width: to - from, height: size.height)
                            start = CGPoint(x: from, y: 0)
                            end = CGPoint(x: to, y: 0)
                        }
                        context.fill(Path(rect), with: .linearGradient(gradient, startPoint: start, endPoint: end))
                    }
                }
            }
        }
        .clipShape(Capsule())
        .accessibilityLabel(active ? "Playing" : "Silent")
    }
}

/// The drops for one bar. Each lands at a random spot and lives for a moment.
final class RainField {
    struct Band {
        let position: Double  // 0…1 along the bar
        let width: Double     // as a share of the bar
        let opacity: Double
    }
    struct Drop {
        var bands: [Band]
    }

    private struct Seed {
        let position: Double
        let born: Double
        let strength: Double
    }

    private var seeds: [Seed] = []
    private var nextDrop: Double = 0

    func drops(at date: Date, active: Bool, calm: Bool) -> [Drop] {
        let t = date.timeIntervalSinceReferenceDate
        let life = calm ? 2.4 : 1.6
        seeds.removeAll { t - $0.born > life }
        if active, t >= nextDrop {
            seeds.append(Seed(position: Double.random(in: 0.08...0.92), born: t, strength: Double.random(in: 0.55...1)))
            // Calm drops land less often.
            nextDrop = t + (calm ? Double.random(in: 1.0...2.2) : Double.random(in: 0.35...1.1))
        }
        return seeds.map { seed in
            let age = (t - seed.born) / life          // 0 → 1
            if calm {
                // Glow in place: fade in quickly, then out slowly. No movement.
                let glow = age < 0.2 ? age / 0.2 : 1 - (age - 0.2) / 0.8
                return Drop(bands: [Band(position: seed.position, width: 0.14, opacity: 0.55 * seed.strength * glow)])
            }
            let fade = pow(1 - age, 2)
            let travel = age * 0.45                   // the waves spread up to 45% of the bar each way
            return Drop(bands: [
                Band(position: seed.position, width: 0.06 + age * 0.05, opacity: 0.7 * seed.strength * pow(1 - age, 4)),
                Band(position: seed.position + travel, width: 0.08 + age * 0.12, opacity: 0.45 * seed.strength * fade),
                Band(position: seed.position - travel, width: 0.08 + age * 0.12, opacity: 0.45 * seed.strength * fade),
            ])
        }
    }
}
