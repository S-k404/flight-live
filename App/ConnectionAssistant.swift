import SwiftUI

// The Connection Assistant: what a connection involves, how likely it is to work, and how to show that.
// Every time here is an estimate from typical times at large airports. FlightLive has no airport's real queue
// times or its minimum connection time, and says so on screen.

/// What decides which checkpoints a connection has.
struct ConnectionContext: Equatable {
    /// You land from another country. Nil when an airport's country isn't known.
    var arrivesFromAbroad: Bool?
    /// You leave for another country. Nil when an airport's country isn't known.
    var leavesForAbroad: Bool?
    /// Your own say, for when the airports' countries are missing or you know better.
    var markedInternational: Bool?
    /// The two terminals differ. Nil when either isn't known.
    var terminalChange: Bool?
    var arrivalTerminal: String?
    var departureTerminal: String?
    var departureGate: String?
    var bagsCheckedThrough = true

    var isInternational: Bool {
        markedInternational ?? (arrivesFromAbroad == true || leavesForAbroad == true)
    }

    /// Whether two terminals differ. "T3", "Terminal 3" and "3" are the same one. Nil when either isn't known.
    static func terminalsDiffer(_ arrival: String?, _ departure: String?) -> Bool? {
        guard let arrival, let departure else { return nil }
        func key(_ terminal: String) -> String {
            terminal.uppercased().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^TERMINAL\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^T(?=\d)"#, with: "", options: .regularExpression)
        }
        return key(arrival) != key(departure)
    }

    /// Counted as domestic only because an airport's country isn't known.
    var internationalIsGuessed: Bool {
        markedInternational == nil && !isInternational && (arrivesFromAbroad == nil || leavesForAbroad == nil)
    }
}

/// One thing between the plane and the next gate, with how long it usually takes.
struct Checkpoint: Identifiable, Equatable {
    enum Kind: String {
        case passport, bags, shuttle, security, walk, gateCloses
    }

    var kind: Kind
    /// Typical minutes, quickest to slowest.
    var minutes: ClosedRange<Int>
    var detail: String?

    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .passport: "Passport control"
        case .bags: "Collect and re-check bags"
        case .shuttle: "Train or shuttle between terminals"
        case .security: "Security"
        case .walk: "Walk to the gate"
        case .gateCloses: "Gate closes before departure"
        }
    }

    var symbol: String {
        switch kind {
        case .passport: "person.text.rectangle"
        case .bags: "suitcase.rolling.fill"
        case .shuttle: "tram.fill"
        case .security: "person.badge.shield.checkmark"
        case .walk: "figure.walk"
        case .gateCloses: "door.left.hand.closed"
        }
    }
}

extension ClosedRange where Bound == Int {
    /// "~10–45m". The tilde is there because it's an estimate.
    var estimateText: String {
        if upperBound < 60 { return lowerBound == upperBound ? "~\(lowerBound)m" : "~\(lowerBound)–\(upperBound)m" }
        return "~\(FlightPresentation.duration(lowerBound))–\(FlightPresentation.duration(upperBound))"
    }
}

struct ConnectionAssessment: Equatable {
    enum Risk: Equatable {
        case risky, minimum, normal

        /// What the connection card says.
        var label: String {
            switch self {
            case .risky: "Risky"
            case .minimum: "Minimum"
            case .normal: "Normal"
            }
        }

        var color: Color {
            switch self {
            case .risky: .flightRed
            case .minimum: .flightAmber
            case .normal: .flightGreen
            }
        }
    }

    var risk: Risk
    var checkpoints: [Checkpoint]
    /// Every checkpoint at its quickest, and at its slowest.
    var lowMinutes: Int
    var highMinutes: Int
    /// Half way between: the layover marked "MIN." on the gauge. Less than this is risky.
    var typicalMinutes: Int
    /// Enough even when the queues are long, and never under an hour: marked "NORMAL".
    var normalMinutes: Int
    /// Things this estimate assumed, to say out loud.
    var notes: [String]

    var totalRange: ClosedRange<Int> { lowMinutes...highMinutes }
}

enum ConnectionRules {
    /// A table of what a connection typically involves, from the context. There is no authoritative source for this,
    /// so the numbers are rounded, typical times at large airports.
    static func assess(minutes: Int, context: ConnectionContext) -> ConnectionAssessment {
        let international = context.isInternational
        let terminalChange = context.terminalChange == true
        var points: [Checkpoint] = []

        if international {
            points.append(Checkpoint(kind: .passport, minutes: 15...45, detail: "A border check, landing or leaving"))
        }
        if !context.bagsCheckedThrough {
            points.append(Checkpoint(kind: .bags, minutes: 20...45, detail: "Wait at the belt, then drop them off again"))
        }
        if terminalChange {
            let route = [context.arrivalTerminal, context.departureTerminal].compactMap { $0 }
            points.append(Checkpoint(kind: .shuttle, minutes: 10...30,
                                     detail: route.count == 2 ? "Terminal \(route[0]) to Terminal \(route[1])" : nil))
        }
        // Leaving the secure area, or crossing a border, means being screened again.
        if international || terminalChange || !context.bagsCheckedThrough {
            points.append(Checkpoint(kind: .security, minutes: 10...30, detail: "Screened again before the next gate"))
        }
        points.append(Checkpoint(kind: .walk, minutes: 5...20, detail: context.departureGate.map { "Gate \($0)" }))
        points.append(Checkpoint(kind: .gateCloses, minutes: 15...20, detail: "Airlines usually close the gate a little before departure"))

        let low = points.map(\.minutes.lowerBound).reduce(0, +)
        let high = points.map(\.minutes.upperBound).reduce(0, +)
        let typical = Int((Double(low + high) / 2).rounded())
        let normal = max(high, 60)

        var notes: [String] = []
        if context.terminalChange == nil {
            notes.append("The terminals aren't both known yet, so no transfer between terminals is counted.")
        }
        if context.internationalIsGuessed {
            notes.append("An airport's country isn't known, so this is counted as a domestic connection.")
        }

        let risk: ConnectionAssessment.Risk = minutes < typical ? .risky : minutes < normal ? .minimum : .normal
        return ConnectionAssessment(
            risk: risk, checkpoints: points, lowMinutes: low, highMinutes: high,
            typicalMinutes: typical, normalMinutes: normal, notes: notes
        )
    }
}

// MARK: - Views

/// Risky ← Minimum ← Normal, with a marker where your layover falls.
struct ConnectionGauge: View {
    var minutes: Int
    var assessment: ConnectionAssessment
    /// "58m at JFK"
    var label: String

    private var axisMax: Double { Double(max(assessment.normalMinutes * 3 / 2, 90)) }

    private func position(_ minutes: Int, in width: CGFloat) -> CGFloat {
        width * CGFloat(min(max(Double(minutes) / axisMax, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let typical = position(assessment.typicalMinutes, in: width)
            let normal = position(assessment.normalMinutes, in: width)
            let marker = min(max(position(minutes, in: width), 7), width - 7)
            // Wide enough for the label, kept inside the card.
            let labelHalf = CGFloat(label.count) * 3.6 + 10
            let labelX = min(max(marker, labelHalf), width - labelHalf)

            ZStack(alignment: .topLeading) {
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.14), in: Capsule())
                    .fixedSize()
                    .position(x: labelX, y: 10)

                HStack(spacing: 0) {
                    Rectangle().fill(Color.flightRed).frame(width: typical)
                    Rectangle().fill(Color.flightAmber).frame(width: max(normal - typical, 0))
                    Rectangle().fill(Color.flightGreen)
                }
                .frame(height: 10)
                .overlay(alignment: .leading) {
                    // Even with every queue short, this much time isn't enough.
                    Hatch()
                        .frame(width: position(assessment.lowMinutes, in: width), height: 10)
                }
                .clipShape(Capsule())
                .offset(y: 28)

                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.flightCard, lineWidth: 3))
                    .position(x: marker, y: 33)

                Group {
                    Text("RISKY").position(x: 18, y: 54)
                    Text("MIN.").position(x: min(max(typical, 30), width - 60), y: 54)
                    Text("NORMAL").position(x: min(max(normal, 50), width - 22), y: 54)
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(assessment.risk.label)")
    }
}

/// Diagonal stripes, for the part of the gauge where the time isn't enough even in the best case.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 5
            }
            context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 1.5)
        }
    }
}

/// A yes/no choice as a row. Plain buttons, so it reads and works like the rest of the card.
private struct OptionRow: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isOn ? Color.flightBlue : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
    }
}

/// The gauge and the checklist for one connection, with the two things you can tell it.
struct ConnectionAssistantView: View {
    var airportCode: String
    var minutes: Int
    var assessment: ConnectionAssessment
    var context: ConnectionContext
    var nextDeparture: FlightActivityAttributes.Movement
    var zone: TimeZone
    /// Where the next flight goes, for "Bags checked through to …".
    var nextDestinationCode: String?
    @Binding var bagsCheckedThrough: Bool
    @Binding var isInternational: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(assessment.risk.label)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(assessment.risk.color)
                Text("ESTIMATE")
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }

            ConnectionGauge(minutes: minutes, assessment: assessment, label: "\(FlightPresentation.duration(minutes)) at \(airportCode)")

            departure

            VStack(alignment: .leading, spacing: 12) {
                ForEach(assessment.checkpoints) { point in
                    CheckpointRow(point: point)
                }
            }

            HStack {
                Text("Estimated total")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(assessment.totalRange.estimateText)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                OptionRow(title: "Bags checked through\(nextDestinationCode.map { " to \($0)" } ?? "")",
                          detail: nil, isOn: $bagsCheckedThrough)
                OptionRow(title: "International connection",
                          detail: context.markedInternational == nil ? "From the airports' countries. Tap to change it." : "Set by you.",
                          isOn: $isInternational)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(assessment.notes, id: \.self) { note in
                    Text(note)
                }
                Text("Estimates from typical times at large airports. Real queues, your airline's own minimum connection time and delays can change this.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// The gate you're heading to, as on the Live Activity: the gate chip, the terminal and the departure time.
    @ViewBuilder
    private var departure: some View {
        if nextDeparture.gate != nil || nextDeparture.terminal != nil || nextDeparture.best != nil {
            HStack(spacing: 10) {
                if let gate = nextDeparture.gate {
                    GateChip(chip: .init(label: "GATE", value: gate), compact: true, showsIcon: true)
                }
                if let terminal = nextDeparture.terminal {
                    Text(terminal.count <= 3 ? "Terminal \(terminal)" : terminal)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                if let best = nextDeparture.best {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(FlightPresentation.time(best, zone))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(FlightPresentation.tone(for: nextDeparture).color)
                        if let status = FlightPresentation.movementStatus(nextDeparture) {
                            Text(status.text)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(status.tone.color)
                        }
                    }
                }
            }
        }
    }
}

private struct CheckpointRow: View {
    var point: Checkpoint

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: point.symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(point.title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail = point.detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 8)
            Text(point.minutes.estimateText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
