import CoreLocation
import Foundation
import MapKit

/// A flight you've already taken, read from a Flighty export or a calendar event.
struct PastFlightRecord {
    /// A time as written: local to the airport ("2026-10-25T14:05"), or an exact instant from a calendar.
    enum Time {
        case local(String)
        case exact(Date)

        func date(in zone: TimeZone) -> Date? {
            switch self {
            case .exact(let date): date
            case .local(let text): PastFlightImport.parseLocal(text, zone: zone)
            }
        }
    }

    /// "6E978" or "IGO978".
    var flightNumber: String
    /// IATA airport codes. Nil when unknown, e.g. from a calendar event; the usual route is used then.
    var from: String?
    var to: String?
    /// Local date, "yyyy-MM-dd", for exports that only give the day.
    var day: String?
    var departureScheduled: Time?
    var departureActual: Time?
    var arrivalScheduled: Time?
    var arrivalActual: Time?
    var departureTerminal: String?
    var departureGate: String?
    var arrivalTerminal: String?
    var arrivalGate: String?
    var aircraft: String?
    var tail: String?
    var seat: String?
    var cancelled = false
}

enum PastFlightImport {
    // MARK: - Flighty

    /// Reads Flighty's CSV export. Columns are found by name, so similar exports from other apps work too.
    static func records(fromCSV text: String) -> [PastFlightRecord] {
        let rows = CSV.parse(text)
        guard let header = rows.first else { return [] }
        let columns = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: String...) -> Int? {
            names.lazy.compactMap { columns.firstIndex(of: $0) }.first
        }
        guard let flightColumn = column("flight", "flight number", "flight #"),
              let fromColumn = column("from", "origin", "departure airport"),
              let toColumn = column("to", "destination", "arrival airport") else { return [] }
        let airlineColumn = column("airline", "airline code")
        let dayColumn = column("date")
        let depScheduled = column("gate departure (scheduled)", "take off (scheduled)", "scheduled departure")
        let depActual = column("gate departure (actual)", "take off (actual)", "actual departure")
        let arrScheduled = column("gate arrival (scheduled)", "landing (scheduled)", "scheduled arrival")
        let arrActual = column("gate arrival (actual)", "landing (actual)", "actual arrival")

        return rows.dropFirst().compactMap { row in
            func value(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let text = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            guard var number = value(flightColumn)?.uppercased().filter({ !$0.isWhitespace }),
                  let from = value(fromColumn)?.uppercased(), let to = value(toColumn)?.uppercased(),
                  from.count == 3, to.count == 3 else { return nil }
            // Flighty keeps the airline in its own column: "IGO" + "978".
            if number.allSatisfy(\.isNumber), let airline = value(airlineColumn)?.uppercased() {
                number = airline + number
            }
            let cancelled = value(column("canceled", "cancelled")).map { ["true", "yes", "1"].contains($0.lowercased()) } ?? false
            return PastFlightRecord(
                flightNumber: number,
                from: from,
                to: to,
                day: value(dayColumn),
                departureScheduled: value(depScheduled).map(PastFlightRecord.Time.local),
                departureActual: value(depActual).map(PastFlightRecord.Time.local),
                arrivalScheduled: value(arrScheduled).map(PastFlightRecord.Time.local),
                arrivalActual: value(arrActual).map(PastFlightRecord.Time.local),
                departureTerminal: value(column("dep terminal", "departure terminal")),
                departureGate: value(column("dep gate", "departure gate")),
                arrivalTerminal: value(column("arr terminal", "arrival terminal")),
                arrivalGate: value(column("arr gate", "arrival gate")),
                aircraft: value(column("aircraft type name", "aircraft type", "aircraft")),
                tail: value(column("tail number", "registration", "tail")),
                seat: value(column("seat")),
                cancelled: cancelled
            )
        }
    }

    // MARK: - Calendar

    /// Flights in calendar events over the past two years.
    static func calendarRecords(now: Date = .now) -> [PastFlightRecord] {
        CalendarImport.flights(from: now.addingTimeInterval(-2 * 365 * 24 * 3600), to: now.addingTimeInterval(-3600))
            .map { found in
                PastFlightRecord(
                    flightNumber: found.flightNumber,
                    departureScheduled: .exact(found.departure),
                    arrivalScheduled: found.arrival.map(PastFlightRecord.Time.exact)
                )
            }
    }

    // MARK: - Building flights

    /// Turns a record into a finished flight, finding its airline and airports. Nil if the airports can't be found.
    @MainActor
    static func flight(from record: PastFlightRecord, knownAirports: [FlightActivityAttributes.Airport],
                       credentials: ScheduleCredentials?, lookUpDetails: Bool = true) async -> TrackedFlight? {
        // "IGO978" → airline IGO, number 978. Three letters is an ICAO code; otherwise the first two characters.
        let compact = record.flightNumber
        let prefixLength = compact.prefix(3).allSatisfy(\.isLetter) && compact.count > 3 ? 3 : 2
        let airlineCode = String(compact.prefix(prefixLength))
        let digits = String(compact.dropFirst(prefixLength))
        async let airlineLookup = AirportDirectory.airline(airlineCode)

        var known = knownAirports
        var usualRoute: (origin: FlightActivityAttributes.Airport, destination: FlightActivityAttributes.Airport)?
        let needsRoute = [record.from, record.to].contains { code in
            code.map { code in !known.contains { $0.code == code } && AirportDirectory.cached(code) == nil } ?? true
        }
        if needsRoute, let route = try? await FlightAPI.route(callsign: compact) {
            let origin = route.origin.attribute, destination = route.destination.attribute
            // A calendar event doesn't say where; otherwise only trust the usual route if it's the same one.
            if record.from == nil || (record.from == origin.code && record.to == destination.code) {
                usualRoute = (origin, destination)
                known += [origin, destination]
            }
        }
        guard let fromCode = record.from ?? usualRoute?.origin.code,
              let toCode = record.to ?? usualRoute?.destination.code else { return nil }
        async let originLookup = AirportDirectory.airport(fromCode, known: known, credentials: credentials)
        async let destinationLookup = AirportDirectory.airport(toCode, known: known, credentials: credentials)
        guard let origin = await originLookup, let destination = await destinationLookup else { return nil }
        let airline = await airlineLookup

        var state = FlightActivityAttributes.ContentState(phase: record.cancelled ? .cancelled : .arrived, updatedAt: .now)
        state.departure.scheduled = record.departureScheduled?.date(in: origin.timeZone)
        state.departure.actual = record.departureActual?.date(in: origin.timeZone)
        state.arrival.scheduled = record.arrivalScheduled?.date(in: destination.timeZone)
        state.arrival.actual = record.arrivalActual?.date(in: destination.timeZone)
        if state.departure.best == nil, let day = record.day {
            // Only the day is known: call it midday, so it lands on the right date.
            state.departure.scheduled = parseLocal(day + "T12:00", zone: origin.timeZone)
        }
        guard state.departure.best != nil else { return nil }
        state.departure.terminal = record.departureTerminal
        state.departure.gate = record.departureGate
        state.arrival.terminal = record.arrivalTerminal
        state.arrival.gate = record.arrivalGate
        state.seat = record.seat

        let aircraft = [record.aircraft, record.tail].compactMap { $0 }.joined(separator: " · ")
        let attributes = FlightActivityAttributes(
            flightNumber: "\(airline?.iata ?? airlineCode) \(digits)",
            airlineCode: airline?.iata ?? (prefixLength == 2 ? airlineCode : nil),
            airline: airline?.name,
            aircraft: aircraft.isEmpty ? nil : aircraft,
            origin: origin,
            destination: destination
        )
        var flight = TrackedFlight(attributes: attributes, state: state)
        flight.seat = record.seat
        flight.addedAt = state.departure.best ?? .now
        // One AeroDataBox request each: for a big import that's left to the Passport's button, which spreads them out.
        if lookUpDetails, let credentials, record.aircraft == nil, !record.cancelled {
            do {
                flight = try await withScheduleDetails(flight, credentials: credentials) ?? flight
                flight.pastDetailsChecked = true
            } catch {
                // Couldn't ask right now; the Passport's button tries again later.
            }
        }
        return flight
    }

    /// The plane, its tail number and the real gate times from AeroDataBox's records of that day.
    /// One request from the monthly quota. Nil if AeroDataBox has no record of it; throws if it couldn't be asked.
    static func withScheduleDetails(_ flight: TrackedFlight, credentials: ScheduleCredentials) async throws -> TrackedFlight? {
        guard let origin = flight.attributes.origin, let departure = flight.state.departure.best else { return nil }
        let number = flight.attributes.flightNumber.filter { !$0.isWhitespace }
        let day = AeroDataBox.dayString(departure, timeZone: origin.timeZone)
        let found: [ScheduledFlight]
        do {
            found = try await AeroDataBox.flights(number: number, date: day, credentials: credentials)
        } catch ScheduleError.server(let code) where code == 400 {
            return nil // a date AeroDataBox doesn't keep records for
        }
        let destination = flight.attributes.destination?.code
        let match = found.first { $0.departure.airport.iata == origin.code && $0.arrival.airport.iata == destination }
            ?? (found.count == 1 ? found.first : nil)
        guard let match, let record = FlightLookup.candidate(from: match, reference: nil) else { return nil }

        var updated = flight
        updated.attributes.aircraft = record.attributes.aircraft ?? flight.attributes.aircraft
        updated.attributes.airline = flight.attributes.airline ?? record.attributes.airline
        updated.attributes.airlineCode = flight.attributes.airlineCode ?? record.attributes.airlineCode
        var state = record.state
        if state.departure.best != nil {
            // It's over: keep it arrived, unless AeroDataBox says it was cancelled. And keep the seat.
            if flight.state.phase.isFinal && state.phase != .cancelled { state.phase = flight.state.phase }
            state.seat = flight.state.seat
            state.units = flight.state.units
            state.departure.gate = state.departure.gate ?? flight.state.departure.gate
            state.departure.terminal = state.departure.terminal ?? flight.state.departure.terminal
            updated.state = state
        }
        updated.hex = flight.hex ?? record.hex
        return updated
    }

    /// "2026-10-25T14:05", "2026-10-25 14:05:00" or a full ISO 8601 time with an offset.
    static func parseLocal(_ text: String, zone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Finds airports and airlines by code, and remembers them so each is looked up once.
@MainActor
enum AirportDirectory {
    private static let cacheKey = "airportDirectory"
    private static var airports: [String: FlightActivityAttributes.Airport] = {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: FlightActivityAttributes.Airport].self, from: data)) ?? [:]
    }()
    private static let airlineCacheKey = "airlineDirectory"
    private static var airlines: [String: FlightAPI.AirlineInfo] = {
        guard let data = UserDefaults.standard.data(forKey: airlineCacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: FlightAPI.AirlineInfo].self, from: data)) ?? [:]
    }()
    /// Asked about and not known, so it isn't asked again until the app is reopened.
    private static var unknownAirlines: Set<String> = []

    /// An airport already looked up on this phone, with its time zone.
    static func cached(_ code: String) -> FlightActivityAttributes.Airport? { airports[code] }

    static func airline(_ code: String) async -> FlightAPI.AirlineInfo? {
        if let cached = airlines[code] { return cached }
        if unknownAirlines.contains(code) { return nil }
        // A failed request says nothing about the airline, so only a real "unknown" is remembered.
        let info: FlightAPI.AirlineInfo?
        do {
            info = try await FlightAPI.airline(code: code)
        } catch {
            return nil
        }
        guard let info else {
            unknownAirlines.insert(code)
            return nil
        }
        airlines[code] = info
        if let data = try? JSONEncoder().encode(airlines) { UserDefaults.standard.set(data, forKey: airlineCacheKey) }
        return info
    }

    /// From what's already known, then AeroDataBox (with a key), then Apple Maps.
    static func airport(_ code: String, known: [FlightActivityAttributes.Airport],
                        credentials: ScheduleCredentials?) async -> FlightActivityAttributes.Airport? {
        if let cached = airports[code] { return cached }
        var found = known.first { $0.code == code && $0.timeZoneID != nil }
        if found == nil, var partial = known.first(where: { $0.code == code }) {
            // adsbdb routes don't say the time zone; Apple's geocoder does.
            partial.timeZoneID = await timeZoneID(latitude: partial.latitude, longitude: partial.longitude)
            found = partial
        }
        if found == nil, let credentials {
            found = try? await AeroDataBox.airport(iata: code, credentials: credentials)
        }
        if found == nil {
            found = await searchMaps(code)
        }
        if let found, found.timeZoneID != nil {
            airports[code] = found
            if let data = try? JSONEncoder().encode(airports) { UserDefaults.standard.set(data, forKey: cacheKey) }
        }
        return found
    }

    private static func timeZoneID(latitude: Double, longitude: Double) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude))
        return placemarks?.first?.timeZone?.identifier
    }

    private static func searchMaps(_ code: String) async -> FlightActivityAttributes.Airport? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = "\(code) airport"
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.airport])
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate = item.placemark.coordinate
        return FlightActivityAttributes.Airport(
            code: code,
            city: item.placemark.locality ?? item.name ?? code,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timeZoneID: item.timeZone?.identifier
        )
    }
}

/// A small CSV reader: quoted fields, commas and line breaks inside quotes, and "" for a quote.
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" || character == "\r" {
                row.append(field)
                field = ""
                if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                row = []
            } else {
                field.append(character)
            }
        }
        row.append(field)
        if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        return rows
    }
}
