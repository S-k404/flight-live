import CoreLocation
import Foundation

extension FlightActivityAttributes.Airport {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum Geo {
    static let earthRadiusNM = 3440.065

    /// Great-circle distance in nautical miles.
    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude.radians, lat2 = b.latitude.radians
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude).radians
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusNM * asin(min(1, sqrt(h)))
    }

    /// Initial bearing in degrees (0 = north).
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude.radians, lat2 = b.latitude.radians
        let dLon = (b.longitude - a.longitude).radians
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x).degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Point a fraction of the way along the great circle from a to b.
    static func intermediate(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D, fraction f: Double) -> CLLocationCoordinate2D {
        let lat1 = a.latitude.radians, lon1 = a.longitude.radians
        let lat2 = b.latitude.radians, lon2 = b.longitude.radians
        let d = distanceNM(a, b) / earthRadiusNM
        guard d > 0 else { return a }
        let sa = sin((1 - f) * d) / sin(d)
        let sb = sin(f * d) / sin(d)
        let x = sa * cos(lat1) * cos(lon1) + sb * cos(lat2) * cos(lon2)
        let y = sa * cos(lat1) * sin(lon1) + sb * cos(lat2) * sin(lon2)
        let z = sa * sin(lat1) + sb * sin(lat2)
        return CLLocationCoordinate2D(latitude: atan2(z, sqrt(x * x + y * y)).degrees, longitude: atan2(y, x).degrees)
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}

/// What we remember between updates to spot takeoff, landing and arrival from ADS-B alone.
struct TrackingMemory: Codable, Hashable {
    var hasBeenAirborne = false
    var takeoffAt: Date?
    var landedAt: Date?
    var stoppedSince: Date?
}

/// The parts of a schedule refresh that get merged into the state.
struct ScheduleSnapshot {
    var phase: FlightPhase
    var departure: FlightActivityAttributes.Movement
    var arrival: FlightActivityAttributes.Movement

    init(_ flight: ScheduledFlight) {
        phase = flight.phase
        departure = flight.departureMovement
        arrival = flight.arrivalMovement
    }

    init(phase: FlightPhase, departure: FlightActivityAttributes.Movement, arrival: FlightActivityAttributes.Movement) {
        self.phase = phase
        self.departure = departure
        self.arrival = arrival
    }
}

enum FlightMath {
    typealias State = FlightActivityAttributes.ContentState
    typealias Movement = FlightActivityAttributes.Movement

    /// Combines the latest schedule and ADS-B data into the next state.
    /// - Parameters:
    ///   - schedule: Fresh schedule data, or nil if it wasn't refreshed this time.
    ///   - aircraft: The plane's position report, or nil if it isn't visible.
    ///   - lookedForAircraft: False when ADS-B wasn't checked this time (so a nil aircraft means nothing).
    ///   - boardingLead: How long before departure boarding starts. Nil keeps the previous boarding time.
    static func nextState(
        attributes: FlightActivityAttributes,
        previous: State,
        schedule: ScheduleSnapshot?,
        aircraft: LiveAircraft?,
        lookedForAircraft: Bool = true,
        boardingLead: TimeInterval? = nil,
        memory: inout TrackingMemory,
        now: Date = .now
    ) -> State {
        var state = previous
        // "Last update" means new data arrived, not just that we looked.
        if schedule != nil || aircraft != nil { state.updatedAt = now }
        var phase = previous.phase

        if let schedule {
            state.departure = merge(schedule.departure, into: previous.departure)
            state.arrival = merge(schedule.arrival, into: previous.arrival)
            if schedule.phase == .cancelled || schedule.phase == .diverted {
                state.phase = schedule.phase
                return state
            }
            if rank(schedule.phase) > rank(phase) || previous.phase == .cancelled {
                phase = schedule.phase
            }
        }

        if let aircraft, let lat = aircraft.lat, let lon = aircraft.lon {
            let here = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            let speed = aircraft.groundSpeed ?? 0
            let altitude = aircraft.altitudeFeet ?? previous.altitudeFeet ?? 0
            let onGround = aircraft.isOnGround || (altitude < 300 && speed < 50)

            var remaining: Double?
            if let origin = attributes.origin, let destination = attributes.destination {
                let flown = Geo.distanceNM(origin.coordinate, here)
                let toGo = Geo.distanceNM(here, destination.coordinate)
                state.progress = flown + toGo > 0 ? flown / (flown + toGo) : 0
                remaining = toGo
            }
            state.altitudeFeet = onGround ? 0 : altitude
            state.groundSpeedKnots = Int(speed.rounded())
            state.verticalRateFPM = aircraft.verticalRate.map { Int($0.rounded()) }
            state.distanceRemainingNM = remaining.map { Int($0.rounded()) }
            state.positionIsEstimated = false

            if onGround {
                let nearDestination = (remaining ?? .infinity) < 15 || (state.progress ?? 0) > 0.93
                if memory.hasBeenAirborne || nearDestination {
                    if memory.landedAt == nil { memory.landedAt = now }
                    if state.arrival.runway == nil { state.arrival.runway = memory.landedAt }
                    memory.stoppedSince = speed < 3 ? (memory.stoppedSince ?? now) : nil
                    // Parked for two minutes after landing: at the gate.
                    if let stopped = memory.stoppedSince, now.timeIntervalSince(stopped) >= 120 {
                        phase = .arrived
                        if state.arrival.actual == nil { state.arrival.actual = stopped }
                    } else if phase != .arrived {
                        phase = .landed
                    }
                } else if speed >= 3 {
                    // Moving at the origin: pushed back and taxiing out.
                    if rank(phase) < rank(.taxiingOut) { phase = .taxiingOut }
                    if state.departure.actual == nil { state.departure.actual = now }
                }
            } else {
                if speed > 60 && !memory.hasBeenAirborne {
                    memory.hasBeenAirborne = true
                    memory.takeoffAt = now
                    if state.departure.runway == nil { state.departure.runway = now }
                    if state.departure.actual == nil { state.departure.actual = now }
                }
                memory.stoppedSince = nil
                let climb = aircraft.verticalRate ?? 0
                phase = climb > 300 ? .climbing : climb < -300 ? .descending : .cruising

                // No schedule: estimate arrival from distance and ground speed.
                if state.arrival.scheduled == nil, let remaining, speed > 60 {
                    var hours = remaining / speed
                    if remaining > 40 { hours += 0.1 } // approach and taxi
                    var estimate = now.addingTimeInterval(hours * 3600)
                    // Damp jitter from small speed changes between reports.
                    if let last = previous.arrival.estimated, abs(estimate.timeIntervalSince(last)) < 20 * 60 {
                        estimate = last.addingTimeInterval(estimate.timeIntervalSince(last) / 2)
                    }
                    state.arrival.estimated = estimate
                }
            }
        } else if lookedForAircraft, phase.isAirborne || (memory.hasBeenAirborne && rank(phase) < rank(.landed)) {
            // Out of ADS-B coverage (common over oceans): estimate progress from the schedule.
            state.positionIsEstimated = true
            phase = .cruising
            if let takeoff = state.departure.runway ?? memory.takeoffAt ?? state.departure.actual,
               let arrival = state.arrival.best {
                let landing = arrival.addingTimeInterval(-7 * 60)
                let total = landing.timeIntervalSince(takeoff)
                if total > 0 {
                    let progress = min(max(now.timeIntervalSince(takeoff) / total, 0), 0.99)
                    state.progress = progress
                    // Roughly the last 30 minutes of a typical flight are the descent.
                    if landing.timeIntervalSince(now) < 30 * 60 { phase = .descending }
                }
                // Long past the arrival time with no signal: it landed while we couldn't see it.
                if now > arrival.addingTimeInterval(30 * 60) { phase = .arrived }
            }
        }

        // Airlines don't always report boarding, so switch at the expected boarding time.
        if let boardingLead, let departure = state.departure.best {
            state.boardingStarts = departure.addingTimeInterval(-boardingLead)
        }
        if phase == .scheduled, let boarding = state.boardingStarts, let departure = state.departure.best,
           now >= boarding, now < departure.addingTimeInterval(30 * 60) {
            phase = .boarding
        }

        // Never step backwards (e.g. a stale schedule saying "boarding" after takeoff).
        if rank(phase) < rank(previous.phase), previous.phase != .cancelled, previous.phase != .diverted {
            phase = previous.phase
        }
        state.phase = phase
        return state
    }

    /// New schedule values win; things we detected ourselves are kept when the schedule doesn't have them.
    static func merge(_ new: Movement, into old: Movement) -> Movement {
        Movement(
            scheduled: new.scheduled ?? old.scheduled,
            estimated: new.estimated ?? old.estimated,
            actual: new.actual ?? old.actual,
            runway: new.runway ?? old.runway,
            terminal: new.terminal ?? old.terminal,
            gate: new.gate ?? old.gate,
            baggageBelt: new.baggageBelt ?? old.baggageBelt
        )
    }

    static func rank(_ phase: FlightPhase) -> Int {
        switch phase {
        case .scheduled, .cancelled: 0
        case .boarding: 1
        case .taxiingOut: 2
        case .climbing, .cruising, .descending: 3
        case .landed: 4
        case .arrived, .diverted: 5
        }
    }

    /// "Where's my plane?": the aircraft before it operates our flight.
    static func inbound(
        aircraft: LiveAircraft?,
        route: FlightRoute?,
        origin: FlightActivityAttributes.Airport?,
        now: Date = .now
    ) -> FlightActivityAttributes.Inbound? {
        guard let aircraft, let lat = aircraft.lat, let lon = aircraft.lon, let origin else { return nil }
        let here = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let toOrigin = Geo.distanceNM(here, origin.coordinate)
        let speed = aircraft.groundSpeed ?? 0
        let onGround = aircraft.isOnGround || ((aircraft.altitudeFeet ?? 0) < 300 && speed < 50)

        if onGround {
            return toOrigin < 5
                ? .init(status: .arrived)
                : .init(status: .elsewhere, fromCode: route?.origin.attribute.code)
        }
        // Only interesting if it's flying to the airport we leave from.
        if let route, route.destination.iataCode != origin.code, route.destination.icaoCode != origin.code {
            return nil
        }
        let hours = toOrigin / max(speed, 150) + (toOrigin > 40 ? 0.1 : 0)
        return .init(
            status: .inAir,
            flightNumber: route?.displayFlightNumber ?? aircraft.callsign,
            fromCode: route?.origin.attribute.code,
            arrival: now.addingTimeInterval(hours * 3600)
        )
    }
}

/// A made-up SFO → JFK trip fast-forwarded into five minutes, so every stage of the
/// Live Activity can be seen without waiting for a real flight: a delay, a gate change,
/// the inbound plane, boarding, taxi, takeoff, cruise, landing, gate arrival and the baggage belt.
enum DemoFlight {
    static let duration: TimeInterval = 300

    // Seconds into the demo.
    private static let gateChange: TimeInterval = 12
    private static let inboundLands: TimeInterval = 16
    private static let boardingStarts: TimeInterval = 22
    private static let pushback: TimeInterval = 50
    private static let takeoff: TimeInterval = 70
    private static let topOfClimb: TimeInterval = 105
    private static let arrivalGateKnown: TimeInterval = 150
    private static let topOfDescent: TimeInterval = 225
    private static let touchdown: TimeInterval = 265
    private static let atGate: TimeInterval = 282
    private static let bagsOut: TimeInterval = 292

    struct Sample {
        var state: FlightActivityAttributes.ContentState
        var coordinate: CLLocationCoordinate2D
        var track: Double
    }

    static func sample(startedAt start: Date, now: Date = .now) -> Sample {
        let attributes = FlightActivityAttributes.demo
        let origin = attributes.origin!.coordinate
        let destination = attributes.destination!.coordinate
        let totalNM = Geo.distanceNM(origin, destination)
        let t = min(max(now.timeIntervalSince(start), 0), duration)
        func at(_ offset: TimeInterval) -> Date { start.addingTimeInterval(offset) }

        let phase: FlightPhase = switch t {
        case ..<boardingStarts: .scheduled
        case ..<pushback: .boarding
        case ..<takeoff: .taxiingOut
        case ..<topOfClimb: .climbing
        case ..<topOfDescent: .cruising
        case ..<touchdown: .descending
        case ..<atGate: .landed
        default: .arrived
        }

        let progress = min(max((t - takeoff) / (touchdown - takeoff), 0), 1)
        let climbed = min(max((t - takeoff) / (topOfClimb - takeoff), 0), 1)
        let descended = min(max((t - topOfDescent) / (touchdown - topOfDescent), 0), 1)
        let (altitude, speed, climb): (Int, Int, Int) = switch phase {
        case .scheduled, .boarding: (0, 0, 0)
        case .taxiingOut: (0, 14, 0)
        case .climbing: (Int(37_000 * climbed), Int(160 + 328 * climbed), 2_300)
        case .cruising: (37_000, 488, 0)
        case .descending: (Int(37_000 * (1 - descended)), Int(488 - 340 * descended), -1_800)
        case .landed: (0, 18, 0)
        default: (0, 0, 0)
        }

        var departure = FlightActivityAttributes.Movement(
            scheduled: at(pushback - 15 * 60),
            estimated: at(pushback),
            terminal: "2",
            gate: t < gateChange ? "D12" : "D14"
        )
        if t >= pushback { departure.actual = at(pushback) }
        if t >= takeoff { departure.runway = at(takeoff) }

        var arrival = FlightActivityAttributes.Movement(
            scheduled: at(atGate - 4 * 60),
            estimated: at(atGate),
            terminal: "4"
        )
        if t >= arrivalGateKnown { arrival.gate = "B31" }
        if t >= touchdown { arrival.runway = at(touchdown) }
        if t >= atGate { arrival.actual = at(atGate) }
        if t >= bagsOut { arrival.baggageBelt = "7" }

        var inbound: FlightActivityAttributes.Inbound?
        if t < inboundLands {
            inbound = .init(status: .inAir, flightNumber: "FL 88", fromCode: "PDX", arrival: at(inboundLands))
        } else if t < boardingStarts {
            inbound = .init(status: .arrived)
        }

        let position = Geo.intermediate(from: origin, to: destination, fraction: progress)
        let state = FlightActivityAttributes.ContentState(
            phase: phase,
            departure: departure,
            arrival: arrival,
            progress: progress,
            altitudeFeet: altitude,
            groundSpeedKnots: speed,
            verticalRateFPM: climb,
            distanceRemainingNM: Int(totalNM * (1 - progress)),
            inbound: inbound,
            boardingStarts: at(boardingStarts),
            updatedAt: now
        )
        let track = progress < 1 ? Geo.bearing(from: position, to: destination) : 90
        return Sample(state: state, coordinate: position, track: track)
    }
}
