import UIKit
import UniformTypeIdentifiers

/// FlightLive in the Share Sheet. Takes the text or link that was shared (a flight from Flighty, a booking email,
/// an airport message) and passes it to the app as flightlive://import?text=…, which reads it like "Add or Update Flight from Text".
final class ShareViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { @MainActor in
            let text = await sharedText()
            if !text.isEmpty { openApp(with: text) }
            try? await Task.sleep(for: .milliseconds(300)) // let the app open before this sheet goes away
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func sharedText() async -> String {
        var parts: [String] = []
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            if let text = item.attributedContentText?.string, !text.isEmpty { parts.append(text) }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                    parts.append(url.absoluteString)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    parts.append(text)
                }
            }
        }
        // The same text often arrives as both the item's text and an attachment.
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    private func openApp(with text: String) {
        var components = URLComponents()
        components.scheme = "flightlive"
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "text", value: String(text.prefix(8000)))]
        guard let url = components.url else { return }

        // A Share extension can't use UIApplication.shared, but the host's UIApplication is in the responder chain.
        // Called by selector: the plain openURL: no longer does anything on iOS 18.
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, [:], nil)
                return
            }
            responder = current.next
        }
    }
}
