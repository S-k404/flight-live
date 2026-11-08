import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Flight details found in an email, an airport text message, a Notion or Claude note, or anything else shared to FlightLive.
struct FlightTextDetails: Equatable {
    enum Status: String, CaseIterable {
        case boarding, finalCall, gateClosed, delayed, cancelled, departed, landed, onTime
    }

    /// Compact flight number, e.g. "6E2001".
    var flightNumber: String?
    /// Departure date and time as written (local to the departure airport). Hour and minute may be missing.
    var departure: DateComponents?
    var gate: String?
    var terminal: String?
    var seat: String?
    var confirmationCode: String?
    var baggageBelt: String?
    var status: Status?

    var isEmpty: Bool {
        flightNumber == nil && departure == nil && gate == nil && terminal == nil && seat == nil
            && confirmationCode == nil && baggageBelt == nil && status == nil
    }

    /// Fills anything missing here from `other`.
    func filling(from other: FlightTextDetails) -> FlightTextDetails {
        var merged = self
        merged.flightNumber = flightNumber ?? other.flightNumber
        merged.departure = departure ?? other.departure
        merged.gate = gate ?? other.gate
        merged.terminal = terminal ?? other.terminal
        merged.seat = seat ?? other.seat
        merged.confirmationCode = confirmationCode ?? other.confirmationCode
        merged.baggageBelt = baggageBelt ?? other.baggageBelt
        merged.status = status ?? other.status
        return merged
    }

    /// "6E 2001 · Gate 23 · Boarding"
    var summary: String {
        var parts: [String] = []
        if let flightNumber { parts.append("\(flightNumber.prefix(2)) \(flightNumber.dropFirst(2))") }
        if let gate { parts.append("gate \(gate)") }
        if let terminal { parts.append("Terminal \(terminal)") }
        if let seat { parts.append("seat \(seat)") }
        if let baggageBelt { parts.append("belt \(baggageBelt)") }
        if let status { parts.append(status.label) }
        return parts.joined(separator: " · ")
    }
}

extension FlightTextDetails.Status {
    var label: String {
        switch self {
        case .boarding: "boarding"
        case .finalCall: "final call"
        case .gateClosed: "gate closed"
        case .delayed: "delayed"
        case .cancelled: "cancelled"
        case .departed: "departed"
        case .landed: "landed"
        case .onTime: "on time"
        }
    }
}

enum FlightTextParser {
    /// Pattern matching first (instant, works everywhere), then Apple Intelligence's on-device model
    /// for anything it missed, when the iPhone supports it. Nothing leaves the phone.
    static func details(from text: String, useOnDeviceModel: Bool = true) async -> FlightTextDetails {
        let quick = patterns(in: text)
        guard useOnDeviceModel, quick.flightNumber == nil || quick.departure == nil || quick.status == nil else { return quick }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), var model = await onDeviceModel(text) {
            // Status only from the text's own words: the model tends to guess "boarding" for any booking.
            model.status = nil
            return quick.filling(from: model)
        }
        #endif
        return quick
    }

    // MARK: Pattern matching

    private static let flightContext = #"(?i)\b(flight|flt|gate|boarding|departure|depart|departs|PNR|booking|terminal|airport|itinerary|e-?ticket|belt|carousel)\b"#

    static func patterns(in text: String) -> FlightTextDetails {
        var details = FlightTextDetails()
        // "Lunch tomorrow at 1:30" has a time but nothing to do with flying.
        guard text.range(of: flightContext, options: .regularExpression) != nil
                || text.range(of: #"\b[A-Z]{3}\s*(-|–|→|to)\s*[A-Z]{3}\b"#, options: .regularExpression) != nil
        else { return details }
        details.flightNumber = flightNumber(in: text)
        details.gate = first(#"(?i)\bgate\s*(?:no\.?|number|#|:)?\s*([A-Z]?\d{1,3}[A-Z]?)\b"#, in: text)?.uppercased()
        details.terminal = first(#"(?i)\bterminal\s*(?:no\.?|:)?\s*T?(\d|[A-Z])\b"#, in: text)?.uppercased()
            ?? first(#"\bT([1-9])\b"#, in: text)
        details.seat = first(#"(?i)\bseat\s*(?:no\.?|number|#|:)?\s*(\d{1,2}[A-K])\b"#, in: text)?.uppercased()
        details.confirmationCode = first(
            #"(?i)\b(?:PNR|booking\s+(?:reference|ref\.?|code|id)|confirmation\s*(?:code|number|#)?|record\s+locator)\s*(?:is|:|#|no\.?)?\s*([A-Z0-9]{6})\b"#,
            in: text
        )?.uppercased()
        details.baggageBelt = first(#"(?i)\b(?:belt|carousel|baggage\s+claim)\s*(?:no\.?|number|#|:)?\s*(\d{1,2}[A-Z]?)\b"#, in: text)?.uppercased()
        details.status = status(in: text)
        details.departure = firstDate(in: text)
        return details
    }

    /// A flight number in text that mentions a flight, airport, gate or booking.
    static func flightNumber(in text: String) -> String? {
        guard text.range(of: flightContext, options: .regularExpression) != nil
                || text.range(of: #"\b[A-Z]{3}\s*(-|–|→|to)\s*[A-Z]{3}\b"#, options: .regularExpression) != nil,
              let regex = try? NSRegularExpression(pattern: #"\b([A-Z]{2}|[A-Z][0-9]|[0-9][A-Z])\s?-?\s?([0-9]{1,4})\b"#)
        else { return nil }
        let notAirlines: Set<String> = ["AM", "PM", "TO", "AT", "ON", "IN", "OF", "NO", "ID", "OR", "BY", "UP",
                                        "Q1", "Q2", "Q3", "Q4", "H1", "H2", "T1", "T2", "T3", "IS", "IT", "AS", "BE"]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let airline = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let number = Range(match.range(at: 2), in: text).map({ String(text[$0]) }),
                  !notAirlines.contains(airline) else { continue }
            // "Gate 23" or "Terminal 2" aren't flights.
            let before = text[text.startIndex..<(Range(match.range, in: text)?.lowerBound ?? text.startIndex)].suffix(10).lowercased()
            if before.hasSuffix("gate ") || before.hasSuffix("terminal ") || before.hasSuffix("seat ") { continue }
            return airline + String(Int(number) ?? 0)
        }
        return nil
    }

    static func status(in text: String) -> FlightTextDetails.Status? {
        let checks: [(String, FlightTextDetails.Status)] = [
            (#"(?i)\bcancel(l)?ed\b|\bcancellation\b"#, .cancelled),
            (#"(?i)\bfinal\s+(boarding\s+)?call\b|\blast\s+call\b"#, .finalCall),
            (#"(?i)\bgate\s+(is\s+)?(now\s+)?clos(ed|ing)\b|\bboarding\s+closed\b"#, .gateClosed),
            (#"(?i)\b(now\s+boarding|is\s+boarding|boarding\s+(has\s+)?(started|commenced|begun|is\s+open|now\s+open))\b"#, .boarding),
            // "Boarding for flight 6E 2001 to Mumbai has commenced at Gate 23"
            (#"(?i)\bboarding\b[^.]{0,60}\b(has\s+|is\s+)?(commenced|started|begun|opened|now\s+open)\b"#, .boarding),
            (#"(?i)\bdelay(ed)?\b|\brescheduled\b|\brevised\s+(departure|time|ETD)\b|\bnew\s+(departure\s+)?time\b"#, .delayed),
            (#"(?i)\b(has\s+)?(departed|took\s+off)\b"#, .departed),
            (#"(?i)\b(has\s+)?(landed|arrived)\b"#, .landed),
            (#"(?i)\bon\s+time\b|\bon\s+schedule\b"#, .onTime),
        ]
        return checks.first { text.range(of: $0.0, options: .regularExpression) != nil }?.1
    }

    /// The departure day and time. "Tue 28 Oct 2026, departs 07:45" mentions them separately, so the day comes
    /// from the last mention of a date and the time from the last mention of a time (usually the newest one).
    static func firstDate(in text: String) -> DateComponents? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        struct Found { var date: Date; var hasTime: Bool; var timeOnly: Bool }
        let found = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Found? in
            guard let date = match.date else { return nil }
            let snippet = Range(match.range, in: text).map { String(text[$0]) } ?? ""
            let hasTime = snippet.range(of: #"\d{1,2}[:.h]\d{2}|\d\s*(am|pm|AM|PM)|\d{4}\s*hrs"#, options: .regularExpression) != nil
            let timeOnly = snippet.range(of: #"(?i)^\s*(at\s+)?\d{1,2}[:.h]?\d{2}\s*(am|pm|hrs|h)?\s*$"#, options: .regularExpression) != nil
            return Found(date: date, hasTime: hasTime, timeOnly: timeOnly)
        }
        let day = found.last { !$0.timeOnly }
        let time = found.last { $0.hasTime }
        guard let dayOrTime = day ?? time else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: dayOrTime.date)
        if let time {
            let clock = Calendar.current.dateComponents([.hour, .minute], from: time.date)
            components.hour = clock.hour
            components.minute = clock.minute
        }
        return components
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: Apple Intelligence

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    static var onDeviceModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func onDeviceModel(_ text: String) async -> FlightTextDetails? {
        guard onDeviceModelAvailable else { return nil }
        // Pulling details out of your own messages is a content transformation, so the lighter guardrails apply.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: """
            You read airline emails, airport text messages and travel notes and pull out flight details. \
            Only report what the text actually says. Leave a field empty if the text doesn't mention it.
            """)
        let prompt = "Extract the flight details from this text:\n\n" + String(text.prefix(4000))
        guard let extracted = try? await session.respond(to: prompt, generating: ExtractedFlight.self).content else { return nil }
        return extracted.details
    }
    #endif
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct ExtractedFlight {
    @Guide(description: "Airline flight number like UA930, 6E2001 or AI 101. Empty if there is none.")
    var flightNumber: String
    @Guide(description: "Departure date as yyyy-MM-dd. Empty if not mentioned.")
    var departureDate: String
    @Guide(description: "Departure time as 24-hour HH:mm, the newest one if it changed. Empty if not mentioned.")
    var departureTime: String
    @Guide(description: "Departure gate, like 23 or B12. Empty if not mentioned.")
    var gate: String
    @Guide(description: "Departure terminal, like 1 or 2. Empty if not mentioned.")
    var terminal: String
    @Guide(description: "Seat, like 23A. Empty if not mentioned.")
    var seat: String
    @Guide(description: "Booking reference or PNR, 6 letters and digits. Empty if not mentioned.")
    var bookingReference: String
    @Guide(description: "Baggage belt or carousel number. Empty if not mentioned.")
    var baggageBelt: String
    @Guide(description: "One of: boarding, final call, gate closed, delayed, cancelled, departed, landed, on time, none.")
    var status: String

    var details: FlightTextDetails {
        func clean(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || ["none", "n/a", "unknown"].contains(trimmed.lowercased()) ? nil : trimmed.uppercased()
        }
        var result = FlightTextDetails()
        result.flightNumber = clean(flightNumber).map { $0.filter { $0.isLetter || $0.isNumber } }
            .flatMap { FlightTextParser.flightNumber(in: "flight \($0.prefix(2)) \($0.dropFirst(2))") }
        result.gate = clean(gate)
        result.terminal = clean(terminal).map { $0.replacingOccurrences(of: "T", with: "") }
        result.seat = clean(seat)
        result.confirmationCode = clean(bookingReference).flatMap { $0.count == 6 ? $0 : nil }
        result.baggageBelt = clean(baggageBelt)
        result.status = switch status.lowercased().trimmingCharacters(in: .whitespaces) {
        case "boarding": .boarding
        case "final call": .finalCall
        case "gate closed": .gateClosed
        case "delayed": .delayed
        case "cancelled", "canceled": .cancelled
        case "departed": .departed
        case "landed": .landed
        case "on time": .onTime
        default: nil
        }
        let parts = departureDate.split(separator: "-").compactMap { Int($0) }
        let time = departureTime.split(separator: ":").compactMap { Int($0) }
        if parts.count == 3 || time.count == 2 {
            var components = DateComponents()
            if parts.count == 3 { (components.year, components.month, components.day) = (parts[0], parts[1], parts[2]) }
            if time.count == 2 { (components.hour, components.minute) = (time[0], time[1]) }
            result.departure = components
        }
        return result
    }
}
#endif
