import SwiftUI
import WidgetKit
import UserNotifications

@main
struct FlightLiveApp: App {
    @State private var store = FlightStore.shared
    @State private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        FlightNotifications.registerCategories()
    }

    var body: some Scene {
        WindowGroup {
            FlightsListView()
                .environment(store)
                .environment(settings)
                .preferredColorScheme(.dark)
                .task {
                    store.restoreActivities()
                    #if DEBUG
                    // For testing: `simctl launch … -startDemo` starts the demo flight without tapping.
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("-startDemo") {
                        _ = await store.addDemo()
                    }
                    // `-importText "<message>"` runs the same path as the Share Sheet / Messages automation.
                    if let index = arguments.firstIndex(of: "-importText"), index + 1 < arguments.count {
                        let result = await store.importText(arguments[index + 1])
                        print("importText:", result.message)
                    }
                    // `-addPast "6E978 2026-11-07"` runs Add Flight's fallback for a flight on a day that has passed.
                    if let index = arguments.firstIndex(of: "-addPast"), index + 1 < arguments.count {
                        let parts = arguments[index + 1].split(separator: " ").map(String.init)
                        let formatter = DateFormatter()
                        formatter.locale = Locale(identifier: "en_US_POSIX")
                        formatter.dateFormat = "yyyy-MM-dd"
                        if parts.count == 2, let day = formatter.date(from: parts[1]) {
                            let started = Date()
                            if let candidate = await FlightLookup.pastCandidate(parts[0], date: day.addingTimeInterval(12 * 3600), knownAirports: []) {
                                let id = await store.add(candidate)
                                let flight = store.flight(id)
                                print("addPast:", flight?.attributes.flightNumber ?? "-", flight?.attributes.origin?.code ?? "?", "to",
                                      flight?.attributes.destination?.code ?? "?", flight?.state.phase.rawValue ?? "-",
                                      flight?.state.departure.best.map { "\($0)" } ?? "-", "inPast:", store.past.contains { $0.id == id },
                                      String(format: "%.2fs", Date().timeIntervalSince(started)))
                            } else {
                                print("addPast: no usual route known for", parts[0])
                            }
                        }
                    }
                    // `-checkPastPhase` checks that a flight long past its arrival moves on from "scheduled".
                    if arguments.contains("-checkPastPhase") {
                        func phase(departingInHours hours: Double) -> FlightPhase {
                            var state = FlightActivityAttributes.ContentState(phase: .scheduled, updatedAt: .now)
                            state.departure.scheduled = .now.addingTimeInterval(hours * 3600)
                            state.arrival.scheduled = .now.addingTimeInterval((hours + 3) * 3600)
                            var memory = TrackingMemory()
                            return FlightMath.nextState(attributes: FlightActivityAttributes(flightNumber: "6E 978"), previous: state,
                                                        schedule: nil, aircraft: nil, lookedForAircraft: false, memory: &memory).phase
                        }
                        print("checkPastPhase: yesterday", phase(departingInHours: -26).rawValue, "| 1h ago", phase(departingInHours: -1).rawValue,
                              "| 4h ago", phase(departingInHours: -4).rawValue, "| tomorrow", phase(departingInHours: 20).rawValue)
                    }
                    // `-importCSV <file in Documents>` runs the Flighty import without the file picker.
                    if let index = arguments.firstIndex(of: "-importCSV"), index + 1 < arguments.count,
                       let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                       let text = try? String(contentsOf: folder.appendingPathComponent(arguments[index + 1]), encoding: .utf8) {
                        let known = store.flights.flatMap { [$0.attributes.origin, $0.attributes.destination].compactMap { $0 } }
                        var built: [TrackedFlight] = []
                        for record in PastFlightImport.records(fromCSV: text) {
                            if let flight = await PastFlightImport.flight(from: record, knownAirports: known, credentials: settings.credentials) {
                                built.append(flight)
                            } else {
                                print("importCSV: couldn't build", record.flightNumber)
                            }
                        }
                        print("importCSV: added", store.addPastFlights(built), "of", built.count)
                    }
                    // `-probeSchedule 6E978 2026-10-25` asks AeroDataBox about one flight and prints the reply.
                    if let index = arguments.firstIndex(of: "-probeSchedule"), index + 2 < arguments.count, let credentials = settings.credentials {
                        do {
                            let found = try await AeroDataBox.flights(number: arguments[index + 1], date: arguments[index + 2], credentials: credentials)
                            print("probeSchedule:", found.count, "flights", found.map { "\($0.departure.airport.iata ?? "?")→\($0.arrival.airport.iata ?? "?") \($0.aircraftDescription ?? "-")" })
                        } catch {
                            print("probeSchedule error:", error)
                        }
                    }
                    // `-probeRoute BLR RPR` lists today's flights on a route and prints them.
                    if let index = arguments.firstIndex(of: "-probeRoute"), index + 2 < arguments.count, let credentials = settings.credentials {
                        do {
                            let found = try await FlightLookup.searchRoute(from: arguments[index + 1], to: arguments[index + 2], date: .now,
                                                                           credentials: credentials, knownAirports: [])
                            print("probeRoute:", found.count, "flights", found.map { "\($0.attributes.flightNumber) \($0.attributes.aircraft ?? "-")" })
                        } catch {
                            print("probeRoute error:", error)
                        }
                    }
                    // `-fillInPastFlights` runs the Passport's "Find the planes and times" button.
                    if arguments.contains("-fillInPastFlights") {
                        let result = await store.fillInPastFlights()
                        print("fillInPastFlights:", result.filled, "filled,", result.notFound, "not found,", result.failed, "failed")
                    }
                    // `-saveWidgetPreviews` draws the widget at its Home Screen sizes, for checking the layout.
                    if arguments.contains("-saveWidgetPreviews"),
                       let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        let flight = WidgetSnapshot.load()?.flights.first ?? .sample
                        for (name, family, size) in [("small", WidgetFamily.systemSmall, CGSize(width: 170, height: 170)),
                                                     ("medium", .systemMedium, CGSize(width: 364, height: 170))] {
                            let view = NextFlightWidgetView(flight: flight, family: family)
                                .padding(16)
                                .frame(width: size.width, height: size.height)
                                .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .environment(\.colorScheme, .dark)
                            let renderer = ImageRenderer(content: view)
                            renderer.scale = 3
                            try? renderer.uiImage?.pngData()?.write(to: folder.appendingPathComponent("widget-\(name).png"))
                        }
                    }
                    // `-notionSample <file in Documents>`: a saved Notion query response, run through the real import.
                    if let index = arguments.firstIndex(of: "-notionSample"), index + 1 < arguments.count,
                       let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                       let data = try? Data(contentsOf: folder.appendingPathComponent(arguments[index + 1])),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let entries = (json["results"] as? [[String: Any]] ?? []).compactMap(NotionImport.flight(fromPage:))
                        for entry in entries {
                            print("notionSample:", entry.flightNumber, entry.departure.map { "\($0)" } ?? entry.day ?? "-",
                                  entry.from ?? "-", entry.to ?? "-", entry.seat ?? "-", entry.confirmationCode ?? "-")
                        }
                        let result = await store.importNotionEntries(entries, notify: false)
                        print("notionSample: added", result.added, "already", result.alreadyHere, "not found", result.notFound)
                    }
                    #endif
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    store.scenePhaseChanged(phase)
                }
        }
        .backgroundTask(.appRefresh(FlightStore.refreshTaskID)) {
            await FlightStore.shared.backgroundRefresh()
        }
    }
}
