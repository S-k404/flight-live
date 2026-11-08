import ActivityKit
import BackgroundTasks
import CoreLocation
import Foundation
import Observation
import SwiftUI

/// A flight on the My Flights list. Saved to disk.
struct TrackedFlight: Codable, Identifiable {
    var id = UUID()
    var attributes: FlightActivityAttributes
    var state: FlightActivityAttributes.ContentState
    /// ATC callsign, used to find the plane when its transponder address isn't known.
    var callsign: String?
    /// ICAO 24-bit transponder address of the assigned aircraft.
    var hex: String?
    var schedule: ScheduleReference?
    var lastScheduleRefresh: Date?
    var memory = TrackingMemory()
    var latitude: Double?
    var longitude: Double?
    var track: Double?
    var inboundLatitude: Double?
    var inboundLongitude: Double?
    var demoStartedAt: Date?
    var activityID: String?
    /// Off when the user turned the Live Activity off or swiped it away.
    var showsLiveActivity = true
    /// Start the Live Activity now instead of three hours before departure.
    var startLiveActivityEarly = false
    var notifiedKeys: Set<String> = []
    var addedAt = Date()
    /// Minutes before departure that boarding starts. Nil uses the default.
    var boardingMinutes: Int?
    var seat: String?
    var confirmationCode: String?
    var passengerName: String?
    /// A boarding pass picture is saved for this flight (see BoardingPassStore).
    var hasBoardingPass: Bool?
    /// What the boarding pass barcode said, when it doesn't match this flight.
    var boardingPassMismatch: String?
    /// Drive time to the departure airport from Apple Maps, when leaving is timed from your location.
    var travel: TravelEstimate?
    /// AeroDataBox has answered about this past flight's plane and times, so it isn't asked again.
    var pastDetailsChecked: Bool?

    static let defaultBoardingMinutes = 40

    var isDemo: Bool { demoStartedAt != nil }

    var boardingLead: TimeInterval {
        TimeInterval((boardingMinutes ?? Self.defaultBoardingMinutes) * 60)
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var inboundCoordinate: CLLocationCoordinate2D? {
        guard let inboundLatitude, let inboundLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: inboundLatitude, longitude: inboundLongitude)
    }

    var sortDate: Date { state.departure.best ?? addedAt }

    /// Finished more than six hours ago.
    func isPast(now: Date = .now) -> Bool {
        guard state.phase.isFinal else { return false }
        let end = state.arrival.best ?? state.departure.best ?? addedAt
        return now.timeIntervalSince(end) > 6 * 3600
    }

    mutating func apply(position aircraft: LiveAircraft) {
        guard let lat = aircraft.lat, let lon = aircraft.lon else { return }
        latitude = lat
        longitude = lon
        track = aircraft.track ?? track
    }

    var shareText: String {
        let presentation = FlightPresentation(attributes: attributes, state: state)
        var lines = [attributes.flightNumber]
        if let origin = attributes.origin, let destination = attributes.destination {
            lines[0] += " · \(origin.code) → \(destination.code)"
            if let departure = state.departure.best {
                lines.append("Departs \(origin.code) \(FlightPresentation.time(departure, origin.timeZone))\(state.departure.gate.map { ", gate \($0)" } ?? "")")
            }
            if let arrival = state.arrival.best {
                lines.append("Arrives \(destination.code) \(FlightPresentation.time(arrival, destination.timeZone))")
            }
        }
        lines.append("\(presentation.statusText) · \(presentation.detail)")
        return lines.joined(separator: "\n")
    }
}


@MainActor
@Observable
final class FlightStore {
    typealias State = FlightActivityAttributes.ContentState

    static let shared = FlightStore()
    static let refreshTaskID = "com.shamit.FlightLive.refresh"

    private(set) var flights: [TrackedFlight] = []
    private(set) var lastError: String?
    private(set) var liveActivitiesEnabled = true
    /// A search Siri asked for; the flight list opens Add Flight with it.
    var pendingSearch: String?

    @ObservationIgnored private var activities: [UUID: Activity<FlightActivityAttributes>] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isInForeground = false
    @ObservationIgnored private var routeCache: [String: FlightRoute] = [:]
    @ObservationIgnored private var refreshing: Set<UUID> = []
    @ObservationIgnored private let settings = AppSettings.shared

    // Battery: each flight is only checked when it's due, and the Live Activity, disk and reminders are
    // only touched when something actually changed.
    @ObservationIgnored private var nextPositionCheck: [UUID: Date] = [:]
    @ObservationIgnored private var pushedStates: [UUID: State] = [:]
    @ObservationIgnored private var lastActivityPush: [UUID: Date] = [:]
    @ObservationIgnored private var reminderSignatures: [UUID: String] = [:]
    @ObservationIgnored private var lastCalendarImport: Date?
    @ObservationIgnored private var lastCalendarRestore: Date?
    /// What each flight looked like when last saved to iCloud Calendar, so unchanged flights aren't written again.
    @ObservationIgnored private var calendarSignatures: [String: String] =
        UserDefaults.standard.dictionary(forKey: "calendarSignatures") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(calendarSignatures, forKey: "calendarSignatures") }
    }
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var hasUnsavedChanges = false

    /// iOS Low Power Mode or FlightLive's own Battery Saver: check about a third as often.
    var savingBattery: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || settings.batterySaver
    }

    private init() {
        load()
    }

    // MARK: - Reading

    func flight(_ id: UUID) -> TrackedFlight? {
        flights.first { $0.id == id }
    }

    var upcoming: [TrackedFlight] {
        flights.filter { !$0.isPast() }.sorted { $0.sortDate < $1.sortDate }
    }

    var past: [TrackedFlight] {
        flights.filter { $0.isPast() }.sorted { $0.sortDate > $1.sortDate }
    }

    func hasLiveActivity(_ id: UUID) -> Bool {
        activities[id] != nil
    }

    /// The flight Siri talks about by default: the next real one that isn't over.
    var nextFlight: TrackedFlight? {
        let active = upcoming.filter { !$0.state.phase.isFinal }
        return active.first { !$0.isDemo } ?? active.first ?? upcoming.first
    }

    // MARK: - Adding and removing

    @discardableResult
    func add(_ candidate: FlightCandidate) async -> UUID {
        if candidate.isPast {
            // Already flown: no tracking, notifications or Live Activity, like an imported flight.
            var flight = TrackedFlight(attributes: candidate.attributes, state: candidate.state)
            flight.addedAt = candidate.state.departure.best ?? .now
            addPastFlights([flight])
            return trackedFlight(matching: flight.attributes.flightNumber, departure: flight.state.departure.best)?.id ?? flight.id
        }
        if let existing = trackedFlight(matching: candidate.attributes.flightNumber,
                                        departure: candidate.state.departure.best,
                                        schedule: candidate.schedule) {
            return existing.id
        }
        var flight = TrackedFlight(
            attributes: candidate.attributes,
            state: candidate.state,
            callsign: candidate.callsign,
            hex: candidate.hex,
            schedule: candidate.schedule,
            lastScheduleRefresh: candidate.schedule == nil ? nil : .now
        )
        flight.state.units = settings.units
        if let aircraft = candidate.aircraft {
            flight.apply(position: aircraft)
            flight.memory.hasBeenAirborne = flight.state.phase.isAirborne
        }
        flights.append(flight)
        save()
        syncToCalendar(flight)

        if settings.notificationsEnabled {
            // Don't wait for the answer: adding the flight shouldn't hang on the permission prompt.
            Task { _ = await FlightNotifications.requestAuthorization() }
        }
        await refresh(flight.id)
        await syncLiveActivities()
        startPolling()
        return flight.id
    }

    /// The same flight number on the same trip (departures within 12 hours of each other).
    func trackedFlight(matching flightNumber: String, departure: Date?, schedule: ScheduleReference? = nil) -> TrackedFlight? {
        let compact = flightNumber.filter { !$0.isWhitespace }
        return flights.first { flight in
            guard !flight.isDemo, flight.attributes.flightNumber.filter({ !$0.isWhitespace }) == compact else { return false }
            if let schedule, let existing = flight.schedule { return schedule == existing }
            guard let departure, let existing = flight.state.departure.best else { return true }
            return abs(existing.timeIntervalSince(departure)) < 12 * 3600
        }
    }

    // MARK: - Calendar

    @ObservationIgnored private var importedCalendarKeys: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "importedCalendarFlights") ?? []
    )

    /// Calendar flights that aren't on My Flights yet.
    func newCalendarFlights() -> [CalendarFlight] {
        CalendarImport.upcomingFlights().filter { found in
            trackedFlight(matching: found.flightNumber, departure: found.departure) == nil
        }
    }

    /// Adds a flight found in the calendar, with the event's times. Nil if its route couldn't be found.
    @discardableResult
    func addFromCalendar(_ found: CalendarFlight) async -> UUID? {
        guard let candidate = try? await CalendarImport.candidate(for: found, credentials: settings.credentials) else { return nil }
        importedCalendarKeys.insert(found.id)
        UserDefaults.standard.set(Array(importedCalendarKeys), forKey: "importedCalendarFlights")
        return await add(candidate)
    }

    /// With the setting on, adds new flights from the calendar on its own and says so.
    func autoImportFromCalendar() async {
        guard settings.autoImportCalendar, CalendarImport.isAuthorized else { return }
        // Bookings don't appear every minute: look at most every 30 minutes (2 hours when saving battery).
        let gap: TimeInterval = savingBattery ? 2 * 3600 : 30 * 60
        if let last = lastCalendarImport, Date().timeIntervalSince(last) < gap { return }
        lastCalendarImport = Date()
        for found in newCalendarFlights() where !importedCalendarKeys.contains(found.id) {
            guard let id = await addFromCalendar(found), let flight = flight(id) else { continue }
            if settings.notificationsEnabled {
                let zone = flight.attributes.origin?.timeZone ?? .current
                let when = found.departure.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone))
                FlightNotifications.post(
                    FlightEvent(key: "calendar-added", title: "Added \(flight.attributes.flightNumber)",
                                body: "Found in your calendar: departs \(when). You'll get check-in, leave-for-the-airport and boarding reminders."),
                    flightID: id,
                    playSound: false
                )
            }
        }
    }

    @discardableResult
    func addDemo() async -> UUID {
        for demo in flights where demo.isDemo {
            await remove(demo.id)
        }
        let start = Date()
        let sample = DemoFlight.sample(startedAt: start, now: start)
        var flight = TrackedFlight(attributes: .demo, state: sample.state, demoStartedAt: start)
        flight.state.units = settings.units
        flight.latitude = sample.coordinate.latitude
        flight.longitude = sample.coordinate.longitude
        flight.track = sample.track
        flight.startLiveActivityEarly = true
        flights.append(flight)
        save()
        await syncLiveActivities()
        startPolling()
        return flight.id
    }

    func remove(_ id: UUID) async {
        if let activity = activities.removeValue(forKey: id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        FlightNotifications.cancelReminders(flightID: id)
        BoardingPassStore.delete(for: id)
        nextPositionCheck[id] = nil
        pushedStates[id] = nil
        lastActivityPush[id] = nil
        reminderSignatures[id] = nil
        calendarSignatures[id.uuidString] = nil
        if settings.syncCalendar { CalendarSync.remove(id) }
        flights.removeAll { $0.id == id }
        save()
    }

    // MARK: - Notion

    struct NotionImportResult {
        var added = 0
        var alreadyHere = 0
        var notFound = 0
    }

    @ObservationIgnored private var lastNotionImport: Date?
    /// Pages already imported, so a flight you remove here doesn't come back on the next import.
    @ObservationIgnored private var importedNotionPages = Set(UserDefaults.standard.stringArray(forKey: "importedNotionPages") ?? []) {
        didSet { UserDefaults.standard.set(Array(importedNotionPages), forKey: "importedNotionPages") }
    }

    /// Adds flights from your Notion database: upcoming ones are tracked live, past ones go to your Passport.
    /// - Parameter force: Import now (the Import button), rather than at most every 30 minutes when the setting is on.
    @discardableResult
    func importFromNotion(force: Bool = false) async throws -> NotionImportResult {
        let token = settings.notionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !settings.notionSourceID.isEmpty else { return NotionImportResult() }
        if !force {
            guard settings.notionAutoImport else { return NotionImportResult() }
            let gap: TimeInterval = savingBattery ? 2 * 3600 : 30 * 60
            if let last = lastNotionImport, Date().timeIntervalSince(last) < gap { return NotionImportResult() }
        }
        lastNotionImport = Date()
        let entries = try await NotionImport.flights(sourceID: settings.notionSourceID, token: token)
        return await importNotionEntries(entries, notify: !force)
    }

    /// - Parameter notify: Say so when an upcoming flight is added (automatic imports).
    func importNotionEntries(_ entries: [NotionFlight], notify: Bool) async -> NotionImportResult {
        var result = NotionImportResult()
        var past: [TrackedFlight] = []
        let known = flights.flatMap { [$0.attributes.origin, $0.attributes.destination].compactMap { $0 } }
        for entry in entries where !importedNotionPages.contains(entry.pageID) {
            if let existing = trackedFlight(matching: entry.flightNumber, departure: entry.roughDeparture) {
                // Already here, e.g. added by hand: just fill in the seat and booking code.
                await fillIn(existing.id, from: entry)
                result.alreadyHere += 1
            } else if let departure = entry.roughDeparture, departure < Date().addingTimeInterval(-6 * 3600) {
                var record = PastFlightRecord(flightNumber: entry.flightNumber, from: entry.from, to: entry.to, day: entry.day)
                record.departureScheduled = entry.departure.map { .exact($0) }
                record.arrivalScheduled = entry.arrival.map { .exact($0) }
                record.departureTerminal = entry.terminal
                record.departureGate = entry.gate
                record.seat = entry.seat
                guard var flight = await PastFlightImport.flight(from: record, knownAirports: known, credentials: settings.credentials,
                                                                 lookUpDetails: entries.count <= 5) else {
                    result.notFound += 1
                    continue
                }
                flight.confirmationCode = entry.confirmationCode
                past.append(flight)
            } else {
                guard let candidate = await NotionImport.candidate(for: entry, credentials: settings.credentials) else {
                    result.notFound += 1
                    continue
                }
                let id = await add(candidate)
                await fillIn(id, from: entry)
                result.added += 1
                if notify, settings.notificationsEnabled, let flight = flight(id) {
                    FlightNotifications.post(
                        FlightEvent(key: "notion-added", title: "Added \(flight.attributes.flightNumber)",
                                    body: "Found in your Notion database. It's on My Flights with live updates and reminders."),
                        flightID: id,
                        playSound: false
                    )
                }
            }
            importedNotionPages.insert(entry.pageID)
        }
        let addedPast = addPastFlights(past)
        result.added += addedPast
        result.alreadyHere += past.count - addedPast
        return result
    }

    /// The seat and booking code from Notion, where FlightLive doesn't have them yet.
    private func fillIn(_ id: UUID, from entry: NotionFlight) async {
        guard var flight = flight(id) else { return }
        let seat = flight.seat ?? entry.seat
        let code = flight.confirmationCode ?? entry.confirmationCode
        guard seat != flight.seat || code != flight.confirmationCode else { return }
        flight.seat = seat
        flight.confirmationCode = code
        await commit(flight, previous: flight.state, next: flight.state, force: true)
    }

    // MARK: - Past flights and iCloud

    /// Adds flights you've already taken, e.g. from a Flighty export or old calendar events. Skips ones already here.
    @discardableResult
    func addPastFlights(_ newFlights: [TrackedFlight]) -> Int {
        var added = 0
        for var flight in newFlights where self.flight(flight.id) == nil
            && trackedFlight(matching: flight.attributes.flightNumber, departure: flight.state.departure.best) == nil {
            flight.state.units = settings.units
            flights.append(flight)
            syncToCalendar(flight)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    /// Flights you've taken where FlightLive doesn't know the plane yet and hasn't asked AeroDataBox.
    var pastFlightsMissingPlanes: [TrackedFlight] {
        flights.filter { $0.isFlown && $0.attributes.aircraft == nil && $0.pastDetailsChecked != true }
    }

    struct PastDetailsResult {
        var filled = 0
        var notFound = 0
        /// Couldn't ask (offline, or the phone locked mid-way); these are tried again next time.
        var failed = 0
        var quotaUsedUp = false
    }

    /// Looks up the plane, tail number and real gate times for past flights: one AeroDataBox request each.
    func fillInPastFlights() async -> PastDetailsResult {
        var result = PastDetailsResult()
        guard let credentials = settings.credentials else { return result }
        // Keep going for a while if the screen locks part way; iOS would otherwise pause the lookups.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Past flight details")
        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
        for (index, flight) in pastFlightsMissingPlanes.enumerated() {
            // The free plan allows about one request a second.
            if index > 0 { try? await Task.sleep(for: .milliseconds(1_200)) }
            let detailed: TrackedFlight?
            do {
                detailed = try await PastFlightImport.withScheduleDetails(flight, credentials: credentials)
            } catch ScheduleError.quotaExceeded {
                result.quotaUsedUp = true
                break
            } catch {
                result.failed += 1
                continue
            }
            guard var latest = self.flight(flight.id) else { continue }
            latest.pastDetailsChecked = true
            if let detailed {
                latest.attributes = detailed.attributes
                latest.state = detailed.state
                latest.hex = detailed.hex
                result.filled += 1
            } else {
                result.notFound += 1
            }
            replace(latest)
            syncToCalendar(latest)
        }
        return result
    }

    /// Saves the flight to the FlightLive calendar in iCloud when something worth keeping changed.
    private func syncToCalendar(_ flight: TrackedFlight) {
        guard settings.syncCalendar, !flight.isDemo, CalendarImport.isAuthorized else { return }
        let state = flight.state
        let minute = { (date: Date?) in date.map { "\(Int($0.timeIntervalSince1970 / 60))" } ?? "" }
        let signature = [
            flight.attributes.flightNumber, state.phase.isFinal ? state.phase.rawValue : "",
            minute(state.departure.best), minute(state.arrival.best), minute(state.departure.scheduled),
            state.departure.gate ?? "", flight.seat ?? "", flight.attributes.aircraft ?? "",
        ].joined(separator: "|")
        guard calendarSignatures[flight.id.uuidString] != signature else { return }
        calendarSignatures[flight.id.uuidString] = signature
        CalendarSync.save(flight)
    }

    /// Puts every flight in the FlightLive calendar that isn't there yet, e.g. right after sync is turned on.
    func syncAllToCalendar() {
        guard settings.syncCalendar, CalendarImport.isAuthorized else { return }
        // The calendar was deleted (or this is a new iPhone): everything needs saving again.
        if CalendarSync.calendar(create: false) == nil { calendarSignatures = [:] }
        for flight in flights { syncToCalendar(flight) }
    }

    /// Brings back flights saved to iCloud Calendar from another device, or before a reinstall.
    @discardableResult
    func restoreFromCalendar(force: Bool = false) -> Int {
        guard settings.syncCalendar, CalendarImport.isAuthorized else { return 0 }
        if !force, let last = lastCalendarRestore, Date().timeIntervalSince(last) < 30 * 60 { return 0 }
        lastCalendarRestore = Date()
        var added = 0
        for var saved in CalendarSync.savedFlights() where flight(saved.id) == nil
            && trackedFlight(matching: saved.attributes.flightNumber, departure: saved.state.departure.best) == nil {
            saved.state.units = settings.units
            flights.append(saved)
            added += 1
        }
        if added > 0 {
            save()
            startPolling()
            Task { await syncLiveActivities() }
        }
        return added
    }

    // MARK: - Boarding pass

    /// Saves a boarding pass picture and reads its barcode for the seat, booking code and name.
    /// Returns what the barcode said, or nil if there was no readable barcode.
    @discardableResult
    func attachBoardingPass(_ image: UIImage, to id: UUID) async throws -> BoardingPassInfo? {
        try BoardingPassStore.save(image, for: id)
        let info = await BoardingPassStore.readBarcode(in: image)
        guard var flight = flight(id) else { return info }
        flight.hasBoardingPass = true
        flight.boardingPassMismatch = nil
        if let info {
            flight.seat = info.seat ?? flight.seat
            flight.confirmationCode = info.confirmationCode.isEmpty ? flight.confirmationCode : info.confirmationCode
            flight.passengerName = info.passengerName
            let number = flight.attributes.flightNumber.filter { !$0.isWhitespace }
            let sameRoute = flight.attributes.origin.map { $0.code == info.from } ?? true
            let sameNumber = number.hasSuffix(info.flightNumber)
            if !sameRoute || !sameNumber {
                flight.boardingPassMismatch = "This pass is for \(info.displayFlight), \(info.from) → \(info.to)."
            }
        }
        await commit(flight, previous: flight.state, next: flight.state, force: true)
        return info
    }

    func removeBoardingPass(from id: UUID) async {
        BoardingPassStore.delete(for: id)
        guard var flight = flight(id) else { return }
        flight.hasBoardingPass = nil
        flight.boardingPassMismatch = nil
        await commit(flight, previous: flight.state, next: flight.state, force: true)
    }

    /// Times, gate, seat and booking code you enter yourself, e.g. from your boarding pass.
    func updateDetails(_ id: UUID, departure: Date?, arrival: Date?, gate: String, boardingMinutes: Int,
                       seat: String = "", confirmationCode: String = "") async {
        guard var flight = flight(id) else { return }
        let previous = flight.state
        flight.boardingMinutes = boardingMinutes
        let trimmedSeat = seat.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        flight.seat = trimmedSeat.isEmpty ? nil : trimmedSeat
        let trimmedCode = confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        flight.confirmationCode = trimmedCode.isEmpty ? nil : trimmedCode
        var edited = previous
        if flight.schedule == nil {
            // Entered as estimates, so the app doesn't claim the flight is on time or delayed.
            edited.departure.estimated = departure
            edited.arrival.estimated = arrival
            // A flown flight may carry the real gate times, which would win over what's entered here.
            if previous.phase.isFinal {
                if edited.departure.actual != nil { edited.departure.actual = departure }
                if edited.arrival.actual != nil { edited.arrival.actual = arrival }
            }
            // Moved to a day that hasn't come yet: it isn't over after all.
            if previous.phase == .arrived, !flight.memory.hasBeenAirborne, let departure, departure > .now {
                edited.phase = .scheduled
            }
        }
        let trimmedGate = gate.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        edited.departure.gate = trimmedGate.isEmpty ? nil : trimmedGate
        if let gate = edited.departure.gate {
            flight.notifiedKeys.insert("gate-\(gate)") // you entered it, no need to announce it
        }

        var memory = flight.memory
        var next = FlightMath.nextState(
            attributes: flight.attributes,
            previous: edited,
            schedule: nil,
            aircraft: nil,
            lookedForAircraft: false,
            boardingLead: flight.boardingLead,
            memory: &memory
        )
        if next.departure.best == nil { next.boardingStarts = nil }
        flight.memory = memory
        next.units = settings.units

        if settings.notificationsEnabled {
            Task { _ = await FlightNotifications.requestAuthorization() }
        }
        await commit(flight, previous: previous, next: next, force: true)
        await syncLiveActivities()
    }

    /// Turns the Lock Screen Live Activity on (right away) or off for one flight.
    /// `canStartInBackground` is for App Intents, which iOS allows to start Live Activities without the app open.
    func setLiveActivity(_ on: Bool, for id: UUID, canStartInBackground: Bool = false) async {
        guard var flight = flight(id) else { return }
        flight.showsLiveActivity = on
        flight.startLiveActivityEarly = on
        replace(flight)
        if !on, let activity = activities.removeValue(forKey: id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        await syncLiveActivities(canStartInBackground: canStartInBackground)
        if let updated = self.flight(id) { updateReminders(for: updated) }
    }

    // MARK: - Refreshing

    func refreshAll(force: Bool = false) async {
        // A forced refresh (pull to refresh, Siri) includes flights that just finished, for the baggage belt,
        // but never old ones: those would only burn network and schedule quota.
        // Together, a few at a time: position lookups don't wait on each other, and schedule requests are spaced
        // out by the AeroDataBox pacer.
        let due = flights.filter { !$0.state.phase.isFinal || (force && !$0.isPast()) }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            var remaining = due.makeIterator()
            for _ in 0..<4 {
                guard let id = remaining.next() else { break }
                group.addTask { await self.refresh(id, forceSchedule: force) }
            }
            while await group.next() != nil {
                if let id = remaining.next() { group.addTask { await self.refresh(id, forceSchedule: force) } }
            }
        }
        await syncLiveActivities()
        await updateTravelTimes()
    }

    // MARK: - Getting to the airport

    /// When to set off: Apple Maps' drive time with traffic from where you are, so you're at the airport
    /// `arriveAtAirportMinutes` before departure. Without your location, a set time before departure.
    func leavePlan(for flight: TrackedFlight) -> LeavePlan? {
        guard !flight.isDemo, let departure = flight.state.departure.best else { return nil }
        if settings.leaveUsingLocation, let travel = flight.travel {
            guard !travel.isAtAirport else { return nil }
            let lead = TimeInterval((settings.arriveAtAirportMinutes + travel.minutes) * 60)
            return LeavePlan(date: departure.addingTimeInterval(-lead), travel: travel)
        }
        guard settings.leaveForAirportMinutes > 0 else { return nil }
        return LeavePlan(date: departure.addingTimeInterval(-TimeInterval(settings.leaveForAirportMinutes * 60)), travel: nil)
    }

    /// Asks Apple Maps for the drive to the airport on the day of the flight: every 15 minutes in the three
    /// hours before you need to leave, as traffic changes, hourly before that, and not at all once you've left.
    func updateTravelTimes(force: Bool = false) async {
        guard settings.leaveUsingLocation, LocationProvider.shared.isAuthorized else { return }
        let now = Date()
        for flight in flights where !flight.isDemo && !flight.state.phase.hasDeparted && flight.state.phase != .cancelled {
            guard let origin = flight.attributes.origin, let departure = flight.state.departure.best,
                  departure > now, departure.timeIntervalSince(now) < 18 * 3600 else { continue }
            let leaveIn = (leavePlan(for: flight)?.date ?? departure).timeIntervalSince(now)
            if leaveIn < -30 * 60 && flight.travel != nil { continue }
            let age = flight.travel.map { now.timeIntervalSince($0.updatedAt) } ?? .infinity
            guard force || age >= (leaveIn < 3 * 3600 ? 15 * 60 : 60 * 60) else { continue }

            guard let location = await LocationProvider.shared.currentLocation(inForeground: isInForeground) else { return }
            let straightLine = location.distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)) / 1000
            var estimate: TravelEstimate?
            if straightLine < 2 {
                estimate = TravelEstimate(minutes: 0, distanceKm: straightLine, updatedAt: now)
            } else if straightLine < 300 {
                // Ask for traffic at about the time you'd leave, not right now.
                let lead = settings.arriveAtAirportMinutes + (flight.travel?.minutes ?? 45)
                estimate = await GettingThere.driveTime(from: location, to: origin,
                                                        leavingAround: departure.addingTimeInterval(-TimeInterval(lead * 60)))
                if estimate == nil { continue } // offline: keep the last estimate
            }
            // Further away than a drive (e.g. the flight is from another city): fall back to the set time.
            guard var latest = self.flight(flight.id), latest.travel != estimate else { continue }
            latest.travel = estimate
            replace(latest)
            // Puts the new leave-by time on the Lock Screen and re-queues the reminder.
            await commit(latest, previous: latest.state, next: latest.state, force: true)
        }
    }

    /// Re-queues reminders after a settings change.
    func refreshReminders() {
        for flight in flights { updateReminders(for: flight) }
    }

    func refresh(_ id: UUID, forceSchedule: Bool = false) async {
        guard !refreshing.contains(id), var flight = flight(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        let now = Date()
        var previous = flight.state

        if let start = flight.demoStartedAt {
            let sample = DemoFlight.sample(startedAt: start, now: now)
            flight.latitude = sample.coordinate.latitude
            flight.longitude = sample.coordinate.longitude
            flight.track = sample.track
            var next = sample.state
            next.units = settings.units
            await commit(flight, previous: previous, next: next)
            return
        }

        // Schedule, gates and delays.
        var snapshot: ScheduleSnapshot?
        if let reference = flight.schedule, let credentials = settings.credentials,
           forceSchedule || scheduleIsDue(flight, now: now) {
            do {
                let results = try await AeroDataBox.flights(number: reference.number, date: reference.date, credentials: credentials)
                if let match = bestMatch(results, for: flight) {
                    snapshot = ScheduleSnapshot(match)
                    flight.hex = flight.hex ?? match.aircraft?.modeS?.lowercased()
                    flight.callsign = flight.callsign ?? match.callSign?.replacingOccurrences(of: " ", with: "")
                }
                flight.lastScheduleRefresh = now
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }

        // Live position, or the inbound plane before departure.
        var aircraft: LiveAircraft?
        var inboundAircraft: LiveAircraft?
        var looked = false
        if forceSchedule || positionIsDue(flight, now: now) {
            if let interval = positionInterval(for: flight, now: now) {
                nextPositionCheck[id] = now.addingTimeInterval(interval)
            }
            do {
                if let hex = flight.hex {
                    if let found = try await FlightAPI.aircraft(hex: hex) {
                        if belongsToFlight(found, flight, now: now) { aircraft = found } else { inboundAircraft = found }
                    }
                    looked = true
                } else if let callsign = flight.callsign {
                    if let found = try await FlightAPI.aircraft(callsign: callsign), belongsToFlight(found, flight, now: now) {
                        aircraft = found
                    }
                    looked = true
                }
            } catch {
                // A network error says nothing about the plane, so don't treat it as out of coverage.
                looked = false
            }
        }

        // While we were waiting on the network, a shared text, the details editor or a boarding pass may have
        // changed this flight. Start from the latest copy so those edits aren't overwritten.
        guard var latest = self.flight(id) else { return } // removed while we were waiting
        latest.hex = flight.hex
        latest.callsign = flight.callsign
        latest.lastScheduleRefresh = flight.lastScheduleRefresh
        flight = latest
        previous = latest.state

        var memory = flight.memory
        var next = FlightMath.nextState(
            attributes: flight.attributes,
            previous: previous,
            schedule: snapshot,
            aircraft: aircraft,
            lookedForAircraft: looked,
            boardingLead: flight.boardingLead,
            memory: &memory,
            now: now
        )
        flight.memory = memory
        next.units = settings.units

        // Pace the next check by what we just learned: a plane found cruising is checked every 30 seconds,
        // not at the slower "waiting for takeoff" pace it had before this check.
        if looked {
            var updated = flight
            updated.state = next
            if let interval = positionInterval(for: updated, now: now) {
                nextPositionCheck[id] = now.addingTimeInterval(interval)
            }
        }

        // "Where's my plane?"
        if next.phase.hasDeparted || next.phase == .cancelled {
            next.inbound = nil
            flight.inboundLatitude = nil
            flight.inboundLongitude = nil
        } else if let aircraft, let origin = flight.attributes.origin, aircraft.lat != nil {
            // Our plane is already sitting at the departure airport.
            next.inbound = FlightMath.inbound(aircraft: aircraft, route: nil, origin: origin, now: now)
        } else if let inboundAircraft {
            let route = await cachedRoute(for: inboundAircraft.callsign)
            next.inbound = FlightMath.inbound(aircraft: inboundAircraft, route: route, origin: flight.attributes.origin, now: now)
            flight.inboundLatitude = next.inbound == nil ? nil : inboundAircraft.lat
            flight.inboundLongitude = next.inbound == nil ? nil : inboundAircraft.lon
        } else if looked {
            next.inbound = nil
        }

        if let aircraft { flight.apply(position: aircraft) }
        await commit(flight, previous: previous, next: next)
    }

    /// Saves the new state, announces what changed and updates the Live Activity.
    /// - Parameter force: The caller changed something outside the state (booking code, boarding pass),
    ///   so save and push even if the state itself is the same.
    func commit(_ flight: TrackedFlight, previous: State, next: State, force: Bool = false) async {
        var flight = flight
        var next = next
        let stored = self.flight(flight.id)
        // Keep what other work recorded while this caller held an older copy.
        if let stored {
            flight.activityID = flight.activityID ?? stored.activityID
            flight.notifiedKeys.formUnion(stored.notifiedKeys)
        }
        // Things you added yourself ride along to the Live Activity.
        next.seat = flight.seat
        next.hasBoardingPass = flight.hasBoardingPass
        flight.state = next
        // When to leave for the airport, for the Lock Screen and the widget before departure.
        let plan = next.phase.hasDeparted ? nil : leavePlan(for: flight)
        next.leaveBy = plan?.date
        next.driveMinutes = plan?.travel?.minutes
        flight.state = next
        var events = FlightEvents.changes(from: previous, to: next, attributes: flight.attributes)
            .filter { !flight.notifiedKeys.contains($0.key) }
        flight.notifiedKeys.formUnion(events.map(\.key))
        // When boarding starts on time, the scheduled reminder has already announced it.
        if let boarding = next.boardingStarts, Date() >= boarding.addingTimeInterval(-60) {
            events.removeAll { $0.key == "boarding" }
        }

        // Nothing new: keep it in memory and skip the disk, the Live Activity and the reminders.
        let significant = force || !events.isEmpty || stored.map { Self.isSignificant(from: $0.state, to: next) } ?? true
        if !significant && stored?.state == next {
            replace(flight, persist: false)
            await keepActivityFresh(for: flight)
            return
        }
        replace(flight, persist: significant)
        updateReminders(for: flight)
        syncToCalendar(flight)

        let hasActivity = activities[flight.id] != nil
        if settings.notificationsEnabled {
            for event in events {
                // The Live Activity already chimes for the first event, so keep the notification quiet then.
                FlightNotifications.post(event, flightID: flight.id, playSound: !hasActivity)
            }
            warnIfConnectionIsTight(after: flight)
        }
        await updateActivity(for: flight, alert: events.first, significant: significant)
    }

    /// When a delay leaves under an hour to make the next flight, say so once, and again if it's missed.
    private func warnIfConnectionIsTight(after flight: TrackedFlight) {
        guard !flight.state.phase.isFinal, let connection = connection(after: flight), connection.isTight else { return }
        let key = connection.isMissed ? "connection-missed" : "connection-tight"
        guard var latest = self.flight(flight.id), !latest.notifiedKeys.contains(key) else { return }
        latest.notifiedKeys.insert(key)
        replace(latest)
        let next = connection.next
        let leaves = next.state.departure.best.map { " at \(FlightPresentation.time($0, connection.airport.timeZone))" } ?? ""
        let event = connection.isMissed
            ? FlightEvent(key: key, title: "Connection at risk in \(connection.airport.city)",
                          body: "\(flight.attributes.flightNumber) now lands after \(next.attributes.flightNumber) is due to leave\(leaves). Check with the airline.")
            : FlightEvent(key: key, title: "Tight connection in \(connection.airport.city)",
                          body: "\(FlightPresentation.duration(connection.minutes)) to make \(next.attributes.flightNumber)\(leaves)\(next.state.departure.gate.map { " from gate \($0)" } ?? "").")
        FlightNotifications.post(event, flightID: flight.id, playSound: true)
    }

    /// Whether a change is worth a Live Activity update or a disk write right away. The countdown and
    /// progress bar move by themselves, so small changes in altitude, speed or estimate can wait.
    static func isSignificant(from old: State, to new: State) -> Bool {
        func sameMovement(_ a: FlightActivityAttributes.Movement, _ b: FlightActivityAttributes.Movement) -> Bool {
            let closeEnough = { (x: Date?, y: Date?) -> Bool in
                switch (x, y) {
                case (nil, nil): true
                case let (x?, y?): abs(x.timeIntervalSince(y)) < 120
                default: false
                }
            }
            return a.scheduled == b.scheduled && closeEnough(a.estimated, b.estimated) && a.actual == b.actual
                && a.runway == b.runway && a.terminal == b.terminal && a.gate == b.gate && a.baggageBelt == b.baggageBelt
        }
        if old.phase != new.phase || !sameMovement(old.departure, new.departure) || !sameMovement(old.arrival, new.arrival) {
            return true
        }
        if old.inbound != new.inbound || old.seat != new.seat || old.hasBoardingPass != new.hasBoardingPass
            || old.boardingStarts != new.boardingStarts || old.positionIsEstimated != new.positionIsEstimated
            || old.units != new.units {
            return true
        }
        let progressJump = abs((old.progress ?? 0) - (new.progress ?? 0)) > 0.02
        let altitudeJump = abs((old.altitudeFeet ?? 0) - (new.altitudeFeet ?? 0)) > 3_000
        let speedJump = abs((old.groundSpeedKnots ?? 0) - (new.groundSpeedKnots ?? 0)) > 40
        return progressJump || altitudeJump || speedJump
    }

    /// Keeps reminders queued on the phone itself, so they fire on time even if FlightLive is closed:
    /// check-in opening, time to leave for the airport, putting the flight on the Lock Screen, and boarding.
    private func updateReminders(for flight: TrackedFlight) {
        let state = flight.state
        // Re-queue only when something that goes into a reminder changed.
        let signature = [
            "\(settings.notificationsEnabled)", "\(settings.checkInReminder)",
            leavePlan(for: flight).map { "\(Int($0.date.timeIntervalSince1970 / 60))" } ?? "",
            state.phase.rawValue, "\(String(describing: state.departure.best))", "\(String(describing: state.boardingStarts))",
            state.departure.gate ?? "", state.departure.terminal ?? "",
            "\(flight.showsLiveActivity)", "\(activities[flight.id] != nil)",
        ].joined(separator: "|")
        guard reminderSignatures[flight.id] != signature else { return }
        reminderSignatures[flight.id] = signature

        guard settings.notificationsEnabled, !state.phase.hasDeparted, state.phase != .cancelled,
              let departure = state.departure.best else {
            FlightNotifications.cancelReminders(flightID: flight.id)
            return
        }
        let name = flight.attributes.flightNumber
        let origin = flight.attributes.origin
        let zone = origin?.timeZone ?? .current
        let to = flight.attributes.destination.map { " to \($0.city)" } ?? ""
        let departs = FlightPresentation.time(departure, zone)
        let place = state.departure.gate.map { "gate \($0)" } ?? state.departure.terminal.map { "Terminal \($0)" }
        var reminders: [FlightNotifications.Reminder] = []

        if settings.checkInReminder && !flight.isDemo {
            reminders.append(.init(
                kind: .checkIn,
                date: departure.addingTimeInterval(-24 * 3600),
                title: "Check in · \(name)",
                body: "Check-in for your flight\(to) is usually open now. It departs tomorrow at \(departs)."
            ))
        }
        if let plan = leavePlan(for: flight) {
            let from = origin.map { " from \($0.code)" } ?? ""
            let body: String
            if let travel = plan.travel {
                let drive = FlightPresentation.duration(travel.minutes)
                let early = FlightPresentation.duration(settings.arriveAtAirportMinutes)
                body = "Leave by \(FlightPresentation.time(plan.date, zone)): \(drive) drive\(origin.map { " to \($0.code)" } ?? "") with traffic, "
                    + "so you're there \(early) before your \(departs) flight\(place.map { " (\($0))" } ?? "")."
            } else {
                body = "Departs at \(departs)\(from)\(place.map { ", \($0)" } ?? "")."
            }
            reminders.append(.init(
                kind: .leave,
                date: plan.date,
                title: "Time to leave for the airport · \(name)",
                body: body,
                directionsTo: origin
            ))
        }
        if flight.showsLiveActivity && activities[flight.id] == nil && !flight.isDemo {
            // iOS only lets the app itself start a Live Activity, so nudge you to open it.
            reminders.append(.init(
                kind: .lockScreen,
                date: departure.addingTimeInterval(-3 * 3600),
                title: "\(name) departs in 3 hours",
                body: "Tap to put it on your Lock Screen and in the Dynamic Island."
            ))
        }
        if state.phase == .scheduled, let boarding = state.boardingStarts {
            reminders.append(.init(
                kind: .boarding,
                date: boarding,
                title: "Boarding · \(name)",
                body: "Boarding starts now\(state.departure.gate.map { " at gate \($0)" } ?? ""). Departs at \(departs)."
            ))
        }
        FlightNotifications.schedule(reminders, flightID: flight.id)
    }

    private func scheduleIsDue(_ flight: TrackedFlight, now: Date) -> Bool {
        guard let last = flight.lastScheduleRefresh else { return true }
        let phase = flight.state.phase
        let untilDeparture = (flight.state.departure.best ?? now).timeIntervalSince(now)
        let interval: TimeInterval
        if phase == .arrived {
            // Keep checking for the baggage belt for an hour after arrival.
            let arrivedAt = flight.state.arrival.best ?? now
            interval = flight.state.arrival.baggageBelt == nil && now.timeIntervalSince(arrivedAt) < 3600 ? 10 * 60 : .infinity
        } else if phase.isFinal {
            interval = .infinity
        } else if phase == .landed {
            interval = 10 * 60
        } else if phase.hasDeparted {
            interval = 30 * 60
        } else if untilDeparture > 24 * 3600 {
            interval = 6 * 3600
        } else if untilDeparture > 3 * 3600 {
            interval = 60 * 60
        } else {
            interval = 15 * 60
        }
        // Battery saver stretches the routine checks, but not the baggage belt after landing.
        let stretch: Double = savingBattery && !phase.isFinal && phase != .landed ? 2 : 1
        return now.timeIntervalSince(last) >= interval * stretch
    }

    /// How often to look for the plane right now, or nil when there's no point yet. Busy moments
    /// (taxiing, landing) are checked often; cruising less; out of radar range or hours before departure, rarely.
    private func positionInterval(for flight: TrackedFlight, now: Date) -> TimeInterval? {
        let state = flight.state
        var interval: TimeInterval
        switch state.phase {
        case .arrived, .cancelled, .diverted:
            return nil
        case .taxiingOut, .landed:
            interval = 15
        case .descending:
            interval = 20
        case .climbing, .cruising:
            interval = state.positionIsEstimated == true ? 180 : 30
        case .boarding:
            interval = 30
        case .scheduled:
            guard let departure = state.departure.best else {
                interval = 120 // no departure time known: just watch for takeoff
                break
            }
            let untilDeparture = departure.timeIntervalSince(now)
            if untilDeparture > 6 * 3600 { return nil }
            interval = untilDeparture > 2 * 3600 ? 300 : untilDeparture > 45 * 60 ? 120 : 30
        }
        return savingBattery ? interval * 3 : interval
    }

    private func positionIsDue(_ flight: TrackedFlight, now: Date) -> Bool {
        guard positionInterval(for: flight, now: now) != nil else { return false }
        return now >= (nextPositionCheck[flight.id] ?? .distantPast)
    }

    /// Before departure, the assigned aircraft is usually still flying its previous trip.
    private func belongsToFlight(_ aircraft: LiveAircraft, _ flight: TrackedFlight, now: Date) -> Bool {
        if flight.state.phase.hasDeparted { return true }
        // Without a schedule the plane was looked up by our own callsign, so it always matches.
        let matches = flight.schedule == nil || (aircraft.callsign != nil && aircraft.callsign == flight.callsign)
        guard let departure = flight.state.departure.best else { return matches }
        // A same-numbered flight from yesterday could still be in the air hours before ours leaves.
        return matches && departure.timeIntervalSince(now) < 90 * 60
    }

    private func bestMatch(_ results: [ScheduledFlight], for flight: TrackedFlight) -> ScheduledFlight? {
        let origin = flight.attributes.origin?.code
        return results.first { $0.departure.airport.iata == origin || $0.departure.airport.icao == origin } ?? results.first
    }

    private func cachedRoute(for callsign: String?) async -> FlightRoute? {
        guard let callsign else { return nil }
        if let cached = routeCache[callsign] { return cached }
        guard let route = try? await FlightAPI.route(callsign: callsign) else { return nil }
        routeCache[callsign] = route
        return route
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = nil
        guard isInForeground, flights.contains(where: { !$0.state.phase.isFinal }) else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                try? await Task.sleep(for: self.nextWake())
            }
        }
    }

    /// Sleep until the next flight is due for a check, rather than waking on a fixed timer.
    private func nextWake() -> Duration {
        if flights.contains(where: { $0.isDemo && !$0.state.phase.isFinal }) { return .seconds(2) }
        let now = Date()
        let soonest = flights.compactMap { flight -> TimeInterval? in
            guard positionInterval(for: flight, now: now) != nil else { return nil }
            return (nextPositionCheck[flight.id] ?? now).timeIntervalSince(now)
        }.min()
        // Still wake at least once a minute for things that happen on the clock, like boarding time.
        let ceiling: TimeInterval = savingBattery ? 180 : 60
        return .seconds(min(max(soonest ?? ceiling, 5), ceiling))
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isInForeground = true
            liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
            restoreFromCalendar()
            syncAllToCalendar()
            startPolling()
            Task {
                await autoImportFromCalendar()
                _ = try? await importFromNotion()
            }
        case .inactive:
            // Still on screen, e.g. behind the notification permission prompt: Live Activities can start.
            isInForeground = true
            Task { await syncLiveActivities() }
        case .background:
            isInForeground = false
            pollTask?.cancel()
            pollTask = nil
            if hasUnsavedChanges { save() }
            scheduleBackgroundRefresh()
        default:
            break
        }
    }

    /// iOS decides when this actually runs, typically every 15+ minutes at best.
    func backgroundRefresh() async {
        await autoImportFromCalendar()
        _ = try? await importFromNotion()
        await refreshAll()
        scheduleBackgroundRefresh()
    }

    /// Asks iOS for a background refresh only as often as the next flight needs: rarely when it's days away.
    private func scheduleBackgroundRefresh() {
        let active = flights.filter { !$0.state.phase.isFinal && !$0.isDemo }
        guard !active.isEmpty else { return }
        let now = Date()
        let soonest = active.map { $0.state.phase.hasDeparted ? now : ($0.state.departure.best ?? now) }.min() ?? now
        let untilDeparture = soonest.timeIntervalSince(now)
        var delay: TimeInterval = untilDeparture > 24 * 3600 ? 3 * 3600 : untilDeparture > 6 * 3600 ? 3600 : 15 * 60
        if savingBattery { delay *= 2 }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = now.addingTimeInterval(delay)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Live Activities

    /// Starts Live Activities for flights leaving within three hours (like Flighty) and stops ones that were turned off.
    func syncLiveActivities(canStartInBackground: Bool = false) async {
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        guard liveActivitiesEnabled else { return }
        let canStart = isInForeground || canStartInBackground
        let now = Date()
        for flight in flights {
            let running = activities[flight.id]
            if let running, running.activityState == .dismissed || running.activityState == .ended {
                // Swiped away from the Lock Screen: respect that.
                activities[flight.id] = nil
                if var updated = self.flight(flight.id), !updated.state.phase.isFinal {
                    updated.showsLiveActivity = false
                    replace(updated)
                }
                continue
            }
            guard running == nil, canStart, flight.showsLiveActivity, !flight.state.phase.isFinal else { continue }
            let departure = flight.state.departure.best ?? now
            let soon = departure.timeIntervalSince(now) <= 3 * 3600
            guard soon || flight.startLiveActivityEarly || flight.state.phase.hasDeparted else { continue }
            do {
                var attributes = flight.attributes
                attributes.flightID = flight.id.uuidString // lets a tap open this flight or its boarding pass
                let activity = try Activity.request(
                    attributes: attributes,
                    content: content(for: flight),
                    pushType: nil
                )
                activities[flight.id] = activity
                pushedStates[flight.id] = flight.state
                lastActivityPush[flight.id] = now
                if var updated = self.flight(flight.id) {
                    updated.activityID = activity.id
                    replace(updated)
                    updateReminders(for: updated) // drops the "put it on your Lock Screen" nudge
                }
            } catch {
                lastError = "Couldn't start the Live Activity: \(error.localizedDescription)"
            }
        }
    }

    /// Pushes to the Live Activity. Small changes are held back (at most one per minute, three when saving
    /// battery) since the countdown and progress bar move on their own; anything you'd notice goes right away.
    private func updateActivity(for flight: TrackedFlight, alert event: FlightEvent?, significant: Bool = true) async {
        guard let activity = activities[flight.id] else { return }
        if flight.state.phase.isFinal {
            // Leave the final state on the Lock Screen for a while, then let iOS remove it.
            let linger: TimeInterval = flight.isDemo ? 5 * 60 : 30 * 60
            await activity.end(content(for: flight), dismissalPolicy: .after(.now.addingTimeInterval(linger)))
            activities[flight.id] = nil
            return
        }
        let now = Date()
        let minimumGap: TimeInterval = flight.isDemo ? 0 : savingBattery ? 180 : 60
        if !significant, event == nil, let last = lastActivityPush[flight.id], now.timeIntervalSince(last) < minimumGap {
            return
        }
        if pushedStates[flight.id] == flight.state, event == nil, let last = lastActivityPush[flight.id],
           now.timeIntervalSince(last) < staleAfter(for: flight) / 2 {
            return // identical to what's already showing
        }
        let alert = event.map { AlertConfiguration(title: "\($0.title)", body: "\($0.body)", sound: .default) }
        await activity.update(content(for: flight), alertConfiguration: alert)
        pushedStates[flight.id] = flight.state
        lastActivityPush[flight.id] = now
    }

    /// When nothing changed, only re-push occasionally so the card doesn't go stale.
    private func keepActivityFresh(for flight: TrackedFlight) async {
        guard activities[flight.id] != nil else { return }
        // No push yet since launch (e.g. a Live Activity restored after a relaunch): its stale date is unknown, so push.
        let last = lastActivityPush[flight.id] ?? .distantPast
        if Date().timeIntervalSince(last) >= staleAfter(for: flight) / 2 {
            await updateActivity(for: flight, alert: nil, significant: true)
        }
    }

    /// Before departure there's little to change, so the card stays fresh longer between pushes.
    private func staleAfter(for flight: TrackedFlight) -> TimeInterval {
        if flight.isDemo { return 60 }
        return flight.state.phase.hasDeparted ? 20 * 60 : 60 * 60
    }

    private func content(for flight: TrackedFlight) -> ActivityContent<State> {
        // Past the stale date the card says when the last update came in.
        ActivityContent(state: flight.state, staleDate: .now.addingTimeInterval(staleAfter(for: flight)))
    }

    /// Re-attaches to Live Activities that survived an app relaunch.
    func restoreActivities() {
        for activity in Activity<FlightActivityAttributes>.activities {
            if let flight = flights.first(where: { $0.activityID == activity.id }), !flight.state.phase.isFinal {
                activities[flight.id] = activity
            } else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
        }
    }

    // MARK: - Storage

    /// - Parameter persist: Write to disk now. Otherwise the change is kept in memory and written within
    ///   two minutes, or when the app goes to the background.
    private func replace(_ flight: TrackedFlight, persist: Bool = true) {
        guard let index = flights.firstIndex(where: { $0.id == flight.id }) else { return }
        flights[index] = flight
        if persist || Date().timeIntervalSince(lastSave) > 120 {
            save()
        } else {
            hasUnsavedChanges = true
        }
    }

    private static var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("flights.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? JSONDecoder().decode([TrackedFlight].self, from: data) else { return }
        flights = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(flights) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        lastSave = Date()
        hasUnsavedChanges = false
        SpotlightIndex.update(flights)
        WidgetSync.update(flights)
        #if DEBUG
        print("[battery] saved flights to disk")
        #endif
    }
}
