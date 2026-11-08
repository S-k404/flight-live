import CoreSpotlight
import SwiftUI

struct FlightsListView: View {
    @Environment(FlightStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var path: [UUID] = []
    @State private var addFlight: AddFlightRoute?
    @State private var showingSettings = false
    @State private var passToShow: BoardingPassRoute?
    @State private var showingPassport = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.flights.isEmpty {
                    EmptyFlightsView(
                        onAdd: { addFlight = AddFlightRoute() },
                        onDemo: { Task { path = [await store.addDemo()] } },
                        onPassport: { showingPassport = true }
                    )
                    .cardRow()
                } else {
                    if let error = store.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.flightAmber)
                            .cardRow()
                    }
                    if !store.upcoming.isEmpty {
                        SectionTitle(text: "Upcoming")
                            .cardRow()
                        ForEach(store.upcoming) { flight in
                            flightRow(flight)
                            if let connection = store.connection(after: flight) {
                                ConnectionRow(connection: connection)
                                    .cardRow()
                            }
                        }
                    }
                    let past = store.past
                    if !past.isEmpty {
                        HStack(alignment: .firstTextBaseline) {
                            SectionTitle(text: "Past")
                            Spacer()
                            if past.count > 3 {
                                Button("See All \(past.count)") { showingPassport = true }
                                    .font(.subheadline.weight(.semibold))
                                    .buttonStyle(.borderless)
                            }
                        }
                        .cardRow()
                        // The rest live in the Passport, so the list stays about what's coming up.
                        ForEach(past.prefix(3)) { flight in
                            flightRow(flight)
                        }
                    }
                    Button {
                        showingPassport = true
                    } label: {
                        PassportTeaser(stats: PassportStats(store.flights.filter(\.isFlown)), units: settings.units)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .cardRow()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("My Flights")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        addFlight = AddFlightRoute()
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                FlightDetailView(flightID: id)
            }
            .refreshable {
                await store.refreshAll(force: true)
            }
            .sheet(item: $addFlight) { route in
                AddFlightView(onAdded: { id in path = [id] }, initialQuery: route.query, searchesInitialQuery: route.searchesNow)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView { id in path = [id] }
            }
            .sheet(isPresented: $showingPassport) {
                PassportView()
            }
            .fullScreenCover(item: $passToShow) { route in
                if let flight = store.flight(route.id) {
                    BoardingPassViewer(flight: flight)
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: store.flights.count)
            .onOpenURL(perform: open)
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                // Tapped in iPhone search.
                if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                   let url = URL(string: "flightlive://flight/\(id)") {
                    open(url)
                }
            }
            .task {
                SpotlightIndex.update(store.flights)
                WidgetSync.update(store.flights)
            }
            .onChange(of: store.pendingSearch, initial: true) { _, query in
                // "Search for a flight in FlightLive" from Siri.
                guard let query else { return }
                store.pendingSearch = nil
                showingSettings = false
                addFlight = AddFlightRoute(query: query)
            }
            #if DEBUG
            .task {
                // For testing: `simctl launch … -openURL flightlive://flight/<id>` opens a flight without the "Open in" prompt.
                if let link = UserDefaults.standard.string(forKey: "openURL"), let url = URL(string: link) {
                    try? await Task.sleep(for: .milliseconds(800))
                    open(url)
                }
                // For testing: `simctl launch … -searchQuery "AI 101"` opens Add Flight and searches.
                if let query = UserDefaults.standard.string(forKey: "searchQuery") {
                    try? await Task.sleep(for: .milliseconds(800)) // let the window appear before presenting a sheet
                    open(URL(string: "flightlive://search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")!)
                }
            }
            #endif
        }
    }

    /// Taps on the Live Activity: flightlive://flight/<id> or flightlive://pass/<id>. Also flightlive://demo and flightlive://passport.
    private func open(_ url: URL) {
        guard url.scheme == "flightlive" else { return }
        if url.host == "passport" {
            addFlight = nil
            showingSettings = false
            showingPassport = true
            return
        }
        if url.host == "demo" {
            Task { path = [await store.addDemo()] }
            return
        }
        if url.host == "search" {
            // flightlive://search?q=UA930
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            showingSettings = false
            showingPassport = false
            addFlight = AddFlightRoute(query: items.first { $0.name == "q" }?.value,
                                       searchesNow: items.first { $0.name == "go" }?.value != "0")
            return
        }
        guard let id = UUID(uuidString: url.lastPathComponent),
              let flight = store.flight(id) else { return }
        addFlight = nil
        showingSettings = false
        showingPassport = false
        path = [id]
        if url.host == "pass", flight.hasBoardingPass == true {
            passToShow = BoardingPassRoute(id: id)
        }
    }

    /// A flight card: tap to open, swipe left or press and hold to remove.
    private func flightRow(_ flight: TrackedFlight) -> some View {
        Button {
            path.append(flight.id)
        } label: {
            FlightRow(flight: flight)
        }
        .buttonStyle(.plain)
        .cardRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                Task { await store.remove(flight.id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            ShareLink(item: flight.shareText) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Task { await store.remove(flight.id) }
            } label: {
                Label("Remove Flight", systemImage: "trash")
            }
        }
    }
}

private extension View {
    /// A list row that looks like a free-floating card on the black background.
    func cardRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

private struct SectionTitle: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .padding(.top, 8)
    }
}

/// One flight on the list: route, times, status and what's next.
struct FlightRow: View {
    var flight: TrackedFlight

    var body: some View {
        let attributes = flight.attributes
        let state = flight.state
        let presentation = FlightPresentation(attributes: attributes, state: state)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AirlineBadge(code: attributes.airlineCode, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(attributes.flightNumber)
                        .font(.system(size: 15, weight: .bold))
                    if let date = state.departure.scheduled ?? state.departure.best {
                        Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                                             timeZone: attributes.origin?.timeZone ?? .current)))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                if flight.isDemo {
                    Text("DEMO")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(presentation.statusText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
            }

            if let origin = attributes.origin, let destination = attributes.destination {
                let muted = state.phase == .cancelled
                HStack(spacing: 10) {
                    EndpointLabel(airport: origin, movement: state.departure, alignment: .leading, muted: muted)
                    RouteProgressBar(progress: state.planeProgress, tint: presentation.tone.color, interval: state.flightInterval)
                    EndpointLabel(airport: destination, movement: state.arrival, alignment: .trailing, muted: muted)
                }
            }

            HStack(spacing: 6) {
                if !state.phase.isFinal, let target = presentation.countdownTarget, target > .now {
                    // The card already shows the status, so just "Departs in" / "Arrives in" here.
                    Text(presentation.countdownLabel.replacingOccurrences(of: "Boarding · d", with: "D"))
                        .lineLimit(1)
                        .fixedSize()
                    Text(timerInterval: Date.now...target, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                    Text("·")
                }
                Text(presentation.detail)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let chip = presentation.chip, !state.phase.isFinal {
                    GateChip(chip: chip, compact: true)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .contentShape(Rectangle())
    }
}

private struct EmptyFlightsView: View {
    var onAdd: () -> Void
    var onDemo: () -> Void
    var onPassport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.flightBlue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 104, height: 104)
                Image(systemName: "airplane")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(-30))
            }
            .padding(.top, 60)
            Text("No flights yet")
                .font(.title2.weight(.bold))
            Text("Add a flight by its number or a plane by its tail number. It shows up on your Lock Screen and in the Dynamic Island three hours before departure.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onAdd) {
                Label("Add a flight", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            Button(action: onDemo) {
                Label("Watch a 5-minute demo flight", systemImage: "play.circle.fill")
            }
            .buttonStyle(.bordered)
            Button(action: onPassport) {
                Label("Import flights you've taken", systemImage: "person.text.rectangle")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }
}

/// The way into the Passport, with the all-time totals.
private struct PassportTeaser: View {
    var stats: PassportStats
    var units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("PASSPORT", systemImage: "person.text.rectangle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if stats.flights == 0 {
                Text("Import the flights you've taken to see your stats, routes and favorite plane.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                HStack {
                    MiniStat(label: "FLIGHTS", value: "\(stats.flights)")
                    Spacer()
                    MiniStat(label: "DISTANCE", value: stats.distance(units))
                    Spacer()
                    MiniStat(label: "IN THE AIR", value: FlightPresentation.duration(stats.minutes), alignment: .trailing)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.05, blue: 0.33), Color(red: 0.15, green: 0.30, blue: 0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
    }
}

/// Opens Add Flight, optionally searching for something straight away.
struct AddFlightRoute: Identifiable {
    let id = UUID()
    var query: String?
    var searchesNow = true
}
