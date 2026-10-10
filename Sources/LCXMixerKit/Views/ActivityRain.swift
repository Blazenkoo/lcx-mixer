import SwiftUI

/// Activity for browser tabs, in the meter's place. macOS can't measure a single tab's sound, so
/// this is deliberately not a level: drops land at random spots on the bar and send soft waves
/// outward both ways, fading as they spread, like rain on a puddle. Neutral in colour, so it never
/// reads as loudness. With Reduce Motion, each drop just glows and fades where it lands.
///
/// The drops stay below the channel's volume (`zone`, 0…1 along the bar), since nothing heard can
/// be louder than that, and fewer land at a lower volume, so a quieter channel looks quieter.
struct ActivityRain: View {
    enum Axis { case vertical, horizontal }

    let active: Bool
    /// The channel's volume on the fader's scale: drops land and spread only below it.
    var zone: CGFloat = 1
    var axis: Axis = .vertical

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rain = RainField()
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || !visible)) { timeline in
            Canvas { context, size in
                let zone = Double(max(0, min(1, self.zone)))
                let drops = active ? rain.drops(at: timeline.date, active: true, calm: reduceMotion, zone: zone) : []
                let length = axis == .vertical ? size.height : size.width
                let thickness = axis == .vertical ? size.width : size.height
                // Nothing shows above the volume line.
                context.clip(to: Path(axis == .vertical
                    ? CGRect(x: 0, y: size.height * (1 - zone), width: size.width, height: size.height * zone)
                    : CGRect(x: 0, y: 0, width: size.width * zone, height: size.height)))
                for drop in drops {
                    for band in drop.bands {
                        let centre = band.position * length
                        let half = max(band.width * length / 2, thickness)
                        let from = centre - half, to = centre + half
                        let gradient = Gradient(stops: band.core ? [
                            .init(color: .primary.opacity(0), location: 0),
                            .init(color: .primary.opacity(band.opacity), location: 0.3),
                            .init(color: .primary.opacity(band.opacity), location: 0.7),
                            .init(color: .primary.opacity(0), location: 1),
                        ] : [
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
        .background(WindowVisibilityProbe(visible: $visible))
        .accessibilityLabel(active ? "Playing" : "Silent")
    }
}

/// The drops for one bar. Each lands at a random spot and lives for a moment.
final class RainField {
    struct Band {
        let position: Double  // 0…1 along the bar
        let width: Double     // as a share of the bar
        let opacity: Double
        /// The drop's centre: a wider, solid middle rather than a single bright line.
        var core = false
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

    /// The waves spread up to this share of the bar each way.
    static let waveTravel = 0.225

    /// `zone` (0…1): drops land only below it. Fewer land in a smaller zone, so the drops per
    /// length of bar stay the same: at 30% about a third as many as at 100%. Below 20% the rate
    /// stops falling, so a quiet channel still shows signs of life.
    func drops(at date: Date, active: Bool, calm: Bool, zone: Double = 1) -> [Drop] {
        let t = date.timeIntervalSinceReferenceDate
        let life = calm ? 2.4 : 1.6
        seeds.removeAll { t - $0.born > life }
        if active, zone > 0.005, t >= nextDrop {
            seeds.append(Seed(position: zone * Double.random(in: 0.08...0.92), born: t, strength: Double.random(in: 0.7...1)))
            // Calm drops land less often.
            let interval = calm ? Double.random(in: 1.0...2.2) : Double.random(in: 0.35...1.1)
            nextDrop = t + interval / max(zone, 0.2)
        }
        return seeds.map { seed in
            let age = (t - seed.born) / life          // 0 → 1
            if calm {
                // Glow in place: fade in quickly, then out slowly. No movement.
                let glow = age < 0.2 ? age / 0.2 : 1 - (age - 0.2) / 0.8
                return Drop(bands: [Band(position: seed.position, width: 0.2, opacity: 0.85 * seed.strength * glow, core: true)])
            }
            let fade = pow(1 - age, 2)
            let travel = age * Self.waveTravel
            return Drop(bands: [
                Band(position: seed.position, width: 0.12 + age * 0.06, opacity: 0.95 * seed.strength * pow(1 - age, 2.5), core: true),
                Band(position: seed.position + travel, width: 0.09 + age * 0.12, opacity: 0.6 * seed.strength * fade),
                Band(position: seed.position - travel, width: 0.09 + age * 0.12, opacity: 0.6 * seed.strength * fade),
            ])
        }
    }
}
