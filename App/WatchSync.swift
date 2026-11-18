import Foundation
import WatchConnectivity

/// Sends your next flights to the Apple Watch app, the same snapshot the Home Screen widget reads. The watch can't
/// read the keychain group the widget uses, and it never calls the flight services itself, so everything it shows
/// comes from here. Nothing happens until a watch is paired and has the FlightLive watch app installed.
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    /// The newest snapshot, kept so it can go out once the session is ready or a watch app first appears.
    private var latest: Data?

    /// The key the watch app reads from the application context.
    static let contextKey = "widgetSnapshot"

    func send(_ snapshot: WidgetSnapshot) {
        guard WCSession.isSupported(), let data = try? JSONEncoder().encode(snapshot) else { return }
        latest = data
        let session = WCSession.default
        if session.delegate == nil { session.delegate = self }
        guard session.activationState == .activated else {
            session.activate() // pushed when activation completes
            return
        }
        push()
    }

    /// An application context holds only the latest value, which is what a "next flights" list wants: a watch that
    /// was off for a day gets the current list, not a queue of old ones.
    private func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled, let data = latest else { return }
        try? session.updateApplicationContext([Self.contextKey: data])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.push() }
    }

    /// The watch app was installed or removed.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.push() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switched to another watch.
        session.activate()
    }
}
