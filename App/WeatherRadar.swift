import MapKit
import SwiftUI
import UIKit

// Live weather radar for the flight screen, from RainViewer's free public API.
//
// What the API allows, from its own documentation (rainviewer.com/api.html) and checked against its tile server:
//  - Personal and educational use, no key. "Weather data by RainViewer", linked to rainviewer.com, must be shown.
//  - The last 2 hours as 13 frames, 10 minutes apart. No forecast frames.
//  - Tiles go up to zoom 7. Above that the server sends a grey "Zoom Level Not Supported" picture.
//  - 100 requests per IP per minute, and abuse can get an address blocked, so `RadarTileLoader` stays well under it.

/// One radar picture: when it was made, and where its tiles are.
struct RadarFrame: Equatable {
    var time: Date
    var path: String
}

/// RainViewer's list of the last two hours of radar. Read once each time the radar is opened, not per frame or per tile.
@MainActor
@Observable
final class RadarFeed {
    enum State: Equatable {
        case idle, loading, ready, unavailable
    }

    private(set) var state = State.idle
    private(set) var host: String?
    private(set) var frames: [RadarFrame] = []
    private var loadedAt: Date?

    private struct Manifest: Decodable {
        struct Radar: Decodable {
            struct Frame: Decodable {
                let time: TimeInterval
                let path: String
            }

            let past: [Frame]
        }

        let host: String
        let radar: Radar
    }

    static let manifestURL = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
    /// Every other frame, so seven pictures 20 minutes apart cover the two hours with half the tiles to fetch.
    static let framesShown = 7

    func load() async {
        guard state == .idle || state == .unavailable else { return }
        state = .loading
        do {
            var request = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("FlightLive/2.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let parsed = try Self.parse(data)
            host = parsed.host
            frames = parsed.frames
            loadedAt = .now
            state = .ready
        } catch is CancellationError {
            state = .idle
        } catch {
            frames = []
            state = .unavailable
        }
    }

    /// The manifest's JSON as the host and the frames to show. Throws if there's nothing usable in it.
    static func parse(_ data: Data) throws -> (host: String, frames: [RadarFrame]) {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        let picked = pick(manifest.radar.past, host: manifest.host)
        guard !picked.isEmpty else { throw URLError(.cannotParseResponse) }
        return (manifest.host, picked)
    }

    /// Oldest to newest, every other frame ending with the newest. Frames that don't point at RainViewer are dropped,
    /// so a changed manifest can't send the app's requests somewhere else.
    private static func pick(_ past: [Manifest.Radar.Frame], host: String) -> [RadarFrame] {
        guard let url = URL(string: host), url.scheme == "https", url.host?.hasSuffix("rainviewer.com") == true else { return [] }
        return stride(from: past.count - 1, through: 0, by: -2)
            .prefix(framesShown)
            .reversed()
            .map { past[$0] }
            .filter { $0.path.hasPrefix("/v2/radar/") }
            .map { RadarFrame(time: Date(timeIntervalSince1970: $0.time), path: $0.path) }
    }

    /// For when the radar is closed: nothing stays loaded, and the next open asks again.
    func reset() {
        state = .idle
        frames = []
        host = nil
        loadedAt = nil
    }

    /// Coming back to the app after a while: the pictures are old by now, so read the list again.
    func refreshIfStale() async {
        guard let loadedAt, Date.now.timeIntervalSince(loadedAt) > 10 * 60 else { return }
        reset()
        await load()
    }

    /// The source stopped answering while the radar was open.
    func markUnavailable() {
        state = .unavailable
    }
}

extension Notification.Name {
    /// Posted by `RadarTileLoader` after several tile requests in a row have failed.
    static let radarSourceFailed = Notification.Name("FlightLive.radarSourceFailed")
}

/// Fetches radar tiles within RainViewer's limit of 100 requests per minute per address, and keeps them on disk
/// (the tiles say they are good for two days), so the same picture is never fetched twice.
actor RadarTileLoader {
    static let shared = RadarTileLoader()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.urlCache = URLCache(memoryCapacity: 40 * 1024 * 1024, diskCapacity: 150 * 1024 * 1024, directory: nil)
        config.httpAdditionalHeaders = ["User-Agent": "FlightLive/2.0 (iOS)"]
        return URLSession(configuration: config)
    }()

    /// Real network requests only; a tile already kept doesn't count. Under the 100 per minute RainViewer allows.
    private let budget: Int
    private let window: TimeInterval
    private let mostAtOnce: Int
    private var started: [Date] = []
    private var inFlight = 0
    private var backoffUntil = Date.distantPast
    private var failuresInARow = 0

    init(budget: Int = 70, window: TimeInterval = 60, mostAtOnce: Int = 6) {
        self.budget = budget
        self.window = window
        self.mostAtOnce = mostAtOnce
    }

    struct TileError: Error {
        var status: Int
    }

    func data(for url: URL) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
        if let kept = session.configuration.urlCache?.cachedResponse(for: request),
           (kept.response as? HTTPURLResponse)?.statusCode == 200 {
            return kept.data
        }
        try await waitForTurn()
        inFlight += 1
        defer { inFlight -= 1 }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // Told to slow down: stop asking for a while.
                if status == 429 { backoffUntil = .now.addingTimeInterval(30) }
                throw TileError(status: status)
            }
            failuresInARow = 0
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            failuresInARow += 1
            // A few misses are normal. Six in a row means the source is down or the network is.
            if failuresInARow == 6 {
                NotificationCenter.default.post(name: .radarSourceFailed, object: nil)
            }
            throw error
        }
    }

    private func waitForTurn() async throws {
        while true {
            try Task.checkCancellation()
            let now = Date.now
            started.removeAll { now.timeIntervalSince($0) >= window }
            var wait = backoffUntil.timeIntervalSince(now)
            if started.count >= budget { wait = max(wait, started[0].addingTimeInterval(window).timeIntervalSince(now)) }
            if inFlight >= mostAtOnce { wait = max(wait, 0.1) }
            if wait <= 0 {
                started.append(now)
                return
            }
            try await Task.sleep(for: .seconds(wait))
        }
    }

    /// The radar is closed or its source answered again: start counting failures afresh.
    func resetFailures() {
        failuresInARow = 0
    }
}

/// The tiles of one radar frame, fetched through the shared `RadarTileLoader`.
final class RadarTileOverlay: MKTileOverlay {
    let frame: RadarFrame
    private let lock = NSLock()
    private var pending = 0
    private var requested = 0
    /// One fetch per tile, even though MapKit asks for each tile twice.
    private var fetches: [URL: Task<Data, Error>] = [:]

    init(host: String, frame: RadarFrame) {
        self.frame = frame
        // 512-pixel tiles: the same detail as 256-pixel ones with a quarter of the requests (measured: 6 tiles a frame
        // against 24 for a full-screen map), which matters under a limit of 100 requests a minute.
        // Colour scheme 2 (Universal Blue) is the only one still served; smoothed, with snow in its own colours.
        super.init(urlTemplate: "\(host)\(frame.path)/512/{z}/{x}/{y}/2/1_1.png")
        tileSize = CGSize(width: 512, height: 512)
        // Zoom 8 and up is a "not supported" picture. Past 7, MapKit stretches the zoom 7 tiles instead.
        maximumZ = 7
        canReplaceMapContent = false
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let url = url(forTilePath: path)
        lock.lock()
        pending += 1
        requested += 1
        let fetch: Task<Data, Error>
        if let existing = fetches[url] {
            fetch = existing
        } else {
            fetch = Task { try await RadarTileLoader.shared.data(for: url) }
            fetches[url] = fetch
        }
        lock.unlock()
        Task.detached { [self] in
            do {
                let data = try await fetch.value
                finish()
                result(data, nil)
            } catch {
                finish()
                result(nil, error)
            }
        }
    }

    private func finish() {
        lock.lock()
        pending -= 1
        lock.unlock()
    }

    /// The radar is closed: stop asking for tiles, including ones still waiting their turn.
    func cancelAll() {
        lock.lock()
        let running = fetches.values
        fetches.removeAll()
        lock.unlock()
        running.forEach { $0.cancel() }
    }

    /// Every tile MapKit has asked for has come back (or failed), and it has asked for some.
    var hasLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested > 0 && pending == 0
    }

    var hasAskedForTiles: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested > 0
    }
}

// MARK: - Playback

/// What the radar is doing, for the controls around the map.
@MainActor
@Observable
final class RadarPlayback {
    /// Playing, unless you paused it (and unless Reduce Motion is on, when it starts paused).
    var wantsPlay = !UIAccessibility.isReduceMotionEnabled
    var shownFrame: RadarFrame?
    /// While the other frames are being fetched: how many are in.
    var loadedCount = 0
    var isUnavailable = false

    /// "6m ago", "1h 26m ago"
    func age(of frame: RadarFrame, now: Date = .now) -> String {
        let minutes = max(Int(now.timeIntervalSince(frame.time) / 60), 0)
        return "\(FlightPresentation.duration(minutes)) ago"
    }
}

// MARK: - The map

/// The route to draw: where the flight is and where it is going.
struct RadarRoute: Equatable {
    var origin: FlightActivityAttributes.Airport?
    var destination: FlightActivityAttributes.Airport?
    var plane: CLLocationCoordinate2D?
    var track: Double?
    var hasDeparted: Bool

    static func == (lhs: RadarRoute, rhs: RadarRoute) -> Bool {
        lhs.origin == rhs.origin && lhs.destination == rhs.destination && lhs.track == rhs.track && lhs.hasDeparted == rhs.hasDeparted
            && lhs.plane?.latitude == rhs.plane?.latitude && lhs.plane?.longitude == rhs.plane?.longitude
    }
}

/// A satellite map with the route, the two airports as pills, the plane turned to its track, and the radar on top.
struct RadarMapView: UIViewRepresentable {
    var host: String?
    var frames: [RadarFrame]
    var route: RadarRoute
    var isInteractive: Bool
    /// False while the screen is covered or the app is in the background: no tiles are asked for.
    var isActive: Bool
    /// Passed in so SwiftUI updates the map when play or pause is tapped.
    var wantsPlay: Bool
    var playback: RadarPlayback

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        map.overrideUserInterfaceStyle = .dark
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.isUserInteractionEnabled = isInteractive
        map.delegate = context.coordinator
        context.coordinator.map = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.isUserInteractionEnabled = isInteractive
        context.coordinator.update(host: host, frames: frames, route: route, isActive: isActive, wantsPlay: wantsPlay)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        let playback: RadarPlayback
        weak var map: MKMapView?
        private var host: String?
        private var frames: [RadarFrame] = []
        private var route: RadarRoute?
        private var isActive = false
        private var overlays: [Date: RadarTileOverlay] = [:]
        private var shown: RadarTileOverlay?
        private var cycle: Task<Void, Never>?
        private var regionTask: Task<Void, Never>?
        private var didFit = false
        private var wasPlaying = true
        private var hadFrames = false
        private var failureObserver: NSObjectProtocol?

        init(playback: RadarPlayback) {
            self.playback = playback
            super.init()
            failureObserver = NotificationCenter.default.addObserver(forName: .radarSourceFailed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sourceFailed() }
            }
        }

        deinit {
            if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        }

        // MARK: Updates from SwiftUI

        func update(host: String?, frames: [RadarFrame], route: RadarRoute, isActive: Bool, wantsPlay: Bool) {
            guard let map else { return }
            if self.route != route {
                self.route = route
                drawRoute(on: map)
            }
            let framesChanged = self.frames != frames || self.host != host
            self.host = host
            self.frames = frames
            if framesChanged || self.isActive != isActive || wasPlaying != wantsPlay {
                self.isActive = isActive
                wasPlaying = wantsPlay
                if framesChanged { removeRadar(from: map) }
                restart()
            }
        }

        private func removeRadar(from map: MKMapView) {
            // Take it off the map and stop any tile still being asked for, so nothing loads once it's closed.
            overlays.values.forEach { $0.cancelAll() }
            map.removeOverlays(map.overlays.filter { $0 is RadarTileOverlay })
            shown = nil
            overlays.removeAll()
        }

        func stop() {
            cycle?.cancel()
            regionTask?.cancel()
            cycle = nil
            if let map { removeRadar(from: map) }
        }

        private func sourceFailed() {
            guard isActive, !frames.isEmpty else { return }
            // Take the radar off the map rather than leave half a picture.
            playback.isUnavailable = true
            stop()
        }

        // MARK: Showing the radar

        private func restart() {
            cycle?.cancel()
            guard isActive, let host, !frames.isEmpty, !playback.isUnavailable, map != nil else {
                // Closed, covered, in the background, or no radar to show: nothing stays on the map or loading.
                stop()
                return
            }
            cycle = Task { [weak self] in await self?.run(host: host) }
        }

        private func overlay(for frame: RadarFrame, host: String) -> RadarTileOverlay {
            if let existing = overlays[frame.time] { return existing }
            let made = RadarTileOverlay(host: host, frame: frame)
            overlays[frame.time] = made
            return made
        }

        /// Shows the newest picture straight away. If it's playing, then fetches the other frames one at a time
        /// (each shown for a moment as it comes in) and loops through them.
        private func run(host: String) async {
            guard let newest = frames.last else { return }
            show(newest, host: host)
            await settle(overlay(for: newest, host: host))
            guard !Task.isCancelled else { return }

            guard frames.count > 1, playback.wantsPlay else { return }
            playback.loadedCount = 1
            for frame in frames.dropLast().reversed() {
                show(frame, host: host)
                await settle(overlay(for: frame, host: host))
                guard !Task.isCancelled else { return }
                playback.loadedCount += 1
            }
            while !Task.isCancelled, playback.wantsPlay {
                for frame in frames {
                    show(frame, host: host)
                    // Stay a little longer on the latest picture.
                    try? await Task.sleep(for: .milliseconds(frame == frames.last ? 1_500 : 650))
                    if Task.isCancelled || !playback.wantsPlay { break }
                }
            }
        }

        /// Waits until the tiles MapKit asked for have come in, giving up after a few seconds.
        private func settle(_ overlay: RadarTileOverlay) async {
            let start = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                let waited = Date.now.timeIntervalSince(start)
                if overlay.hasLoaded && waited > 0.3 { return }
                // MapKit hasn't asked for anything (off-screen, or nothing to cover): don't wait for it.
                if !overlay.hasAskedForTiles && waited > 1 { return }
                if waited > 8 { return }
            }
        }

        private func show(_ frame: RadarFrame, host: String) {
            guard let map else { return }
            let next = overlay(for: frame, host: host)
            playback.shownFrame = frame
            guard next !== shown else { return }
            map.addOverlay(next, level: .aboveRoads)
            let old = shown
            shown = next
            // Take the previous picture off once the new one has had a moment to draw, so the map never blinks.
            if let old {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    if let self, old !== self.shown { self.map?.removeOverlay(old) }
                }
            }
        }

        // MARK: Route and airports

        private func drawRoute(on map: MKMapView) {
            map.removeOverlays(map.overlays.filter { $0 is MKPolyline })
            map.removeAnnotations(map.annotations)
            guard let route else { return }
            var rect = MKMapRect.null
            func extend(_ coordinate: CLLocationCoordinate2D) {
                let point = MKMapPoint(coordinate)
                rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }

            if let origin = route.origin, let destination = route.destination {
                let flown: [CLLocationCoordinate2D]?
                var ahead: [CLLocationCoordinate2D]
                if route.hasDeparted, let plane = route.plane {
                    flown = [origin.coordinate, plane]
                    ahead = [plane, destination.coordinate]
                } else {
                    flown = nil
                    ahead = [origin.coordinate, destination.coordinate]
                }
                let aheadLine = MKGeodesicPolyline(coordinates: ahead, count: 2)
                aheadLine.title = "ahead"
                map.addOverlay(aheadLine, level: .aboveLabels)
                if let flown {
                    let flownLine = MKGeodesicPolyline(coordinates: flown, count: 2)
                    flownLine.title = "flown"
                    map.addOverlay(flownLine, level: .aboveLabels)
                }
                for airport in [origin, destination] {
                    map.addAnnotation(AirportAnnotation(airport: airport))
                    extend(airport.coordinate)
                }
            }
            if let plane = route.plane, route.hasDeparted || route.origin == nil {
                map.addAnnotation(PlaneAnnotation(coordinate: plane, track: route.track))
                extend(plane)
            }
            if !didFit, !rect.isNull {
                didFit = true
                let padded = rect.insetBy(dx: -max(rect.width * 0.15, 400_000), dy: -max(rect.height * 0.25, 400_000))
                map.setVisibleMapRect(padded, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 56, right: 40), animated: false)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tiles)
                renderer.alpha = 0.78
                return renderer
            }
            let renderer = MKPolylineRenderer(overlay: overlay)
            renderer.lineCap = .round
            renderer.lineWidth = 3
            if (overlay as? MKPolyline)?.title == "flown" {
                renderer.strokeColor = UIColor(Color.flightBlue)
            } else {
                renderer.strokeColor = UIColor.white.withAlphaComponent(0.85)
                renderer.lineDashPattern = [1, 7]
                renderer.lineWidth = 2.5
            }
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let airport = annotation as? AirportAnnotation {
                let view = MKAnnotationView(annotation: airport, reuseIdentifier: "airport")
                let pill = AirportPill(city: airport.airport.city, code: airport.airport.code)
                view.image = Self.image(of: pill, scale: mapView.traitCollection.displayScale)
                // The ring is at the bottom of the picture, and sits on the airport.
                view.centerOffset = CGPoint(x: 0, y: -((view.image?.size.height ?? 0) / 2 - AirportPill.ringSize / 2))
                view.displayPriority = .required
                view.canShowCallout = false
                return view
            }
            if let plane = annotation as? PlaneAnnotation {
                let view = MKAnnotationView(annotation: plane, reuseIdentifier: "plane")
                view.image = Self.image(of: RadarPlane(track: plane.track), scale: mapView.traitCollection.displayScale)
                view.displayPriority = .required
                view.canShowCallout = false
                view.zPriority = .max
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard didFit, isActive, !frames.isEmpty else { return }
            // After you've moved or zoomed the map, fetch the radar for the new area, once it has settled.
            regionTask?.cancel()
            regionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.restart()
            }
        }

        private static func image<V: View>(of view: V, scale: CGFloat) -> UIImage? {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
            renderer.scale = scale
            return renderer.uiImage
        }
    }
}

private final class AirportAnnotation: NSObject, MKAnnotation {
    let airport: FlightActivityAttributes.Airport
    var coordinate: CLLocationCoordinate2D { airport.coordinate }

    init(airport: FlightActivityAttributes.Airport) {
        self.airport = airport
    }
}

private final class PlaneAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let track: Double?

    init(coordinate: CLLocationCoordinate2D, track: Double?) {
        self.coordinate = coordinate
        self.track = track
    }
}

/// "Austin AUS" in a blue pill, with a ring under it on the airport.
struct AirportPill: View {
    var city: String
    var code: String

    static let ringSize: CGFloat = 14

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text(city)
                    .fontWeight(.semibold)
                Text(code)
                    .fontWeight(.heavy)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.flightBlue, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            Circle()
                .strokeBorder(.white, lineWidth: 2.5)
                .background(Circle().fill(Color.flightBlue.opacity(0.4)))
                .frame(width: Self.ringSize, height: Self.ringSize)
        }
        .shadow(color: .black.opacity(0.5), radius: 2)
        .padding(4)
    }
}

/// The plane, turned to the way it's heading.
struct RadarPlane: View {
    var track: Double?

    var body: some View {
        Image(systemName: "airplane")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            // The symbol points east; map headings start at north.
            .rotationEffect(.degrees((track ?? 90) - 90))
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.flightBlue))
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 3)
            .padding(4)
    }
}

// MARK: - On the flight screen

/// The credit RainViewer asks for, linked to them.
struct RadarCredit: View {
    var body: some View {
        Link(destination: URL(string: "https://www.rainviewer.com/")!) {
            Text("Weather data by RainViewer")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
        }
    }
}

/// Play or pause, and how old the picture on the map is.
private struct RadarControls: View {
    var feed: RadarFeed
    var playback: RadarPlayback

    var body: some View {
        HStack(spacing: 8) {
            if playback.isUnavailable || feed.state == .unavailable {
                HStack(spacing: 6) {
                    Image(systemName: "cloud.slash")
                    Text("Radar unavailable")
                }
                .font(.system(size: 12, weight: .semibold))
            } else if feed.state == .loading || playback.shownFrame == nil {
                ProgressView().controlSize(.small)
                Text("Loading radar")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                Button {
                    playback.wantsPlay.toggle()
                } label: {
                    Image(systemName: playback.wantsPlay ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.wantsPlay ? "Pause radar" : "Play radar")
                if let frame = playback.shownFrame {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(frame.time.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(playback.age(of: frame))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                if playback.wantsPlay, playback.loadedCount > 0, playback.loadedCount < feed.frames.count {
                    Text("\(playback.loadedCount)/\(feed.frames.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

/// A "Weather radar" map on the flight screen. Tap it for full screen.
struct RadarCard: View {
    var flight: TrackedFlight

    @State private var feed = RadarFeed()
    @State private var playback = RadarPlayback()
    @State private var showsFullScreen = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WEATHER RADAR")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            ZStack(alignment: .bottom) {
                RadarMapView(
                    host: feed.host, frames: feed.frames, route: RadarRoute(flight: flight), isInteractive: false,
                    isActive: scenePhase == .active && !showsFullScreen, wantsPlay: playback.wantsPlay, playback: playback
                )
                // The map doesn't take touches itself, so a tap anywhere on it opens the big one.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showsFullScreen = true }
                    .accessibilityLabel("Weather radar")
                    .accessibilityHint("Opens the radar full screen")
                    .accessibilityAddTraits(.isButton)
                // Apple's "Maps" mark sits at the bottom left and has to stay clear, so the controls go on top.
                VStack {
                    HStack {
                        RadarControls(feed: feed, playback: playback)
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        RadarCredit()
                    }
                }
                .padding(8)
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(Color.flightCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // The list of frames is read once each time the flight screen is opened, and dropped when it closes.
        .task {
            await feed.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await feed.refreshIfStale() } }
        }
        .onDisappear {
            // Covered by the full-screen radar isn't leaving the screen.
            if !showsFullScreen { feed.reset() }
        }
        .fullScreenCover(isPresented: $showsFullScreen) {
            RadarFullScreen(flight: flight, feed: feed)
        }
    }
}

/// The radar, full screen, that you can move around and zoom.
struct RadarFullScreen: View {
    var flight: TrackedFlight
    var feed: RadarFeed

    @State private var playback = RadarPlayback()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .top) {
            RadarMapView(
                host: feed.host, frames: feed.frames, route: RadarRoute(flight: flight), isInteractive: true,
                isActive: scenePhase == .active, wantsPlay: playback.wantsPlay, playback: playback
            )
            .ignoresSafeArea()
            VStack {
                HStack(alignment: .top) {
                    RadarControls(feed: feed, playback: playback)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Close radar")
                }
                Spacer()
                HStack {
                    Spacer()
                    RadarCredit()
                }
            }
            .padding(14)
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

extension RadarRoute {
    init(flight: TrackedFlight) {
        self.init(
            origin: flight.attributes.origin, destination: flight.attributes.destination,
            plane: flight.coordinate, track: flight.track, hasDeparted: flight.state.phase.hasDeparted
        )
    }
}
