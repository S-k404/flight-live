import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// Everywhere you've flown: a map of your routes, shareable stats cards and every past flight.
struct PassportView: View {
    @Environment(FlightStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    /// Nil for all time.
    @State private var year: Int?
    @State private var sort: HistorySort = .date
    @State private var choosingFile = false
    @State private var importing = false
    @State private var importMessage: String?
    /// A real photo for the most flown aircraft card.
    @State private var aircraftPhoto: LoadedPhoto?

    struct LoadedPhoto {
        var photo: AircraftPhoto
        var image: UIImage
    }

    private var flown: [TrackedFlight] { store.flights.filter(\.isFlown) }

    private var shown: [TrackedFlight] {
        guard let year else { return flown }
        return flown.filter { $0.passportYear == year }
    }

    private var years: [Int] {
        Array(Set(flown.compactMap(\.passportYear))).sorted(by: >)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    RoutesMap(flights: shown)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                    if !years.isEmpty {
                        YearChips(years: years, selection: $year)
                    }

                    if shown.isEmpty {
                        emptyState
                    } else {
                        let stats = PassportStats(shown)
                        let key = "\(year ?? 0)-\(shown.count)-\(settings.units.rawValue)"
                        ShareableCard(key: key) {
                            PassportCard(stats: stats, title: "\(year.map(String.init) ?? "All-Time") FlightLive Passport", units: settings.units)
                        }
                        ShareableCard(key: key) {
                            DelayCard(stats: stats)
                        }
                        if let aircraft = stats.topAircraft {
                            ShareableCard(key: key + (aircraftPhoto == nil ? "" : "-photo"), iconColor: Color(red: 0.1, green: 0.12, blue: 0.35)) {
                                AircraftCard(favorite: aircraft, photo: aircraftPhoto)
                            }
                            .task(id: aircraft.title) { await loadPhoto(model: aircraft.title) }
                        }
                        ShareableCard(key: key) {
                            FavoritesCard(stats: stats)
                        }
                        HistorySection(flights: shown, sort: $sort, units: settings.units)
                    }

                    importCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.black)
            .navigationTitle("Passport")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                FlightDetailView(flightID: id)
            }
            .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .plainText, .text]) { result in
                guard case .success(let url) = result else { return }
                importFile(url)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe.asia.australia.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.flightBlue)
            Text("No flights here yet")
                .font(.title3.weight(.bold))
            Text("Flights you've taken show up here with your stats. Import the ones you've already flown below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("IMPORT & EXPORT")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Button {
                choosingFile = true
            } label: {
                Label("Import from Flighty", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            Button {
                importFromCalendar()
            } label: {
                Label("Find past flights in Calendar", systemImage: "calendar")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            if !settings.notionSourceID.isEmpty {
                Button {
                    importFromNotion()
                } label: {
                    Label("Import from Notion", systemImage: "tablecells")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            let missing = store.pastFlightsMissingPlanes.count
            if missing > 0, settings.credentials != nil {
                Button {
                    fillInPlanes()
                } label: {
                    Label("Find the planes and times for \(missing) flight\(missing == 1 ? "" : "s")", systemImage: "airplane.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                Text("Which plane flew it, its tail number and photo, and the real gate times. Uses \(missing) of your AeroDataBox requests.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            if importing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Looking up airports and airlines…")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if let importMessage {
                Text(importMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !store.flights.filter({ !$0.isDemo }).isEmpty {
                ShareLink(item: FlightsCSV(flights: store.flights),
                          preview: SharePreview("FlightLive flights.csv", image: Image(systemName: "tablecells"))) {
                    Label("Export all flights (CSV)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
            Text("In Flighty, export your flights as a CSV file, then choose that file here. Calendar finds flights from booking emails over the past two years. Exporting makes the same kind of file, as a backup or for other apps.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
        }
        .disabled(importing)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func importFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            importMessage = "Couldn't read that file."
            return
        }
        let records = PastFlightImport.records(fromCSV: text)
        guard !records.isEmpty else {
            importMessage = "No flights found in that file. Choose the CSV file Flighty exports."
            return
        }
        importRecords(records)
    }

    private func importFromCalendar() {
        Task {
            guard await CalendarImport.requestAccess() else {
                importMessage = "FlightLive doesn't have access to your calendar. You can allow it in Settings › FlightLive."
                return
            }
            let records = PastFlightImport.calendarRecords()
            guard !records.isEmpty else {
                importMessage = "No past flights found in your calendar."
                return
            }
            importRecords(records)
        }
    }

    /// One of your own planes of that type if someone has photographed it, else the type from Wikipedia.
    private func loadPhoto(model: String) async {
        let registration = shown.first { $0.aircraftModel == model && $0.registration != nil }?.registration
        guard let photo = await AircraftPhotos.photo(registration: registration, model: model),
              let image = await AircraftPhotos.image(for: photo) else { return }
        aircraftPhoto = LoadedPhoto(photo: photo, image: image)
    }

    private func fillInPlanes() {
        importing = true
        importMessage = nil
        Task {
            let result = await store.fillInPastFlights()
            var parts = ["Found the plane for \(result.filled) flight\(result.filled == 1 ? "" : "s")."]
            if result.notFound > 0 { parts.append("AeroDataBox has no record of \(result.notFound).") }
            if result.failed > 0 { parts.append("Couldn't reach AeroDataBox for \(result.failed); tap again to retry.") }
            if result.quotaUsedUp { parts.append("This month's AeroDataBox requests are used up; the rest will work after it resets.") }
            importMessage = parts.joined(separator: " ")
            importing = false
        }
    }

    private func importFromNotion() {
        importing = true
        importMessage = nil
        Task {
            do {
                let result = try await store.importFromNotion(force: true)
                importMessage = "Added \(result.added) flight\(result.added == 1 ? "" : "s") from Notion."
            } catch {
                importMessage = error.localizedDescription
            }
            importing = false
        }
    }

    private func importRecords(_ records: [PastFlightRecord]) {
        importing = true
        importMessage = nil
        Task {
            let known = store.flights.flatMap { [$0.attributes.origin, $0.attributes.destination].compactMap { $0 } }
            var built: [TrackedFlight] = []
            var missing = 0
            for record in records {
                if let flight = await PastFlightImport.flight(from: record, knownAirports: known, credentials: settings.credentials,
                                                              lookUpDetails: records.count <= 5) {
                    built.append(flight)
                } else {
                    missing += 1
                }
            }
            let added = store.addPastFlights(built)
            let already = built.count - added
            var parts = ["Added \(added) flight\(added == 1 ? "" : "s")."]
            if already > 0 { parts.append("\(already) \(already == 1 ? "was" : "were") already here.") }
            if missing > 0 { parts.append("Couldn't find the airports for \(missing).") }
            if records.count > 5, settings.credentials != nil, !store.pastFlightsMissingPlanes.isEmpty {
                parts.append("Tap “Find the planes and times” to fill in the aircraft.")
            }
            importMessage = parts.joined(separator: " ")
            importing = false
        }
    }
}

// MARK: - Map

private struct RoutesMap: View {
    var flights: [TrackedFlight]

    private struct Route: Hashable {
        var from: FlightActivityAttributes.Airport
        var to: FlightActivityAttributes.Airport
    }

    private var routes: [Route] {
        var seen = Set<String>()
        return flights.compactMap { flight in
            guard let from = flight.attributes.origin, let to = flight.attributes.destination else { return nil }
            // One line per pair of airports, whichever way.
            let key = [from.code, to.code].sorted().joined()
            return seen.insert(key).inserted ? Route(from: from, to: to) : nil
        }
    }

    private var airports: [FlightActivityAttributes.Airport] {
        var seen = Set<String>()
        return routes.flatMap { [$0.from, $0.to] }.filter { seen.insert($0.code).inserted }
    }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(routes, id: \.self) { route in
                MapPolyline(coordinates: [route.from.coordinate, route.to.coordinate], contourStyle: .geodesic)
                    .stroke(Color.white.opacity(0.75), lineWidth: 1.5)
            }
            ForEach(airports, id: \.code) { airport in
                Annotation(airport.code, coordinate: airport.coordinate, anchor: .center) {
                    Circle()
                        .fill(Color.flightBlue)
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                }
            }
        }
        .mapStyle(.hybrid(elevation: .flat, pointsOfInterest: .excludingAll))
        .id(routes.count) // re-fit when the year changes
    }
}

private struct YearChips: View {
    var years: [Int]
    @Binding var selection: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All-Time", value: nil)
                ForEach(years, id: \.self) { chip(String($0), value: $0) }
            }
        }
    }

    private func chip(_ title: String, value: Int?) -> some View {
        Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(selection == value ? Color.white.opacity(0.18) : .clear, in: Capsule())
                .foregroundStyle(selection == value ? .white : .white.opacity(0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cards

/// A card with a share button that shares it as a picture.
private struct ShareableCard<Content: View>: View {
    /// Re-renders the picture when this changes.
    var key: String
    var iconColor: Color = .white
    @ViewBuilder var content: Content
    @State private var image: Image?

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if let image {
                    ShareLink(item: image, preview: SharePreview("My FlightLive Passport", image: image)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(iconColor.opacity(0.9))
                            .padding(18)
                    }
                }
            }
            .task(id: key) { render() }
    }

    @MainActor
    private func render() {
        let picture = VStack(spacing: 10) {
            content
            Label("FlightLive", systemImage: "airplane")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        .frame(width: 400)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: picture)
        renderer.scale = 3
        if let uiImage = renderer.uiImage {
            image = Image(uiImage: uiImage)
            #if DEBUG
            // For checking the shared pictures from the Simulator.
            if ProcessInfo.processInfo.arguments.contains("-saveShareCards"),
               let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? uiImage.pngData()?.write(to: folder.appendingPathComponent("card-\(abs(key.hashValue ^ "\(Content.self)".hashValue)).png"))
            }
            #endif
        }
    }
}

private struct PassportCard: View {
    var stats: PassportStats
    var title: String
    var units: UnitSystem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 22, weight: .semibold))
                    .fontWidth(.condensed)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.trailing, 40)
                Label("PASSPORT • PASS • PASAPORTE", systemImage: "person.text.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                GridRow {
                    stat("FLIGHTS", "\(stats.flights)", detail: "\(stats.longHaul) Long Haul")
                    stat("DISTANCE", stats.distance(units), detail: stats.aroundTheWorld)
                        .gridCellColumns(2)
                }
                GridRow {
                    stat("FLIGHT TIME", FlightPresentation.duration(stats.minutes))
                    stat("AIRPORTS", "\(stats.airports)")
                    stat("AIRLINES", "\(stats.airlines)")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.05, blue: 0.33), Color(red: 0.15, green: 0.30, blue: 0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }

    private func stat(_ label: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .fontWidth(.condensed)
                .foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.system(size: 34, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

private struct DelayCard: View {
    var stats: PassportStats

    var body: some View {
        let onTime = stats.delayedFlights == 0
        let hours = stats.delayMinutes >= 60
        let amount = hours ? Int((Double(stats.delayMinutes) / 60).rounded()) : stats.delayMinutes
        VStack(alignment: .leading, spacing: 4) {
            Text("\(amount)")
                .font(.system(size: 64, weight: .heavy))
            Text("\(hours ? "hour" : "minute")\(amount == 1 ? "" : "s") lost from delays")
                .font(.title3.weight(.semibold))
            Text(onTime
                 ? "Every flight was on time"
                 : "\(stats.delayedFlights) delayed flight\(stats.delayedFlights == 1 ? "" : "s") averaged \(FlightPresentation.duration(stats.delayMinutes / stats.delayedFlights)) late")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: onTime
                           ? [Color(red: 0.05, green: 0.40, blue: 0.22), Color(red: 0.02, green: 0.20, blue: 0.12)]
                           : [Color(red: 0.70, green: 0.08, blue: 0.10), Color(red: 0.30, green: 0.02, blue: 0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct AircraftCard: View {
    var favorite: PassportStats.Favorite
    var photo: PassportView.LoadedPhoto?

    var body: some View {
        let ink = Color(red: 0.1, green: 0.12, blue: 0.35)
        VStack(alignment: .leading, spacing: 2) {
            Text("Most flown aircraft")
                .font(.title3.weight(.semibold))
            Text(favorite.title)
                .font(.system(size: 44, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(favorite.count) flight\(favorite.count == 1 ? "" : "s")")
                .font(.title3)
                .foregroundStyle(ink.opacity(0.6))
            if let photo {
                PlanePicture(image: photo.image)
                    .shadow(color: ink.opacity(0.25), radius: 10, y: 6)
                    .padding(.top, 14)
                PhotoCredit(photo: photo.photo, model: favorite.title, thisAircraftLabel: "One of your planes", color: ink.opacity(0.5))
                    .padding(.top, 6)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(ink)
        .background(
            LinearGradient(colors: [Color(red: 0.88, green: 0.89, blue: 0.98), Color(red: 0.72, green: 0.76, blue: 0.95)],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
    }
}

private struct FavoritesCard: View {
    var stats: PassportStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("FAVORITES")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            if let airline = stats.topAirline {
                row(label: "Top airline", title: airline.title, count: airline.count, unit: "flight") {
                    AirlineBadge(code: airline.code, size: 34)
                }
            }
            if let airport = stats.topAirport {
                row(label: "Most visited", title: [airport.title, airport.subtitle].compactMap { $0 }.joined(separator: " · "),
                    count: airport.count, unit: "visit") {
                    symbol("building.columns.fill")
                }
            }
            if let route = stats.topRoute {
                row(label: "Top route", title: route.title, count: route.count, unit: "flight") {
                    symbol("point.topleft.down.to.point.bottomright.curvepath.fill")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func row<Icon: View>(label: String, title: String, count: Int, unit: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(count) \(unit)\(count == 1 ? "" : "s")")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

// MARK: - History

enum HistorySort: String, CaseIterable, Identifiable {
    case date = "Date", from = "From", to = "To", airline = "Airline", aircraft = "Aircraft", distance = "Distance"
    var id: Self { self }
}

private struct HistorySection: View {
    var flights: [TrackedFlight]
    @Binding var sort: HistorySort
    var units: UnitSystem
    @State private var editingFlight: TrackedFlight?

    private var sorted: [TrackedFlight] {
        let byDate = flights.sorted { $0.sortDate > $1.sortDate }
        switch sort {
        case .date: return byDate
        case .from: return byDate.sorted { ($0.attributes.origin?.city ?? "") < ($1.attributes.origin?.city ?? "") }
        case .to: return byDate.sorted { ($0.attributes.destination?.city ?? "") < ($1.attributes.destination?.city ?? "") }
        case .airline: return byDate.sorted { $0.attributes.flightNumber < $1.attributes.flightNumber }
        case .aircraft: return byDate.sorted { ($0.aircraftModel ?? "~") < ($1.aircraftModel ?? "~") }
        case .distance: return byDate.sorted { ($0.distanceKm ?? 0) > ($1.distanceKm ?? 0) }
        }
    }

    /// By year when sorted by date; one group otherwise.
    private var groups: [(title: String, flights: [TrackedFlight])] {
        guard sort == .date else { return [("All flights", sorted)] }
        var groups: [(title: String, flights: [TrackedFlight])] = []
        for flight in sorted {
            let title = flight.passportYear.map(String.init) ?? "Undated"
            if groups.last?.title == title { groups[groups.count - 1].flights.append(flight) } else { groups.append((title, [flight])) }
        }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(HistorySort.allCases) { option in
                        Button {
                            withAnimation(.snappy) { sort = option }
                        } label: {
                            Text(option == .date ? "Date ↓" : option.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(sort == option ? Color.white.opacity(0.18) : .clear, in: Capsule())
                                .foregroundStyle(sort == option ? .white : .white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 8)

            ForEach(groups, id: \.title) { group in
                HStack {
                    Text(group.title)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Text("\(group.flights.count) FLIGHT\(group.flights.count == 1 ? "" : "S")")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.top, 16)
                .padding(.bottom, 6)
                Divider().overlay(Color.white.opacity(0.15))
                ForEach(group.flights) { flight in
                    NavigationLink(value: flight.id) {
                        HistoryRow(flight: flight, showsDistance: sort == .distance, units: units)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            editingFlight = flight
                        } label: {
                            Label("Edit Details", systemImage: "pencil")
                        }
                    }
                    Divider().overlay(Color.white.opacity(0.1)).padding(.leading, 56)
                }
            }
        }
        .foregroundStyle(.white)
        .sheet(item: $editingFlight) { flight in
            EditFlightDetailsView(flight: flight)
        }
    }
}

private struct HistoryRow: View {
    var flight: TrackedFlight
    var showsDistance: Bool
    var units: UnitSystem

    var body: some View {
        let attributes = flight.attributes
        HStack(spacing: 14) {
            AirlineBadge(code: attributes.airlineCode, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(attributes.flightNumber)
                    if let origin = attributes.origin, let destination = attributes.destination {
                        Text("\(origin.code) → \(destination.code)")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                Text("\(attributes.origin?.city ?? "?") to \(attributes.destination?.city ?? "?")")
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(trailing)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var trailing: String {
        if showsDistance, let km = flight.distanceKm {
            let value = units == .imperial ? km / 1.609 : km
            return "\(Int(value.rounded()).formatted()) \(units == .imperial ? "mi" : "km")"
        }
        guard let departure = flight.state.departure.best else { return "" }
        return departure.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted,
                                                    timeZone: flight.attributes.origin?.timeZone ?? .current))
    }
}
