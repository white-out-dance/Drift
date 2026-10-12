//
//  PlaceSearch.swift
//  Drift
//

import Foundation
import MapKit

@MainActor
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" {
        didSet { update() }
    }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    @Published private(set) var coordinateMatch: CLLocationCoordinate2D?

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func setRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    private func update() {
        coordinateMatch = Self.parseCoordinate(query)
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
            completer.cancel()
        } else {
            completer.queryFragment = query
        }
    }

    func clear() {
        query = ""
        results = []
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let items = completer.results
        Task { @MainActor in self.results = Array(items.prefix(8)) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    func resolve(_ completion: MKLocalSearchCompletion) async -> Place? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return Place(name: completion.title, subtitle: completion.subtitle, coordinate: item.placemark.coordinate)
    }

    /// Accepts "48.8584, 2.2945" style input.
    static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2,
              (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    static func describe(_ coordinate: CLLocationCoordinate2D) async -> Place {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first {
            let name = mark.name ?? mark.locality ?? "Dropped pin"
            let subtitle = [mark.locality, mark.administrativeArea, mark.country]
                .compactMap { $0 }
                .filter { $0 != name }
                .joined(separator: ", ")
            return Place(name: name, subtitle: subtitle, coordinate: coordinate)
        }
        return Place(name: "Dropped pin", subtitle: "", coordinate: coordinate)
    }
}
