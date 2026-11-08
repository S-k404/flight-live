import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Every flight as a CSV file in Flighty's export layout, so it opens in Numbers or Excel, imports into
/// Flighty-compatible apps, and comes back into FlightLive with Import from Flighty.
struct FlightsCSV: Transferable {
    let text: String

    init(flights: [TrackedFlight]) {
        let header = [
            "Date", "Airline", "Flight", "From", "To", "Dep Terminal", "Dep Gate", "Arr Terminal", "Arr Gate", "Canceled",
            "Gate Departure (Scheduled)", "Gate Departure (Actual)", "Gate Arrival (Scheduled)", "Gate Arrival (Actual)",
            "Aircraft Type Name", "Tail Number", "PNR", "Seat",
        ]
        let rows = flights
            .filter { !$0.isDemo && $0.attributes.hasRoute }
            .sorted { $0.sortDate < $1.sortDate }
            .map(Self.row)
        text = ([header] + rows).map { $0.map(Self.escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
            .suggestedFileName("FlightLive flights.csv")
    }

    private static func row(_ flight: TrackedFlight) -> [String] {
        let attributes = flight.attributes
        let state = flight.state
        let originZone = attributes.origin?.timeZone ?? .current
        let destinationZone = attributes.destination?.timeZone ?? .current
        // "6E 978" → airline "6E", flight "978", the way Flighty splits them.
        let parts = attributes.flightNumber.split(separator: " ", maxSplits: 1).map(String.init)
        let airline = attributes.airlineCode ?? (parts.count == 2 ? parts[0] : "")
        let number = parts.count == 2 ? parts[1] : attributes.flightNumber
        return [
            state.departure.best.map { local($0, originZone, format: "yyyy-MM-dd") } ?? "",
            airline,
            number,
            attributes.origin?.code ?? "",
            attributes.destination?.code ?? "",
            state.departure.terminal ?? "",
            state.departure.gate ?? "",
            state.arrival.terminal ?? "",
            state.arrival.gate ?? "",
            state.phase == .cancelled ? "true" : "false",
            state.departure.scheduled.map { local($0, originZone) } ?? "",
            state.departure.actual.map { local($0, originZone) } ?? "",
            state.arrival.scheduled.map { local($0, destinationZone) } ?? "",
            state.arrival.actual.map { local($0, destinationZone) } ?? "",
            flight.aircraftModel.map { attributes.aircraft?.hasPrefix("Airbus") == true ? "Airbus \($0)" : $0 } ?? "",
            flight.registration ?? "",
            flight.confirmationCode ?? "",
            flight.seat ?? "",
        ]
    }

    private static func local(_ date: Date, _ zone: TimeZone, format: String = "yyyy-MM-dd'T'HH:mm") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func escape(_ field: String) -> String {
        field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
            ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : field
    }
}
