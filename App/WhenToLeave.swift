import SwiftUI

/// How long to be at the airport before departure. It comes from the domestic and international times in
/// Settings, and the countries of the two airports decide which one applies.
struct AirportTime: Equatable {
    enum Kind: Equatable {
        case domestic, international
        /// An airport's country isn't known, so the domestic time is used.
        case assumedDomestic
    }

    var minutes: Int
    var kind: Kind

    init(origin: String?, destination: String?, domesticMinutes: Int, internationalMinutes: Int) {
        let international = origin.flatMap { origin in
            destination.flatMap { AirportCountries.isInternational(from: origin, to: $0) }
        }
        switch international {
        case .some(true): (minutes, kind) = (internationalMinutes, .international)
        case .some(false): (minutes, kind) = (domesticMinutes, .domestic)
        case .none: (minutes, kind) = (domesticMinutes, .assumedDomestic)
        }
    }

    /// Where the number comes from, so it isn't mistaken for something the app measured.
    var source: String {
        switch kind {
        case .domestic: "Domestic flight · your time in Settings"
        case .international: "International flight · your time in Settings"
        case .assumedDomestic: "Assumed domestic, airport country unknown · your time in Settings"
        }
    }
}

/// Everything the flight screen's timeline shows: the drive, arriving at the airport, and the time there.
struct LeaveTimeline: Equatable {
    enum Drive: Equatable {
        /// Apple Maps' drive time with traffic from where you are.
        case estimate(TravelEstimate)
        case atAirport
        /// FlightLive can't use your location, so there's no drive time. `denied` when it was refused in Settings.
        case needsLocation(denied: Bool)
        /// Location is on, but there's no drive time yet.
        case pending
    }

    var drive: Drive
    /// When to set off. The same time the Live Activity and the reminder use.
    var leaveBy: Date?
    /// A set number of minutes before departure, used while there's no drive time.
    var setLeadMinutes: Int?
    var arriveBy: Date
    var airport: FlightActivityAttributes.Airport
    var terminal: String?
    var airportTime: AirportTime
}

/// Leave from where you are, arrive at the airport, time at the airport: a vertical timeline.
struct LeaveTimelineView: View {
    var timeline: LeaveTimeline
    var onAllowLocation: () -> Void
    var onOpenSettings: () -> Void

    private var zone: TimeZone { timeline.airport.timeZone }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            driveRow
            if timeline.drive != .atAirport {
                TimelineRow(time: FlightPresentation.time(timeline.arriveBy, zone), symbol: "mappin.and.ellipse") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Arrive at \(timeline.airport.code)\(timeline.terminal.map { " · \(terminalName($0))" } ?? "")")
                            .font(.system(size: 15, weight: .semibold))
                        Text(timeline.airport.city)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            TimelineRow(time: nil, symbol: "airplane", isLast: true) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TIME AT THE AIRPORT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(FlightPresentation.duration(timeline.airportTime.minutes))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(timeline.airportTime.source)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    @ViewBuilder
    private var driveRow: some View {
        let leaveNow = timeline.leaveBy.map { $0 < .now } ?? false
        let leaveTime = timeline.leaveBy.map { leaveNow ? "Now" : FlightPresentation.time($0, zone) }
        switch timeline.drive {
        case .estimate(let travel):
            TimelineRow(time: leaveTime, timeColor: leaveNow ? .flightAmber : .white, symbol: "car.fill",
                        tint: leaveNow ? .flightAmber : .white) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LEAVE FROM")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(travel.placeName ?? "Where you are")
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                        Text("Drive with traffic, from Apple Maps")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(FlightPresentation.duration(travel.minutes))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                        if let worse = travel.minutesWorse {
                            Text("Up by \(FlightPresentation.duration(worse))")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.flightRed)
                        }
                    }
                }
            }
        case .atAirport:
            TimelineRow(time: nil, symbol: "checkmark", tint: .flightGreen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're at the airport")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.flightGreen)
                    Text("Nothing left to drive")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        case .needsLocation(let denied):
            TimelineRow(time: leaveTime, timeColor: leaveNow ? .flightAmber : .white, symbol: "location.slash.fill",
                        tint: .flightAmber) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allow location to time your drive")
                        .font(.system(size: 15, weight: .semibold))
                    Text(denied
                         ? "Location is off for FlightLive. Turn it on in Settings, and Apple Maps will time the drive with traffic."
                         : "Apple Maps then times the drive with traffic from where you are.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    if let lead = timeline.setLeadMinutes {
                        Text("Until then: leave \(FlightPresentation.duration(lead)) before departure.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Button(denied ? "Open Settings" : "Allow location", action: denied ? onOpenSettings : onAllowLocation)
                        .font(.system(size: 13, weight: .semibold))
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        case .pending:
            TimelineRow(time: leaveTime, timeColor: leaveNow ? .flightAmber : .white, symbol: "car.fill", tint: .white.opacity(0.6)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No drive time yet")
                        .font(.system(size: 15, weight: .semibold))
                    Text(timeline.setLeadMinutes.map { "Leave \(FlightPresentation.duration($0)) before departure for now." }
                         ?? "Apple Maps is asked on the day of your flight.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    /// "Terminal 2", but a name like "International" as it is.
    private func terminalName(_ terminal: String) -> String {
        terminal.count <= 3 ? "Terminal \(terminal)" : terminal
    }
}

/// One step: a time on the left, a node on the rail, and what happens on the right.
private struct TimelineRow<Content: View>: View {
    var time: String?
    var timeColor: Color = .white
    var symbol: String
    var tint: Color = .white
    var isLast = false
    @ViewBuilder var content: Content

    private let timeWidth: CGFloat = 62
    private let nodeSize: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(time ?? "")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(timeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: timeWidth, alignment: .trailing)
                .padding(.top, 4)
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: nodeSize, height: nodeSize)
                .background(tint.opacity(0.16), in: Circle())
            content
                // Take the height the text needs: without this a second line of small print can be cut to "…".
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 16)
        }
        .background(alignment: .topLeading) {
            if !isLast {
                // Runs from under this node to the top of the next row.
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 2)
                    .padding(.leading, timeWidth + 10 + nodeSize / 2 - 1)
                    .padding(.top, nodeSize + 3)
            }
        }
    }
}
