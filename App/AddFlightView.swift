import SwiftUI

struct AddFlightView: View {
    /// Called with the new flight's id after it's added.
    var onAdded: (UUID) -> Void
    /// Search for this straight away, e.g. from Siri or a flightlive://search link.
    var initialQuery: String? = nil
    /// False to only fill the field in, e.g. flightlive://search?q=BLR%20to%20&go=0.
    var searchesInitialQuery = true

    @Environment(FlightStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var day: SearchDay = .today
    @State private var otherDate = Date()
    @State private var results: [FlightCandidate] = []
    @State private var searching = false
    @State private var errorMessage: String?
    @State private var calendarFlights: [CalendarFlight] = []
    @State private var calendarChecked = false
    @State private var addingFromCalendar: String?
    @State private var importingText = false
    @State private var importMessage: String?
    /// Set when the results are a route's flights: "BLR → RPR".
    @State private var routeTitle: String?
    @AppStorage("recentSearches") private var recentSearchesStorage = ""
    @FocusState private var fieldFocused: Bool

    private var recentSearches: [String] {
        recentSearchesStorage.split(separator: ",").map(String.init)
    }

    private func remember(_ query: String) {
        let normalized = query.uppercased()
        let updated = [normalized] + recentSearches.filter { $0 != normalized }
        recentSearchesStorage = updated.prefix(6).joined(separator: ",")
    }

    enum SearchDay: String, CaseIterable, Identifiable {
        case yesterday = "Yesterday", today = "Today", tomorrow = "Tomorrow", other = "Other"
        var id: Self { self }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedDate: Date {
        let calendar = Calendar.current
        switch day {
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: .now) ?? .now
        case .today: return .now
        case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
        case .other: return otherDate
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Flight, route or tail number", text: $query, prompt: Text("6E 978, BLR to RPR, N172SP"))
                        .font(.title3.weight(.semibold))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($fieldFocused)
                        .onSubmit(search)
                        .onChange(of: query) {
                            // Typing again: put the suggestions back instead of the last results.
                            if !searching { results = []; routeTitle = nil; errorMessage = nil }
                        }
                    if fieldFocused, results.isEmpty, !searching {
                        ForEach(suggestions) { suggestion in
                            Button {
                                query = suggestion.fill
                                if suggestion.searchesNow { search() }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: suggestion.symbol)
                                        .foregroundStyle(Color.flightBlue)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(suggestion.title)
                                            .foregroundStyle(.primary)
                                        if let subtitle = suggestion.subtitle {
                                            Text(subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: suggestion.searchesNow ? "magnifyingglass" : "arrow.up.left")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if trimmedQuery.isEmpty && !recentSearches.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentSearches, id: \.self) { recent in
                                    Button {
                                        query = recent
                                        search()
                                    } label: {
                                        Label(recent, systemImage: "clock.arrow.circlepath")
                                            .font(.subheadline.weight(.semibold))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    if settings.credentials != nil {
                        Picker("Day", selection: $day) {
                            ForEach(SearchDay.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if day == .other {
                            DatePicker("Date", selection: $otherDate, displayedComponents: .date)
                        }
                    }
                } footer: {
                    if settings.credentials == nil {
                        Text("Without a schedule key, FlightLive can only find planes that are in the air right now. Add a free AeroDataBox key in Settings to add future flights and get gates, delays and baggage belts.")
                    }
                }

                Section {
                    Button(action: search) {
                        HStack {
                            Text(searching ? "Searching…" : "Search")
                                .font(.headline)
                            Spacer()
                            if searching { ProgressView() }
                        }
                    }
                    .disabled(trimmedQuery.isEmpty || searching)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.flightAmber)
                    }
                }

                if !results.isEmpty {
                    Section(routeTitle.map { "\(results.count) flight\(results.count == 1 ? "" : "s") · \($0)" }
                            ?? (results.count == 1 ? "Found it" : "Pick your flight")) {
                        ForEach(results) { candidate in
                            Button {
                                add(candidate)
                            } label: {
                                CandidateRow(candidate: candidate)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            importText(strings.joined(separator: "\n"))
                        }
                        .disabled(importingText)
                        Spacer()
                        if importingText { ProgressView() }
                    }
                    if let importMessage {
                        Text(importMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("From an email or message")
                } footer: {
                    Text("Copy a booking email, an airport text, or a note from Notion or Claude, then tap Paste. FlightLive finds the flight number, time, gate, seat and booking code.")
                }

                calendarSection
            }
            .navigationTitle("Add Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if let initialQuery, !initialQuery.isEmpty, query.isEmpty {
                    query = initialQuery
                    if searchesInitialQuery { search() } else { fieldFocused = true }
                } else {
                    fieldFocused = true
                }
                if CalendarImport.isAuthorized { loadCalendarFlights() }
            }
        }
    }

    /// Flights found in calendar events, e.g. added by Gmail or Apple Mail from booking emails.
    @ViewBuilder
    private var calendarSection: some View {
        Section {
            if !CalendarImport.isAuthorized && !calendarChecked {
                Button {
                    Task {
                        _ = await CalendarImport.requestAccess()
                        loadCalendarFlights()
                    }
                } label: {
                    Label("Find my flights in Calendar", systemImage: "calendar.badge.plus")
                }
            } else if calendarFlights.isEmpty {
                Text(CalendarImport.isAuthorized
                     ? "No new flights in your calendar for the next 30 days."
                     : "FlightLive doesn't have access to your calendar. You can allow it in Settings › FlightLive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(calendarFlights) { found in
                    Button {
                        addFromCalendar(found)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(found.displayNumber)
                                    .font(.headline)
                                Text(found.departure.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(found.eventTitle)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if addingFromCalendar == found.id {
                                ProgressView()
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.flightBlue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(addingFromCalendar != nil)
                }
            }
        } header: {
            Text("From your Calendar")
        } footer: {
            Text("Gmail and Apple Mail usually put flights from booking emails in your calendar, with departure and arrival times. No API key needed.")
        }
    }

    private func importText(_ text: String) {
        importingText = true
        importMessage = nil
        Task {
            let result = await store.importText(text)
            importingText = false
            if let id = result.flightID {
                dismiss()
                onAdded(id)
            } else {
                importMessage = result.message
            }
        }
    }

    private func loadCalendarFlights() {
        calendarFlights = store.newCalendarFlights()
        calendarChecked = true
    }

    private func addFromCalendar(_ found: CalendarFlight) {
        addingFromCalendar = found.id
        errorMessage = nil
        Task {
            if let id = await store.addFromCalendar(found) {
                dismiss()
                onAdded(id)
            } else {
                errorMessage = "Couldn't find the route for \(found.displayNumber). Search for it above instead."
            }
            addingFromCalendar = nil
        }
    }

    private var knownAirports: [FlightActivityAttributes.Airport] {
        store.flights.flatMap { [$0.attributes.origin, $0.attributes.destination].compactMap { $0 } }
    }

    private var suggestions: [SearchSuggestion] {
        SearchSuggestions.make(for: query, recent: recentSearches, flights: store.flights)
    }

    private func search() {
        guard !trimmedQuery.isEmpty, !searching else { return }
        fieldFocused = false
        searching = true
        errorMessage = nil
        results = []
        routeTitle = nil
        let query = trimmedQuery
        let date = selectedDate
        let credentials = settings.credentials
        let extra = knownAirports.map { KnownAirports.Airport(code: $0.code, city: $0.city) }
        Task {
            do {
                if let route = RouteQuery.parse(query, extra: extra) {
                    guard let credentials else {
                        throw FlightLookup.NotFound(query: query, hasSchedules: false, isRoute: true)
                    }
                    let found = try await FlightLookup.searchRoute(from: route.from, to: route.to, date: date,
                                                                    credentials: credentials, knownAirports: knownAirports)
                    routeTitle = "\(route.from) → \(route.to)"
                    results = found
                    remember("\(route.from) to \(route.to)")
                } else {
                    results = try await FlightLookup.search(query, date: date, credentials: credentials)
                    remember(query)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            searching = false
        }
    }

    private func add(_ candidate: FlightCandidate) {
        Task {
            let id = await store.add(candidate)
            dismiss()
            onAdded(id)
        }
    }
}

private struct CandidateRow: View {
    var candidate: FlightCandidate

    var body: some View {
        let attributes = candidate.attributes
        let presentation = FlightPresentation(attributes: attributes, state: candidate.state)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AirlineBadge(code: attributes.airlineCode, size: 22)
                Text(attributes.flightNumber)
                    .font(.headline)
                if let airline = attributes.airline {
                    Text(airline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(presentation.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(presentation.tone.color)
            }
            if let origin = attributes.origin, let destination = attributes.destination {
                HStack(spacing: 10) {
                    EndpointLabel(airport: origin, movement: candidate.state.departure, alignment: .leading)
                    RouteProgressBar(progress: candidate.state.displayProgress, tint: presentation.tone.color)
                    EndpointLabel(airport: destination, movement: candidate.state.arrival, alignment: .trailing)
                }
                .padding(10)
                .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let aircraft = attributes.aircraft {
                Text("\(aircraft) · no filed route")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Label("Add to My Flights", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.flightBlue)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
