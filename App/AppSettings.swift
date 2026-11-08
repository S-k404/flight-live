import Foundation
import Observation
import Security

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var provider: ScheduleProvider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }

    /// AeroDataBox key, stored in the Keychain.
    var apiKey: String {
        didSet { Keychain.set(apiKey, account: Keys.apiKey) }
    }

    var units: UnitSystem {
        didSet { defaults.set(units.rawValue, forKey: Keys.units) }
    }

    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    /// Remind 24 hours before departure that check-in is open.
    var checkInReminder: Bool {
        didSet { defaults.set(checkInReminder, forKey: Keys.checkIn) }
    }

    /// Check for updates about a third as often. iOS Low Power Mode does the same automatically.
    var batterySaver: Bool {
        didSet { defaults.set(batterySaver, forKey: Keys.batterySaver) }
    }

    /// Add flights found in the calendar automatically when the app opens or refreshes.
    var autoImportCalendar: Bool {
        didSet { defaults.set(autoImportCalendar, forKey: Keys.autoImportCalendar) }
    }

    /// Keep every flight in a FlightLive calendar in iCloud, so flights follow your Apple ID to other devices.
    var syncCalendar: Bool {
        didSet { defaults.set(syncCalendar, forKey: Keys.syncCalendar) }
    }

    /// Minutes before departure to say it's time to head to the airport. 0 turns it off.
    var leaveForAirportMinutes: Int {
        didSet { defaults.set(leaveForAirportMinutes, forKey: Keys.leaveForAirport) }
    }

    /// Time leaving from your location: Apple Maps' drive time with traffic, so you get there `arriveAtAirportMinutes` early.
    var leaveUsingLocation: Bool {
        didSet { defaults.set(leaveUsingLocation, forKey: Keys.leaveUsingLocation) }
    }

    /// Minutes before departure to be at the airport, when leaving is timed from your location.
    var arriveAtAirportMinutes: Int {
        didSet { defaults.set(arriveAtAirportMinutes, forKey: Keys.arriveAtAirport) }
    }

    /// What Apple Music plays when you tap Go: empty for nothing, `LeaveMusic.resume`, or a playlist id.
    var leaveMusic: String {
        didSet { defaults.set(leaveMusic, forKey: Keys.leaveMusic) }
    }

    /// Internal Integration Secret from Notion, stored in the Keychain.
    var notionToken: String {
        didSet { Keychain.set(notionToken, account: Keys.notionToken) }
    }

    /// The Notion database (data source) flights are imported from.
    var notionSourceID: String {
        didSet { defaults.set(notionSourceID, forKey: Keys.notionSource) }
    }

    var notionSourceTitle: String {
        didSet { defaults.set(notionSourceTitle, forKey: Keys.notionSourceTitle) }
    }

    /// Look for new flights in Notion when the app opens or refreshes.
    var notionAutoImport: Bool {
        didSet { defaults.set(notionAutoImport, forKey: Keys.notionAutoImport) }
    }

    var credentials: ScheduleCredentials? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : ScheduleCredentials(provider: provider, key: key)
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let provider = "scheduleProvider"
        static let apiKey = "aerodatabox"
        static let units = "units"
        static let notifications = "notificationsEnabled"
        static let checkIn = "checkInReminder"
        static let leaveForAirport = "leaveForAirportMinutes"
        static let leaveUsingLocation = "leaveUsingLocation"
        static let arriveAtAirport = "arriveAtAirportMinutes"
        static let leaveMusic = "leaveMusic"
        static let autoImportCalendar = "autoImportCalendar"
        static let syncCalendar = "syncCalendar"
        static let notionToken = "notion"
        static let notionSource = "notionSourceID"
        static let notionSourceTitle = "notionSourceTitle"
        static let notionAutoImport = "notionAutoImport"
        static let batterySaver = "batterySaver"
    }

    private init() {
        provider = defaults.string(forKey: Keys.provider).flatMap(ScheduleProvider.init(rawValue:)) ?? .rapidAPI
        apiKey = Keychain.string(account: Keys.apiKey) ?? ""
        units = defaults.string(forKey: Keys.units).flatMap(UnitSystem.init(rawValue:)) ?? .aviation
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        checkInReminder = defaults.object(forKey: Keys.checkIn) as? Bool ?? true
        leaveForAirportMinutes = defaults.object(forKey: Keys.leaveForAirport) as? Int ?? 120
        leaveUsingLocation = defaults.bool(forKey: Keys.leaveUsingLocation)
        arriveAtAirportMinutes = defaults.object(forKey: Keys.arriveAtAirport) as? Int ?? 120
        leaveMusic = defaults.string(forKey: Keys.leaveMusic) ?? ""
        autoImportCalendar = defaults.bool(forKey: Keys.autoImportCalendar)
        syncCalendar = defaults.bool(forKey: Keys.syncCalendar)
        notionToken = Keychain.string(account: Keys.notionToken) ?? ""
        notionSourceID = defaults.string(forKey: Keys.notionSource) ?? ""
        notionSourceTitle = defaults.string(forKey: Keys.notionSourceTitle) ?? ""
        notionAutoImport = defaults.object(forKey: Keys.notionAutoImport) as? Bool ?? true
        batterySaver = defaults.bool(forKey: Keys.batterySaver)
    }
}

enum Keychain {
    private static let service = "FlightLive"

    static func string(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        // Readable after first unlock so background refreshes work while the phone is locked.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
