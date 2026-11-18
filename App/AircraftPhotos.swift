import CryptoKit
import SwiftUI
import UIKit

/// A real photo of a plane, and who to credit for it.
struct AircraftPhoto: Codable, Equatable {
    var imageURL: URL
    /// "N509FZ · CC BY-SA 4.0"
    var credit: String
    /// The photo's page on Wikimedia Commons, with its full licence.
    var pageURL: URL?
    /// The very plane, found by its tail number, rather than another plane of the same type.
    var isThisAircraft: Bool
}

extension TrackedFlight {
    /// "VT-IUK" from "Airbus A321neo · VT-IUK".
    var registration: String? {
        attributes.aircraft?.components(separatedBy: " · ").dropFirst().compactMap(AircraftNames.registration).first
    }
}

/// Older records, and ones imported from other apps, hold the plane the way that app wrote it. This turns that into
/// what the photo lookups can find.
enum AircraftNames {
    /// "vt-iuk" → "VT-IUK". Nil if it doesn't look like a tail number.
    static func registration(_ text: String) -> String? {
        let tail = text.trimmingCharacters(in: .whitespaces).uppercased()
        // "VT-IUK", "N509FZ", and Japan's and Korea's, which are written without a dash: "JA801A", "HL7777".
        let pattern = #"^[A-Z0-9]{1,2}-[A-Z0-9]{2,5}$|^N[0-9]{1,5}[A-Z]{0,2}$|^(JA|HL)[0-9]{3,4}[A-Z]?$"#
        return tail.range(of: pattern, options: .regularExpression) == nil ? nil : tail
    }

    /// The name of the type's Wikipedia article: "Boeing 737-800 (winglets)" → "Boeing 737-800", "A21N" → "Airbus A321neo".
    static func typeName(_ text: String) -> String {
        var name = text.replacingOccurrences(of: #"\s*\(\s*neo\s*\)"#, with: "neo", options: [.regularExpression, .caseInsensitive])
        if let bracket = name.firstIndex(of: "(") { name = String(name[..<bracket]) } // "(winglets)", "(Sharklets)"
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let mapped = AircraftTypes.name(for: name.uppercased()) // an ICAO code from an export
        return mapped == name.uppercased() ? name : mapped
    }
}

/// Real photos from Wikimedia Commons: the exact plane by its tail number, or else its type from the Wikipedia
/// article. Free, no key; each photo is looked up once and kept.
@MainActor
enum AircraftPhotos {
    private static let cacheKey = "aircraftPhotos"
    private static var found: [String: AircraftPhoto] = {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AircraftPhoto].self, from: data)) ?? [:]
    }()
    private static var notFound: Set<String> = []
    private static var images: [URL: UIImage] = [:]
    /// Wikimedia answered with an error (too many requests, no signal); don't ask again for a bit.
    private static var coolingDownUntil = Date.distantPast

    private enum LookupError: Error { case unavailable }

    /// Wikimedia was busy or out of reach a moment ago, so a plane with no photo may be worth asking about again.
    static var isRetryWorthwhile: Bool { Date.now < coolingDownUntil }

    /// Photos found whose picture then wouldn't load, and when to look for them again.
    private static var brokenUntil: [String: Date] = [:]

    /// The plane itself if someone has photographed it, otherwise a plane of the same type, with its picture.
    /// A photo is only worth having if its picture comes down: when it doesn't, the next best is used instead of
    /// leaving the plane blank.
    static func loaded(registration: String?, model: String?) async -> (photo: AircraftPhoto, image: UIImage)? {
        let registration = registration.flatMap(AircraftNames.registration)
        let model = model.map(AircraftNames.typeName).flatMap { $0.isEmpty ? nil : $0 }
        var attempts: [(key: String, lookup: () async throws -> AircraftPhoto?)] = []
        if let registration { attempts.append(("reg:\(registration)", { try await photo(registration: registration) })) }
        if let model { attempts.append(("type:\(model)", { try await photo(model: model) })) }
        for attempt in attempts {
            guard let found = await cached(attempt.key, lookup: attempt.lookup) else { continue }
            switch await fetch(found) {
            case .image(let picture):
                return (found, picture)
            case .busy:
                // Too many requests or no signal: the photo is fine, so keep it and try again soon.
                if Task.isCancelled { return nil }
                coolingDownUntil = .now.addingTimeInterval(30)
            case .gone:
                forget(attempt.key)
            }
        }
        return nil
    }

    /// A photo whose picture can't be had (taken down, or it won't download): drop it from what's kept for good, and
    /// look again in a minute.
    private static func forget(_ key: String) {
        found[key] = nil
        brokenUntil[key] = .now.addingTimeInterval(60)
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: cacheKey) }
    }

    /// The picture itself, from memory, the app's cache folder, or downloaded.
    static func image(for photo: AircraftPhoto) async -> UIImage? {
        if case .image(let image) = await fetch(photo) { return image }
        return nil
    }

    private enum Fetch {
        case image(UIImage)
        /// Wikimedia is busy or there's no signal, which says nothing about the picture.
        case busy
        /// Taken down, or not a picture.
        case gone
    }

    private static func fetch(_ photo: AircraftPhoto) async -> Fetch {
        if let image = images[photo.imageURL] { return .image(image) }
        let file = cacheFolder.appendingPathComponent(
            SHA256.hash(data: Data(photo.imageURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            images[photo.imageURL] = image
            return .image(image)
        }
        guard let (data, response) = try? await HTTP.session.data(from: photo.imageURL),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .busy }
        guard status == 200 else { return status == 429 || status >= 500 ? .busy : .gone }
        guard let image = UIImage(data: data) else { return .gone }
        try? data.write(to: file)
        images[photo.imageURL] = image
        return .image(image)
    }

    // MARK: - Looking up

    private static func cached(_ key: String, lookup: () async throws -> AircraftPhoto?) async -> AircraftPhoto? {
        if let photo = found[key] { return photo }
        guard !notFound.contains(key), Date.now >= coolingDownUntil, Date.now >= brokenUntil[key] ?? .distantPast else { return nil }
        let result: AircraftPhoto?
        do {
            result = try await lookup()
        } catch is CancellationError {
            return nil // the screen moved on
        } catch {
            // Couldn't ask, which isn't the same as there being no photo: don't remember it as missing.
            coolingDownUntil = .now.addingTimeInterval(30)
            return nil
        }
        guard let photo = result else {
            notFound.insert(key) // try again next launch, not on every redraw
            return nil
        }
        found[key] = photo
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: cacheKey) }
        return photo
    }

    /// A Commons photo with the tail number in its name, e.g. "IndiGo VT-IUK at Delhi.jpg". Landscape ones first.
    private static func photo(registration: String) async throws -> AircraftPhoto? {
        let pages = try await commons([
            "generator": "search", "gsrnamespace": "6", "gsrlimit": "5",
            "gsrsearch": "intitle:\"\(registration)\" filetype:bitmap",
        ])
        // The tail number on its own, so N509 doesn't pick up a photo of N5090.
        let tail = "(?<![A-Z0-9])" + NSRegularExpression.escapedPattern(for: registration) + "(?![A-Z0-9])"
        let matching = pages.filter { $0.title.range(of: tail, options: [.regularExpression, .caseInsensitive]) != nil && $0.looksLikeAircraft }
        for file in (matching.filter(\.isLandscape) + matching.filter { !$0.isLandscape }).prefix(3) {
            if let file = try await usable(file) { return file.photo(isThisAircraft: true) }
        }
        return try await categoryPhoto(registration: registration)
    }

    /// Photos in the plane's own Commons category ("Category:VT-IUK (aircraft)"), which often holds photos whose file
    /// names don't carry the tail number, so the search by name above can't find them.
    private static func categoryPhoto(registration: String) async throws -> AircraftPhoto? {
        let files = try await commons([
            "generator": "categorymembers", "gcmtitle": "Category:\(registration) (aircraft)", "gcmtype": "file", "gcmlimit": "10",
        ]).filter(\.isPicture)
        for file in (files.filter(\.isLandscape) + files.filter { !$0.isLandscape }).prefix(3) {
            if let file = try await usable(file) { return file.photo(isThisAircraft: true) }
        }
        return nil
    }

    /// The lead photo of the type's Wikipedia article, e.g. "Airbus A321neo".
    private static func photo(model: String) async throws -> AircraftPhoto? {
        var titles = [model.range(of: #"^A[0-9]{3}"#, options: .regularExpression) != nil ? "Airbus " + model : model]
        if let base = titles[0].split(separator: "-").first, base.count < titles[0].count {
            titles.append(String(base)) // "ATR 72-600" → "ATR 72"
        }
        // "Daher TBM 900" → "Daher TBM": drop trailing words, down to two.
        var words = titles[0].split(separator: " ")
        while words.count > 2 {
            words.removeLast()
            titles.append(words.joined(separator: " "))
        }
        // The flight screen drops "Airbus " from the name, which "Beluga" and "Helicopters H145" then lack.
        if !model.hasPrefix("Airbus") { titles.append("Airbus " + model) }
        var seen = Set<String>()
        titles = titles.filter { seen.insert($0).inserted }
        for title in titles {
            if let photo = try await typePhoto(leadImage: leadImage(article: title)) { return photo }
        }
        // No article has that exact title (an unusual spelling, or a variant): let Wikipedia search for the closest one.
        return try await typePhoto(leadImage: searchedLeadImage(model: model))
    }

    private static func typePhoto(leadImage file: String?) async throws -> AircraftPhoto? {
        guard let file, let page = try await commons(["titles": "File:\(file)"]).first, let usable = try await usable(page) else { return nil }
        return usable.photo(isThisAircraft: false)
    }

    /// The lead image of the article Wikipedia's search ranks first for the type, as long as it is about the same
    /// family ("737" in the title for a "Boeing 737-8AS"), so a search can't wander off to some other plane.
    private static func searchedLeadImage(model: String) async throws -> String? {
        guard let range = model.range(of: #"[A-Za-z]*\d+[A-Za-z]*"#, options: .regularExpression) else { return nil }
        let family = model[range].lowercased()
        let json = try await get("https://en.wikipedia.org/w/api.php", [
            "action": "query", "generator": "search", "gsrsearch": "\(model) aircraft", "gsrnamespace": "0", "gsrlimit": "5",
            "prop": "pageimages", "piprop": "name", "format": "json", "formatversion": "2",
        ])
        let pages = ((json["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? [])
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return pages.first { page in
            page["pageimage"] is String && (page["title"] as? String ?? "").lowercased().contains(family)
        }?["pageimage"] as? String
    }

    private static func leadImage(article: String) async throws -> String? {
        let json = try await get("https://en.wikipedia.org/w/api.php", [
            "action": "query", "titles": article, "redirects": "1", "prop": "pageimages", "piprop": "name",
            "format": "json", "formatversion": "2",
        ])
        let pages = (json["query"] as? [String: Any])?["pages"] as? [[String: Any]]
        return pages?.first?["pageimage"] as? String
    }

    private struct CommonsFile {
        var title: String
        var thumbURL: URL
        var pageURL: URL?
        var artist: String?
        var license: String?
        var width: Int
        var height: Int
        /// The width of the version `thumbURL` points to.
        var thumbWidth: Int
        /// The Commons categories it's in. Empty when the answer didn't say.
        var categories: [String] = []
        var mime = ""

        /// A photo rather than a video, document or drawing.
        var isPicture: Bool { mime.isEmpty || (mime.hasPrefix("image/") && !mime.contains("svg")) }

        /// In an aircraft or airline category, so a tail number that turns up in some other file's name doesn't count.
        /// Files whose categories weren't returned are given the benefit of the doubt.
        var looksLikeAircraft: Bool {
            categories.isEmpty || categories.contains { $0.range(of: #"(?i)aircraft|airplane|airliner|aviation|airline|airways"#, options: .regularExpression) != nil }
        }

        var isLandscape: Bool { width > height }

        /// The API answers with the original file when the photo is no wider than the size asked for.
        var isUnscaled: Bool { thumbURL.absoluteString.contains("thumbnail_unscaled") || (thumbWidth > 0 && thumbWidth >= width) }

        func photo(isThisAircraft: Bool) -> AircraftPhoto {
            let credit = [artist, license].compactMap { $0 }.joined(separator: " · ")
            return AircraftPhoto(imageURL: thumbURL, credit: credit.isEmpty ? "Wikimedia Commons" : credit,
                                 pageURL: pageURL, isThisAircraft: isThisAircraft)
        }
    }

    /// Wikimedia's image servers answer 429 ("too many requests") for an original file, however rarely it's asked for,
    /// and the API gives out the original's address when a photo is no wider than the size asked for (a 1200-pixel-wide
    /// photo asked for at 1200). A smaller standard thumbnail size is a real resize, and that loads.
    private static func usable(_ file: CommonsFile) async throws -> CommonsFile? {
        guard file.isUnscaled else { return file }
        guard let step = thumbnailSteps.first(where: { $0 < file.width }) else { return nil }
        return try await commons(["titles": file.title], width: step).first { !$0.isUnscaled }
    }

    /// The thumbnail widths Wikimedia serves, below the 1280 that `commons` normally gets.
    private static let thumbnailSteps = [960, 500, 330, 250, 120]

    /// Image files with a version `width` pixels wide, the photographer and the licence.
    private static func commons(_ query: [String: String], width: Int = 1200) async throws -> [CommonsFile] {
        var parameters = query
        parameters.merge([
            "action": "query", "prop": "imageinfo|categories", "clshow": "!hidden", "cllimit": "30",
            "iiprop": "url|extmetadata|size|mime", "iiurlwidth": String(width),
            "iiextmetadatafilter": "Artist|LicenseShortName", "format": "json", "formatversion": "2",
        ]) { mine, _ in mine }
        let json = try await get("https://commons.wikimedia.org/w/api.php", parameters)
        let pages = ((json["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? [])
            .sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return pages.compactMap { page in
            guard let title = page["title"] as? String,
                  let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)) else { return nil }
            let meta = info["extmetadata"] as? [String: [String: Any]]
            return CommonsFile(
                title: title,
                thumbURL: thumb,
                pageURL: (info["descriptionurl"] as? String).flatMap(URL.init(string:)),
                artist: (meta?["Artist"]?["value"] as? String).map(plainText),
                license: meta?["LicenseShortName"]?["value"] as? String,
                width: info["width"] as? Int ?? 0,
                height: info["height"] as? Int ?? 0,
                thumbWidth: info["thumbwidth"] as? Int ?? 0,
                categories: (page["categories"] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? [],
                mime: info["mime"] as? String ?? ""
            )
        }
    }

    /// The photographer's name without the link Commons wraps it in.
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The answer, which may well say there's nothing. Throws when Wikimedia couldn't be asked or didn't answer properly.
    private static func get(_ base: String, _ parameters: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: base)
        components?.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw LookupError.unavailable }
        let result: (Data, URLResponse)
        do {
            result = try await HTTP.session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LookupError.unavailable
        }
        guard (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any] else { throw LookupError.unavailable }
        return json
    }

    private static var cacheFolder: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AircraftPhotos")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// The plane as Flighty shows it: a real photo with the type and tail number over it and the photographer's credit
/// below. Without a photo, just the words.
struct AircraftPhotoView: View {
    /// "Airbus A321neo · VT-IUK" as the flight has it.
    var aircraft: String?
    var registration: String?
    var model: String?
    /// The flight is over, so "the airline hasn't said yet" no longer fits.
    var isPast = false
    @State private var photo: AircraftPhoto?
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image, let photo {
                AircraftHero(image: image, title: type, registration: registration)
                PhotoCredit(photo: photo, model: model)
            } else if let aircraft {
                Text(aircraft)
                    .font(.headline)
            } else {
                Text(isPast ? "No plane was recorded for this flight" : "The airline hasn't said which plane yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(registration ?? "")|\(model ?? "")") {
            // A different plane than before (say its details just arrived): don't leave the old one's photo up.
            photo = nil
            image = nil
            // If Wikimedia was only busy, ask again once it has had time to calm down, rather than staying blank.
            for _ in 0..<3 {
                if let loaded = await AircraftPhotos.loaded(registration: registration, model: model) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        image = loaded.image
                        photo = loaded.photo
                    }
                    return
                }
                guard AircraftPhotos.isRetryWorthwhile else { return }
                try? await Task.sleep(for: .seconds(35))
                if Task.isCancelled { return }
            }
        }
    }

    /// "Airbus A321neo" from "Airbus A321neo · VT-IUK".
    private var type: String? {
        aircraft?.components(separatedBy: " · ").first?.trimmingCharacters(in: .whitespaces) ?? model
    }
}

/// A photo with a dark fade up from the bottom, the tail number in a pill and the type's name over it.
struct AircraftHero: View {
    var image: UIImage
    var title: String?
    var registration: String?

    var body: some View {
        PlanePicture(image: image)
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: UnitPoint(x: 0.5, y: 0.4), endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    if let registration {
                        Text(registration)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let title {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .foregroundStyle(.white)
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) // the fade has square corners
    }
}

/// A photo cropped to 3:2 with rounded corners.
struct PlanePicture: View {
    var image: UIImage

    var body: some View {
        Color.clear
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "This plane · Photo: N509FZ · CC BY-SA 4.0", linking to the photo's page.
struct PhotoCredit: View {
    var photo: AircraftPhoto
    var model: String?
    var thisAircraftLabel = "This plane"
    var color: Color = .white.opacity(0.5)

    var body: some View {
        // A type's photo is its Wikipedia article's lead picture, which can be a sister model (a 777-200 for a 777-300ER).
        let lead = photo.isThisAircraft ? thisAircraftLabel : (model.map { "Similar to \($0)" } ?? "Similar plane")
        let text = Text("\(lead) · Photo: \(photo.credit)")
            .font(.caption2)
            .foregroundStyle(color)
            .lineLimit(1)
        if let page = photo.pageURL {
            Link(destination: page) { text }
        } else {
            text
        }
    }
}
