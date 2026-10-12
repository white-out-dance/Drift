//
//  Models.swift
//  Drift
//

import Foundation
import CoreLocation
import MapKit

enum SettingsKey {
    static let deviceIP = "deviceIP"
    static let killswitchMinutes = "killswitchMinutes"
    static let jitter = "naturalJitter"
    static let keepAliveLocation = "keepAliveLocation"
    static let walkKmh = "walkKmh"
    static let bikeKmh = "bikeKmh"
    static let driveKmh = "driveKmh"
}

struct Place: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double
    var date = Date()

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(name: String, subtitle: String = "", coordinate: CLLocationCoordinate2D) {
        self.name = name
        self.subtitle = subtitle
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }

    var coordinateText: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    func isNear(_ other: Place, meters: Double = 25) -> Bool {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude)) < meters
    }
}

enum TravelMode: String, Codable, CaseIterable, Identifiable {
    case walk, bike, drive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .walk: return "Walk"
        case .bike: return "Bike"
        case .drive: return "Drive"
        }
    }

    var symbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .bike: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    var defaultKmh: Double {
        switch self {
        case .walk: return 5
        case .bike: return 16
        case .drive: return 50
        }
    }

    var settingsKey: String {
        switch self {
        case .walk: return SettingsKey.walkKmh
        case .bike: return SettingsKey.bikeKmh
        case .drive: return SettingsKey.driveKmh
        }
    }

    var savedKmh: Double {
        let value = UserDefaults.standard.double(forKey: settingsKey)
        return value > 0 ? value : defaultKmh
    }

    var transport: MKDirectionsTransportType {
        self == .drive ? .automobile : .walking
    }
}

struct PlannedRoute: Equatable {
    var start: Place
    var end: Place
    var mode: TravelMode
    var coordinates: [CLLocationCoordinate2D]
    var distance: CLLocationDistance
    var followsRoads: Bool

    static func == (lhs: PlannedRoute, rhs: PlannedRoute) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end && lhs.mode == rhs.mode && lhs.distance == rhs.distance
    }
}

enum ScheduledAction: Codable, Equatable {
    case teleport(Place)
    case route(start: Place, end: Place, mode: TravelMode, kmh: Double, loop: Bool)

    var title: String {
        switch self {
        case .teleport(let place): return "Teleport to \(place.name)"
        case .route(_, let end, let mode, _, _): return "\(mode.label) to \(end.name)"
        }
    }
}

struct ScheduledJob: Codable, Identifiable, Equatable {
    var id = UUID()
    var fireDate: Date
    var action: ScheduledAction
}

/// History, bookmarks and schedules, saved as JSON in Application Support.
@MainActor
final class Library: ObservableObject {
    @Published var history: [Place] = [] { didSet { save() } }
    @Published var bookmarks: [Place] = [] { didSet { save() } }
    @Published var jobs: [ScheduledJob] = [] { didSet { save() } }

    private struct Snapshot: Codable {
        var history: [Place]
        var bookmarks: [Place]
        var jobs: [ScheduledJob]?
    }

    private let url = URL.applicationSupportDirectory.appendingPathComponent("library.json")
    private var loading = false

    init() {
        loading = true
        if let data = try? Data(contentsOf: url),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            history = snapshot.history
            bookmarks = snapshot.bookmarks
            jobs = snapshot.jobs ?? []
        }
        loading = false
    }

    func record(_ place: Place) {
        var entry = place
        entry.id = UUID()
        entry.date = Date()
        history.removeAll { $0.isNear(entry) }
        history.insert(entry, at: 0)
        if history.count > 60 { history.removeLast(history.count - 60) }
    }

    func isBookmarked(_ place: Place) -> Bool {
        bookmarks.contains { $0.isNear(place) }
    }

    func toggleBookmark(_ place: Place) {
        if isBookmarked(place) {
            bookmarks.removeAll { $0.isNear(place) }
        } else {
            var entry = place
            entry.id = UUID()
            bookmarks.insert(entry, at: 0)
        }
    }

    private func save() {
        guard !loading else { return }
        let snapshot = Snapshot(history: history, bookmarks: bookmarks, jobs: jobs)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
