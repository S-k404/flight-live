import MapKit
import SwiftUI

struct FlightDetailView: View {
    var flightID: UUID

    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmingDelete = false
    @State private var shareImage: Image?
    @State private var editingDetails = false

    /// The Lock Screen card on black with a FlightLive label, for sharing.
    @MainActor
    private func renderShareImage(_ flight: TrackedFlight) {
        let card = VStack(spacing: 10) {
            FlightLockScreenView(attributes: flight.attributes, state: flight.state)
                .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            Label("FlightLive", systemImage: "airplane")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(16)
        .frame(width: 400)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        shareImage = renderer.uiImage.map { Image(uiImage: $0) }
    }

    var body: some View {
        if let flight = store.flight(flightID) {
            content(flight)
        } else {
            ContentUnavailableView("Flight removed", systemImage: "airplane")
        }
    }

    private func content(_ flight: TrackedFlight) -> some View {
        let attributes = flight.attributes
        let state = flight.state
        let units = state.units ?? .aviation

        return ScrollView {
            VStack(spacing: 14) {
                FlightMapView(flight: flight)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                FlightLockScreenView(attributes: attributes, state: state)
                    .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08))
                    )

                LiveActivityControl(flight: flight)

                if !state.phase.hasDeparted && state.phase != .cancelled {
                    Button {
                        editingDetails = true
                    } label: {
                        Label(state.departure.best == nil ? "Add departure time & boarding alert" : "Edit times, gate, seat & boarding alert",
                              systemImage: state.departure.best == nil ? "clock.badge.exclamationmark" : "clock")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.departure.best == nil ? Color.flightBlue : Color.white.opacity(0.15))
                }

                if let origin = attributes.origin, let departure = state.departure.best, !flight.isDemo,
                   !state.phase.hasDeparted, state.phase != .cancelled, departure.timeIntervalSinceNow < 24 * 3600 {
                    GettingThereCard(flight: flight, airport: origin)
                }

                if !state.phase.isFinal || flight.hasBoardingPass == true {
                    BoardingPassCard(flight: flight)
                }

                if let inbound = state.inbound {
                    InboundCard(inbound: inbound, originZone: attributes.origin?.timeZone ?? .current)
                }

                if let origin = attributes.origin {
                    AirportCard(title: "Departure", airport: origin, movement: state.departure, showsBelt: false)
                }
                if let destination = attributes.destination {
                    AirportCard(title: "Arrival", airport: destination, movement: state.arrival, showsBelt: true)
                }

                if let connection = store.connection(before: flight) {
                    ConnectionCard(connection: connection, isOutbound: false)
                }
                if let connection = store.connection(after: flight) {
                    ConnectionCard(connection: connection, isOutbound: true)
                }

                if attributes.hasRoute {
                    TimelineCard(attributes: attributes, state: state)
                }

                if state.phase.isAirborne || state.altitudeFeet != nil {
                    Card(title: "Live") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            GridRow {
                                MiniStat(label: "ALTITUDE", value: units.altitude(state.altitudeFeet))
                                MiniStat(label: "GROUND SPEED", value: units.speed(state.groundSpeedKnots))
                            }
                            GridRow {
                                MiniStat(label: "VERTICAL SPEED", value: state.verticalRateFPM.map { "\($0.formatted()) ft/min" } ?? "—")
                                MiniStat(label: "DISTANCE TO GO", value: units.distance(state.distanceRemainingNM))
                            }
                            GridRow {
                                MiniStat(label: "PROGRESS", value: state.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("LAST UPDATE")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.5))
                                    Text(state.updatedAt, style: .relative)
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                }
                            }
                        }
                        if state.positionIsEstimated == true {
                            Label("Out of ADS-B range. Position is estimated from the schedule.", systemImage: "antenna.radiowaves.left.and.right.slash")
                                .font(.footnote)
                                .foregroundStyle(Color.flightAmber)
                        }
                    }
                }

                if !flight.isDemo || attributes.aircraft != nil {
                    Card(title: "Aircraft") {
                        AircraftPhotoView(registration: flight.registration, model: flight.aircraftModel)
                        VStack(alignment: .leading, spacing: 4) {
                            if let aircraft = attributes.aircraft {
                                Text(aircraft)
                                    .font(.headline)
                            } else {
                                Text("The airline hasn't said which plane yet")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let hex = flight.hex {
                                Text("Transponder \(hex.uppercased())")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let origin = attributes.origin, let destination = attributes.destination, !flight.isDemo,
                   let url = URL(string: "flightlive://search?q=\(destination.code)%20to%20\(origin.code)&go=0") {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Add return flight · \(destination.code) → \(origin.code)", systemImage: "arrow.uturn.left")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 6)
                }

                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("Remove Flight", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .padding(.top, 6)
            }
            .padding(16)
        }
        .background(Color.black)
        .navigationTitle(attributes.flightNumber)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // The flight card as a picture, with the details as text alongside.
                if let shareImage {
                    ShareLink(item: shareImage, message: Text(flight.shareText),
                              preview: SharePreview(attributes.flightNumber, image: shareImage)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                } else {
                    ShareLink(item: flight.shareText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingDetails = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .refreshable {
            await store.refresh(flightID, forceSchedule: true)
        }
        .task(id: state) { renderShareImage(flight) }
        .sheet(isPresented: $editingDetails) {
            EditFlightDetailsView(flight: flight)
        }
        .confirmationDialog("Remove \(attributes.flightNumber)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove Flight", role: .destructive) {
                Task {
                    await store.remove(flightID)
                    dismiss()
                }
            }
        }
    }
}

/// Rounded dark card with a small caps title.
private struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .foregroundStyle(.white)
        .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// When to leave for the airport, from Apple Maps' drive time with traffic, and a Go button.
private struct GettingThereCard: View {
    var flight: TrackedFlight
    var airport: FlightActivityAttributes.Airport

    @Environment(FlightStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var locating = false

    var body: some View {
        Card(title: "Getting to \(airport.code)") {
            if settings.leaveUsingLocation, flight.travel?.isAtAirport == true {
                Label("You're at the airport", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.flightGreen)
            } else if let plan = store.leavePlan(for: flight) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.date < .now ? "Leave now" : "Leave by \(FlightPresentation.time(plan.date, airport.timeZone))")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(plan.date < .now ? Color.flightAmber : .white)
                    Text(detail(plan))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(spacing: 10) {
                Button {
                    GettingThere.go(to: airport)
                } label: {
                    Label(settings.leaveMusic.isEmpty ? "Go" : "Go with music", systemImage: "car.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                if !settings.leaveUsingLocation {
                    Button {
                        useLocation()
                    } label: {
                        HStack(spacing: 6) {
                            if locating { ProgressView() } else { Image(systemName: "location.fill") }
                            Text("Use my location")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .disabled(locating || LocationProvider.shared.isDenied)
                }
            }
        }
        .task(id: flight.state.departure.best) {
            await store.updateTravelTimes()
        }
    }

    /// "52 min drive with traffic · be there 2h early" or "2h before departure".
    private func detail(_ plan: LeavePlan) -> String {
        if let travel = plan.travel {
            return "\(FlightPresentation.duration(travel.minutes)) drive with traffic · there \(FlightPresentation.duration(settings.arriveAtAirportMinutes)) early"
        }
        return "\(FlightPresentation.duration(settings.leaveForAirportMinutes)) before departure"
    }

    private func useLocation() {
        locating = true
        Task {
            if await LocationProvider.shared.requestAuthorization() {
                settings.leaveUsingLocation = true
                await store.updateTravelTimes(force: true)
                store.refreshReminders()
            }
            locating = false
        }
    }
}

private struct LiveActivityControl: View {
    var flight: TrackedFlight
    @Environment(FlightStore.self) private var store

    var body: some View {
        let running = store.hasLiveActivity(flight.id)
        HStack(spacing: 12) {
            Image(systemName: "lock.iphone")
                .font(.title3)
                .foregroundStyle(running ? Color.flightGreen : .white.opacity(0.6))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(running ? "On your Lock Screen" : "Live Activity")
                    .font(.subheadline.weight(.semibold))
                Text(caption(running: running))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            if !flight.state.phase.isFinal {
                Button(running ? "Stop" : "Start") {
                    Task { await store.setLiveActivity(!running, for: flight.id) }
                }
                .buttonStyle(.bordered)
                .tint(running ? .white : Color.flightBlue)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func caption(running: Bool) -> String {
        if !store.liveActivitiesEnabled { return "Turned off in Settings › FlightLive" }
        if flight.state.phase.isFinal { return "This flight is over" }
        if running { return "Lock Screen and Dynamic Island" }
        if !flight.showsLiveActivity { return "Off for this flight" }
        return "Starts automatically 3 hours before departure"
    }
}

private struct InboundCard: View {
    var inbound: FlightActivityAttributes.Inbound
    var originZone: TimeZone

    var body: some View {
        Card(title: "Where's my plane?") {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FlightPresentation.inboundText(inbound, zone: originZone))
                        .font(.subheadline.weight(.semibold))
                    if let number = inbound.flightNumber {
                        Text("Arriving as \(number)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
    }

    private var icon: String {
        switch inbound.status {
        case .inAir: "airplane.arrival"
        case .arrived: "checkmark.circle.fill"
        case .elsewhere: "mappin.and.ellipse"
        }
    }

    private var color: Color {
        switch inbound.status {
        case .inAir: .flightBlue
        case .arrived: .flightGreen
        case .elsewhere: .flightAmber
        }
    }
}

private struct AirportCard: View {
    var title: String
    var airport: FlightActivityAttributes.Airport
    var movement: FlightActivityAttributes.Movement
    /// The arrival end: shows the baggage belt and the weather when you land.
    var showsBelt: Bool
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Card(title: "\(title) · \(airport.code)") {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(airport.city)
                        .font(.title3.weight(.bold))
                    if let best = movement.best {
                        Text(best.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: airport.timeZone)))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(timeColor)
                    }
                    if let scheduled = movement.scheduled, abs(movement.delayMinutes ?? 0) >= 5 {
                        Text("Scheduled \(FlightPresentation.time(scheduled, airport.timeZone))")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    if showsBelt, let best = movement.best {
                        ArrivalWeatherLine(airport: airport, arrival: best, fahrenheit: settings.units == .imperial)
                            .padding(.top, 4)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    if let terminal = movement.terminal {
                        InfoTile(label: "TERMINAL", value: terminal)
                    }
                    if let gate = movement.gate {
                        GateChip(chip: .init(label: "GATE", value: gate))
                    }
                    if showsBelt, let belt = movement.baggageBelt {
                        GateChip(chip: .init(label: "BELT", value: belt))
                    }
                }
            }
            HStack {
                Label(localTime, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Link(destination: directionsURL) {
                    Label("Directions", systemImage: "car.fill")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    /// "Now 3:42 PM local · 8h ahead"
    private var localTime: String {
        let now = Date()
        var text = "Now \(FlightPresentation.time(now, airport.timeZone)) local"
        let difference = airport.timeZone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)
        if difference != 0 {
            let hours = Double(abs(difference)) / 3600
            let amount = hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
            text += " · \(amount) \(difference > 0 ? "ahead" : "behind")"
        }
        return text
    }

    private var directionsURL: URL {
        URL(string: "https://maps.apple.com/?daddr=\(airport.latitude),\(airport.longitude)&q=\(airport.code)%20Airport&dirflg=d")!
    }

    private var timeColor: Color {
        let tone = FlightPresentation.tone(for: movement)
        return tone == .neutral ? .white : tone.color
    }
}

private struct InfoTile: View {
    var label: String
    var value: String

    var body: some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .opacity(0.6)
                .lineLimit(1)
                .fixedSize()
            Text(value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(minWidth: 56)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TimelineCard: View {
    var attributes: FlightActivityAttributes
    var state: FlightActivityAttributes.ContentState

    var body: some View {
        let originZone = attributes.origin?.timeZone ?? .current
        let destinationZone = attributes.destination?.timeZone ?? .current
        Card(title: "Timeline") {
            VStack(spacing: 10) {
                TimelineRow(icon: "figure.walk.departure", label: "Gate departure",
                            scheduled: state.departure.scheduled, actual: state.departure.actual,
                            estimated: state.departure.estimated, zone: originZone)
                TimelineRow(icon: "airplane.departure", label: "Takeoff",
                            scheduled: nil, actual: state.departure.runway, estimated: nil, zone: originZone)
                TimelineRow(icon: "airplane.arrival", label: "Landing",
                            scheduled: nil, actual: state.arrival.runway, estimated: nil, zone: destinationZone)
                TimelineRow(icon: "figure.walk.arrival", label: "Gate arrival",
                            scheduled: state.arrival.scheduled, actual: state.arrival.actual,
                            estimated: state.arrival.estimated, zone: destinationZone)
            }
            if let out = state.departure.best, let into = state.arrival.best, into > out {
                Text("Gate to gate \(FlightPresentation.duration(Int(into.timeIntervalSince(out) / 60)))")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }
}

private struct TimelineRow: View {
    var icon: String
    var label: String
    var scheduled: Date?
    var actual: Date?
    var estimated: Date?
    var zone: TimeZone

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(actual != nil ? Color.flightGreen : .white.opacity(0.4))
            Text(label)
                .font(.subheadline)
            Spacer()
            if let scheduled, let shown = actual ?? estimated, abs(shown.timeIntervalSince(scheduled)) >= 5 * 60 {
                Text(FlightPresentation.time(scheduled, zone))
                    .strikethrough()
                    .foregroundStyle(.white.opacity(0.4))
            }
            if let actual {
                Text(FlightPresentation.time(actual, zone))
                    .fontWeight(.semibold)
            } else if let estimated {
                Text("est. \(FlightPresentation.time(estimated, zone))")
                    .foregroundStyle(.white.opacity(0.75))
            } else if let scheduled {
                Text(FlightPresentation.time(scheduled, zone))
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Text("—")
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .font(.subheadline)
        .monospacedDigit()
    }
}

struct FlightMapView: View {
    var flight: TrackedFlight
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let attributes = flight.attributes
        Map(position: $camera) {
            if let origin = attributes.origin, let destination = attributes.destination {
                MapPolyline(coordinates: [origin.coordinate, destination.coordinate], contourStyle: .geodesic)
                    .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 6]))
                if let position = flight.coordinate, flight.state.phase.hasDeparted {
                    MapPolyline(coordinates: [origin.coordinate, position], contourStyle: .geodesic)
                        .stroke(Color.flightBlue, lineWidth: 3)
                }
                Annotation(origin.code, coordinate: origin.coordinate) {
                    AirportDot()
                }
                Annotation(destination.code, coordinate: destination.coordinate) {
                    AirportDot()
                }
            }
            if let inbound = flight.inboundCoordinate {
                Annotation("Your plane", coordinate: inbound) {
                    PlaneMarker(track: nil, color: .gray)
                }
            }
            if let position = flight.coordinate, flight.state.phase.hasDeparted || flight.attributes.origin == nil {
                Annotation(attributes.flightNumber, coordinate: position) {
                    PlaneMarker(track: flight.track, color: .flightBlue)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .dark)
    }
}

private struct AirportDot: View {
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 2))
    }
}

private struct PlaneMarker: View {
    var track: Double?
    var color: Color

    var body: some View {
        Image(systemName: "airplane")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            // The symbol points east; map headings start at north.
            .rotationEffect(.degrees((track ?? 90) - 90))
            .frame(width: 32, height: 32)
            .background(Circle().fill(color))
            .shadow(radius: 3)
    }
}
