import EventKit
import UIKit

/// Keeps every flight in a "FlightLive" calendar in your iCloud account, so your flights follow your Apple ID:
/// a new iPhone or a reinstall gets them back, and they show in Calendar on your Mac and iPad.
enum CalendarSync {
    private static var store: EKEventStore { CalendarImport.store }
    private static let calendarKey = "syncCalendarID"
    private static let eventsKey = "syncCalendarEvents"
    private static let marker = "FlightLive data (keeps this flight in sync):"

    static var calendarID: String? {
        UserDefaults.standard.string(forKey: calendarKey)
    }

    /// The FlightLive calendar, made in iCloud the first time.
    static func calendar(create: Bool) -> EKCalendar? {
        guard CalendarImport.isAuthorized else { return nil }
        if let id = calendarID, let calendar = store.calendar(withIdentifier: id) { return calendar }
        // After a reinstall the saved id is gone, but the calendar is still in iCloud.
        if let existing = store.calendars(for: .event).first(where: { $0.title == "FlightLive" && $0.allowsContentModifications }) {
            UserDefaults.standard.set(existing.calendarIdentifier, forKey: calendarKey)
            return existing
        }
        guard create else { return nil }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "FlightLive"
        calendar.cgColor = UIColor.systemBlue.cgColor
        calendar.source = store.sources.first { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("iCloud") }
            ?? store.defaultCalendarForNewEvents?.source
            ?? store.sources.first { $0.sourceType == .local }
        guard (try? store.saveCalendar(calendar, commit: true)) != nil else { return nil }
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarKey)
        return calendar
    }

    /// False when the calendar ended up on this iPhone only, e.g. with iCloud Calendars turned off.
    static var isInICloud: Bool {
        calendar(create: false)?.source.title.localizedCaseInsensitiveContains("iCloud") ?? false
    }

    /// Adds or updates the flight's event.
    static func save(_ flight: TrackedFlight) {
        guard !flight.isDemo, let departure = flight.state.departure.best, let calendar = calendar(create: true) else { return }
        let event = existingEvent(for: flight.id) ?? EKEvent(eventStore: store)
        let attributes = flight.attributes
        let route = [attributes.origin?.code, attributes.destination?.code].compactMap { $0 }.joined(separator: " → ")
        event.calendar = calendar
        event.title = "✈︎ \(attributes.flightNumber)\(route.isEmpty ? "" : " · \(route)")"
        event.startDate = departure
        event.endDate = max(flight.state.arrival.best ?? departure.addingTimeInterval(2 * 3600), departure.addingTimeInterval(15 * 60))
        event.timeZone = attributes.origin?.timeZone
        event.location = attributes.origin.map { "\($0.city) (\($0.code))" }
        event.url = URL(string: "flightlive://flight/\(flight.id.uuidString)")
        event.notes = notes(for: flight)
        guard (try? store.save(event, span: .thisEvent, commit: true)) != nil else { return }
        var events = savedEventIDs
        events[flight.id.uuidString] = event.eventIdentifier
        savedEventIDs = events
    }

    static func remove(_ id: UUID) {
        guard CalendarImport.isAuthorized, let event = existingEvent(for: id) else { return }
        try? store.remove(event, span: .thisEvent, commit: true)
        var events = savedEventIDs
        events[id.uuidString] = nil
        savedEventIDs = events
    }

    /// Flights saved by FlightLive on any device with this Apple ID, three years back and one ahead.
    static func savedFlights(now: Date = .now) -> [TrackedFlight] {
        guard let calendar = calendar(create: false) else { return [] }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3 * 365 * 24 * 3600),
            end: now.addingTimeInterval(365 * 24 * 3600),
            calendars: [calendar]
        )
        var events = savedEventIDs
        let flights = store.events(matching: predicate).compactMap { event -> TrackedFlight? in
            guard let notes = event.notes, let range = notes.range(of: marker) else { return nil }
            let encoded = notes[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
            // On a new iPhone, remember which event is which so later changes update it instead of adding another.
            events[payload.id.uuidString] = event.eventIdentifier
            return payload.flight
        }
        savedEventIDs = events
        return flights
    }

    // MARK: - Private

    /// What's needed to bring the flight back. The booking code stays on the phone.
    private struct Payload: Codable {
        var id: UUID
        var attributes: FlightActivityAttributes
        var state: FlightActivityAttributes.ContentState
        var callsign: String?
        var hex: String?
        var schedule: ScheduleReference?
        var seat: String?
        var boardingMinutes: Int?
        var addedAt: Date

        init(_ flight: TrackedFlight) {
            id = flight.id
            attributes = flight.attributes
            state = flight.state
            callsign = flight.callsign
            hex = flight.hex
            schedule = flight.schedule
            seat = flight.seat
            boardingMinutes = flight.boardingMinutes
            addedAt = flight.addedAt
        }

        var flight: TrackedFlight {
            var flight = TrackedFlight(id: id, attributes: attributes, state: state, callsign: callsign, hex: hex, schedule: schedule)
            flight.seat = seat
            flight.boardingMinutes = boardingMinutes
            flight.addedAt = addedAt
            return flight
        }
    }

    private static var savedEventIDs: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: eventsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: eventsKey) }
    }

    private static func existingEvent(for id: UUID) -> EKEvent? {
        guard let eventID = savedEventIDs[id.uuidString] else { return nil }
        return store.event(withIdentifier: eventID)
    }

    private static func notes(for flight: TrackedFlight) -> String {
        let attributes = flight.attributes
        var lines: [String] = []
        if let origin = attributes.origin, let destination = attributes.destination {
            lines.append("\(attributes.flightNumber) · \(origin.city) → \(destination.city)")
            if let departure = flight.state.departure.best {
                lines.append("Departs \(origin.code) \(FlightPresentation.time(departure, origin.timeZone))")
            }
            if let arrival = flight.state.arrival.best {
                lines.append("Arrives \(destination.code) \(FlightPresentation.time(arrival, destination.timeZone))")
            }
        }
        if let seat = flight.seat { lines.append("Seat \(seat)") }
        let data = (try? JSONEncoder().encode(Payload(flight))) ?? Data()
        lines.append("")
        lines.append(marker)
        lines.append(data.base64EncodedString())
        return lines.joined(separator: "\n")
    }
}
