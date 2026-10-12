//
//  DriftActivityAttributes.swift
//  Drift (shared by the app and the Live Activity extension)
//

import ActivityKit
import AppIntents
import Foundation
import SwiftUI

struct DriftActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Kind: String, Codable, Hashable { case holding, walk, bike, drive }

        var kind: Kind
        var paused: Bool
        /// Where you appear to be (holding) or where you're heading (route).
        var placeName: String
        var detail: String
        /// Start of the spoof session, for the counting-up timer.
        var startedAt: Date
        /// Route progress 0...1 (ignored while holding).
        var progress: Double
        /// Expected arrival, for the countdown (nil while holding or paused).
        var arrival: Date?

        var symbol: String {
            switch kind {
            case .holding: return "location.fill"
            case .walk: return "figure.walk"
            case .bike: return "bicycle"
            case .drive: return "car.fill"
            }
        }

        var title: String {
            switch kind {
            case .holding: return "Spoofing"
            case .walk: return paused ? "Walk paused" : "Walking"
            case .bike: return paused ? "Ride paused" : "Biking"
            case .drive: return paused ? "Drive paused" : "Driving"
            }
        }
    }
}

extension Color {
    static let activityAccent = Color(red: 0.42, green: 0.78, blue: 0.93)
    static let activityGreen = Color(red: 0.36, green: 0.85, blue: 0.47)
    static let activityRed = Color(red: 1.0, green: 0.37, blue: 0.33)
}

/// Stop button on the Lock Screen / Dynamic Island. Runs inside the Drift app.
struct StopSpoofIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop spoofing"
    static var description = IntentDescription("Stops Drift and restores your real location.")

    func perform() async throws -> some IntentResult {
        await DriftIntentBridge.stop()
        return .result()
    }
}

/// The app plugs its engine in here; the extension never calls it directly.
enum DriftIntentBridge {
    @MainActor static var stopHandler: (() async -> Void)?

    @MainActor static func stop() async {
        await stopHandler?()
    }
}
