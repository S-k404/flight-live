import Foundation
import UIKit
import UserNotifications

/// Something worth telling the user about: a gate change, a new delay, takeoff, landing, bags.
struct FlightEvent {
    /// Identifies the event so it's only announced once.
    var key: String
    var title: String
    var body: String
}

enum FlightEvents {
    typealias State = FlightActivityAttributes.ContentState

    static func changes(from old: State, to new: State, attributes: FlightActivityAttributes) -> [FlightEvent] {
        var events: [FlightEvent] = []
        let flight = attributes.flightNumber
        let originZone = attributes.origin?.timeZone ?? .current
        let destinationZone = attributes.destination?.timeZone ?? .current
        func time(_ date: Date?, _ zone: TimeZone) -> String {
            date.map { FlightPresentation.time($0, zone) } ?? "—"
        }

        if new.phase == .cancelled && old.phase != .cancelled {
            return [FlightEvent(key: "cancelled", title: "Cancelled · \(flight)", body: "\(flight) has been cancelled.")]
        }
        if new.phase == .diverted && old.phase != .diverted {
            return [FlightEvent(key: "diverted", title: "Diverted · \(flight)", body: "\(flight) has been diverted.")]
        }

        // Before departure: gate and delay changes.
        if !new.phase.hasDeparted {
            if let gate = new.departure.gate, gate != old.departure.gate {
                let body = old.departure.gate.map { "Now departs from gate \(gate) (was \($0))." } ?? "Departs from gate \(gate)."
                let title = old.departure.gate == nil ? "Gate assigned" : "Gate change"
                events.append(FlightEvent(key: "gate-\(gate)", title: "\(title) · \(flight)", body: body))
            }
            if let newDelay = new.departure.delayMinutes {
                let oldDelay = old.departure.delayMinutes ?? 0
                if abs(newDelay - oldDelay) >= 15 {
                    let status = FlightPresentation.delayStatus(newDelay, departed: false).0
                    events.append(FlightEvent(
                        key: "delay-\(newDelay / 5 * 5)",
                        title: "\(newDelay > oldDelay ? "Delayed" : "Delay reduced") · \(flight)",
                        body: "Now departs at \(time(new.departure.best, originZone)). \(status)."
                    ))
                }
            }
        }

        if new.phase != old.phase {
            if new.phase == .boarding {
                let gate = new.departure.gate.map { " at gate \($0)" } ?? ""
                events.append(FlightEvent(key: "boarding", title: "Boarding · \(flight)", body: "Now boarding\(gate)."))
            } else if new.phase.isAirborne && !old.phase.isAirborne {
                let from = attributes.origin.map { "Left \($0.city). " } ?? ""
                events.append(FlightEvent(
                    key: "takeoff",
                    title: "Took off · \(flight)",
                    body: "\(from)Arrives at \(time(new.arrival.best, destinationZone))."
                ))
            } else if new.phase == .landed {
                let city = attributes.destination.map { " in \($0.city)" } ?? ""
                let gate = new.arrival.gate.map { " Heading to gate \($0)." } ?? ""
                events.append(FlightEvent(key: "landed", title: "Landed · \(flight)", body: "Landed\(city).\(gate)"))
            } else if new.phase == .arrived {
                let gate = new.arrival.gate.map { " at gate \($0)" } ?? ""
                let status = FlightPresentation(attributes: attributes, state: new).statusText
                events.append(FlightEvent(key: "arrived", title: "Arrived · \(flight)", body: "Arrived\(gate). \(status)."))
            }
        }

        if new.phase.hasDeparted, let gate = new.arrival.gate, gate != old.arrival.gate, new.phase != .arrived {
            events.append(FlightEvent(key: "arrgate-\(gate)", title: "Arrival gate · \(flight)", body: "Arriving at gate \(gate)."))
        }
        if let belt = new.arrival.baggageBelt, belt != old.arrival.baggageBelt {
            events.append(FlightEvent(key: "belt-\(belt)", title: "Baggage · \(flight)", body: "Bags arrive on belt \(belt)."))
        }
        return events
    }
}

enum FlightNotifications {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(_ event: FlightEvent, flightID: UUID, playSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.threadIdentifier = flightID.uuidString
        if playSound { content.sound = .default }
        let request = UNNotificationRequest(identifier: "\(flightID.uuidString)-\(event.key)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// A notification queued on the phone for a set time, so it goes off even when FlightLive isn't running.
    struct Reminder {
        enum Kind: String, CaseIterable {
            case checkIn = "checkin", leave, lockScreen = "lockscreen", boarding
        }

        var kind: Kind
        var date: Date
        var title: String
        var body: String
        /// Adds a "Go" button that starts your music and opens Apple Maps to this airport.
        var directionsTo: FlightActivityAttributes.Airport?
    }

    static let leaveCategory = "LEAVE_FOR_AIRPORT"
    static let directionsAction = "DIRECTIONS"

    private static func reminderID(_ flightID: UUID, _ kind: Reminder.Kind) -> String {
        "\(flightID.uuidString)-\(kind.rawValue)-reminder"
    }

    /// Replaces this flight's queued reminders with `reminders`, skipping any whose time has passed.
    static func schedule(_ reminders: [Reminder], flightID: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Reminder.Kind.allCases.map { reminderID(flightID, $0) })
        for reminder in reminders {
            let delay = reminder.date.timeIntervalSinceNow
            // Traffic can move the time to leave into the last few minutes: say so now rather than not at all.
            let lateLeave = reminder.kind == .leave && delay > -15 * 60
            guard delay > 1 || lateLeave else { continue }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = flightID.uuidString
            if let airport = reminder.directionsTo {
                content.categoryIdentifier = leaveCategory
                content.userInfo = ["latitude": airport.latitude, "longitude": airport.longitude, "name": "\(airport.code) Airport"]
            }
            let id = reminderID(flightID, reminder.kind)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 1), repeats: false)
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            if delay > 1 {
                center.add(request)
            } else {
                // Unless it already went off.
                center.getDeliveredNotifications { delivered in
                    if !delivered.contains(where: { $0.request.identifier == id }) { center.add(request) }
                }
            }
        }
    }

    static func cancelReminders(flightID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Reminder.Kind.allCases.map { reminderID(flightID, $0) })
    }

    /// The "Go" button on the leave-for-the-airport reminder. Call again when the music setting changes.
    @MainActor
    static func registerCategories() {
        let title = AppSettings.shared.leaveMusic.isEmpty ? "Go: Directions in Apple Maps" : "Go: Music & Apple Maps"
        let directions = UNNotificationAction(identifier: directionsAction, title: title, options: [.foreground],
                                              icon: UNNotificationActionIcon(systemImageName: "car.fill"))
        let leave = UNNotificationCategory(identifier: leaveCategory, actions: [directions], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([leave])
    }
}

/// Shows flight notifications as banners even while the app is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// "Go" starts your music and opens Apple Maps with driving directions.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == FlightNotifications.directionsAction,
           let latitude = info["latitude"] as? Double, let longitude = info["longitude"] as? Double {
            let name = info["name"] as? String ?? "Airport"
            DispatchQueue.main.async { GettingThere.go(latitude: latitude, longitude: longitude, name: name) }
        }
        completionHandler()
    }
}
