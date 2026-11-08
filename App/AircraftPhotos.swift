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
        attributes.aircraft?.components(separatedBy: " · ").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.range(of: #"^[A-Z0-9]{1,2}-[A-Z0-9]{2,5}$|^N[0-9]{1,5}[A-Z]{0,2}$"#, options: .regularExpression) != nil }
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

    /// The plane itself if someone has photographed it, otherwise a plane of the same type.
    static func photo(registration: String?, model: String?) async -> AircraftPhoto? {
        if let registration, let photo = await cached("reg:\(registration)", lookup: { await photo(registration: registration) }) {
            return photo
        }
        guard let model else { return nil }
        return await cached("type:\(model)", lookup: { await photo(model: model) })
    }

    /// The picture itself, from memory, the app's cache folder, or downloaded.
    static func image(for photo: AircraftPhoto) async -> UIImage? {
        if let image = images[photo.imageURL] { return image }
        let file = cacheFolder.appendingPathComponent(
            SHA256.hash(data: Data(photo.imageURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            images[photo.imageURL] = image
            return image
        }
        guard let (data, response) = try? await HTTP.session.data(from: photo.imageURL),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
        try? data.write(to: file)
        images[photo.imageURL] = image
        return image
    }

    // MARK: - Looking up

    private static func cached(_ key: String, lookup: () async -> AircraftPhoto?) async -> AircraftPhoto? {
        if let photo = found[key] { return photo }
        guard !notFound.contains(key) else { return nil }
        guard let photo = await lookup() else {
            notFound.insert(key) // try again next launch, not on every redraw
            return nil
        }
        found[key] = photo
        if let data = try? JSONEncoder().encode(found) { UserDefaults.standard.set(data, forKey: cacheKey) }
        return photo
    }

    /// A Commons photo with the tail number in its name, e.g. "IndiGo VT-IUK at Delhi.jpg". Landscape ones first.
    private static func photo(registration: String) async -> AircraftPhoto? {
        let pages = await commons([
            "generator": "search", "gsrnamespace": "6", "gsrlimit": "5",
            "gsrsearch": "intitle:\"\(registration)\" filetype:bitmap",
        ])
        let matching = pages.filter { $0.title.uppercased().contains(registration.uppercased()) }
        return (matching.first { $0.isLandscape } ?? matching.first)?.photo(isThisAircraft: true)
    }

    /// The lead photo of the type's Wikipedia article, e.g. "Airbus A321neo".
    private static func photo(model: String) async -> AircraftPhoto? {
        var titles = [model.range(of: #"^A[0-9]{3}"#, options: .regularExpression) != nil ? "Airbus " + model : model]
        if let base = titles[0].split(separator: "-").first, base.count < titles[0].count {
            titles.append(String(base)) // "ATR 72-600" → "ATR 72"
        }
        for title in titles {
            if let file = await leadImage(article: title), let page = await commons(["titles": "File:\(file)"]).first {
                return page.photo(isThisAircraft: false)
            }
        }
        return nil
    }

    private static func leadImage(article: String) async -> String? {
        let json = await get("https://en.wikipedia.org/w/api.php", [
            "action": "query", "titles": article, "redirects": "1", "prop": "pageimages", "piprop": "name",
            "format": "json", "formatversion": "2",
        ])
        let pages = (json?["query"] as? [String: Any])?["pages"] as? [[String: Any]]
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

        var isLandscape: Bool { width > height }

        func photo(isThisAircraft: Bool) -> AircraftPhoto {
            let credit = [artist, license].compactMap { $0 }.joined(separator: " · ")
            return AircraftPhoto(imageURL: thumbURL, credit: credit.isEmpty ? "Wikimedia Commons" : credit,
                                 pageURL: pageURL, isThisAircraft: isThisAircraft)
        }
    }

    /// Image files with a 1200-pixel-wide version, the photographer and the licence.
    private static func commons(_ query: [String: String]) async -> [CommonsFile] {
        var parameters = query
        parameters.merge([
            "action": "query", "prop": "imageinfo", "iiprop": "url|extmetadata|size", "iiurlwidth": "1200",
            "iiextmetadatafilter": "Artist|LicenseShortName", "format": "json", "formatversion": "2",
        ]) { mine, _ in mine }
        let json = await get("https://commons.wikimedia.org/w/api.php", parameters)
        let pages = ((json?["query"] as? [String: Any])?["pages"] as? [[String: Any]] ?? [])
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
                height: info["height"] as? Int ?? 0
            )
        }
    }

    /// The photographer's name without the link Commons wraps it in.
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func get(_ base: String, _ parameters: [String: String]) async -> [String: Any]? {
        var components = URLComponents(string: base)
        components?.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url,
              let (data, response) = try? await HTTP.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static var cacheFolder: URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("AircraftPhotos")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// A real photo of the plane with its credit; nothing at all if no photo is found.
struct AircraftPhotoView: View {
    var registration: String?
    var model: String?
    @State private var photo: AircraftPhoto?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image, let photo {
                VStack(alignment: .leading, spacing: 6) {
                    PlanePicture(image: image)
                    PhotoCredit(photo: photo, model: model)
                }
            }
        }
        .task(id: "\(registration ?? "")|\(model ?? "")") {
            guard let found = await AircraftPhotos.photo(registration: registration, model: model) else { return }
            image = await AircraftPhotos.image(for: found)
            photo = found
        }
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
        let lead = photo.isThisAircraft ? thisAircraftLabel : (model.map { "Another \($0)" } ?? "Same type")
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
