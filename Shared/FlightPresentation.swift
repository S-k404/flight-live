import SwiftUI

enum FlightTone {
    case good, warning, bad, info, neutral

    var color: Color {
        switch self {
        case .good: .flightGreen
        case .warning: .flightAmber
        case .bad: .flightRed
        case .info: .flightBlue
        case .neutral: .white.opacity(0.6)
        }
    }
}

/// Decides what a flight card shows right now: the status, the countdown, the gate or belt chip,
/// and one line of context that changes with each stage of the trip.
struct FlightPresentation {
    struct Chip: Hashable {
        var label: String
        var value: String
    }

    var statusText: String
    var tone: FlightTone
    var countdownLabel: String
    /// Live countdown target. Nil shows `headline` instead.
    var countdownTarget: Date?
    var headline: String
    var chip: Chip?
    var detail: String

    init(attributes: FlightActivityAttributes, state: FlightActivityAttributes.ContentState, now: Date = .now) {
        let departure = state.departure
        let arrival = state.arrival
        let units = state.units ?? .aviation
        let originZone = attributes.origin?.timeZone ?? .current
        let destinationZone = attributes.destination?.timeZone ?? .current

        // Status: delay vs. schedule, or the phase when there's no schedule.
        switch state.phase {
        case .cancelled:
            (statusText, tone) = ("Cancelled", .bad)
        case .diverted:
            (statusText, tone) = ("Diverted", .bad)
        default:
            let departed = state.phase.hasDeparted
            let delay = departed ? (arrival.delayMinutes ?? departure.delayMinutes) : departure.delayMinutes
            if let delay {
                (statusText, tone) = Self.delayStatus(delay, departed: departed)
            } else {
                (statusText, tone) = (state.phase.label, state.phase == .arrived ? .good : .info)
            }
        }

        // Countdown.
        func upcoming(_ date: Date?) -> Date? {
            guard let date, date > now else { return nil }
            return date
        }
        switch state.phase {
        case .scheduled, .boarding:
            countdownLabel = state.phase == .boarding ? "Boarding · departs in" : "Departs in"
            if departure.best == nil {
                // No schedule (no AeroDataBox key): all we know is that it hasn't taken off.
                countdownLabel = "Status"
                countdownTarget = nil
                headline = "Not airborne yet"
            } else if let target = upcoming(departure.best), target.timeIntervalSince(now) > 12 * 3600 {
                countdownLabel = "Departs"
                countdownTarget = nil
                headline = target.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: originZone))
            } else {
                countdownTarget = upcoming(departure.best)
                headline = departure.best == nil ? "—" : "Any minute"
            }
        case .taxiingOut, .climbing, .cruising, .descending:
            countdownLabel = "Arrives in"
            countdownTarget = upcoming(arrival.best)
            headline = arrival.best == nil ? "—" : "Any minute"
        case .landed:
            countdownLabel = "At the gate in"
            countdownTarget = upcoming(arrival.best)
            headline = "Taxiing"
        case .arrived:
            countdownLabel = "Arrived"
            countdownTarget = nil
            headline = arrival.best.map { Self.time($0, destinationZone) } ?? "At gate"
        case .cancelled:
            countdownLabel = "Was scheduled for"
            countdownTarget = nil
            headline = departure.scheduled.map { Self.time($0, originZone) } ?? "—"
        case .diverted:
            countdownLabel = "Status"
            countdownTarget = nil
            headline = state.phase.label
        }

        // Gate or baggage chip.
        switch state.phase {
        case .scheduled, .boarding:
            chip = departure.gate.map { Chip(label: "GATE", value: $0) }
                ?? departure.terminal.map { Chip(label: "TERMINAL", value: $0) }
        case .taxiingOut, .climbing, .cruising, .descending:
            chip = arrival.gate.map { Chip(label: "ARR GATE", value: $0) }
                ?? arrival.terminal.map { Chip(label: "ARR TERM", value: $0) }
        case .landed, .arrived:
            chip = arrival.baggageBelt.map { Chip(label: "BAGGAGE", value: $0) }
                ?? arrival.gate.map { Chip(label: "GATE", value: $0) }
        case .cancelled, .diverted:
            chip = nil
        }

        // Context line.
        switch state.phase {
        case .scheduled:
            if let leaveBy = state.leaveBy, leaveBy > now {
                let drive = state.driveMinutes.map { " · \(Self.duration($0)) drive" } ?? ""
                detail = "Leave by \(Self.time(leaveBy, originZone))\(drive)"
            } else if let inbound = state.inbound {
                detail = Self.inboundText(inbound, zone: originZone)
            } else if let boarding = state.boardingStarts, boarding > now {
                let place = departure.gate.map { " · gate \($0)" } ?? departure.terminal.map { " · Terminal \($0)" } ?? ""
                let seat = state.seat.map { " · seat \($0)" } ?? ""
                detail = "Boarding starts \(Self.time(boarding, originZone))\(place)\(seat)"
            } else if let terminal = departure.terminal {
                detail = "Departs from Terminal \(terminal)"
            } else if let scheduled = departure.scheduled {
                detail = "Scheduled \(Self.time(scheduled, originZone))"
            } else {
                detail = "Goes live as soon as it takes off"
            }
        case .boarding:
            let seat = state.seat.map { " · seat \($0)" } ?? ""
            detail = (departure.gate.map { "Boarding now at gate \($0)" } ?? "Boarding now") + seat
        case .taxiingOut:
            detail = departure.actual.map { "Left the gate at \(Self.time($0, originZone)) · taxiing" } ?? "Taxiing to the runway"
        case .climbing, .cruising, .descending:
            if state.positionIsEstimated == true {
                detail = "Out of radar range · position estimated"
            } else {
                detail = "\(state.phase.label) · \(units.altitude(state.altitudeFeet)) · \(units.speed(state.groundSpeedKnots))"
            }
        case .landed:
            let touchdown = arrival.runway.map { " \(Self.time($0, destinationZone))" } ?? ""
            detail = "Landed\(touchdown) · taxiing to the gate"
        case .arrived:
            detail = arrival.baggageBelt.map { "Bags arrive on belt \($0)" }
                ?? arrival.gate.map { "Arrived at gate \($0)" } ?? "Arrived"
        case .cancelled:
            detail = "This flight has been cancelled"
        case .diverted:
            detail = "This flight has been diverted"
        }

        // A plane with no filed route (often a private flight): lead with altitude instead of a countdown.
        if !attributes.hasRoute && !state.phase.isFinal {
            countdownLabel = "Altitude"
            countdownTarget = nil
            headline = units.altitude(state.altitudeFeet)
            detail = attributes.aircraft.map { "\($0) · live from ADS-B" } ?? "Live from ADS-B"
        }
    }

    static func delayStatus(_ minutes: Int, departed: Bool) -> (String, FlightTone) {
        if minutes <= -5 { return ("\(duration(-minutes)) early", .good) }
        if minutes <= 5 { return ("On time", .good) }
        let text = departed ? "\(duration(minutes)) late" : "Delayed \(duration(minutes))"
        return (text, minutes <= 30 ? .warning : .bad)
    }

    /// Tone for a single time compared with its schedule.
    static func tone(for movement: FlightActivityAttributes.Movement) -> FlightTone {
        guard let delay = movement.delayMinutes else { return .neutral }
        if delay <= 5 { return .good }
        return delay <= 30 ? .warning : .bad
    }

    static func inboundText(_ inbound: FlightActivityAttributes.Inbound, zone: TimeZone) -> String {
        switch inbound.status {
        case .inAir:
            let from = inbound.fromCode.map { " from \($0)" } ?? ""
            let lands = inbound.arrival.map { " · lands \(time($0, zone))" } ?? ""
            return "Your plane is flying in\(from)\(lands)"
        case .arrived:
            return "Your plane is here"
        case .elsewhere:
            let from = inbound.fromCode.map { " at \($0)" } ?? ""
            return "Your plane is on the ground\(from)"
        }
    }

    static func time(_ date: Date, _ zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    /// "45m", "1h 05m"
    static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
