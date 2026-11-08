import Foundation

/// Airports people search for most, so "Bengaluru" or "BLR" can be recognised and suggested as you type.
enum KnownAirports {
    struct Airport: Hashable {
        var code: String
        var city: String
        /// Other names people use: "Bangalore", "Bombay".
        var aliases: [String] = []
    }

    static let all: [Airport] = [
        // India
        .init(code: "BLR", city: "Bengaluru", aliases: ["Bangalore"]), .init(code: "BOM", city: "Mumbai", aliases: ["Bombay"]),
        .init(code: "NMI", city: "Navi Mumbai"), .init(code: "DEL", city: "Delhi", aliases: ["New Delhi"]),
        .init(code: "MAA", city: "Chennai", aliases: ["Madras"]), .init(code: "CCU", city: "Kolkata", aliases: ["Calcutta"]),
        .init(code: "HYD", city: "Hyderabad"), .init(code: "COK", city: "Kochi", aliases: ["Cochin"]),
        .init(code: "GOI", city: "Goa", aliases: ["Dabolim"]), .init(code: "GOX", city: "Goa Mopa", aliases: ["Mopa"]),
        .init(code: "PNQ", city: "Pune"), .init(code: "AMD", city: "Ahmedabad"), .init(code: "JAI", city: "Jaipur"),
        .init(code: "LKO", city: "Lucknow"), .init(code: "PAT", city: "Patna"), .init(code: "RPR", city: "Raipur"),
        .init(code: "BBI", city: "Bhubaneswar"), .init(code: "IXC", city: "Chandigarh"), .init(code: "SXR", city: "Srinagar"),
        .init(code: "IXB", city: "Bagdogra", aliases: ["Siliguri"]), .init(code: "GAU", city: "Guwahati"),
        .init(code: "TRV", city: "Thiruvananthapuram", aliases: ["Trivandrum"]), .init(code: "CCJ", city: "Kozhikode", aliases: ["Calicut"]),
        .init(code: "IXE", city: "Mangaluru", aliases: ["Mangalore"]), .init(code: "NAG", city: "Nagpur"), .init(code: "IDR", city: "Indore"),
        .init(code: "BHO", city: "Bhopal"), .init(code: "VNS", city: "Varanasi"), .init(code: "IXR", city: "Ranchi"),
        .init(code: "VTZ", city: "Visakhapatnam", aliases: ["Vizag"]), .init(code: "CJB", city: "Coimbatore"),
        .init(code: "TRZ", city: "Tiruchirappalli", aliases: ["Trichy"]), .init(code: "IXM", city: "Madurai"),
        .init(code: "ATQ", city: "Amritsar"), .init(code: "DED", city: "Dehradun"), .init(code: "IXJ", city: "Jammu"),
        .init(code: "IXL", city: "Leh"), .init(code: "UDR", city: "Udaipur"), .init(code: "JDH", city: "Jodhpur"),
        .init(code: "STV", city: "Surat"), .init(code: "BDQ", city: "Vadodara", aliases: ["Baroda"]), .init(code: "IXZ", city: "Port Blair"),
        .init(code: "GAY", city: "Gaya"), .init(code: "IXA", city: "Agartala"), .init(code: "IMF", city: "Imphal"),
        .init(code: "VGA", city: "Vijayawada"), .init(code: "TIR", city: "Tirupati"), .init(code: "HBX", city: "Hubballi", aliases: ["Hubli"]),
        .init(code: "JLR", city: "Jabalpur"), .init(code: "GWL", city: "Gwalior"), .init(code: "IXU", city: "Aurangabad"),
        // Middle East
        .init(code: "DXB", city: "Dubai"), .init(code: "AUH", city: "Abu Dhabi"), .init(code: "DOH", city: "Doha"),
        .init(code: "SHJ", city: "Sharjah"), .init(code: "MCT", city: "Muscat"), .init(code: "BAH", city: "Bahrain"),
        .init(code: "KWI", city: "Kuwait"), .init(code: "RUH", city: "Riyadh"), .init(code: "JED", city: "Jeddah"),
        // Asia
        .init(code: "SIN", city: "Singapore"), .init(code: "KUL", city: "Kuala Lumpur"), .init(code: "BKK", city: "Bangkok"),
        .init(code: "DMK", city: "Bangkok Don Mueang"), .init(code: "HKT", city: "Phuket"), .init(code: "HKG", city: "Hong Kong"),
        .init(code: "SGN", city: "Ho Chi Minh City", aliases: ["Saigon"]), .init(code: "HAN", city: "Hanoi"),
        .init(code: "DAD", city: "Da Nang"), .init(code: "PQC", city: "Phu Quoc"), .init(code: "CMB", city: "Colombo"),
        .init(code: "KTM", city: "Kathmandu"), .init(code: "DAC", city: "Dhaka"), .init(code: "MLE", city: "Malé", aliases: ["Male", "Maldives"]),
        .init(code: "DPS", city: "Bali", aliases: ["Denpasar"]), .init(code: "CGK", city: "Jakarta"), .init(code: "MNL", city: "Manila"),
        .init(code: "TPE", city: "Taipei"), .init(code: "NRT", city: "Tokyo Narita"), .init(code: "HND", city: "Tokyo Haneda", aliases: ["Tokyo"]),
        .init(code: "ICN", city: "Seoul"), .init(code: "PEK", city: "Beijing"), .init(code: "PVG", city: "Shanghai"),
        // Europe, Americas, Oceania
        .init(code: "LHR", city: "London Heathrow", aliases: ["London"]), .init(code: "LGW", city: "London Gatwick"),
        .init(code: "CDG", city: "Paris"), .init(code: "FRA", city: "Frankfurt"), .init(code: "MUC", city: "Munich"),
        .init(code: "AMS", city: "Amsterdam"), .init(code: "ZRH", city: "Zurich"), .init(code: "IST", city: "Istanbul"),
        .init(code: "JFK", city: "New York JFK", aliases: ["New York"]), .init(code: "EWR", city: "Newark"),
        .init(code: "SFO", city: "San Francisco"), .init(code: "LAX", city: "Los Angeles"), .init(code: "ORD", city: "Chicago"),
        .init(code: "YYZ", city: "Toronto"), .init(code: "SYD", city: "Sydney"), .init(code: "MEL", city: "Melbourne"),
    ]

    /// "BLR", "blr", "Bengaluru" or "Bangalore" → "BLR". With `strict`, only codes FlightLive knows.
    static func code(for text: String, extra: [Airport] = [], strict: Bool = false) -> String? {
        let token = text.trimmingCharacters(in: .whitespaces)
        let airports = extra + all
        if token.count == 3, token.allSatisfy(\.isLetter) {
            let code = token.uppercased()
            return !strict || airports.contains { $0.code == code } ? code : nil
        }
        guard token.count >= 3 else { return nil }
        return airports.first { airport in
            ([airport.city] + airport.aliases).contains { $0.compare(token, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }?.code
    }

    /// Airports whose code or city starts with what's typed.
    static func matching(_ text: String, extra: [Airport] = []) -> [Airport] {
        let token = text.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return [] }
        var seen = Set<String>()
        return (extra + all).filter { airport in
            let byCode = token.count <= 3 && airport.code.hasPrefix(token.uppercased())
            let byName = token.count >= 2 && ([airport.city] + airport.aliases).contains {
                $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil
            }
            return (byCode || byName) && seen.insert(airport.code).inserted
        }
    }
}

/// Airlines to suggest as you type, with their codes.
enum Airlines {
    static let popular: [(name: String, code: String)] = [
        ("IndiGo", "6E"), ("Air India", "AI"), ("Air India Express", "IX"), ("Akasa Air", "QP"), ("SpiceJet", "SG"),
        ("Alliance Air", "9I"), ("Star Air", "S5"), ("Emirates", "EK"), ("Qatar Airways", "QR"), ("Etihad", "EY"),
        ("flydubai", "FZ"), ("Air Arabia", "G9"), ("Saudia", "SV"), ("Oman Air", "WY"), ("Gulf Air", "GF"),
        ("SriLankan Airlines", "UL"), ("Singapore Airlines", "SQ"), ("Scoot", "TR"), ("Cathay Pacific", "CX"),
        ("Thai Airways", "TG"), ("Malaysia Airlines", "MH"), ("AirAsia", "AK"), ("Vietnam Airlines", "VN"),
        ("VietJet Air", "VJ"), ("Lufthansa", "LH"), ("British Airways", "BA"), ("Virgin Atlantic", "VS"),
        ("Air France", "AF"), ("KLM", "KL"), ("Turkish Airlines", "TK"), ("United", "UA"), ("American Airlines", "AA"),
        ("Delta", "DL"), ("Air Canada", "AC"), ("Qantas", "QF"), ("Japan Airlines", "JL"), ("ANA", "NH"),
        ("Korean Air", "KE"), ("Swiss", "LX"), ("Ethiopian Airlines", "ET"),
    ]
}

/// "BLR to RPR", "BLR → RPR", "BLR-RPR", "Bengaluru to Raipur" or "BLR RPR".
enum RouteQuery {
    static func parse(_ text: String, extra: [KnownAirports.Airport] = []) -> (from: String, to: String)? {
        let query = text.trimmingCharacters(in: .whitespaces)
        for separator in [" to ", "→", "->", " - ", " – ", "–", "-"] {
            guard let range = query.range(of: separator, options: .caseInsensitive) else { continue }
            if let from = KnownAirports.code(for: String(query[..<range.lowerBound]), extra: extra),
               let to = KnownAirports.code(for: String(query[range.upperBound...]), extra: extra), from != to {
                return (from, to)
            }
        }
        // Two codes with just a space: only ones FlightLive knows, so "AAL 103" stays a flight number.
        let words = query.split(separator: " ").map(String.init)
        if words.count == 2, let from = KnownAirports.code(for: words[0], extra: extra, strict: true),
           let to = KnownAirports.code(for: words[1], extra: extra, strict: true), from != to {
            return (from, to)
        }
        return nil
    }
}

/// Something to tap under the search field.
struct SearchSuggestion: Identifiable, Hashable {
    var id: String { fill }
    var title: String
    var subtitle: String?
    var symbol: String
    /// What goes in the search field.
    var fill: String
    /// Search straight away, or keep typing (an airline still needs its flight number).
    var searchesNow: Bool
}

enum SearchSuggestions {
    /// Up to six: the other end of a route, recent searches, airlines and airports.
    static func make(for text: String, recent: [String], flights: [TrackedFlight]) -> [SearchSuggestion] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let yours = flights.flatMap { [$0.attributes.origin, $0.attributes.destination].compactMap { $0 } }
            .map { KnownAirports.Airport(code: $0.code, city: $0.city) }

        // "BLR to ra…": finish the route. Keep a trailing space, so "BLR to " counts as started.
        var typed = String(text.drop { $0.isWhitespace })
        if typed.lowercased().hasSuffix(" to") { typed += " " }
        for separator in [" to ", "→", " - "] {
            guard let range = typed.range(of: separator, options: .caseInsensitive),
                  let from = KnownAirports.code(for: String(typed[..<range.lowerBound]), extra: yours) else { continue }
            let rest = String(typed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // Nothing typed yet: where you've flown from there before.
            let destinations = rest.isEmpty
                ? flights.filter { $0.attributes.origin?.code == from }.compactMap(\.attributes.destination)
                    .map { KnownAirports.Airport(code: $0.code, city: $0.city) }
                : KnownAirports.matching(rest, extra: yours)
            var seen = Set<String>()
            return destinations.filter { $0.code != from && seen.insert($0.code).inserted }.prefix(6).map { airport in
                SearchSuggestion(title: "\(from) → \(airport.code)", subtitle: "Flights to \(airport.city)",
                                 symbol: "point.topleft.down.to.point.bottomright.curvepath", fill: "\(from) to \(airport.code)",
                                 searchesNow: true)
            }
        }

        var suggestions: [SearchSuggestion] = []
        for search in recent where search.hasPrefix(query.uppercased()) && search != query.uppercased() {
            suggestions.append(SearchSuggestion(title: search, symbol: "clock.arrow.circlepath", fill: search, searchesNow: true))
        }
        let airlines = Airlines.popular.filter { airline in
            airline.code.caseInsensitiveCompare(query) == .orderedSame
                || (query.count >= 2 && airline.name.range(of: query, options: [.caseInsensitive, .anchored]) != nil)
        }
        for airline in airlines {
            suggestions.append(SearchSuggestion(title: airline.name, subtitle: "\(airline.code) · then type the flight number",
                                                symbol: "airplane", fill: "\(airline.code) ", searchesNow: false))
        }
        for airport in KnownAirports.matching(query, extra: yours) {
            suggestions.append(SearchSuggestion(title: "\(airport.code) · \(airport.city)", subtitle: "Flights from \(airport.city)",
                                                symbol: "airplane.departure", fill: "\(airport.code) to ", searchesNow: false))
        }
        var seen = Set<String>()
        return Array(suggestions.filter { seen.insert($0.fill).inserted }.prefix(6))
    }
}
