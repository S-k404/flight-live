import Foundation

/// A flight written down in a Notion database.
struct NotionFlight: Equatable {
    var pageID: String
    /// Compact flight number, e.g. "6E978".
    var flightNumber: String
    /// Departure, when the Notion date has a time.
    var departure: Date?
    /// Local date ("yyyy-MM-dd") when the Notion date has no time.
    var day: String?
    var arrival: Date?
    /// IATA codes, when the page says.
    var from: String?
    var to: String?
    var seat: String?
    var confirmationCode: String?
    var gate: String?
    var terminal: String?

    /// The departure, or midday on the day when only the date is known.
    var roughDeparture: Date? {
        departure ?? day.flatMap { PastFlightImport.parseLocal($0 + "T12:00", zone: .current) }
    }
}

/// Reads flights from a Notion database, through an integration you make in Notion and connect to the database.
enum NotionImport {
    struct Source: Identifiable, Hashable {
        var id: String
        var title: String
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    private static let base = "https://api.notion.com/v1"
    private static let version = "2025-09-03"

    /// The databases the integration can see, i.e. the ones connected to it in Notion.
    static func sources(token: String) async throws -> [Source] {
        var sources: [Source] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": ["property": "object", "value": "data_source"], "page_size": 100]
            body["start_cursor"] = cursor
            let page = try await post("/search", body: body, token: token)
            for result in page["results"] as? [[String: Any]] ?? [] {
                guard let id = result["id"] as? String else { continue }
                let title = plainText(result["title"]) ?? ""
                sources.append(Source(id: id, title: title.isEmpty ? "Untitled" : title))
            }
            cursor = page["has_more"] as? Bool == true ? page["next_cursor"] as? String : nil
        } while cursor != nil
        return sources
    }

    /// Every page in the database that has a flight number.
    static func flights(sourceID: String, token: String) async throws -> [NotionFlight] {
        var flights: [NotionFlight] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            body["start_cursor"] = cursor
            let page = try await post("/data_sources/\(sourceID)/query", body: body, token: token)
            flights += (page["results"] as? [[String: Any]] ?? []).compactMap(flight(fromPage:))
            cursor = page["has_more"] as? Bool == true ? page["next_cursor"] as? String : nil
        } while cursor != nil
        return flights
    }

    /// Something to track for an upcoming flight: the real schedule with a key, else the usual route with Notion's times.
    static func candidate(for entry: NotionFlight, credentials: ScheduleCredentials?) async -> FlightCandidate? {
        var candidate: FlightCandidate?
        if let departure = entry.departure {
            let found = CalendarFlight(id: entry.pageID, flightNumber: entry.flightNumber, departure: departure,
                                       arrival: entry.arrival, eventTitle: entry.flightNumber)
            candidate = try? await CalendarImport.candidate(for: found, credentials: credentials)
        } else if let credentials, let day = entry.roughDeparture {
            // Only the day: the schedule knows the time.
            candidate = try? await FlightLookup.search(entry.flightNumber, date: day, credentials: credentials).first
        }
        if candidate == nil, let route = try? await FlightAPI.route(callsign: entry.flightNumber) {
            // No time and no key: add it on its route, and you can put the time in yourself.
            candidate = FlightCandidate(
                attributes: FlightActivityAttributes(
                    flightNumber: route.displayFlightNumber,
                    airlineCode: route.airline?.iata,
                    airline: route.airline?.name,
                    origin: route.origin.attribute,
                    destination: route.destination.attribute
                ),
                state: FlightActivityAttributes.ContentState(phase: .scheduled, updatedAt: .now),
                callsign: route.callsignIcao ?? route.callsign
            )
        }
        if candidate?.state.departure.gate == nil { candidate?.state.departure.gate = entry.gate }
        if candidate?.state.departure.terminal == nil { candidate?.state.departure.terminal = entry.terminal }
        return candidate
    }

    // MARK: - Reading a page

    /// Columns are found by name, so a database you already have probably works as it is.
    static func flight(fromPage page: [String: Any]) -> NotionFlight? {
        guard let pageID = page["id"] as? String, page["in_trash"] as? Bool != true, page["archived"] as? Bool != true,
              let properties = page["properties"] as? [String: [String: Any]] else { return nil }
        let byName = Dictionary(properties.map { ($0.key.trimmingCharacters(in: .whitespaces).lowercased(), $0.value) },
                                uniquingKeysWith: { first, _ in first })
        func property(_ names: [String], type: String? = nil) -> [String: Any]? {
            names.lazy.compactMap { byName[$0] }.first { type == nil || $0["type"] as? String == type }
        }
        func text(_ names: String...) -> String? { property(names).flatMap(Self.text(of:)) }

        // The flight: a "Flight" column, with the airline from its own column if it's just a number,
        // or else whatever flight number is in the page's title.
        let title = properties.values.first { $0["type"] as? String == "title" }.flatMap(Self.text(of:))
        var spoken = text("flight", "flight number", "flight no", "flight no.", "flight #", "flight code")
        if let number = spoken, number.allSatisfy({ $0.isNumber || $0.isWhitespace }),
           let airline = text("airline", "carrier") {
            spoken = "\(airline) \(number)"
        }
        let compact = (spoken.map(FlightLookup.normalize) ?? "").filter { !$0.isWhitespace }
        guard let flightNumber = isFlightNumber(compact) ? compact
                : title.flatMap({ CalendarImport.flightNumber(in: FlightLookup.normalize($0), requireContext: false) })
        else { return nil }

        let departureNames = ["departure", "departs", "departure time", "date", "flight date", "when", "day"]
        let dateProperty = property(departureNames, type: "date")
            ?? properties.values.first { $0["type"] as? String == "date" }
        let date = dateProperty?["date"] as? [String: Any]
        let start = date.flatMap { parseDate($0["start"] as? String, zoneID: $0["time_zone"] as? String) }
        let arrivalDate = (property(["arrival", "arrives", "arrival time", "lands"], type: "date")?["date"] as? [String: Any])
            .flatMap { parseDate($0["start"] as? String, zoneID: $0["time_zone"] as? String) }
        let end = date.flatMap { parseDate($0["end"] as? String, zoneID: $0["time_zone"] as? String) }

        return NotionFlight(
            pageID: pageID,
            flightNumber: flightNumber,
            departure: start?.exact,
            day: start?.day,
            arrival: arrivalDate?.exact ?? end?.exact,
            from: text("from", "origin", "departure airport", "leaving from").flatMap(airportCode),
            to: text("to", "destination", "arrival airport", "going to").flatMap(airportCode),
            seat: text("seat")?.uppercased(),
            confirmationCode: text("booking", "booking code", "booking reference", "pnr", "confirmation", "confirmation code")?.uppercased(),
            gate: text("gate")?.uppercased(),
            terminal: text("terminal")?.uppercased()
        )
    }

    /// Any property as plain text: title, text, select, number, formula, URL and so on.
    static func text(of property: [String: Any]) -> String? {
        guard let type = property["type"] as? String, let value = property[type] else { return nil }
        let text: String?
        switch value {
        case let parts as [[String: Any]] where type == "title" || type == "rich_text":
            text = plainText(parts)
        case let options as [[String: Any]]:
            text = options.compactMap { $0["name"] as? String }.joined(separator: ", ")
        case let option as [String: Any]:
            if let name = option["name"] as? String {
                text = name
            } else if let kind = option["type"] as? String {
                // A formula or rollup: its own little typed value.
                text = option[kind].map { "\($0)" }
            } else {
                text = nil
            }
        case let number as NSNumber:
            text = number.doubleValue == number.doubleValue.rounded() ? "\(number.intValue)" : number.stringValue
        case let string as String:
            text = string
        default:
            text = nil
        }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func plainText(_ value: Any?) -> String? {
        guard let parts = value as? [[String: Any]] else { return nil }
        return parts.compactMap { $0["plain_text"] as? String }.joined()
    }

    private static func isFlightNumber(_ compact: String) -> Bool {
        compact.range(of: #"^([A-Z]{2,3}|[A-Z][0-9]|[0-9][A-Z])[0-9]{1,4}[A-Z]?$"#, options: .regularExpression) != nil
    }

    /// "BLR", "blr", "Bengaluru (BLR)" or "BLR – Kempegowda" → "BLR".
    private static func airportCode(_ text: String) -> String? {
        if text.count == 3, text.allSatisfy(\.isLetter) { return text.uppercased() }
        guard let range = text.range(of: #"\b[A-Z]{3}\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Notion dates are "2026-10-25" or "2026-10-25T14:05:00.000+05:30" (or without the offset, plus a time zone).
    private static func parseDate(_ text: String?, zoneID: String?) -> (exact: Date?, day: String?)? {
        guard let text else { return nil }
        if text.count == 10 { return (nil, text) }
        let zone = zoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return PastFlightImport.parseLocal(trimmed, zone: zone).map { ($0, nil) }
    }

    // MARK: - Requests

    private static func post(_ path: String, body: [String: Any], token: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await HTTP.session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            return json
        case 401:
            throw Failure(errorDescription: "Notion didn't accept that secret. Copy the Internal Integration Secret again from Notion's integration page.")
        case 404:
            throw Failure(errorDescription: "Notion can't find that database. In Notion, open the database, tap ••• › Connections and add your FlightLive integration.")
        case 429:
            throw Failure(errorDescription: "Notion asked FlightLive to slow down. Try again in a minute.")
        case let code:
            throw Failure(errorDescription: "Notion returned an error (\(code))\((json["message"] as? String).map { ": \($0)" } ?? ".")")
        }
    }
}
