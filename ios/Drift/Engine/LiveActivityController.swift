//
//  LiveActivityController.swift
//  Drift
//
//  Shows the Lock Screen / Dynamic Island card while spoofing or moving,
//  and removes it the moment spoofing stops.
//

import ActivityKit
import Foundation

@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    private var activity: Activity<DriftActivityAttributes>?
    private var lastState: DriftActivityAttributes.ContentState?
    private var lastPush = Date.distantPast

    private init() {}

    /// Starts the card, or updates it. Progress-only changes are throttled.
    func show(_ state: DriftActivityAttributes.ContentState, force: Bool = false) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        if let activity, activity.activityState == .active {
            if !force, let last = lastState,
               last.kind == state.kind, last.paused == state.paused, last.placeName == state.placeName,
               Date().timeIntervalSince(lastPush) < 5 {
                return
            }
            lastState = state
            lastPush = Date()
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }

        do {
            activity = try Activity.request(
                attributes: DriftActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            lastState = state
            lastPush = Date()
        } catch {
            // iOS only allows starting a Live Activity while Drift is on screen.
            NSLog("Drift Live Activity start failed: \(error.localizedDescription)")
        }
    }

    func end() {
        let current = activity
        activity = nil
        lastState = nil
        Task {
            await current?.end(nil, dismissalPolicy: .immediate)
            for leftover in Activity<DriftActivityAttributes>.activities {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Clears cards left behind if iOS closed Drift mid-spoof.
    func endLeftovers() {
        guard activity == nil else { return }
        Task {
            for leftover in Activity<DriftActivityAttributes>.activities {
                await leftover.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
