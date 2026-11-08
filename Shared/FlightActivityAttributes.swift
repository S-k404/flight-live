import ActivityKit
import Foundation

/// Data shared between the app and the Live Activity widget.
/// Static fields describe the flight; `ContentState` is what changes on every update.
struct FlightActivityAttributes: ActivityAttributes {
    struct Airport: Codable, Hashable {
        var code: String
        var city: String
        var latitude: Double
        var longitude: Double
        var timeZoneID: String?

        var timeZone: TimeZone {
            timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        }
    }

    /// One end of the flight. Times are absolute instants, shown in that airport's time zone.
    struct Movement: Codable, Hashable {
        var scheduled: Date?
        var estimated: Date?
        /// Gate departure or gate arrival.
        var actual: Date?
        /// Takeoff or touchdown.
        var runway: Date?
        var terminal: String?
        var gate: String?
        var baggageBelt: String?

        var best: Date? { actual ?? estimated ?? scheduled }

        /// Positive when late, negative when early.
        var delayMinutes: Int? {
            guard let scheduled, let best else { return nil }
            return Int((best.timeIntervalSince(scheduled) / 60).rounded())
        }
    }

    /// The aircraft's previous flight: "Where's my plane?"
    struct Inbound: Codable, Hashable {
        enum Status: String, Codable, Hashable {
            case inAir, arrived, elsewhere
        }

        var status: Status
        var flightNumber: String?
        var fromCode: String?
        var arrival: Date?
    }

    struct ContentState: Codable, Hashable {
        var phase: FlightPhase
        var departure = Movement()
        var arrival = Movement()
        /// 0...1 along the route.
        var progress: Double?
        var altitudeFeet: Int?
        var groundSpeedKnots: Int?
        var verticalRateFPM: Int?
        var distanceRemainingNM: Int?
        /// Set when the plane is out of ADS-B range and progress is extrapolated from the schedule.
        var positionIsEstimated: Bool?
        var inbound: Inbound?
        var units: UnitSystem?
        /// When boarding is expected to start: the airline's time if known, otherwise a set time before departure.
        var boardingStarts: Date?
        /// From the boarding pass or entered by hand, e.g. "23A".
        var seat: String?
        /// Tapping the Live Activity opens the boarding pass when there is one.
        var hasBoardingPass: Bool?
        /// When to set off for the airport, and the drive time if it's from Apple Maps.
        var leaveBy: Date?
        var driveMinutes: Int?
        /// Time of the last real data update.
        var updatedAt: Date
    }

    /// "UA 930", or a tail number like "N172SP".
    var flightNumber: String
    /// IATA airline code for the badge, e.g. "UA".
    var airlineCode: String?
    var airline: String?
    /// "Boeing 787-9 · N26966"
    var aircraft: String?
    var origin: Airport?
    var destination: Airport?
    /// The app's id for this flight, so tapping the Live Activity can open it.
    var flightID: String?

    var hasRoute: Bool { origin != nil && destination != nil }

    /// Where tapping the Live Activity goes: the boarding pass before departure if there is one, else the flight.
    func tapURL(for state: ContentState) -> URL? {
        guard let flightID else { return nil }
        let showPass = state.hasBoardingPass == true && !state.phase.hasDeparted
        return URL(string: "flightlive://\(showPass ? "pass" : "flight")/\(flightID)")
    }
}

enum FlightPhase: String, Codable, Hashable, CaseIterable {
    case scheduled, boarding, taxiingOut, climbing, cruising, descending, landed, arrived, cancelled, diverted

    var label: String {
        switch self {
        case .scheduled: "Scheduled"
        case .boarding: "Boarding"
        case .taxiingOut: "Taxiing"
        case .climbing: "Climbing"
        case .cruising: "Cruising"
        case .descending: "Descending"
        case .landed: "Landed"
        case .arrived: "Arrived"
        case .cancelled: "Cancelled"
        case .diverted: "Diverted"
        }
    }

    var symbol: String {
        switch self {
        case .scheduled: "clock"
        case .boarding: "figure.walk"
        case .taxiingOut: "airplane"
        case .climbing: "airplane.departure"
        case .cruising: "airplane"
        case .descending: "airplane.arrival"
        case .landed: "airplane.arrival"
        case .arrived: "checkmark.circle.fill"
        case .cancelled: "xmark.octagon.fill"
        case .diverted: "arrow.triangle.branch"
        }
    }

    var isAirborne: Bool {
        self == .climbing || self == .cruising || self == .descending
    }

    /// Pushed back from the gate or later.
    var hasDeparted: Bool {
        switch self {
        case .scheduled, .boarding, .cancelled: false
        default: true
        }
    }

    /// Nothing left to track.
    var isFinal: Bool {
        self == .arrived || self == .cancelled || self == .diverted
    }
}

enum UnitSystem: String, Codable, Hashable, CaseIterable, Identifiable {
    case aviation, imperial, metric

    var id: Self { self }

    var title: String {
        switch self {
        case .aviation: "Aviation (ft, kt, nm)"
        case .imperial: "Imperial (ft, mph, mi)"
        case .metric: "Metric (m, km/h, km)"
        }
    }

    func altitude(_ feet: Int?) -> String {
        guard let feet else { return "—" }
        if feet <= 0 { return "Ground" }
        switch self {
        case .aviation, .imperial: return "\(feet.formatted()) ft"
        case .metric: return "\(Int(Double(feet) * 0.3048).formatted()) m"
        }
    }

    func speed(_ knots: Int?) -> String {
        guard let knots else { return "—" }
        switch self {
        case .aviation: return "\(knots) kt"
        case .imperial: return "\(Int((Double(knots) * 1.15078).rounded())) mph"
        case .metric: return "\(Int((Double(knots) * 1.852).rounded())) km/h"
        }
    }

    func distance(_ nm: Int?) -> String {
        guard let nm else { return "—" }
        switch self {
        case .aviation: return "\(nm.formatted()) nm"
        case .imperial: return "\(Int((Double(nm) * 1.15078).rounded()).formatted()) mi"
        case .metric: return "\(Int((Double(nm) * 1.852).rounded()).formatted()) km"
        }
    }
}
