import Foundation
import Security

/// Your next flights, saved by the app where the Home Screen widget can read them.
/// It lives in a keychain group the app and widget share; that works with a free developer account,
/// where a shared app group doesn't.
struct WidgetSnapshot: Codable {
    struct Flight: Codable, Identifiable {
        var id: String
        var attributes: FlightActivityAttributes
        var state: FlightActivityAttributes.ContentState
    }

    /// Soonest first.
    var flights: [Flight]

    private static let service = "FlightLive"
    private static let account = "widgetSnapshot"

    static func load() -> WidgetSnapshot? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Without an access group, the item goes in the first shared group in the entitlements, which the widget also has.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            // The widget refreshes while the phone is locked.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
