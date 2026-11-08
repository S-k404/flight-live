import Foundation

extension TrackedFlight {
    /// Counts in the Passport: a real flight that has happened and wasn't cancelled.
    var isFlown: Bool {
        guard !isDemo, state.phase != .cancelled else { return false }
        if state.phase.isFinal { return true }
        // Tracking can stop early (no key, out of range); still count it once it's well over.
        guard let departure = state.departure.best else { return false }
        return departure < Date().addingTimeInterval(-12 * 3600)
    }

    /// The year it left, in the departure airport's time.
    var passportYear: Int? {
        guard let departure = state.departure.best else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = attributes.origin?.timeZone ?? .current
        return calendar.component(.year, from: departure)
    }

    var distanceKm: Double? {
        guard let origin = attributes.origin, let destination = attributes.destination else { return nil }
        return Geo.distanceNM(origin.coordinate, destination.coordinate) * 1.852
    }

    /// Gate to gate, or an estimate from the distance when the times aren't known.
    var flownMinutes: Int {
        if let out = state.departure.actual ?? state.departure.best,
           let into = state.arrival.actual ?? state.arrival.best,
           into > out, into.timeIntervalSince(out) < 24 * 3600 {
            return Int(into.timeIntervalSince(out) / 60)
        }
        guard let km = distanceKm else { return 0 }
        return Int(km / 800 * 60) + 30
    }

    /// Minutes late at the gate on arrival, or on departure when the arrival isn't known.
    var delayMinutes: Int? {
        state.arrival.actual != nil ? state.arrival.delayMinutes : (state.departure.delayMinutes ?? state.arrival.delayMinutes)
    }

    /// "A321neo" from "Airbus A321 (neo) · VT-IUK".
    var aircraftModel: String? {
        guard let raw = attributes.aircraft?.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return raw
            .replacingOccurrences(of: "Airbus ", with: "")
            .replacingOccurrences(of: #"(?i)\s*\(?neo\)?"#, with: "neo", options: .regularExpression)
    }
}

/// Totals for the Passport: every flight you've taken, or one year's.
struct PassportStats {
    struct Favorite {
        var title: String
        var subtitle: String?
        var code: String?
        var count: Int
    }

    /// A flight counts as delayed at 15 minutes late, like airline on-time stats.
    static let delayThreshold = 15

    var flights = 0
    var longHaul = 0
    var distanceKm = 0.0
    var minutes = 0
    var airports = 0
    var airlines = 0
    var delayedFlights = 0
    var delayMinutes = 0
    var topAircraft: Favorite?
    var topAirline: Favorite?
    var topAirport: Favorite?
    var topRoute: Favorite?

    init(_ flights: [TrackedFlight]) {
        var airportVisits: [String: (city: String, count: Int)] = [:]
        var airlineFlights: [String: (name: String?, count: Int)] = [:]
        var aircraftFlights: [String: Int] = [:]
        var routeFlights: [String: Int] = [:]

        for flight in flights {
            self.flights += 1
            let minutes = flight.flownMinutes
            self.minutes += minutes
            if minutes >= 6 * 60 { longHaul += 1 }
            distanceKm += flight.distanceKm ?? 0
            if let delay = flight.delayMinutes, delay >= Self.delayThreshold {
                delayedFlights += 1
                delayMinutes += delay
            }
            for airport in [flight.attributes.origin, flight.attributes.destination].compactMap({ $0 }) {
                airportVisits[airport.code, default: (airport.city, 0)].count += 1
            }
            if let code = flight.attributes.airlineCode ?? flight.attributes.flightNumber.split(separator: " ").first.map(String.init) {
                airlineFlights[code, default: (flight.attributes.airline, 0)].count += 1
            }
            if let model = flight.aircraftModel {
                aircraftFlights[model, default: 0] += 1
            }
            if let origin = flight.attributes.origin, let destination = flight.attributes.destination {
                routeFlights["\(origin.code) → \(destination.code)", default: 0] += 1
            }
        }

        airports = airportVisits.count
        airlines = airlineFlights.count
        topAircraft = Self.top(aircraftFlights).map { Favorite(title: $0.key, count: $0.value) }
        topAirline = Self.top(airlineFlights.mapValues(\.count)).map {
            Favorite(title: airlineFlights[$0.key]?.name ?? $0.key, code: $0.key, count: $0.value)
        }
        topAirport = Self.top(airportVisits.mapValues(\.count)).map {
            Favorite(title: $0.key, subtitle: airportVisits[$0.key]?.city, code: $0.key, count: $0.value)
        }
        topRoute = Self.top(routeFlights).map { Favorite(title: $0.key, count: $0.value) }
    }

    /// The most frequent, alphabetical on a tie so it doesn't jump around.
    private static func top(_ counts: [String: Int]) -> (key: String, value: Int)? {
        counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }
    }

    func distance(_ units: UnitSystem) -> String {
        let value = units == .imperial ? distanceKm / 1.609 : distanceKm
        return "\(Int(value.rounded()).formatted()) \(units == .imperial ? "mi" : "km")"
    }

    /// "0.3× around the world"
    var aroundTheWorld: String {
        "\(String(format: "%.1f", distanceKm / 40_075))× around the world"
    }
}
