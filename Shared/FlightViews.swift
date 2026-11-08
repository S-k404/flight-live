import SwiftUI

// Building blocks shared by the Live Activity and the app.

extension Color {
    static let flightGreen = Color(red: 0.19, green: 0.82, blue: 0.35)
    static let flightAmber = Color(red: 1.0, green: 0.62, blue: 0.04)
    static let flightRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let flightBlue = Color(red: 0.30, green: 0.62, blue: 1.0)
    static let flightYellow = Color(red: 1.0, green: 0.84, blue: 0.04)
    static let flightCard = Color(red: 0.06, green: 0.06, blue: 0.08)
}

enum AirlineColors {
    private static let known: [String: Color] = [
        "UA": Color(red: 0.00, green: 0.36, blue: 0.67), "AA": Color(red: 0.00, green: 0.47, blue: 0.82),
        "DL": Color(red: 0.78, green: 0.06, blue: 0.18), "WN": Color(red: 0.19, green: 0.30, blue: 0.70),
        "B6": Color(red: 0.00, green: 0.20, blue: 0.63), "AS": Color(red: 0.00, green: 0.26, blue: 0.42),
        "BA": Color(red: 0.03, green: 0.35, blue: 0.67), "LH": Color(red: 0.02, green: 0.09, blue: 0.30),
        "AF": Color(red: 0.00, green: 0.13, blue: 0.34), "KL": Color(red: 0.00, green: 0.63, blue: 0.87),
        "EK": Color(red: 0.84, green: 0.10, blue: 0.13), "QR": Color(red: 0.36, green: 0.02, blue: 0.20),
        "AC": Color(red: 0.94, green: 0.08, blue: 0.16), "VS": Color(red: 0.85, green: 0.02, blue: 0.19),
        "AI": Color(red: 0.85, green: 0.15, blue: 0.11), "6E": Color(red: 0.00, green: 0.11, blue: 0.58),
        "QF": Color(red: 0.88, green: 0.00, blue: 0.11), "TK": Color(red: 0.78, green: 0.04, blue: 0.05),
        "SQ": Color(red: 0.00, green: 0.18, blue: 0.40), "NH": Color(red: 0.05, green: 0.24, blue: 0.58),
        "JL": Color(red: 0.80, green: 0.00, blue: 0.10), "EY": Color(red: 0.74, green: 0.55, blue: 0.07),
        "FR": Color(red: 0.03, green: 0.22, blue: 0.53), "U2": Color(red: 1.00, green: 0.40, blue: 0.00),
    ]

    static func color(for code: String?) -> Color {
        guard let code, !code.isEmpty else { return Color(white: 0.3) }
        if let color = known[code] { return color }
        // Stable hue from the code so each airline keeps its color.
        let seed = code.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.6, brightness: 0.72)
    }
}

struct AirlineBadge: View {
    var code: String?
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(AirlineColors.color(for: code))
            .frame(width: size, height: size)
            .overlay {
                if let code, !code.isEmpty {
                    Text(code)
                        .font(.system(size: size * 0.42, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .padding(2)
                } else {
                    Image(systemName: "airplane")
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }
}

/// The yellow gate / baggage box.
struct GateChip: View {
    var chip: FlightPresentation.Chip
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                Text(chip.label)
                    .font(.system(size: 8, weight: .heavy))
                    .opacity(0.65)
            }
            Text(chip.value)
                .font(.system(size: compact ? 13 : 22, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(.black)
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 2 : 4)
        .frame(minWidth: compact ? 0 : 56)
        .background(Color.flightYellow, in: RoundedRectangle(cornerRadius: compact ? 6 : 10, style: .continuous))
    }
}

/// A live countdown, or a fixed headline when there's nothing to count down to.
struct CountdownValue: View {
    var presentation: FlightPresentation
    var size: CGFloat
    var alignment: TextAlignment = .leading

    var body: some View {
        Group {
            if let target = presentation.countdownTarget, target > .now {
                Text(timerInterval: Date.now...target, countsDown: true)
            } else {
                Text(presentation.headline)
                    .contentTransition(.numericText())
            }
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .monospacedDigit()
        .multilineTextAlignment(alignment)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Airport code with its time, colored by delay, and the original time struck through when it changed.
struct EndpointLabel: View {
    var airport: FlightActivityAttributes.Airport
    var movement: FlightActivityAttributes.Movement
    var alignment: HorizontalAlignment
    /// Grey the time out, e.g. for a cancelled flight.
    var muted = false

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(airport.code)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            if let best = movement.best {
                HStack(spacing: 4) {
                    if alignment == .trailing { scheduled }
                    Text(FlightPresentation.time(best, airport.timeZone))
                        .foregroundStyle(timeColor)
                    if alignment != .trailing { scheduled }
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
            }
        }
        .fixedSize()
    }

    private var timeColor: Color {
        let tone = FlightPresentation.tone(for: movement)
        if muted { return .white.opacity(0.45) }
        return tone == .neutral ? .white.opacity(0.75) : tone.color
    }

    @ViewBuilder
    private var scheduled: some View {
        if !muted, let scheduled = movement.scheduled, abs(movement.delayMinutes ?? 0) >= 5 {
            Text(FlightPresentation.time(scheduled, airport.timeZone))
                .strikethrough()
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// A bar that iOS fills by itself from takeoff to arrival, so it keeps moving on the Lock Screen
/// and in the Dynamic Island between updates, even while FlightLive is closed.
struct TimedProgressBar: View {
    var interval: ClosedRange<Date>
    var tint: Color

    var body: some View {
        ProgressView(timerInterval: interval, countsDown: false) {
            EmptyView()
        } currentValueLabel: {
            EmptyView()
        }
        .progressViewStyle(.linear)
        .tint(tint)
    }
}

/// Origin dot, flown part of the route, the plane, then the rest of the way.
/// In the air with known times, the flown part fills on its own over time.
struct RouteProgressBar: View {
    var progress: Double
    var tint: Color
    /// Takeoff to arrival. When set, the bar animates continuously.
    var interval: ClosedRange<Date>? = nil
    /// Hidden once the data is stale, since the bar keeps moving but the plane can't.
    var showsPlane = true

    private let planeSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let mid = geo.size.height / 2
            let fraction = min(max(progress, 0), 1)
            let planeX = planeSize / 2 + (width - planeSize) * fraction

            ZStack {
                if let interval {
                    TimedProgressBar(interval: interval, tint: tint)
                        .frame(width: max(width - 8, 0))
                        .position(x: width / 2, y: mid)
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: planeX, y: mid))
                        path.addLine(to: CGPoint(x: width, y: mid))
                    }
                    .stroke(Color.white.opacity(0.28), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: mid))
                        path.addLine(to: CGPoint(x: planeX, y: mid))
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                    .position(x: 3, y: mid)
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .position(x: width - 3.5, y: mid)
                if showsPlane {
                    Image(systemName: "airplane")
                        .font(.system(size: planeSize, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .position(x: planeX, y: mid)
                }
            }
            .animation(.easeInOut(duration: 1.2), value: fraction)
        }
        .frame(height: 16)
    }
}

/// Small ring for the Dynamic Island's minimal presentation. Fills by itself in the air.
struct ProgressRing: View {
    var progress: Double
    var tint: Color
    var interval: ClosedRange<Date>? = nil

    var body: some View {
        ZStack {
            if let interval {
                ProgressView(timerInterval: interval, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(tint)
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.22), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "airplane")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

struct MiniStat: View {
    var label: String
    var value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

extension FlightActivityAttributes.ContentState {
    /// Progress to draw: pinned to the ends before takeoff and after landing.
    var displayProgress: Double {
        switch phase {
        case .scheduled, .boarding, .taxiingOut, .cancelled: 0
        case .landed, .arrived: 1
        default: progress ?? 0
        }
    }

    /// Takeoff to arrival while in the air, for bars and rings that fill by themselves between updates.
    var flightInterval: ClosedRange<Date>? {
        guard phase.isAirborne, let end = arrival.best else { return nil }
        var start = departure.runway ?? departure.actual
        // Only the position is known: work back from progress so the bar starts in the right place.
        if start == nil, let progress, progress > 0.02, progress < 0.98, end > updatedAt {
            start = updatedAt.addingTimeInterval(-progress * end.timeIntervalSince(updatedAt) / (1 - progress))
        }
        guard let start, end.timeIntervalSince(start) > 60 else { return nil }
        return start...end
    }

    /// Where to draw the plane. Uses the same timeline as the self-filling bar so the two line up.
    var planeProgress: Double {
        guard let interval = flightInterval else { return displayProgress }
        let total = interval.upperBound.timeIntervalSince(interval.lowerBound)
        return min(max(updatedAt.timeIntervalSince(interval.lowerBound) / total, 0), 1)
    }
}

/// The Lock Screen Live Activity. The app shows the same card on the flight screen.
struct FlightLockScreenView: View {
    var attributes: FlightActivityAttributes
    var state: FlightActivityAttributes.ContentState
    var isStale = false

    var body: some View {
        let presentation = FlightPresentation(attributes: attributes, state: state)
        let units = state.units ?? .aviation

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AirlineBadge(code: attributes.airlineCode, size: 20)
                Text(attributes.flightNumber)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                if let destination = attributes.destination {
                    Text("to \(destination.city)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(presentation.statusText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(presentation.countdownLabel.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .contentTransition(.opacity)
                    CountdownValue(presentation: presentation, size: 30)
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 8)
                if let chip = presentation.chip {
                    GateChip(chip: chip)
                        .id(chip)
                        .transition(.push(from: .bottom))
                }
            }

            if let origin = attributes.origin, let destination = attributes.destination {
                let muted = state.phase == .cancelled
                HStack(spacing: 10) {
                    EndpointLabel(airport: origin, movement: state.departure, alignment: .leading, muted: muted)
                    RouteProgressBar(
                        progress: state.planeProgress,
                        tint: presentation.tone.color,
                        interval: state.flightInterval,
                        showsPlane: !isStale
                    )
                    EndpointLabel(airport: destination, movement: state.arrival, alignment: .trailing, muted: muted)
                }
            } else {
                HStack {
                    MiniStat(label: "SPEED", value: units.speed(state.groundSpeedKnots))
                    Spacer()
                    MiniStat(label: "CLIMB", value: state.verticalRateFPM.map { "\($0) fpm" } ?? "—", alignment: .trailing)
                }
            }

            Group {
                if isStale {
                    Text("Last update \(state.updatedAt, style: .relative) ago")
                } else {
                    Text(presentation.detail)
                        .id(presentation.detail)
                        .transition(.push(from: .bottom))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
