import SwiftUI

/// The first thing you see. Three sentences about what the app does and where your mail
/// goes, because the honest answer to "does this send my inbox somewhere" is the reason
/// the app exists -- and a settings window is a poor place to say it.
struct Welcome: View {
    let done: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Flow()
                .frame(height: 168)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.035))

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("welcome.title"))
                        .font(.system(size: 21, weight: .semibold))
                    Text(t("welcome.tagline"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 11) {
                    point("envelope.badge", "welcome.point1")
                    point("hand.raised", "welcome.point2")
                    point("calendar.badge.plus", "welcome.point3")
                }

                HStack {
                    Spacer()
                    Button(t("welcome.later")) { done() }
                    Button(t("welcome.setUp")) { done(); openSettings() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .padding(18)
        }
        .frame(width: 520)
    }

    private func point(_ symbol: String, _ key: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(t(key)).font(.system(size: 12.5, weight: .medium))
                Text(t(key + ".body"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Mail drifting past the model and splitting into the two things the app can make. It is
/// the whole app in one picture, which beats a paragraph explaining the same thing.
///
/// Positions are computed from the clock rather than kept in `@State`: a timeline that is
/// a pure function of time cannot drift, cannot get stuck halfway, and costs nothing when
/// the window is hidden because SwiftUI stops asking.
private struct Flow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 520
    private let mailX: CGFloat = 62
    private let modelX: CGFloat = 258
    private let outX: CGFloat = 452
    private let midY: CGFloat = 84
    private let topY: CGFloat = 40
    private let lowY: CGFloat = 128

    /// Four letters, evenly spaced around the loop. Two go to the calendar, two to the
    /// list -- fixed per letter, so the picture stays readable instead of flickering.
    private let count = 4
    /// How far a letter stays clear of the icon it is leaving or arriving at.
    private let gap: CGFloat = 26
    private func toCalendar(_ i: Int) -> Bool { i == 0 || i == 3 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                rails
                chip("tray.full.fill", t("welcome.lane.mail"), at: CGPoint(x: mailX, y: midY))
                chip("calendar", t("welcome.lane.calendar"), at: CGPoint(x: outX, y: topY))
                chip("checklist", t("welcome.lane.reminders"), at: CGPoint(x: outX, y: lowY))

                ForEach(0..<count, id: \.self) { i in
                    let p = phase(i, time)
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                        .opacity(fade(p))
                        .position(position(i, p))
                }

                // Last, so a letter disappears behind the model rather than sliding across
                // it: the jump from one side to the other happens out of sight.
                reader(time)
            }
            .frame(width: width)
        }
    }

    /// Where a letter is at phase `p`: first to the model, then out along the rail to its
    /// destination. It starts and stops clear of the icons, so nothing ever sits on a label.
    private func position(_ i: Int, _ p: Double) -> CGPoint {
        if p < 0.5 {
            let s = eased(p / 0.5)
            return CGPoint(x: (mailX + gap) + ((modelX - gap) - (mailX + gap)) * s, y: midY)
        }
        // The same quadratic the rail is drawn with, so the letter rides the line instead
        // of cutting the corner.
        let s = eased((p - 0.5) / 0.5)
        let p0 = CGPoint(x: modelX + gap, y: midY)
        let c  = CGPoint(x: modelX + 90, y: midY)
        let p2 = CGPoint(x: outX - gap, y: toCalendar(i) ? topY : lowY)
        let u = 1 - s
        return CGPoint(x: u * u * p0.x + 2 * u * s * c.x + s * s * p2.x,
                       y: u * u * p0.y + 2 * u * s * c.y + s * s * p2.y)
    }

    private func phase(_ i: Int, _ time: Double) -> Double {
        // Held still for Reduce Motion: spread along the path instead of moving along it.
        guard !reduceMotion else { return 0.2 + Double(i) * 0.2 }
        let raw = time * 0.2 + Double(i) / Double(count)
        return raw - raw.rounded(.down)
    }

    /// In and out at the ends, so nothing pops into existence on top of a label, and out
    /// again in the middle: being read is the one moment the letter is not in transit.
    private func fade(_ p: Double) -> Double {
        let atModel = abs(p - 0.5)
        if atModel < 0.05 { return atModel / 0.05 }
        if p < 0.10 { return p / 0.10 }
        if p > 0.88 { return max(0, (1 - p) / 0.12) }
        return 1
    }

    private func eased(_ s: Double) -> Double { s * s * (3 - 2 * s) }

    private var rails: some View {
        Path { p in
            p.move(to: CGPoint(x: mailX + gap, y: midY))
            p.addLine(to: CGPoint(x: modelX - gap, y: midY))
            for y in [topY, lowY] {
                p.move(to: CGPoint(x: modelX + gap, y: midY))
                p.addQuadCurve(to: CGPoint(x: outX - gap, y: y),
                               control: CGPoint(x: modelX + 90, y: midY))
            }
        }
        .stroke(Color.primary.opacity(0.13),
                style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    /// The model, with a pulse as each letter passes through it -- the only moment in the
    /// picture where anything is actually read.
    private func reader(_ time: Double) -> some View {
        let nearest = (0..<count)
            .map { abs(phase($0, time) - 0.5) }
            .min() ?? 1
        let pulse = max(0, 1 - nearest / 0.09)
        return VStack(spacing: 3) {
            Image(systemName: "cpu")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.accentColor)
            Text(t("welcome.lane.model"))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.08 + 0.14 * pulse))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.18 + 0.3 * pulse), lineWidth: 1))
        )
        .scaleEffect(1 + 0.045 * pulse)
        .position(x: modelX, y: midY)
    }

    private func chip(_ symbol: String, _ label: String, at spot: CGPoint) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .position(spot)
    }
}
