import AppIntents
import SwiftUI

struct SettingsView: View {
    /// Called with the demo flight's id after it's added.
    var onDemoAdded: (UUID) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var keyCheck: KeyCheckResult?
    @State private var checkingKey = false
    @State private var playlists: [LeaveMusic.Playlist] = []
    @State private var calendarInICloud = true

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Picker("Marketplace", selection: $settings.provider) {
                        ForEach(ScheduleProvider.allCases) { Text($0.title).tag($0) }
                    }
                    SecureField("API key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: settings.apiKey) { keyCheck = nil }
                        .onChange(of: settings.provider) { keyCheck = nil }
                    Button {
                        Task { await checkKey() }
                    } label: {
                        HStack {
                            Label("Check key", systemImage: "checkmark.shield")
                            Spacer()
                            if checkingKey { ProgressView() }
                        }
                    }
                    .disabled(settings.credentials == nil || checkingKey)
                    if let keyCheck {
                        Label(keyCheck.message, systemImage: keyCheck.works ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .font(.subheadline)
                            .foregroundStyle(keyCheck.works ? Color.flightGreen : Color.flightRed)
                    }
                    // Only while there's no key, or the key doesn't work: no need to sign up again.
                    if settings.credentials == nil || keyCheck?.works == false {
                        Link(destination: settings.provider.signUpURL) {
                            Label("Get a free AeroDataBox key", systemImage: "key.fill")
                        }
                    }
                } header: {
                    Text("Schedules, gates and delays")
                } footer: {
                    Text("AeroDataBox provides scheduled and estimated times, gates, terminals, baggage belts, cancellations and which plane is assigned. To stay within the free tier, FlightLive checks about every 15 minutes close to departure and less often otherwise. Live positions come from ADS-B and don't need a key.")
                }

                Section {
                    Toggle("Sync with iCloud Calendar", isOn: $settings.syncCalendar)
                        .onChange(of: settings.syncCalendar) { _, enabled in
                            guard enabled else { return }
                            Task {
                                if await CalendarImport.requestAccess() {
                                    store.restoreFromCalendar(force: true)
                                    store.syncAllToCalendar()
                                    calendarInICloud = CalendarSync.isInICloud
                                } else {
                                    settings.syncCalendar = false
                                }
                            }
                        }
                } header: {
                    Text("Your Apple ID")
                } footer: {
                    Text(settings.syncCalendar && !calendarInICloud
                         ? "Your FlightLive calendar is only on this iPhone. Turn on Calendars in Settings › your name › iCloud so it follows your Apple ID."
                         : "Keeps every flight, past and upcoming, in a FlightLive calendar in iCloud. A new iPhone or a reinstall gets them back on its own, and they show in Calendar on your Mac and iPad.")
                }

                Section {
                    NavigationLink {
                        NotionSettingsView()
                    } label: {
                        LabeledContent("Notion", value: settings.notionSourceID.isEmpty ? "Not set up" : settings.notionSourceTitle)
                    }
                } header: {
                    Text("Import from")
                } footer: {
                    Text("Keep your trips in a Notion database and FlightLive adds the flights on its own.")
                }

                Section {
                    Toggle("Battery Saver", isOn: $settings.batterySaver)
                } footer: {
                    Text(ProcessInfo.processInfo.isLowPowerModeEnabled
                         ? "Low Power Mode is on, so FlightLive is already checking less often."
                         : "Checks for updates about a third as often. Countdowns and progress bars still move smoothly, and gate changes, boarding and landing still come through, just a little later. Turns on by itself in Low Power Mode.")
                }

                Section("Units") {
                    Picker("Units", selection: $settings.units) {
                        ForEach(UnitSystem.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Toggle("Flight alerts", isOn: $settings.notificationsEnabled)
                        .onChange(of: settings.notificationsEnabled) { _, enabled in
                            if enabled { Task { _ = await FlightNotifications.requestAuthorization() } }
                        }
                    Toggle("Add flights from Calendar automatically", isOn: $settings.autoImportCalendar)
                        .onChange(of: settings.autoImportCalendar) { _, enabled in
                            guard enabled else { return }
                            Task {
                                if await CalendarImport.requestAccess() {
                                    await store.autoImportFromCalendar()
                                } else {
                                    settings.autoImportCalendar = false
                                }
                            }
                        }
                    if settings.notificationsEnabled {
                        Toggle("Check-in reminder", isOn: $settings.checkInReminder)
                    }
                } header: {
                    Text("Alerts & automatic reminders")
                } footer: {
                    Text("Alerts: gate changes, delays, boarding, takeoff, landing, arrival gate and baggage belt. Reminders go off on their own, even when FlightLive is closed: check-in opening 24 hours ahead, when to leave for the airport (with directions), a nudge 3 hours before departure to put the flight on your Lock Screen, and when boarding starts.")
                }

                Section {
                    Toggle("Time it from my location", isOn: $settings.leaveUsingLocation)
                        .onChange(of: settings.leaveUsingLocation) { _, enabled in
                            guard enabled else { return }
                            Task {
                                if await LocationProvider.shared.requestAuthorization() {
                                    await store.updateTravelTimes(force: true)
                                } else {
                                    settings.leaveUsingLocation = false
                                }
                            }
                        }
                    if settings.leaveUsingLocation {
                        Picker("Be at the airport", selection: $settings.arriveAtAirportMinutes) {
                            ForEach([45, 60, 90, 120, 150, 180, 240], id: \.self) { minutes in
                                Text("\(FlightPresentation.duration(minutes)) before").tag(minutes)
                            }
                        }
                    } else {
                        Picker("Leave for the airport", selection: $settings.leaveForAirportMinutes) {
                            Text("Off").tag(0)
                            ForEach([60, 90, 120, 150, 180, 240], id: \.self) { minutes in
                                Text("\(FlightPresentation.duration(minutes)) before").tag(minutes)
                            }
                        }
                    }
                    Picker("Music when you leave", selection: $settings.leaveMusic) {
                        Text("None").tag("")
                        Text("What I was listening to").tag(LeaveMusic.resume)
                        ForEach(playlists) { Text($0.name).tag($0.id) }
                        // Keep a playlist that's no longer in the library selectable, so the picker isn't blank.
                        if Int(settings.leaveMusic) != nil, !playlists.contains(where: { $0.id == settings.leaveMusic }) {
                            Text("A playlist").tag(settings.leaveMusic)
                        }
                    }
                    .onChange(of: settings.leaveMusic) { _, choice in
                        FlightNotifications.registerCategories()
                        guard !choice.isEmpty, !LeaveMusic.isAuthorized else { return }
                        Task {
                            if await LeaveMusic.requestAuthorization() {
                                playlists = LeaveMusic.playlists()
                            } else {
                                settings.leaveMusic = ""
                                FlightNotifications.registerCategories()
                            }
                        }
                    }
                } header: {
                    Text("Getting to the airport")
                } footer: {
                    Text(locationFooter)
                }

                Section {
                    SiriTipView(intent: FlightStatusIntent())
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach([
                            "When does my flight leave in FlightLive",
                            "Where's my plane in FlightLive",
                            "When does my flight land in FlightLive",
                            "Show my flight on the Lock Screen with FlightLive",
                            "Track a flight in FlightLive",
                            "Search for a flight in FlightLive",
                        ], id: \.self) { phrase in
                            Label("\u{201C}\(phrase)\u{201D}", systemImage: "waveform")
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                    ShortcutsLink()
                } header: {
                    Text("Siri & Shortcuts")
                } footer: {
                    Text("""
                    Say these to Siri; no setup needed.

                    Share to FlightLive: in Shortcuts, make a shortcut that receives Text from the Share Sheet and runs "Add or Update Flight from Text", then turn on Show in Share Sheet. Share → that shortcut then works from Mail, Gmail, Notion, Claude and Messages.

                    Airport texts: in Shortcuts › Automation, choose Message, pick the sender (e.g. BLR Airport or your airline), choose Run Immediately, and add "Add or Update Flight from Text" with the Message as its text. Gate changes, boarding, delays and belts then update your flight and Lock Screen on their own.
                    """)
                }

                Section {
                    Button {
                        Task {
                            let id = await store.addDemo()
                            dismiss()
                            onDemoAdded(id)
                        }
                    } label: {
                        Label("Watch a demo flight", systemImage: "play.circle.fill")
                    }
                } footer: {
                    Text("A made-up SFO → JFK flight fast-forwarded into five minutes: a delay, a gate change, the inbound plane, boarding, takeoff, landing and the baggage belt.")
                }

                Section("Data sources") {
                    LabeledContent("Live positions", value: "adsb.lol (ODbL)")
                    LabeledContent("Routes", value: "adsbdb.com")
                    LabeledContent("Schedules", value: "AeroDataBox")
                    LabeledContent("Weather", value: "Open-Meteo.com (CC BY 4.0)")
                    LabeledContent("Plane photos", value: "Wikimedia Commons")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                        store.refreshReminders()
                        Task { await store.refreshAll(force: keyCheck?.works == true) }
                    }
                }
            }
            .task {
                playlists = LeaveMusic.playlists()
                if settings.syncCalendar { calendarInICloud = CalendarSync.isInICloud }
                // Show straight away whether a saved key still works. The check is free.
                if settings.credentials != nil { await checkKey() }
            }
        }
    }

    private var locationFooter: String {
        if LocationProvider.shared.isDenied {
            return "FlightLive isn't allowed to use your location. You can allow it in Settings › FlightLive › Location."
        }
        if settings.leaveUsingLocation {
            return "On the day of your flight, FlightLive asks Apple Maps how long the drive to the airport takes from where you are, with traffic, and reminds you when to leave. Tap Go on the reminder to start your music and open Apple Maps directions. Your location is only checked while FlightLive is open or updating, and never leaves your phone except to ask Apple Maps for the route."
        }
        return "Turn on Time it from my location to get a leave time from Apple Maps with live traffic instead of a fixed time. Tap Go on the reminder to start your music and open Apple Maps directions."
    }

    private func checkKey() async {
        guard let credentials = settings.credentials else { return }
        checkingKey = true
        keyCheck = await AeroDataBox.checkKey(credentials)
        checkingKey = false
    }
}
