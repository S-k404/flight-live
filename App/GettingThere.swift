import CoreLocation
import MapKit
import MediaPlayer
import UIKit

/// How long the drive to the departure airport takes, from Apple Maps with traffic. Saved with the flight.
struct TravelEstimate: Codable, Equatable {
    var minutes: Int
    var distanceKm: Double
    var updatedAt: Date

    /// Close enough that there's nothing left to drive.
    var isAtAirport: Bool { distanceKm < 2 }
}

/// When to set off for the airport.
struct LeavePlan: Equatable {
    var date: Date
    /// Set when the time comes from your location and Apple Maps; nil for a set time before departure.
    var travel: TravelEstimate?
}

/// Your location, asked for only when a leave time is being worked out.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []

    override private init() {
        super.init()
        manager.delegate = self
        // A drive time doesn't need GPS precision, and this is much cheaper on battery.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    /// Shows the "Allow While Using App" prompt the first time.
    func requestAuthorization() async -> Bool {
        guard manager.authorizationStatus == .notDetermined else { return isAuthorized }
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
        return isAuthorized
    }

    /// A fresh fix while FlightLive is open. In the background, the last fix iOS has, if it's from today.
    func currentLocation(inForeground: Bool) async -> CLLocation? {
        guard isAuthorized else { return nil }
        if let last = manager.location, Date().timeIntervalSince(last.timestamp) < 10 * 60 { return last }
        guard inForeground else {
            return manager.location.flatMap { Date().timeIntervalSince($0.timestamp) < 6 * 3600 ? $0 : nil }
        }
        return await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 { manager.requestLocation() }
        }
    }

    private func finish(_ location: CLLocation?) {
        let waiters = locationWaiters
        locationWaiters = []
        waiters.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in self.finish(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.manager.authorizationStatus != .notDetermined else { return }
            let waiters = self.authorizationWaiters
            self.authorizationWaiters = []
            waiters.forEach { $0.resume() }
        }
    }
}

enum GettingThere {
    /// Drive time from `location` to the airport, using Apple Maps' traffic for around when you'd leave.
    static func driveTime(from location: CLLocation, to airport: FlightActivityAttributes.Airport, leavingAround: Date) async -> TravelEstimate? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: airport.latitude, longitude: airport.longitude)))
        request.transportType = .automobile
        request.departureDate = max(leavingAround, .now)
        guard let response = try? await MKDirections(request: request).calculateETA() else { return nil }
        return TravelEstimate(
            minutes: Int((response.expectedTravelTime / 60).rounded(.up)),
            distanceKm: response.distance / 1000,
            updatedAt: .now
        )
    }

    /// "Go": starts your music, if you picked some, and opens Apple Maps with driving directions to the airport.
    @MainActor
    static func go(latitude: Double, longitude: Double, name: String) {
        LeaveMusic.play(AppSettings.shared.leaveMusic)
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
        destination.name = name
        destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    @MainActor
    static func go(to airport: FlightActivityAttributes.Airport) {
        go(latitude: airport.latitude, longitude: airport.longitude, name: "\(airport.code) Airport")
    }
}

/// Plays your Apple Music when you head to the airport. It plays in the Music app, so it keeps going in Maps.
enum LeaveMusic {
    /// The setting's value for "carry on with what you were listening to". A playlist is stored by its id.
    static let resume = "resume"

    static var isAuthorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    struct Playlist: Identifiable, Hashable {
        var id: String
        var name: String
    }

    /// The playlists in your library, for the picker in Settings.
    static func playlists() -> [Playlist] {
        guard isAuthorized else { return [] }
        return (MPMediaQuery.playlists().collections ?? []).compactMap { collection in
            guard let playlist = collection as? MPMediaPlaylist, playlist.count > 0 else { return nil }
            return Playlist(id: String(playlist.persistentID), name: playlist.name ?? "Playlist")
        }
    }

    @MainActor
    static func play(_ choice: String) {
        guard !choice.isEmpty, isAuthorized else { return }
        let player = MPMusicPlayerController.systemMusicPlayer
        if let id = UInt64(choice) {
            let query = MPMediaQuery.playlists()
            query.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaPlaylistPropertyPersistentID))
            if let playlist = query.collections?.first {
                player.setQueue(with: playlist)
            }
        } else if player.playbackState == .playing {
            return
        } else if player.nowPlayingItem == nil {
            // Nothing to pick up from, so shuffle your library.
            player.setQueue(with: MPMediaQuery.songs())
            player.shuffleMode = .songs
        }
        player.play()
    }
}
