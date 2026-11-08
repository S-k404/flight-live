import SwiftUI
import WidgetKit

/// Your next flight on the Home Screen or Lock Screen, read from what the app last saved.
struct NextFlightWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextFlight", provider: NextFlightProvider()) { entry in
            NextFlightEntryView(entry: entry)
        }
        .configurationDisplayName("Next Flight")
        .description("Your next flight's countdown, gate and status, or the one you're on.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

private struct NextFlightEntryView: View {
    var entry: NextFlightEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        NextFlightWidgetView(flight: entry.flight, family: family)
    }
}

struct NextFlightEntry: TimelineEntry {
    var date: Date
    var flight: WidgetSnapshot.Flight?
}

struct NextFlightProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextFlightEntry {
        NextFlightEntry(date: .now, flight: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextFlightEntry) -> Void) {
        let flights = WidgetSnapshot.load()?.flights ?? []
        completion(NextFlightEntry(date: .now, flight: current(flights, at: .now) ?? (context.isPreview ? .sample : nil)))
    }

    /// An entry now, and one as each flight lands, so the widget moves on to the next flight by itself.
    /// The countdowns tick on their own; the app asks for a new timeline when anything else changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextFlightEntry>) -> Void) {
        let flights = WidgetSnapshot.load()?.flights ?? []
        let now = Date()
        var entries = [NextFlightEntry(date: now, flight: current(flights, at: now))]
        let landings = flights.compactMap { $0.state.arrival.best?.addingTimeInterval(30 * 60) }.filter { $0 > now }.sorted()
        for moment in landings.prefix(5) {
            entries.append(NextFlightEntry(date: moment, flight: current(flights, at: moment)))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    /// The flight you're on, or else the next to leave. A flight stays up for half an hour after landing.
    private func current(_ flights: [WidgetSnapshot.Flight], at date: Date) -> WidgetSnapshot.Flight? {
        flights.first { flight in
            guard let landing = flight.state.arrival.best ?? flight.state.departure.best?.addingTimeInterval(3 * 3600) else { return true }
            return landing.addingTimeInterval(30 * 60) > date
        }
    }
}
