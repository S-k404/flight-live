import CoreSpotlight
import Foundation

/// Puts your flights in iPhone search, so typing "6E 978" or "Raipur" finds the flight and opens it.
@MainActor
enum SpotlightIndex {
    private static let domain = "flights"
    /// What was last indexed, so unchanged lists aren't sent to Spotlight again.
    private static var lastSignature = ""

    static func update(_ flights: [TrackedFlight]) {
        let real = flights.filter { !$0.isDemo }
        let items = real.map(item)
        let signature = items.map { "\($0.uniqueIdentifier)|\($0.attributeSet.title ?? "")|\($0.attributeSet.contentDescription ?? "")" }
            .sorted().joined(separator: "\n")
        guard signature != lastSignature else { return }
        lastSignature = signature
        let index = CSSearchableIndex.default()
        // Start from scratch so removed flights disappear from search too.
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items)
        }
    }

    private static func item(_ flight: TrackedFlight) -> CSSearchableItem {
        let attributes = flight.attributes
        let set = CSSearchableItemAttributeSet(contentType: .content)
        let route = [attributes.origin?.code, attributes.destination?.code].compactMap { $0 }.joined(separator: " → ")
        set.title = route.isEmpty ? attributes.flightNumber : "\(attributes.flightNumber) · \(route)"
        var lines: [String] = []
        if let origin = attributes.origin, let destination = attributes.destination {
            lines.append("\(origin.city) to \(destination.city)")
        }
        if let departure = flight.state.departure.best {
            lines.append(departure.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                                              timeZone: attributes.origin?.timeZone ?? .current)))
        }
        set.contentDescription = lines.joined(separator: " · ")
        set.keywords = [
            attributes.flightNumber, attributes.flightNumber.filter { !$0.isWhitespace }, attributes.airline,
            attributes.origin?.code, attributes.origin?.city, attributes.destination?.code, attributes.destination?.city,
            flight.seat, "flight", "FlightLive",
        ].compactMap { $0 }
        return CSSearchableItem(uniqueIdentifier: flight.id.uuidString, domainIdentifier: domain, attributeSet: set)
    }
}
