//
//  RoutePlanner.swift
//  Drift
//
//  Real-road routes from Apple Maps, then turned into one GPS fix per second
//  at a realistic speed.
//

import Foundation
import MapKit

enum RoutePlanner {
    static func plan(from start: Place, to end: Place, mode: TravelMode) async -> PlannedRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = mode.transport
        request.requestsAlternateRoutes = false

        if let response = try? await MKDirections(request: request).calculate(),
           let route = response.routes.first {
            var coords = [CLLocationCoordinate2D](
                repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: route.polyline.pointCount))
            coords.insert(start.coordinate, at: 0)
            coords.append(end.coordinate)
            return PlannedRoute(start: start, end: end, mode: mode, coordinates: coords,
                                distance: route.distance, followsRoads: true)
        }

        // No road route (ocean, other continent…): go in a straight line.
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        return PlannedRoute(start: start, end: end, mode: mode,
                            coordinates: [start.coordinate, end.coordinate],
                            distance: distance, followsRoads: false)
    }

    /// One coordinate per `interval` seconds while moving at `metersPerSecond`,
    /// with a little speed variation so it doesn't look robotic.
    static func samples(along coordinates: [CLLocationCoordinate2D],
                        metersPerSecond: Double,
                        interval: TimeInterval = 1,
                        variation: Double = 0.12) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 1, metersPerSecond > 0 else { return coordinates }

        var result: [CLLocationCoordinate2D] = [coordinates[0]]
        var segmentIndex = 0
        var segmentStart = coordinates[0]
        var carried: Double = 0

        func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }

        while segmentIndex < coordinates.count - 1 {
            let jitter = 1 + Double.random(in: -variation...variation)
            var step = metersPerSecond * interval * jitter + carried
            carried = 0

            while segmentIndex < coordinates.count - 1 {
                let segmentEnd = coordinates[segmentIndex + 1]
                let remaining = distance(segmentStart, segmentEnd)
                if step < remaining {
                    let fraction = step / remaining
                    segmentStart = CLLocationCoordinate2D(
                        latitude: segmentStart.latitude + (segmentEnd.latitude - segmentStart.latitude) * fraction,
                        longitude: segmentStart.longitude + (segmentEnd.longitude - segmentStart.longitude) * fraction)
                    result.append(segmentStart)
                    break
                }
                step -= remaining
                segmentStart = segmentEnd
                segmentIndex += 1
                if segmentIndex == coordinates.count - 1 {
                    result.append(segmentEnd)
                    carried = 0
                }
            }
        }
        return result
    }
}
