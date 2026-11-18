import SwiftUI

/// What has gone wrong on your flights: what's happening now, and how it adds up over time.
struct DisruptionReport {
    enum Kind: Equatable {
        case delayed(minutes: Int), cancelled, diverted
    }

    struct Item: Identifiable {
        var flight: TrackedFlight
        var kind: Kind
        var id: UUID { flight.id }
    }

    /// An airline or an airport, and how its flights for you went.
    struct Tally: Identifiable {
        var name: String
        var flights: Int
        var delayed: Int
        var id: String { name }
        var onTimePercent: Int { Int((Double(flights - delayed) / Double(max(flights, 1)) * 100).rounded()) }
    }

    /// Not over yet, or over less than six hours ago. Soonest first.
    var live: [Item] = []
    /// Over. Newest first.
    var past: [Item] = []
    var flown = 0
    var delayed = 0
    var cancelled = 0
    var diverted = 0
    var averageDelay = 0
    var worstDelay = 0
    /// Only the ones with a delay, worst first.
    var airlines: [Tally] = []
    var airports: [Tally] = []

    var onTimePercent: Int { Int((Double(flown - delayed) / Double(max(flown, 1)) * 100).rounded()) }

    /// Late enough to count, like the Passport and airline on-time stats do.
    static func kind(of flight: TrackedFlight) -> Kind? {
        switch flight.state.phase {
        case .cancelled: return .cancelled
        case .diverted: return .diverted
        default:
            guard let delay = flight.delayMinutes, delay >= PassportStats.delayThreshold else { return nil }
            return .delayed(minutes: delay)
        }
    }

    init(_ flights: [TrackedFlight], now: Date = .now) {
        let real = flights.filter { !$0.isDemo }
        for flight in real.sorted(by: { $0.sortDate > $1.sortDate }) {
            guard let kind = Self.kind(of: flight) else { continue }
            if flight.isPast(now: now) {
                past.append(Item(flight: flight, kind: kind))
            } else {
                live.insert(Item(flight: flight, kind: kind), at: 0) // newest first in, so this ends up soonest first
            }
        }

        let flownFlights = real.filter(\.isFlown)
        flown = flownFlights.count
        let lates = flownFlights.compactMap(\.delayMinutes).filter { $0 >= PassportStats.delayThreshold }
        delayed = lates.count
        averageDelay = lates.isEmpty ? 0 : lates.reduce(0, +) / lates.count
        worstDelay = lates.max() ?? 0
        cancelled = real.filter { $0.state.phase == .cancelled }.count
        diverted = real.filter { $0.state.phase == .diverted }.count

        func tallies(_ name: (TrackedFlight) -> String?) -> [Tally] {
            var counts: [String: (flights: Int, delayed: Int)] = [:]
            for flight in flownFlights {
                guard let key = name(flight) else { continue }
                counts[key, default: (0, 0)].flights += 1
                if let delay = flight.delayMinutes, delay >= PassportStats.delayThreshold { counts[key, default: (0, 0)].delayed += 1 }
            }
            return counts
                .filter { $0.value.delayed > 0 }
                .map { Tally(name: $0.key, flights: $0.value.flights, delayed: $0.value.delayed) }
                .sorted { a, b in
                    if a.delayed != b.delayed { return a.delayed > b.delayed }
                    if a.onTimePercent != b.onTimePercent { return a.onTimePercent < b.onTimePercent } // the worse record first
                    return a.flights != b.flights ? a.flights > b.flights : a.name < b.name
                }
        }
        airlines = tallies { flight in
            flight.attributes.airline ?? flight.attributes.airlineCode ?? flight.attributes.flightNumber.split(separator: " ").first.map(String.init)
        }
        airports = tallies { flight in
            flight.attributes.origin.map { "\($0.city) (\($0.code))" }
        }
    }
}

/// Delays, cancellations and diversions on your flights, in a page of their own.
struct DelaysView: View {
    /// Opens a flight; the list behind this page shows it.
    var onOpen: (UUID) -> Void

    @Environment(FlightStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let report = DisruptionReport(store.flights)
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let error = store.lastError {
                        Label("Live updates are having trouble: \(error)", systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(Color.flightAmber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.flightAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    DisruptionCard(title: "Right now") {
                        if report.live.isEmpty {
                            Label("Nothing is delayed or cancelled", systemImage: "checkmark.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Color.flightGreen)
                        } else {
                            rows(report.live)
                        }
                    }

                    if report.flown > 0 {
                        DisruptionCard(title: "Your flights so far") {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                                GridRow {
                                    MiniStat(label: "ON TIME", value: "\(report.onTimePercent)%")
                                    MiniStat(label: "DELAYED", value: "\(report.delayed) of \(report.flown)")
                                }
                                GridRow {
                                    MiniStat(label: "AVERAGE DELAY", value: report.delayed == 0 ? "—" : FlightPresentation.duration(report.averageDelay))
                                    MiniStat(label: "WORST DELAY", value: report.delayed == 0 ? "—" : FlightPresentation.duration(report.worstDelay))
                                }
                                GridRow {
                                    MiniStat(label: "CANCELLED", value: "\(report.cancelled)")
                                    MiniStat(label: "DIVERTED", value: "\(report.diverted)")
                                }
                            }
                        }
                    }

                    if !report.past.isEmpty {
                        DisruptionCard(title: "Past disruptions") {
                            rows(Array(report.past.prefix(20)))
                            if report.past.count > 20 {
                                Text("and \(report.past.count - 20) more")
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }

                    if !report.airlines.isEmpty {
                        DisruptionCard(title: "By airline") { tallyRows(Array(report.airlines.prefix(5))) }
                    }
                    if !report.airports.isEmpty {
                        DisruptionCard(title: "By departure airport") { tallyRows(Array(report.airports.prefix(5))) }
                    }

                    if report.flown == 0 && report.live.isEmpty && report.past.isEmpty {
                        Text("Delays and cancellations show up here once you've added flights.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("Delays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func rows(_ items: [DisruptionReport.Item]) -> some View {
        VStack(spacing: 14) {
            ForEach(items) { item in
                DisruptionRow(item: item) {
                    dismiss()
                    onOpen(item.id)
                }
            }
        }
    }

    private func tallyRows(_ tallies: [DisruptionReport.Tally]) -> some View {
        VStack(spacing: 12) {
            ForEach(tallies) { tally in
                HStack {
                    Text(tally.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(tally.delayed) of \(tally.flights) late · \(tally.onTimePercent)% on time")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

private struct DisruptionCard<Content: View>: View {
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

/// "6E 978 · BLR → DEL · 12 Oct 2026", with how it went on the right.
private struct DisruptionRow: View {
    var item: DisruptionReport.Item
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.flight.attributes.flightNumber)
                        .font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 8)
                Text(label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(color.opacity(0.16), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        let attributes = item.flight.attributes
        let route = [attributes.origin?.code, attributes.destination?.code].compactMap { $0 }.joined(separator: " → ")
        let day = item.flight.state.departure.best.map {
            $0.formatted(Date.FormatStyle(timeZone: attributes.origin?.timeZone ?? .current).day().month(.abbreviated).year())
        }
        return [route, day].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var label: String {
        switch item.kind {
        case .delayed(let minutes): "\(FlightPresentation.duration(minutes)) late"
        case .cancelled: "Cancelled"
        case .diverted: "Diverted"
        }
    }

    private var color: Color {
        switch item.kind {
        case .delayed(let minutes): minutes >= 60 ? .flightRed : .flightAmber
        case .cancelled: .flightRed
        case .diverted: .flightAmber
        }
    }
}
