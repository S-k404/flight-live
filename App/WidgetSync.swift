import Foundation
import WidgetKit

/// Keeps the Home Screen widget's copy of your next flights current.
@MainActor
enum WidgetSync {
    private static var last: WidgetSnapshot?

    /// Writes the next three flights for the widget and asks it to redraw, only when they changed in a way it
    /// would show. Countdowns and progress bars move on their own, so small time shifts don't count.
    static func update(_ flights: [TrackedFlight]) {
        let upcoming = flights
            .filter { !$0.isDemo && !$0.isPast() && $0.state.phase != .arrived }
            .sorted { $0.sortDate < $1.sortDate }
            .prefix(3)
            .map { flight -> WidgetSnapshot.Flight in
                var attributes = flight.attributes
                attributes.flightID = flight.id.uuidString
                return WidgetSnapshot.Flight(id: flight.id.uuidString, attributes: attributes, state: flight.state)
            }
        let snapshot = WidgetSnapshot(flights: Array(upcoming))
        guard snapshot.signature != last?.signature else { return }
        last = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

private extension WidgetSnapshot {
    var signature: String {
        flights.map { flight in
            let state = flight.state
            let minute = { (date: Date?) in date.map { "\(Int($0.timeIntervalSince1970 / 300))" } ?? "" }
            return [flight.id, state.phase.rawValue, minute(state.departure.best), minute(state.arrival.best),
                    state.departure.gate ?? "", state.arrival.baggageBelt ?? "", minute(state.leaveBy)].joined(separator: "|")
        }.joined(separator: "\n")
    }
}
