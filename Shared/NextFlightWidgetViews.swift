import SwiftUI
import WidgetKit

/// The Home Screen and Lock Screen widget: your next flight, or the one you're on.
struct NextFlightWidgetView: View {
    var flight: WidgetSnapshot.Flight?
    var family: WidgetFamily

    var body: some View {
        Group {
            if let flight {
                switch family {
                case .systemMedium, .systemLarge, .systemExtraLarge:
                    MediumFlightView(flight: flight)
                case .accessoryRectangular:
                    RectangularFlightView(flight: flight)
                case .accessoryInline:
                    InlineFlightView(flight: flight)
                default:
                    SmallFlightView(flight: flight)
                }
            } else {
                NoFlightView(family: family)
            }
        }
        .widgetURL(flight.flatMap { URL(string: "flightlive://flight/\($0.id)") })
    }
}

private struct SmallFlightView: View {
    var flight: WidgetSnapshot.Flight

    var body: some View {
        let attributes = flight.attributes
        let presentation = FlightPresentation(attributes: attributes, state: flight.state)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                AirlineBadge(code: attributes.airlineCode, size: 20)
                Text(attributes.flightNumber)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
            }
            if let origin = attributes.origin, let destination = attributes.destination {
                Text("\(origin.code) → \(destination.code)")
                    .font(.system(size: 21, weight: .heavy))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(presentation.countdownLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
            CountdownValue(presentation: presentation, size: 22)
            HStack(spacing: 4) {
                Text(presentation.statusText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let chip = presentation.chip {
                    GateChip(chip: chip, compact: true)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) { Color.flightCard }
    }
}

private struct MediumFlightView: View {
    var flight: WidgetSnapshot.Flight

    var body: some View {
        let attributes = flight.attributes
        let state = flight.state
        let presentation = FlightPresentation(attributes: attributes, state: state)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AirlineBadge(code: attributes.airlineCode, size: 22)
                Text(attributes.flightNumber)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(presentation.statusText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(presentation.tone.color)
            }
            if let origin = attributes.origin, let destination = attributes.destination {
                HStack(spacing: 10) {
                    EndpointLabel(airport: origin, movement: state.departure, alignment: .leading)
                    RouteProgressBar(progress: state.planeProgress, tint: presentation.tone.color, interval: state.flightInterval)
                    EndpointLabel(airport: destination, movement: state.arrival, alignment: .trailing)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.countdownLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    CountdownValue(presentation: presentation, size: 20)
                }
                Spacer(minLength: 4)
                Text(presentation.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                if let chip = presentation.chip {
                    GateChip(chip: chip, compact: true)
                }
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color.flightCard }
    }
}

/// Lock Screen, under the clock.
private struct RectangularFlightView: View {
    var flight: WidgetSnapshot.Flight

    var body: some View {
        let attributes = flight.attributes
        let presentation = FlightPresentation(attributes: attributes, state: flight.state)
        let route = [attributes.origin?.code, attributes.destination?.code].compactMap { $0 }.joined(separator: "→")
        VStack(alignment: .leading, spacing: 1) {
            Text(route.isEmpty ? attributes.flightNumber : "\(attributes.flightNumber) · \(route)")
                .font(.headline)
                .widgetAccentable()
                .lineLimit(1)
            if let target = presentation.countdownTarget {
                Text("\(presentation.countdownLabel) ") + Text(target, style: .relative)
            } else {
                Text("\(presentation.countdownLabel) \(presentation.headline)")
            }
            Text(presentation.chip.map { "\($0.label.capitalized) \($0.value) · \(presentation.statusText)" } ?? presentation.statusText)
                .lineLimit(1)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { Color.clear }
    }
}

/// Lock Screen, next to the date.
private struct InlineFlightView: View {
    var flight: WidgetSnapshot.Flight

    var body: some View {
        let presentation = FlightPresentation(attributes: flight.attributes, state: flight.state)
        let place = presentation.chip.map { " · \($0.label.capitalized) \($0.value)" } ?? ""
        if let target = presentation.countdownTarget {
            Text("✈︎ \(flight.attributes.flightNumber)\(place) · ") + Text(target, style: .relative)
        } else {
            Text("✈︎ \(flight.attributes.flightNumber)\(place) · \(presentation.statusText)")
        }
    }
}

private struct NoFlightView: View {
    var family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Text("✈︎ No upcoming flights")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("FlightLive").font(.headline).widgetAccentable()
                Text("No upcoming flights").font(.caption)
            }
            .containerBackground(for: .widget) { Color.clear }
        default:
            VStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.flightBlue)
                    .rotationEffect(.degrees(-30))
                Text("No upcoming flights")
                    .font(.system(size: 14, weight: .bold))
                Text("Add one in FlightLive")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .containerBackground(for: .widget) { Color.flightCard }
        }
    }
}

extension WidgetSnapshot.Flight {
    /// For the widget gallery before any flight is added.
    static var sample: WidgetSnapshot.Flight {
        let now = Date()
        var state = FlightActivityAttributes.ContentState(phase: .scheduled, updatedAt: now)
        state.departure.scheduled = now.addingTimeInterval(2 * 3600 + 15 * 60)
        state.departure.gate = "12"
        state.arrival.scheduled = now.addingTimeInterval(4 * 3600 + 5 * 60)
        state.leaveBy = now.addingTimeInterval(25 * 60)
        state.driveMinutes = 50
        let attributes = FlightActivityAttributes(
            flightNumber: "6E 978", airlineCode: "6E", airline: "IndiGo",
            origin: .init(code: "BLR", city: "Bengaluru", latitude: 13.1979, longitude: 77.7063, timeZoneID: "Asia/Kolkata"),
            destination: .init(code: "RPR", city: "Raipur", latitude: 21.1804, longitude: 81.7388, timeZoneID: "Asia/Kolkata")
        )
        return WidgetSnapshot.Flight(id: "sample", attributes: attributes, state: state)
    }
}
