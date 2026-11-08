import AppIntents
import SwiftUI

// Siri, Spotlight, Shortcuts and Action button support. These run on the iPhone; the phrases in
// FlightLiveShortcuts work with "Hey Siri" as soon as the app is installed, with no setup.

struct FlightEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Flight")
    static let defaultQuery = FlightEntityQuery()

    let id: UUID
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ flight: TrackedFlight) {
        id = flight.id
        title = flight.attributes.flightNumber
        var parts: [String] = []
        if let origin = flight.attributes.origin, let destination = flight.attributes.destination {
            parts.append("\(origin.code) → \(destination.code)")
        }
        if let departure = flight.state.departure.best {
            parts.append(departure.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                                              timeZone: flight.attributes.origin?.timeZone ?? .current)))
        }
        subtitle = parts.joined(separator: " · ")
    }
}

struct FlightEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [FlightEntity] {
        identifiers.compactMap { FlightStore.shared.flight($0) }.map(FlightEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [FlightEntity] {
        FlightStore.shared.upcoming.map(FlightEntity.init)
    }
}

/// Picks the flight an intent is about: the one chosen, or the next upcoming one.
@MainActor
private func resolveFlight(_ entity: FlightEntity?) async -> TrackedFlight? {
    let store = FlightStore.shared
    guard let flight = entity.flatMap({ store.flight($0.id) }) ?? store.nextFlight else { return nil }
    // Siri answers should be fresh, so update anything older than two minutes first.
    if Date().timeIntervalSince(flight.state.updatedAt) > 120 {
        await store.refresh(flight.id)
    }
    return store.flight(flight.id)
}

private let noFlightsMessage = "You don't have any upcoming flights in FlightLive. Say \"Track a flight in FlightLive\" to add one."

struct FlightStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Flight Status"
    static let description = IntentDescription("When your flight leaves or lands, its gate, delays and boarding time.")

    @Parameter(title: "Flight")
    var flight: FlightEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let tracked = await resolveFlight(flight)
        let text = tracked?.spokenStatus ?? noFlightsMessage
        return .result(dialog: "\(text)", view: FlightSnippetView(flight: tracked))
    }
}

struct WhereIsMyPlaneIntent: AppIntent {
    static let title: LocalizedStringResource = "Where's My Plane?"
    static let description = IntentDescription("Where the aircraft for your next flight is right now.")

    @Parameter(title: "Flight")
    var flight: FlightEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let tracked = await resolveFlight(flight) else {
            return .result(dialog: "\(noFlightsMessage)")
        }
        let name = tracked.attributes.flightNumber
        let state = tracked.state
        let text: String
        if state.phase.hasDeparted {
            text = "Your plane is operating \(name) now. \(tracked.spokenStatus)"
        } else if let inbound = state.inbound {
            text = FlightPresentation.inboundText(inbound, zone: tracked.attributes.origin?.timeZone ?? .current) + "."
        } else if tracked.hex == nil {
            text = "I don't know which plane will fly \(name) yet. That needs an AeroDataBox key in FlightLive's Settings, and airlines usually assign the plane on the day of the flight."
        } else {
            text = "The plane for \(name) isn't flying right now and isn't visible on radar."
        }
        return .result(dialog: "\(text)")
    }
}

struct FlightArrivalIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Flight Arrival Time"
    static let description = IntentDescription("When your flight lands, as text you can use in a Shortcut, like a message to whoever is picking you up.")

    @Parameter(title: "Flight")
    var flight: FlightEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let tracked = await resolveFlight(flight) else {
            return .result(value: noFlightsMessage, dialog: "\(noFlightsMessage)")
        }
        let text = tracked.spokenArrival
        return .result(value: text, dialog: "\(text)")
    }
}

/// Runs in the app's process, which lets it start a Live Activity even from the background.
struct ShowOnLockScreenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Show Flight on Lock Screen"
    static let description = IntentDescription("Puts your flight on the Lock Screen and in the Dynamic Island.")

    @Parameter(title: "Flight")
    var flight: FlightEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let tracked = await resolveFlight(flight) else {
            return .result(dialog: "\(noFlightsMessage)")
        }
        let store = FlightStore.shared
        await store.setLiveActivity(true, for: tracked.id, canStartInBackground: true)
        let name = tracked.attributes.flightNumber
        if store.hasLiveActivity(tracked.id) {
            return .result(dialog: "\(name) is on your Lock Screen.")
        }
        return .result(dialog: "I couldn't start the Live Activity for \(name). Check that Live Activities are on for FlightLive in Settings.")
    }
}

struct TrackFlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Track a Flight"
    static let description = IntentDescription("Adds a flight to FlightLive by its flight number or a plane's tail number.")

    @Parameter(title: "Flight number", requestValueDialog: "Which flight? For example, IndiGo 2001 or United 930.")
    var flightNumber: String

    @Parameter(title: "Date")
    var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let candidates = try await FlightLookup.search(flightNumber, date: date ?? .now, credentials: AppSettings.shared.credentials)
        guard let candidate = candidates.first else {
            return .result(dialog: "I couldn't find \(flightNumber).", view: FlightSnippetView(flight: nil))
        }
        let store = FlightStore.shared
        let id = await store.add(candidate)
        let tracked = store.flight(id)
        let status = tracked?.spokenStatus ?? ""
        return .result(dialog: "Added \(candidate.attributes.flightNumber). \(status)", view: FlightSnippetView(flight: tracked))
    }
}

struct SearchFlightIntent: AppIntent {
    static let title: LocalizedStringResource = "Search for a Flight"
    static let description = IntentDescription("Opens FlightLive and searches for a flight by its number, or a plane by its tail number, so you can pick the right one.")
    static let openAppWhenRun = true

    @Parameter(title: "Flight number", requestValueDialog: "Which flight? For example, IndiGo 2001 or United 930.")
    var flightNumber: String

    @MainActor
    func perform() async throws -> some IntentResult {
        FlightStore.shared.pendingSearch = flightNumber
        return .result()
    }
}

struct RefreshFlightsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Update Flights"
    static let description = IntentDescription("Fetches the latest status for all your flights and updates the Lock Screen. Handy in a Shortcuts automation, e.g. when you arrive at the airport.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = FlightStore.shared
        await store.refreshAll(force: true)
        await store.syncLiveActivities(canStartInBackground: true)
        let text = store.nextFlight?.spokenStatus ?? "Your flights are up to date."
        return .result(dialog: "\(text)")
    }
}

struct FlightLiveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FlightStatusIntent(),
            phrases: [
                "When does my flight leave in \(.applicationName)",
                "What's my flight status in \(.applicationName)",
                "Is my flight on time in \(.applicationName)",
                "\(.applicationName) flight status",
            ],
            shortTitle: "Flight Status",
            systemImageName: "airplane"
        )
        AppShortcut(
            intent: WhereIsMyPlaneIntent(),
            phrases: [
                "Where's my plane in \(.applicationName)",
                "Where is my plane in \(.applicationName)",
            ],
            shortTitle: "Where's My Plane?",
            systemImageName: "airplane.arrival"
        )
        AppShortcut(
            intent: FlightArrivalIntent(),
            phrases: [
                "When does my flight land in \(.applicationName)",
                "\(.applicationName) arrival time",
            ],
            shortTitle: "Arrival Time",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: ShowOnLockScreenIntent(),
            phrases: [
                "Show my flight on the Lock Screen with \(.applicationName)",
                "Start \(.applicationName)",
            ],
            shortTitle: "Show on Lock Screen",
            systemImageName: "lock.iphone"
        )
        AppShortcut(
            intent: TrackFlightIntent(),
            phrases: [
                "Track a flight in \(.applicationName)",
                "Add a flight to \(.applicationName)",
            ],
            shortTitle: "Track a Flight",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: SearchFlightIntent(),
            phrases: [
                "Search for a flight in \(.applicationName)",
                "Find a flight in \(.applicationName)",
                "Search \(.applicationName)",
            ],
            shortTitle: "Search Flights",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: UpdateFlightFromTextIntent(),
            phrases: [
                "Add a flight from text in \(.applicationName)",
                "Update my flight from a message in \(.applicationName)",
            ],
            shortTitle: "Flight from Text",
            systemImageName: "text.viewfinder"
        )
        AppShortcut(
            intent: RefreshFlightsIntent(),
            phrases: [
                "Update my flights in \(.applicationName)",
            ],
            shortTitle: "Update Flights",
            systemImageName: "arrow.clockwise"
        )
    }
}

/// The card Siri shows with its answer.
struct FlightSnippetView: View {
    var flight: TrackedFlight?

    var body: some View {
        if let flight {
            FlightLockScreenView(attributes: flight.attributes, state: flight.state)
                .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .environment(\.colorScheme, .dark)
        } else {
            Label("No upcoming flights", systemImage: "airplane")
                .padding()
        }
    }
}

// MARK: - Spoken answers

extension TrackedFlight {
    /// A sentence or two for Siri to read out.
    var spokenStatus: String {
        let now = Date()
        let name = attributes.flightNumber
        let to = attributes.destination.map { " to \($0.city)" } ?? ""
        let originZone = attributes.origin?.timeZone ?? .current
        let units = state.units ?? .aviation
        var sentences: [String] = []

        switch state.phase {
        case .scheduled, .boarding:
            guard let departure = state.departure.best else {
                return "\(name)\(to) hasn't taken off yet. Add its departure time in FlightLive to get a countdown and a boarding alert."
            }
            var first = "\(name)\(to) departs \(Self.spokenTime(departure, originZone, now: now))"
            if let gate = state.departure.gate { first += " from gate \(gate)" }
            if let delay = state.departure.delayMinutes { first += ", \(Self.spokenDelay(delay))" }
            sentences.append(first + ".")
            if state.phase == .boarding {
                sentences.append("It's boarding now.")
            } else if let boarding = state.boardingStarts, boarding > now {
                sentences.append("Boarding starts at \(FlightPresentation.time(boarding, originZone)).")
            }
            if let inbound = state.inbound {
                sentences.append(FlightPresentation.inboundText(inbound, zone: originZone) + ".")
            }
        case .taxiingOut:
            sentences.append("\(name) has left the gate and is taxiing to the runway.")
            sentences.append(spokenArrival)
        case .climbing, .cruising, .descending:
            if state.positionIsEstimated == true {
                sentences.append("\(name) is out of radar range, probably over the ocean.")
            } else {
                sentences.append("\(name) is \(state.phase.label.lowercased()) at \(units.altitude(state.altitudeFeet)).")
            }
            sentences.append(spokenArrival)
            if let remaining = state.distanceRemainingNM, state.positionIsEstimated != true {
                sentences.append("\(units.distance(remaining)) to go.")
            }
        case .landed:
            let city = attributes.destination.map { " in \($0.city)" } ?? ""
            let gate = state.arrival.gate.map { " and is taxiing to gate \($0)" } ?? ""
            sentences.append("\(name) has landed\(city)\(gate).")
        case .arrived:
            sentences.append(spokenArrival)
            if let belt = state.arrival.baggageBelt { sentences.append("Bags arrive on belt \(belt).") }
        case .cancelled:
            sentences.append("\(name)\(to) has been cancelled.")
        case .diverted:
            sentences.append("\(name)\(to) has been diverted.")
        }
        return sentences.joined(separator: " ")
    }

    /// "UA 930 lands in London at 10:40 AM local time, on time."
    var spokenArrival: String {
        let name = attributes.flightNumber
        let city = attributes.destination.map { " in \($0.city)" } ?? ""
        let zone = attributes.destination?.timeZone ?? .current
        guard let arrival = state.arrival.best else {
            return "There's no arrival time for \(name) yet."
        }
        let delay = state.arrival.delayMinutes.map { ", \(Self.spokenDelay($0))" } ?? ""
        let time = Self.spokenTime(arrival, zone, now: .now)
        if state.phase == .arrived {
            return "\(name) arrived\(city) \(time)\(delay)."
        }
        return "\(name) lands\(city) \(time)\(delay)."
    }

    static func spokenTime(_ date: Date, _ zone: TimeZone, now: Date) -> String {
        var calendar = Calendar.current
        calendar.timeZone = zone
        var text = "at \(FlightPresentation.time(date, zone))"
        if calendar.isDateInTomorrow(date) {
            text = "tomorrow " + text
        } else if !calendar.isDate(date, inSameDayAs: now) {
            text = "on \(date.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: zone))) " + text
        }
        if zone.secondsFromGMT(for: date) != TimeZone.current.secondsFromGMT(for: date) {
            text += " local time"
        }
        return text
    }

    static func spokenDelay(_ minutes: Int) -> String {
        if abs(minutes) <= 5 { return "on time" }
        let amount = abs(minutes) < 60
            ? "\(abs(minutes)) minutes"
            : "\(abs(minutes) / 60) hour\(abs(minutes) >= 120 ? "s" : "") \(abs(minutes) % 60) minutes"
        return minutes < 0 ? "\(amount) early" : "\(amount) late"
    }
}
