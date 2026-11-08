import SwiftUI

/// The time between landing on one flight and taking off on the next from the same airport.
struct Connection {
    var airport: FlightActivityAttributes.Airport
    var previous: TrackedFlight
    var next: TrackedFlight
    var minutes: Int

    /// Under an hour is tight for most airports, with security and a walk between gates.
    var isTight: Bool { minutes < 60 }
    /// The next flight leaves before this one lands.
    var isMissed: Bool { minutes < 0 }

    /// "2h 10m in Kolkata"
    var summary: String {
        isMissed ? "Leaves before you land in \(airport.city)" : "\(FlightPresentation.duration(minutes)) in \(airport.city)"
    }

    var color: Color {
        isMissed ? .flightRed : isTight ? .flightAmber : .white.opacity(0.6)
    }
}

extension FlightStore {
    /// The next flight you take from the airport this one lands at, within a day of landing.
    func connection(after flight: TrackedFlight) -> Connection? {
        guard !flight.isDemo, flight.state.phase != .cancelled,
              let destination = flight.attributes.destination, let landing = flight.state.arrival.best else { return nil }
        let next = flights
            .filter { other in
                guard other.id != flight.id, !other.isDemo, other.state.phase != .cancelled,
                      other.attributes.origin?.code == destination.code,
                      let leaves = other.state.departure.best else { return false }
                return leaves > landing.addingTimeInterval(-6 * 3600) && leaves < landing.addingTimeInterval(24 * 3600)
            }
            .min { ($0.state.departure.best ?? .distantFuture) < ($1.state.departure.best ?? .distantFuture) }
        guard let next, let leaves = next.state.departure.best else { return nil }
        return Connection(airport: destination, previous: flight, next: next, minutes: Int(leaves.timeIntervalSince(landing) / 60))
    }

    /// The flight that connects into this one, if any.
    func connection(before flight: TrackedFlight) -> Connection? {
        flights.lazy.compactMap { self.connection(after: $0) }.first { $0.next.id == flight.id }
    }
}

/// The little line between two connecting flights on My Flights.
struct ConnectionRow: View {
    var connection: Connection

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: connection.isTight ? "exclamationmark.triangle.fill" : "arrow.triangle.turn.up.right.circle")
            Text(connection.isMissed ? connection.summary : "Connection · \(connection.summary)")
            if connection.isTight && !connection.isMissed {
                Text("Tight")
                    .font(.system(size: 11, weight: .heavy))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.flightAmber.opacity(0.2), in: Capsule())
            }
            Spacer()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(connection.color)
        .padding(.horizontal, 14)
    }
}

/// On the flight screen: how long you have before the next flight, or after the one before.
struct ConnectionCard: View {
    var connection: Connection
    /// True on the first flight (showing the one after), false on the second.
    var isOutbound: Bool

    var body: some View {
        let other = isOutbound ? connection.next : connection.previous
        NavigationLink(value: other.id) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CONNECTION IN \(connection.airport.city.uppercased())")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                HStack(alignment: .firstTextBaseline) {
                    Text(connection.isMissed ? "Missed" : FlightPresentation.duration(connection.minutes))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(connection.isTight ? connection.color : .white)
                    if connection.isTight && !connection.isMissed {
                        Text("Tight")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.flightAmber)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(detail(other))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// "Next: 6E 1641 to Ho Chi Minh City at 9:15 PM" or "From 6E 669, landing 2:15 PM".
    private func detail(_ other: TrackedFlight) -> String {
        let zone = connection.airport.timeZone
        if isOutbound {
            let leaves = other.state.departure.best.map { " at \(FlightPresentation.time($0, zone))" } ?? ""
            let gate = other.state.departure.gate.map { ", gate \($0)" } ?? ""
            return "Next: \(other.attributes.flightNumber) to \(other.attributes.destination?.city ?? "?")\(leaves)\(gate)"
        }
        let lands = other.state.arrival.best.map { ", landing \(FlightPresentation.time($0, zone))" } ?? ""
        return "From \(other.attributes.flightNumber) out of \(other.attributes.origin?.city ?? "?")\(lands)"
    }
}
