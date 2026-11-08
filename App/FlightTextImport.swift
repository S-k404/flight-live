import AppIntents
import Foundation

struct TextImportResult {
    var flightID: UUID?
    var message: String
}

/// Turns shared or pasted text (booking emails, airport text messages, notes) into a new flight or an update to one.
extension FlightStore {
    func importText(_ text: String) async -> TextImportResult {
        let details = await FlightTextParser.details(from: text)
        guard !details.isEmpty else {
            return TextImportResult(message: "I couldn't find any flight details in that.")
        }

        var target = matchingFlight(for: details)
        if target == nil, details.flightNumber == nil {
            // An update without a flight number: only safe if there's exactly one flight coming up.
            let active = upcoming.filter { !$0.state.phase.isFinal && !$0.isDemo }
            if active.count == 1 { target = active.first }
        }

        var added = false
        if target == nil {
            guard let number = details.flightNumber else {
                return TextImportResult(message: "I found \(details.summary), but not which flight it's for.")
            }
            guard let candidate = await candidate(for: number, details: details) else {
                return TextImportResult(message: "I found flight \(number) but couldn't look up its route.")
            }
            let id = await add(candidate)
            target = flight(id)
            added = true
        }
        guard let flight = target else { return TextImportResult(message: "Something went wrong adding that flight.") }

        let changes = await applyTextDetails(details, to: flight.id)
        let name = flight.attributes.flightNumber
        let message: String
        if added {
            let extra = changes.isEmpty ? "" : " with \(changes.joined(separator: ", "))"
            message = "Added \(name)\(extra)."
        } else if changes.isEmpty {
            message = "\(name) is already up to date."
        } else {
            message = "Updated \(name): \(changes.joined(separator: ", "))."
        }
        return TextImportResult(flightID: flight.id, message: message)
    }

    /// Text or a link from the Share Sheet. A link with no flight in the text itself, like Flighty's, is opened and its page read.
    func importShared(_ text: String) async -> TextImportResult {
        let result = await importText(text)
        guard result.flightID == nil else { return result }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        let links = (detector?.matches(in: text, range: range) ?? []).compactMap(\.url).filter { $0.scheme?.hasPrefix("http") == true }
        for link in links {
            guard let page = await pageText(link) else { continue }
            let fromPage = await importText(page)
            if fromPage.flightID != nil { return fromPage }
        }
        return result
    }

    /// The title, description and visible text of a web page, enough for the text reader to find a flight in.
    private func pageText(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        func matches(_ pattern: String, in text: String) -> [String] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: $0.numberOfRanges - 1), in: text).map { String(text[$0]) }
            }
        }
        // <title> and <meta> descriptions first: share pages often keep the flight there.
        var pieces = matches("<title[^>]*>(.*?)</title>", in: html)
        for tag in matches("(<meta[^>]*>)", in: html) where tag.localizedCaseInsensitiveContains("description") || tag.localizedCaseInsensitiveContains("title") {
            pieces += matches("content=\"([^\"]*)\"", in: tag)
        }
        let body = html
            .replacingOccurrences(of: "<(script|style)[^>]*>.*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        pieces.append(body)
        let text = pieces.joined(separator: "\n")
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(6000))
    }

    /// The tracked flight this text is about: same flight number, nearest departure.
    private func matchingFlight(for details: FlightTextDetails) -> TrackedFlight? {
        guard let number = details.flightNumber else { return nil }
        let candidates = flights.filter {
            !$0.isDemo && $0.attributes.flightNumber.filter { !$0.isWhitespace } == number
        }
        guard let approx = approximateDeparture(details) else {
            return candidates.first { !$0.state.phase.isFinal } ?? candidates.last
        }
        return candidates
            .filter { abs(($0.state.departure.best ?? approx).timeIntervalSince(approx)) < 36 * 3600 }
            .min { abs(($0.state.departure.best ?? approx).timeIntervalSince(approx))
                < abs(($1.state.departure.best ?? approx).timeIntervalSince(approx)) }
    }

    private func approximateDeparture(_ details: FlightTextDetails) -> Date? {
        details.departure.flatMap { Calendar.current.date(from: $0) }
    }

    /// Reads the departure in the airport's own time zone ("18:45" at BLR means 18:45 in India).
    private func resolve(_ components: DateComponents, in zone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var full = components
        if full.year == nil || full.month == nil || full.day == nil {
            let today = calendar.dateComponents([.year, .month, .day], from: .now)
            (full.year, full.month, full.day) = (today.year, today.month, today.day)
        }
        return calendar.date(from: full)
    }

    private func candidate(for number: String, details: FlightTextDetails) async -> FlightCandidate? {
        let approx = approximateDeparture(details) ?? .now
        if let credentials = AppSettings.shared.credentials,
           let found = try? await FlightLookup.search(number, date: approx, credentials: credentials).first,
           found.schedule != nil {
            return found
        }
        guard let route = try? await FlightAPI.route(callsign: number) else { return nil }
        let origin = route.origin.attribute
        let departure = details.departure?.hour == nil ? nil : details.departure.flatMap { resolve($0, in: origin.timeZone) }
        let found = CalendarFlight(id: "text-\(number)", flightNumber: number, departure: departure ?? approx,
                                   arrival: nil, eventTitle: number)
        guard var candidate = try? await CalendarImport.candidate(for: found, credentials: nil) else { return nil }
        if departure == nil { candidate.state.departure.estimated = nil } // only the day was known
        return candidate
    }

    /// Applies gate, terminal, seat, booking code, belt, new times and boarding/cancelled status. Returns what changed.
    func applyTextDetails(_ details: FlightTextDetails, to id: UUID) async -> [String] {
        guard var flight = flight(id) else { return [] }
        let previous = flight.state
        var next = previous
        var changes: [String] = []
        let originZone = flight.attributes.origin?.timeZone ?? .current

        if let gate = details.gate, !next.phase.hasDeparted, gate != next.departure.gate {
            next.departure.gate = gate
            changes.append("gate \(gate)")
        }
        if let terminal = details.terminal, !next.phase.hasDeparted, terminal != next.departure.terminal {
            next.departure.terminal = terminal
            changes.append("Terminal \(terminal)")
        }
        if let belt = details.baggageBelt, belt != next.arrival.baggageBelt {
            next.arrival.baggageBelt = belt
            changes.append("belt \(belt)")
        }
        if let seat = details.seat, seat != flight.seat {
            flight.seat = seat
            changes.append("seat \(seat)")
        }
        if let code = details.confirmationCode, code != flight.confirmationCode {
            flight.confirmationCode = code
            changes.append("booking \(code)")
        }

        // A new departure time: from a delay message, or the first time we hear it for a flight without a schedule.
        if let components = details.departure, components.hour != nil, !next.phase.hasDeparted,
           let time = resolve(components, in: originZone),
           details.status == .delayed || flight.schedule == nil || next.departure.best == nil {
            let current = next.departure.best
            let plausible = current.map { abs(time.timeIntervalSince($0)) < 36 * 3600 } ?? true
            if plausible, current.map({ abs(time.timeIntervalSince($0)) >= 60 }) ?? true {
                next.departure.estimated = time
                next.boardingStarts = time.addingTimeInterval(-flight.boardingLead)
                changes.append("departs \(FlightPresentation.time(time, originZone))")
            }
        }

        switch details.status {
        case .boarding?, .finalCall?, .gateClosed?:
            if next.phase == .scheduled {
                next.phase = .boarding
                changes.append(details.status?.label ?? "boarding")
            }
        case .cancelled?:
            if next.phase != .cancelled {
                next.phase = .cancelled
                changes.append("cancelled")
            }
        case .departed?:
            if !next.phase.hasDeparted {
                next.phase = .taxiingOut
                changes.append("departed")
            }
        case .landed?:
            if next.phase.isAirborne {
                next.phase = .landed
                changes.append("landed")
            }
        default:
            break
        }

        guard !changes.isEmpty else { return [] }
        next.updatedAt = .now
        await commit(flight, previous: previous, next: next, force: true)
        return changes
    }
}

/// Share Sheet and Messages automations: "Add or Update Flight from Text".
struct UpdateFlightFromTextIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add or Update Flight from Text"
    static let description = IntentDescription(
        "Reads an email, airport text message or note for a flight number, time, gate, seat, belt or boarding status, then adds the flight or updates it. Use it from the Share Sheet, or in a Messages automation for texts from the airport."
    )

    @Parameter(title: "Text", inputConnectionBehavior: .connectToPreviousIntentResult)
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = FlightStore.shared
        let result = await store.importText(text)
        await store.syncLiveActivities(canStartInBackground: true)
        return .result(value: result.message, dialog: "\(result.message)")
    }
}
