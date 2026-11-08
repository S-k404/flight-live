import Foundation
import PDFKit
import UIKit
import Vision

/// What a boarding pass barcode says (IATA "BCBP" format, used by nearly every airline).
struct BoardingPassInfo: Equatable {
    var passengerName: String
    var confirmationCode: String
    var from: String
    var to: String
    var carrier: String
    var flightNumber: String
    var seat: String?
    var cabin: String?

    /// "UA 930"
    var displayFlight: String { "\(carrier) \(flightNumber)" }

    /// Parses the first leg of a BCBP barcode, e.g.
    /// "M1DOE/JANE            EABC123 SFOLHRUA 0930 299Y023A0012 100".
    init?(barcode raw: String) {
        let chars = Array(raw)
        guard chars.count >= 58, chars[0] == "M" else { return nil }
        func field(_ start: Int, _ length: Int) -> String {
            String(chars[start..<start + length]).trimmingCharacters(in: .whitespaces)
        }
        let name = field(2, 20)
        // "DOE/JANE MS" -> "Jane Doe"
        let parts = name.split(separator: "/").map { $0.split(separator: " ").first.map(String.init) ?? String($0) }
        passengerName = (parts.count == 2 ? "\(parts[1]) \(parts[0])" : name).capitalized
        confirmationCode = field(23, 7)
        from = field(30, 3)
        to = field(33, 3)
        carrier = field(36, 3)
        let number = field(39, 5).trimmingCharacters(in: .letters)
        flightNumber = String(Int(number) ?? 0)
        cabin = field(47, 1).isEmpty ? nil : field(47, 1)
        let rawSeat = field(48, 4)
        let trimmedSeat = rawSeat.drop { $0 == "0" }
        seat = trimmedSeat.isEmpty ? nil : String(trimmedSeat)
        guard from.count == 3, to.count == 3, !carrier.isEmpty, flightNumber != "0" else { return nil }
    }
}

enum BoardingPassStore {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("BoardingPasses", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(for flightID: UUID) -> URL {
        folder.appendingPathComponent("\(flightID.uuidString).jpg")
    }

    static func image(for flightID: UUID) -> UIImage? {
        UIImage(contentsOfFile: url(for: flightID).path)
    }

    static func save(_ image: UIImage, for flightID: UUID) throws {
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        // Complete protection: the pass has your name and booking code on it.
        try data.write(to: url(for: flightID), options: [.atomic, .completeFileProtection])
    }

    static func delete(for flightID: UUID) {
        try? FileManager.default.removeItem(at: url(for: flightID))
    }

    /// Loads a picked file: an image, or the first page of a PDF rendered sharp enough to scan.
    static func image(fromFile url: URL) -> UIImage? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "pdf" {
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2400 / max(bounds.width, bounds.height)
            return page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Finds and decodes the boarding pass barcode in a picture (PDF417, Aztec or QR).
    static func readBarcode(in image: UIImage) async -> BoardingPassInfo? {
        guard let cgImage = image.cgImage else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.pdf417, .aztec, .qr, .dataMatrix]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
            try? handler.perform([request])
            let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
            return payloads.lazy.compactMap { BoardingPassInfo(barcode: $0) }.first
        }.value
    }
}
