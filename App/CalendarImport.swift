import EventKit
import Foundation

/// A flight spotted in a calendar event, such as one Gmail or Apple Mail added from a booking email.
struct CalendarFlight: Identifiable, Hashable {
    /// Flight number plus departure time, so the same event is only imported once.
    let id: String
    /// Compact IATA flight number, e.g. "UA930".
    let flightNumber: String
    let departure: Date
    let arrival: Date?
    let eventTitle: String

    /// "UA 930"
    var displayNumber: String {
        "\(flightNumber.prefix(2)) \(flightNumber.dropFirst(2))"
    }
}

enum CalendarImport {
    static let store = EKEventStore()

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Flights in calendar events over the next 30 days.
    static func upcomingFlights(now: Date = .now) -> [CalendarFlight] {
        flights(from: now.addingTimeInterval(-6 * 3600), to: now.addingTimeInterval(30 * 24 * 3600))
    }

    /// Flights in calendar events between two dates, leaving out FlightLive's own calendar.
    static func flights(from start: Date, to end: Date) -> [CalendarFlight] {
        guard isAuthorized else { return [] }
        let calendars = store.calendars(for: .event).filter { $0.calendarIdentifier != CalendarSync.calendarID }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        var seen = Set<String>()
        return store.events(matching: predicate)
            .compactMap { event -> CalendarFlight? in
                guard !event.isAllDay, let number = flightNumber(in: event) else { return nil }
                let key = "\(number)-\(Int(event.startDate.timeIntervalSince1970 / 60))"
                guard seen.insert(key).inserted else { return nil }
                let duration = event.endDate.timeIntervalSince(event.startDate)
                // Booking events usually span departure to arrival; ignore placeholder lengths.
                let arrival = (1_200.0...79_200.0).contains(duration) ? event.endDate : nil
                return CalendarFlight(id: key, flightNumber: number, departure: event.startDate,
                                      arrival: arrival, eventTitle: event.title ?? number)
            }
            .sorted { $0.departure < $1.departure }
    }

    /// Finds a flight number like "UA 930", "6E2001" or "B6 123" in an event that looks like a flight.
    static func flightNumber(in event: EKEvent) -> String? {
        flightNumber(in: [event.title, event.location, event.notes].compactMap { $0 }.joined(separator: "\n"))
    }

    /// - Parameter requireContext: Only when the text also looks like it's about a flight, so a calendar's
    ///   "Q3 review" isn't read as one. Off where the text is known to be a flight, like a Notion flights database.
    static func flightNumber(in text: String, requireContext: Bool = true) -> String? {
        let looksLikeFlight = text.range(of: "flight", options: .caseInsensitive) != nil
            || text.range(of: #"\b[A-Z]{3}\s*(-|–|→|to)\s*[A-Z]{3}\b"#, options: .regularExpression) != nil
        guard looksLikeFlight || !requireContext,
              let regex = try? NSRegularExpression(pattern: #"\b([A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])\s?([0-9]{1,4})\b"#)
        else { return nil }
        let notAirlines: Set<String> = ["AM", "PM", "TO", "AT", "ON", "IN", "OF", "NO", "ID", "OR", "BY", "UP",
                                        "Q1", "Q2", "Q3", "Q4", "H1", "H2"]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let airline = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let number = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                  !notAirlines.contains(airline) else { continue }
            return airline + number
        }
        return nil
    }

    /// Turns a calendar flight into something to track, keeping the event's times when there's no schedule key.
    static func candidate(for found: CalendarFlight, credentials: ScheduleCredentials?) async throws -> FlightCandidate? {
        if let credentials {
            let results = try await FlightLookup.search(found.flightNumber, date: found.departure, credentials: credentials)
            let closest = results.min {
                abs(($0.state.departure.best ?? .distantFuture).timeIntervalSince(found.departure))
                    < abs(($1.state.departure.best ?? .distantFuture).timeIntervalSince(found.departure))
            }
            if let closest, closest.schedule != nil { return closest }
        }
        guard let route = try await FlightAPI.route(callsign: found.flightNumber) else { return nil }
        let attributes = FlightActivityAttributes(
            flightNumber: route.displayFlightNumber,
            airlineCode: route.airline?.iata,
            airline: route.airline?.name,
            origin: route.origin.attribute,
            destination: route.destination.attribute
        )
        var state = FlightActivityAttributes.ContentState(phase: .scheduled, updatedAt: .now)
        // Entered as estimates, so the app doesn't claim the flight is on time or delayed.
        state.departure.estimated = found.departure
        state.arrival.estimated = found.arrival
        return FlightCandidate(attributes: attributes, state: state, callsign: route.callsignIcao ?? route.callsign)
    }
}
