import Foundation

// MARK: - Live positions (adsb.lol)

/// A live ADS-B position report from adsb.lol (ADS-B Exchange v2 format).
struct LiveAircraft: Decodable {
    enum Altitude: Decodable, Equatable {
        case ground
        case feet(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                guard text == "ground" else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unexpected altitude \(text)")
                }
                self = .ground
            } else {
                self = .feet(Int(try container.decode(Double.self)))
            }
        }
    }

    let hex: String
    let flight: String?
    let registration: String?
    let typeCode: String?
    let lat: Double?
    let lon: Double?
    let altitude: Altitude?
    let groundSpeed: Double?
    let track: Double?
    let baroRate: Double?
    let geomRate: Double?
    let seenPos: Double?

    enum CodingKeys: String, CodingKey {
        case hex, flight, lat, lon, track
        case registration = "r"
        case typeCode = "t"
        case altitude = "alt_baro"
        case groundSpeed = "gs"
        case baroRate = "baro_rate"
        case geomRate = "geom_rate"
        case seenPos = "seen_pos"
    }

    var callsign: String? {
        let trimmed = flight?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    var isOnGround: Bool { altitude == .ground }

    var altitudeFeet: Int? {
        switch altitude {
        case .ground: 0
        case .feet(let feet): feet
        case nil: nil
        }
    }

    var verticalRate: Double? { baroRate ?? geomRate }

    /// "Boeing 787-9 · N851MK"
    var typeAndRegistration: String? {
        let parts = [typeCode.map(AircraftTypes.name(for:)), registration].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Routes (adsbdb.com)

/// A route from adsbdb.com: which airports a callsign usually flies between.
struct FlightRoute: Decodable {
    struct Airline: Decodable {
        let name: String?
        let iata: String?
    }

    struct Airport: Decodable {
        let iataCode: String?
        let icaoCode: String?
        let latitude: Double
        let longitude: Double
        let municipality: String?
        let name: String?

        var attribute: FlightActivityAttributes.Airport {
            FlightActivityAttributes.Airport(
                code: iataCode ?? icaoCode ?? "???",
                city: municipality ?? name ?? "",
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    let callsign: String
    let callsignIcao: String?
    let callsignIata: String?
    let airline: Airline?
    let origin: Airport
    let destination: Airport

    /// "AA 103"
    var displayFlightNumber: String {
        guard let iata = callsignIata, iata.count > 2 else { return callsignIcao ?? callsign }
        return "\(iata.prefix(2)) \(iata.dropFirst(2))"
    }
}

// MARK: - Schedules, gates and delays (AeroDataBox)

/// Where the AeroDataBox key comes from. Both marketplaces have a free tier.
enum ScheduleProvider: String, Codable, CaseIterable, Identifiable {
    case rapidAPI, apiMarket

    var id: Self { self }

    var title: String {
        switch self {
        case .rapidAPI: "RapidAPI"
        case .apiMarket: "API.Market"
        }
    }

    var baseURL: String {
        switch self {
        case .rapidAPI: "https://aerodatabox.p.rapidapi.com"
        case .apiMarket: "https://prod.api.market/api/v1/aedbx/aerodatabox"
        }
    }

    var signUpURL: URL {
        switch self {
        case .rapidAPI: URL(string: "https://rapid.aerodatabox.com/pricing")!
        case .apiMarket: URL(string: "https://apimarket.aerodatabox.com/")!
        }
    }

    func headers(key: String) -> [String: String] {
        switch self {
        case .rapidAPI: ["X-RapidAPI-Key": key, "X-RapidAPI-Host": "aerodatabox.p.rapidapi.com"]
        case .apiMarket: ["x-api-market-key": key]
        }
    }
}

struct ScheduleCredentials {
    var provider: ScheduleProvider
    var key: String
}

/// How to fetch a flight's schedule again later.
struct ScheduleReference: Codable, Hashable {
    var number: String
    /// Local departure date, "yyyy-MM-dd".
    var date: String
}

/// One flight from AeroDataBox's flight status endpoint.
struct ScheduledFlight: Decodable {
    struct Airport: Decodable {
        struct Location: Decodable {
            let lat: Double
            let lon: Double
        }

        let icao: String?
        let iata: String?
        let name: String?
        let shortName: String?
        let municipalityName: String?
        let location: Location?
        let timeZone: String?

        var attribute: FlightActivityAttributes.Airport? {
            guard let location, let code = iata ?? icao else { return nil }
            return FlightActivityAttributes.Airport(
                code: code,
                city: municipalityName ?? shortName ?? name ?? code,
                latitude: location.lat,
                longitude: location.lon,
                timeZoneID: timeZone
            )
        }
    }

    struct Time: Decodable {
        let utc: String
        var date: Date? { AeroDataBox.parseTime(utc) }
    }

    struct Movement: Decodable {
        let airport: Airport
        let scheduledTime: Time?
        let revisedTime: Time?
        let predictedTime: Time?
        let runwayTime: Time?
        let terminal: String?
        let gate: String?
        let baggageBelt: String?

        /// `revisedTime` is the estimate until the plane moves, then the actual gate time.
        func movement(hasHappened: Bool) -> FlightActivityAttributes.Movement {
            let revised = revisedTime?.date ?? predictedTime?.date
            return FlightActivityAttributes.Movement(
                scheduled: scheduledTime?.date,
                estimated: revised,
                actual: hasHappened ? revised : nil,
                runway: runwayTime?.date,
                terminal: terminal,
                gate: gate,
                baggageBelt: baggageBelt
            )
        }
    }

    struct Aircraft: Decodable {
        let reg: String?
        let modeS: String?
        let model: String?
    }

    struct Airline: Decodable {
        let name: String?
        let iata: String?
        let icao: String?
    }

    let number: String
    let callSign: String?
    let status: String
    let departure: Movement
    let arrival: Movement
    let aircraft: Aircraft?
    let airline: Airline?

    var phase: FlightPhase {
        switch status {
        case "Boarding", "GateClosed": .boarding
        case "Departed": .taxiingOut
        case "EnRoute": .cruising
        case "Approaching": .descending
        case "Arrived": .arrived
        case "Canceled", "CanceledUncertain": .cancelled
        case "Diverted": .diverted
        default: .scheduled
        }
    }

    var departureMovement: FlightActivityAttributes.Movement {
        departure.movement(hasHappened: phase.hasDeparted && phase != .cancelled)
    }

    var arrivalMovement: FlightActivityAttributes.Movement {
        arrival.movement(hasHappened: phase == .arrived)
    }

    /// "UA 930"
    var displayNumber: String {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), trimmed.count > 2 else { return trimmed }
        return "\(trimmed.prefix(2)) \(trimmed.dropFirst(2))"
    }

    var aircraftDescription: String? {
        let parts = [aircraft?.model, aircraft?.reg].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum ScheduleError: LocalizedError {
    /// `rateLimited`: too many requests a second, which the free plan allows only one of. Not the monthly quota.
    case badKey, quotaExceeded, rateLimited, server(Int)

    var errorDescription: String? {
        switch self {
        case .badKey: "Your AeroDataBox key was rejected. Check it in Settings."
        case .quotaExceeded: "You've used up this month's AeroDataBox requests. Schedules will update again when the quota resets."
        case .rateLimited: "AeroDataBox asked FlightLive to slow down. Try again in a moment."
        case .server(let code): "The schedule service returned an error (\(code))."
        }
    }
}

struct KeyCheckResult {
    var works: Bool
    var message: String
}

enum AeroDataBox {
    /// Tests a key with AeroDataBox's free status endpoint, which doesn't use any of the monthly quota.
    static func checkKey(_ credentials: ScheduleCredentials) async -> KeyCheckResult {
        guard let url = URL(string: "\(credentials.provider.baseURL)/health/services/feeds/FlightSchedules") else {
            return KeyCheckResult(works: false, message: "Couldn't build the test request.")
        }
        var request = URLRequest(url: url)
        for (field, value) in credentials.provider.headers(key: credentials.key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await HTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let serverMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            switch status {
            case 200, 204, 503:
                return KeyCheckResult(works: true, message: "Your key works. Schedules, gates and delays are on.")
            case 429:
                return KeyCheckResult(works: true, message: "Your key works, but this month's free requests are used up.")
            case 403 where serverMessage?.localizedCaseInsensitiveContains("not subscribed") == true:
                return KeyCheckResult(works: false, message: "\(credentials.provider.title) says this key isn't subscribed to AeroDataBox. Subscribe to the free Basic plan, and copy the key from the Headers tab (X-RapidAPI-Key).")
            case 400, 401, 403:
                return KeyCheckResult(works: false, message: "That key isn't valid\(serverMessage.map { ": \($0)" } ?? "."). Copy it again, and check the Marketplace setting matches where you signed up.")
            default:
                return KeyCheckResult(works: false, message: "AeroDataBox answered with an unexpected error (\(status)). Try again in a minute.")
            }
        } catch {
            return KeyCheckResult(works: false, message: "Couldn't reach AeroDataBox: \(error.localizedDescription)")
        }
    }

    /// Flights operating under a flight number on a local date ("yyyy-MM-dd"), or the nearest date if nil.
    /// The free plan allows about one request a second, so a "slow down" is waited out and tried again.
    static func flights(number: String, date: String?, credentials: ScheduleCredentials) async throws -> [ScheduledFlight] {
        try await retryingWhenRateLimited {
            try await requestFlights(number: number, date: date, credentials: credentials)
        }
    }

    /// Every departure from an airport over a local day, each with both ends of its trip. The API gives at most
    /// 12 hours at a time, so this is one request for the rest of today, or two for another day.
    static func departures(from airport: FlightActivityAttributes.Airport, day: Date, credentials: ScheduleCredentials) async throws -> [ScheduledFlight] {
        let zone = airport.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = calendar.startOfDay(for: day)
        let end = midnight.addingTimeInterval(24 * 3600 - 60)
        var start = midnight
        if calendar.isDate(day, inSameDayAs: .now) { start = max(midnight, Date().addingTimeInterval(-3600)) }
        var flights: [ScheduledFlight] = []
        var isFirstRequest = true
        while start < end {
            let windowEnd = min(start.addingTimeInterval(12 * 3600 - 60), end)
            if !isFirstRequest { try await Task.sleep(for: .milliseconds(1_200)) } // about one a second
            isFirstRequest = false
            flights += try await retryingWhenRateLimited {
                try await requestDepartures(airport: airport, from: start, to: windowEnd, credentials: credentials)
            }
            start = windowEnd.addingTimeInterval(60)
        }
        return flights
    }

    /// The free plan allows about one request a second, so a "slow down" is waited out and tried again.
    private static func retryingWhenRateLimited<T>(_ request: () async throws -> T) async throws -> T {
        for attempt in 1...3 {
            do {
                return try await request()
            } catch ScheduleError.rateLimited where attempt < 3 {
                try await Task.sleep(for: .milliseconds(1_500 * attempt))
            }
        }
        throw ScheduleError.rateLimited
    }

    /// Skips any flight that doesn't decode rather than losing the whole board.
    private struct Lenient: Decodable {
        let flight: ScheduledFlight?
        init(from decoder: Decoder) throws { flight = try? ScheduledFlight(from: decoder) }
    }

    private static func requestDepartures(airport: FlightActivityAttributes.Airport, from: Date, to: Date,
                                          credentials: ScheduleCredentials) async throws -> [ScheduledFlight] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = airport.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let urlString = "\(credentials.provider.baseURL)/flights/airports/iata/\(escape(airport.code))/\(formatter.string(from: from))/\(formatter.string(from: to))"
            + "?withLeg=true&direction=Departure&withCancelled=true&withCodeshared=false&withCargo=false&withPrivate=false&withLocation=false"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        for (field, value) in credentials.provider.headers(key: credentials.key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await HTTP.session.data(for: request)
        #if DEBUG
        print("[aerodatabox]", url.path, (response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data.prefix(400), as: UTF8.self))
        #endif
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try departuresBoard(data, from: airport)
        case 204, 404: return []
        case 401, 403: throw ScheduleError.badKey
        case 429: throw tooManyRequests(data)
        case let code: throw ScheduleError.server(code)
        }
    }

    private static func requestFlights(number: String, date: String?, credentials: ScheduleCredentials) async throws -> [ScheduledFlight] {
        var urlString = "\(credentials.provider.baseURL)/flights/number/\(escape(number))"
        if let date { urlString += "/\(date)" }
        // The date is the day it leaves; otherwise a late flight landing that day matches too.
        urlString += "?withAircraftImage=false&withLocation=false" + (date == nil ? "" : "&dateLocalRole=Departure")
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        for (field, value) in credentials.provider.headers(key: credentials.key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await HTTP.session.data(for: request)
        #if DEBUG
        print("[aerodatabox]", url.path, (response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data.prefix(400), as: UTF8.self))
        #endif
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONDecoder().decode([ScheduledFlight].self, from: data)
        case 204, 404: return []
        case 401, 403: throw ScheduleError.badKey
        case 429: throw tooManyRequests(data)
        case let code: throw ScheduleError.server(code)
        }
    }

    /// A departures board leaves out the departure airport, since it's the one asked about; put it back so each
    /// entry reads like a single flight's record.
    private static func departuresBoard(_ data: Data, from airport: FlightActivityAttributes.Airport) throws -> [ScheduledFlight] {
        guard let board = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entries = board["departures"] as? [[String: Any]] else { return [] }
        let origin: [String: Any] = [
            "iata": airport.code, "municipalityName": airport.city, "timeZone": airport.timeZone.identifier,
            "location": ["lat": airport.latitude, "lon": airport.longitude],
        ]
        for index in entries.indices {
            guard var departure = entries[index]["departure"] as? [String: Any], departure["airport"] == nil else { continue }
            departure["airport"] = origin
            entries[index]["departure"] = departure
        }
        let fixed = try JSONSerialization.data(withJSONObject: entries)
        return try JSONDecoder().decode([Lenient].self, from: fixed).compactMap(\.flight)
    }

    /// RapidAPI answers 429 both for the monthly quota and for going faster than the plan's rate limit.
    private static func tooManyRequests(_ data: Data) -> ScheduleError {
        let message = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
        let monthly = ["month", "quota", "exceeded the"].contains { message.localizedCaseInsensitiveContains($0) }
        return monthly ? .quotaExceeded : .rateLimited
    }

    /// An airport by its IATA code, with its time zone. Uses one request from the monthly quota.
    static func airport(iata: String, credentials: ScheduleCredentials) async throws -> FlightActivityAttributes.Airport? {
        guard let url = URL(string: "\(credentials.provider.baseURL)/airports/iata/\(escape(iata))") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        for (field, value) in credentials.provider.headers(key: credentials.key) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await HTTP.session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try JSONDecoder().decode(ScheduledFlight.Airport.self, from: data).attribute
        case 204, 404: return nil
        case 401, 403: throw ScheduleError.badKey
        case 429: throw tooManyRequests(data)
        case let code: throw ScheduleError.server(code)
        }
    }

    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// AeroDataBox times look like "2026-10-25 14:05Z"; accept ISO 8601 variants too.
    static func parseTime(_ text: String) -> Date? {
        for formatter in timeFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let timeFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mmXXXXX", "yyyy-MM-dd'T'HH:mmXXXXX",
        "yyyy-MM-dd HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - HTTP

enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "FlightLive/2.0 (iOS)"]
        return URLSession(configuration: config)
    }()
}

private func escape(_ component: String) -> String {
    component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
}

enum FlightAPI {
    private struct RouteEnvelope: Decodable {
        struct Response: Decodable { let flightroute: FlightRoute }
        let response: Response
    }

    private struct AircraftEnvelope: Decodable {
        let ac: [LiveAircraft]?
    }

    struct AirlineInfo: Decodable {
        let name: String?
        let icao: String?
        let iata: String?
    }

    private struct AirlineEnvelope: Decodable {
        let response: [AirlineInfo]
    }

    /// Looks up an airline by its ICAO ("IGO") or IATA ("6E") code. Nil if unknown.
    static func airline(code: String) async throws -> AirlineInfo? {
        let (data, status) = try await get("https://api.adsbdb.com/v0/airline/\(escape(code))")
        guard status == 200 else { return nil }
        return try? JSONDecoder().decode(AirlineEnvelope.self, from: data).response.first
    }

    /// Looks up the route for an ICAO ("AAL103") or IATA ("AA103") flight number. Nil if unknown.
    static func route(callsign: String) async throws -> FlightRoute? {
        let (data, status) = try await get("https://api.adsbdb.com/v0/callsign/\(escape(callsign))")
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RouteEnvelope.self, from: data).response.flightroute
    }

    static func aircraft(callsign: String) async throws -> LiveAircraft? {
        try await aircraft(path: "callsign/\(escape(callsign))")
    }

    static func aircraft(registration: String) async throws -> LiveAircraft? {
        try await aircraft(path: "reg/\(escape(registration))")
    }

    static func aircraft(hex: String) async throws -> LiveAircraft? {
        try await aircraft(path: "hex/\(escape(hex.lowercased()))")
    }

    private static func aircraft(path: String) async throws -> LiveAircraft? {
        let (data, status) = try await get("https://api.adsb.lol/v2/\(path)")
        guard status == 200 else { throw URLError(.badServerResponse) }
        let list = try JSONDecoder().decode(AircraftEnvelope.self, from: data).ac ?? []
        // Prefer the freshest report that has a position.
        let positioned = list.filter { $0.lat != nil && $0.lon != nil }
        return positioned.min { ($0.seenPos ?? .infinity) < ($1.seenPos ?? .infinity) } ?? list.first
    }

    private static func get(_ urlString: String) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, response) = try await HTTP.session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - Search

/// A flight found by a search, ready to be added to My Flights.
struct FlightCandidate: Identifiable {
    let id = UUID()
    var attributes: FlightActivityAttributes
    var state: FlightActivityAttributes.ContentState
    var callsign: String?
    var hex: String?
    var schedule: ScheduleReference?
    var aircraft: LiveAircraft?
}

enum FlightLookup {
    struct NotFound: LocalizedError {
        var query: String
        var hasSchedules: Bool
        var isRoute = false

        var errorDescription: String? {
            if isRoute {
                return "Searching by route needs your free AeroDataBox key. Add it in Settings, or search by flight number."
            }
            return hasSchedules
                ? "No flight \(query) on that day. Check the flight number and date."
                : "Couldn't find \(query). It isn't in the air and its route isn't known. Add a free AeroDataBox key in Settings to find any flight by number and date."
        }
    }

    /// Accepts "UA930", "UAL 930", "N172SP" or "G-ELUE", and what people say to Siri: "IndiGo 2001", "United flight 930".
    static func search(_ rawQuery: String, date: Date, credentials: ScheduleCredentials?) async throws -> [FlightCandidate] {
        let query = normalize(rawQuery).filter { !$0.isWhitespace }
        let compact = query.replacingOccurrences(of: "-", with: "")
        guard !compact.isEmpty else { throw NotFound(query: rawQuery, hasSchedules: credentials != nil) }

        if let credentials {
            let day = AeroDataBox.dayString(date)
            let flights = try await AeroDataBox.flights(number: compact, date: day, credentials: credentials)
            let candidates = flights.compactMap { candidate(from: $0, reference: ScheduleReference(number: compact, date: day)) }
            if !candidates.isEmpty { return candidates }
        }

        // Without schedules (or for a tail number), look for the plane in the air right now.
        guard let live = try await liveCandidate(query: query, compact: compact) else {
            throw NotFound(query: query, hasSchedules: credentials != nil)
        }
        return [live]
    }

    struct NoFlightsOnRoute: LocalizedError {
        var from: String
        var to: String
        var errorDescription: String? { "No direct flights from \(from) to \(to) on that day." }
    }

    /// Direct flights between two airports on a day, earliest first. Uses one or two AeroDataBox requests.
    @MainActor
    static func searchRoute(from: String, to: String, date: Date, credentials: ScheduleCredentials,
                            knownAirports: [FlightActivityAttributes.Airport]) async throws -> [FlightCandidate] {
        guard let origin = await AirportDirectory.airport(from, known: knownAirports, credentials: credentials) else {
            throw NoFlightsOnRoute(from: from, to: to)
        }
        let zone = origin.timeZone
        let departures = try await AeroDataBox.departures(from: origin, day: date, credentials: credentials)
        let candidates = departures
            .filter { $0.arrival.airport.iata == to || $0.arrival.airport.icao == to }
            .compactMap { flight -> FlightCandidate? in
                let day = flight.departure.scheduledTime?.date.map { AeroDataBox.dayString($0, timeZone: zone) }
                let reference = day.map { ScheduleReference(number: flight.number.filter { !$0.isWhitespace }, date: $0) }
                return candidate(from: flight, reference: reference)
            }
            .sorted { ($0.state.departure.best ?? .distantFuture) < ($1.state.departure.best ?? .distantFuture) }
        guard !candidates.isEmpty else { throw NoFlightsOnRoute(from: from, to: to) }
        return candidates
    }

    /// Turns a typed or spoken flight into a flight or tail number:
    /// "IndiGo 2001" → 6E 2001, "the United flight 930" → UA 930, "Air India one oh one" → AI 101.
    static func normalize(_ rawQuery: String) -> String {
        let fillers: Set<String> = ["the", "my", "flight", "flights", "number", "no", "no.", "#", "plane"]
        let digits = ["zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4",
                      "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        let words = rawQuery.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !fillers.contains($0) }
            .map { digits[$0] ?? $0 }
        var text = words.joined(separator: " ")
        // Longest names first, so "air india express" wins over "air india".
        for (name, code) in airlineNames.sorted(by: { $0.key.count > $1.key.count }) where text.hasPrefix(name) {
            let rest = text.dropFirst(name.count)
            if rest.isEmpty || rest.first == " " || rest.first?.isNumber == true {
                text = code + " " + rest.trimmingCharacters(in: .whitespaces)
                break
            }
        }
        return text.uppercased()
    }

    /// Airline names people say instead of their two-letter codes.
    private static let airlineNames: [String: String] = [
        "indigo": "6E", "air india": "AI", "air india express": "IX", "akasa": "QP", "akasa air": "QP",
        "spicejet": "SG", "spice jet": "SG", "alliance air": "9I", "star air": "S5",
        "emirates": "EK", "qatar": "QR", "qatar airways": "QR", "etihad": "EY", "flydubai": "FZ", "fly dubai": "FZ",
        "air arabia": "G9", "saudia": "SV", "oman air": "WY", "gulf air": "GF", "kuwait airways": "KU",
        "srilankan": "UL", "sri lankan": "UL", "biman": "BG",
        "singapore": "SQ", "singapore airlines": "SQ", "scoot": "TR", "cathay": "CX", "cathay pacific": "CX",
        "thai": "TG", "thai airways": "TG", "malaysia": "MH", "malaysia airlines": "MH", "airasia": "AK", "air asia": "AK",
        "vietnam airlines": "VN", "vietjet": "VJ", "vietjet air": "VJ", "vistara": "UK", "philippine airlines": "PR", "garuda": "GA", "eva air": "BR", "china airlines": "CI",
        "air china": "CA", "china eastern": "MU", "china southern": "CZ", "korean air": "KE", "asiana": "OZ",
        "ana": "NH", "all nippon": "NH", "jal": "JL", "japan airlines": "JL", "qantas": "QF", "virgin australia": "VA",
        "air new zealand": "NZ",
        "lufthansa": "LH", "british airways": "BA", "virgin atlantic": "VS", "air france": "AF", "klm": "KL",
        "turkish": "TK", "turkish airlines": "TK", "swiss": "LX", "austrian": "OS", "finnair": "AY", "sas": "SK",
        "iberia": "IB", "aer lingus": "EI", "tap": "TP", "brussels airlines": "SN", "ryanair": "FR", "easyjet": "U2",
        "ethiopian": "ET", "kenya airways": "KQ", "royal jordanian": "RJ",
        "united": "UA", "american": "AA", "american airlines": "AA", "delta": "DL", "southwest": "WN",
        "jetblue": "B6", "jet blue": "B6", "alaska": "AS", "alaska airlines": "AS", "hawaiian": "HA",
        "frontier": "F9", "spirit": "NK", "air canada": "AC", "westjet": "WS", "aeromexico": "AM",
        "latam": "LA", "avianca": "AV", "copa": "CM",
    ]

    static func candidate(from flight: ScheduledFlight, reference: ScheduleReference?) -> FlightCandidate? {
        let attributes = FlightActivityAttributes(
            flightNumber: flight.displayNumber,
            airlineCode: flight.airline?.iata,
            airline: flight.airline?.name,
            aircraft: flight.aircraftDescription,
            origin: flight.departure.airport.attribute,
            destination: flight.arrival.airport.attribute
        )
        let state = FlightActivityAttributes.ContentState(
            phase: flight.phase,
            departure: flight.departureMovement,
            arrival: flight.arrivalMovement,
            updatedAt: .now
        )
        return FlightCandidate(
            attributes: attributes,
            state: state,
            callsign: flight.callSign?.replacingOccurrences(of: " ", with: ""),
            hex: flight.aircraft?.modeS?.lowercased(),
            schedule: reference
        )
    }

    private static func liveCandidate(query: String, compact: String) async throws -> FlightCandidate? {
        var route = try await FlightAPI.route(callsign: compact)
        var aircraft: LiveAircraft?
        if let route {
            aircraft = try await FlightAPI.aircraft(callsign: route.callsignIcao ?? route.callsign)
        } else {
            aircraft = try await FlightAPI.aircraft(callsign: compact)
            if aircraft == nil {
                aircraft = try await FlightAPI.aircraft(registration: query)
            }
            // Found by tail number: see whether the flight it's operating has a known route.
            if let callsign = aircraft?.callsign, callsign != compact {
                route = try? await FlightAPI.route(callsign: callsign)
            }
        }
        guard let aircraft else {
            // Not in the air yet, but the route is known: add it now and pick the plane up when it takes off.
            guard let route else { return nil }
            let attributes = FlightActivityAttributes(
                flightNumber: route.displayFlightNumber,
                airlineCode: route.airline?.iata,
                airline: route.airline?.name,
                origin: route.origin.attribute,
                destination: route.destination.attribute
            )
            return FlightCandidate(
                attributes: attributes,
                state: FlightActivityAttributes.ContentState(phase: .scheduled, updatedAt: .now),
                callsign: route.callsignIcao ?? route.callsign
            )
        }

        let attributes = FlightActivityAttributes(
            flightNumber: route?.displayFlightNumber ?? aircraft.registration ?? aircraft.callsign ?? query,
            airlineCode: route?.airline?.iata,
            airline: route?.airline?.name,
            // Without a route the tail number is already the headline, so only add the type.
            aircraft: route == nil ? aircraft.typeCode.map(AircraftTypes.name(for:)) : aircraft.typeAndRegistration,
            origin: route?.origin.attribute,
            destination: route?.destination.attribute
        )
        var memory = TrackingMemory()
        let state = FlightMath.nextState(
            attributes: attributes,
            previous: FlightActivityAttributes.ContentState(phase: .scheduled, updatedAt: .now),
            schedule: nil,
            aircraft: aircraft,
            memory: &memory
        )
        return FlightCandidate(
            attributes: attributes,
            state: state,
            callsign: route?.callsignIcao ?? aircraft.callsign ?? compact,
            hex: aircraft.hex,
            aircraft: aircraft
        )
    }
}

enum AircraftTypes {
    private static let names: [String: String] = [
        "A19N": "Airbus A319neo", "A20N": "Airbus A320neo", "A21N": "Airbus A321neo",
        "A318": "Airbus A318", "A319": "Airbus A319", "A320": "Airbus A320", "A321": "Airbus A321",
        "A332": "Airbus A330-200", "A333": "Airbus A330-300", "A338": "Airbus A330-800", "A339": "Airbus A330-900",
        "A343": "Airbus A340-300", "A346": "Airbus A340-600", "A359": "Airbus A350-900", "A35K": "Airbus A350-1000",
        "A388": "Airbus A380", "BCS1": "Airbus A220-100", "BCS3": "Airbus A220-300",
        "B712": "Boeing 717", "B737": "Boeing 737-700", "B738": "Boeing 737-800", "B739": "Boeing 737-900",
        "B37M": "Boeing 737 MAX 7", "B38M": "Boeing 737 MAX 8", "B39M": "Boeing 737 MAX 9", "B3XM": "Boeing 737 MAX 10",
        "B744": "Boeing 747-400", "B748": "Boeing 747-8", "B752": "Boeing 757-200", "B753": "Boeing 757-300",
        "B762": "Boeing 767-200", "B763": "Boeing 767-300", "B764": "Boeing 767-400",
        "B772": "Boeing 777-200", "B77L": "Boeing 777-200LR", "B77W": "Boeing 777-300ER", "B778": "Boeing 777-8", "B779": "Boeing 777-9",
        "B788": "Boeing 787-8", "B789": "Boeing 787-9", "B78X": "Boeing 787-10",
        "E170": "Embraer 170", "E75L": "Embraer 175", "E75S": "Embraer 175", "E190": "Embraer 190", "E195": "Embraer 195",
        "E290": "Embraer E190-E2", "E295": "Embraer E195-E2",
        "CRJ2": "Bombardier CRJ200", "CRJ7": "Bombardier CRJ700", "CRJ9": "Bombardier CRJ900", "CRJX": "Bombardier CRJ1000",
        "DH8D": "De Havilland Dash 8-400", "AT72": "ATR 72", "AT76": "ATR 72-600", "AT75": "ATR 72-500",
        "C152": "Cessna 152", "C172": "Cessna 172", "C182": "Cessna 182", "C208": "Cessna Caravan",
        "P28A": "Piper PA-28", "PA46": "Piper Malibu", "SR20": "Cirrus SR20", "SR22": "Cirrus SR22", "SF50": "Cirrus Vision Jet",
        "DA40": "Diamond DA40", "DA42": "Diamond DA42", "PC12": "Pilatus PC-12", "TBM9": "Daher TBM 900",
        "BE36": "Beechcraft Bonanza", "BE20": "Beechcraft King Air 200", "C25A": "Cessna Citation CJ2", "GLF6": "Gulfstream G650",
    ]

    static func name(for code: String) -> String {
        names[code] ?? code
    }
}
