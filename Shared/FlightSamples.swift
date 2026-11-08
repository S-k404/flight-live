import Foundation

/// Sample data for SwiftUI previews and the in-app demo flight.
extension FlightActivityAttributes {
    static let demo = FlightActivityAttributes(
        flightNumber: "FL 101",
        airlineCode: "FL",
        airline: "FlightLive Air",
        aircraft: "Boeing 787-9 · N101FL",
        origin: Airport(code: "SFO", city: "San Francisco", latitude: 37.6189, longitude: -122.3750,
                        timeZoneID: "America/Los_Angeles"),
        destination: Airport(code: "JFK", city: "New York", latitude: 40.6398, longitude: -73.7789,
                             timeZoneID: "America/New_York")
    )

    static let noRoute = FlightActivityAttributes(
        flightNumber: "N172SP",
        aircraft: "Cessna 172"
    )
}

extension FlightActivityAttributes.ContentState {
    private static func minutes(_ value: Double) -> Date { .now.addingTimeInterval(value * 60) }

    static let scheduled = Self(
        phase: .scheduled,
        departure: .init(scheduled: minutes(70), estimated: minutes(85), terminal: "2", gate: "D14"),
        arrival: .init(scheduled: minutes(390), estimated: minutes(398), terminal: "4"),
        inbound: .init(status: .inAir, flightNumber: "FL 88", fromCode: "PDX", arrival: minutes(32)),
        updatedAt: .now
    )

    static let boarding = Self(
        phase: .boarding,
        departure: .init(scheduled: minutes(22), estimated: minutes(22), terminal: "2", gate: "D14"),
        arrival: .init(scheduled: minutes(342), estimated: minutes(340), terminal: "4"),
        updatedAt: .now
    )

    static let cruising = Self(
        phase: .cruising,
        departure: .init(scheduled: minutes(-140), actual: minutes(-128), runway: minutes(-117), gate: "D14"),
        arrival: .init(scheduled: minutes(170), estimated: minutes(176), terminal: "4", gate: "B31"),
        progress: 0.43, altitudeFeet: 37_000, groundSpeedKnots: 488, verticalRateFPM: 0, distanceRemainingNM: 1_270,
        updatedAt: .now
    )

    static let descending = Self(
        phase: .descending,
        departure: .init(scheduled: minutes(-300), actual: minutes(-262), runway: minutes(-250)),
        arrival: .init(scheduled: minutes(-20), estimated: minutes(19), terminal: "4", gate: "B31"),
        progress: 0.95, altitudeFeet: 11_250, groundSpeedKnots: 284, verticalRateFPM: -1_600, distanceRemainingNM: 61,
        updatedAt: .now
    )

    static let landed = Self(
        phase: .arrived,
        departure: .init(scheduled: minutes(-330), actual: minutes(-326), runway: minutes(-315)),
        arrival: .init(scheduled: minutes(-4), actual: minutes(-9), runway: minutes(-16), terminal: "4", gate: "B31",
                       baggageBelt: "7"),
        progress: 1, altitudeFeet: 0, groundSpeedKnots: 0,
        updatedAt: .now
    )

    static let cancelled = Self(
        phase: .cancelled,
        departure: .init(scheduled: minutes(95), terminal: "2", gate: "D14"),
        arrival: .init(scheduled: minutes(415)),
        updatedAt: .now
    )

    static let generalAviation = Self(
        phase: .cruising,
        altitudeFeet: 4_500, groundSpeedKnots: 108, verticalRateFPM: 0,
        updatedAt: .now
    )
}
