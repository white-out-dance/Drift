//
//  RenewalReminder.swift
//  Drift
//
//  Apps signed with a free Apple ID stop opening when their provisioning
//  profile expires (7 days). Drift reads its own expiry date and schedules
//  local notifications ahead of it, so renewing is never a surprise.
//

import Foundation
import UIKit
import UserNotifications

enum SigningInfo {
    /// Expiry of the embedded provisioning profile, or nil (e.g. simulator builds).
    static let expirationDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    static var timeLeft: TimeInterval? {
        expirationDate.map { $0.timeIntervalSinceNow }
    }

    /// True when renewal is due within two days.
    static var renewalDueSoon: Bool {
        guard let left = timeLeft else { return false }
        return left < 2 * 24 * 3600
    }

    static var shortCountdown: String {
        guard let left = timeLeft else { return "" }
        if left <= 0 { return "now" }
        let hours = Int(left / 3600)
        if hours < 24 { return hours <= 1 ? "in under an hour" : "in \(hours) hours" }
        let days = Int((left / 86400).rounded(.down))
        return days == 1 ? "in 1 day" : "in \(days) days"
    }
}

@MainActor
final class RenewalReminder: ObservableObject {
    static let shared = RenewalReminder()

    enum Status: Equatable { case unknown, notAsked, on, off }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var nextReminder: Date?

    private static let ids = ["renew-48h", "renew-24h", "renew-3h"]
    private let center = UNUserNotificationCenter.current()

    /// Called on launch and whenever Drift comes to the foreground.
    /// Asks for permission the first time, then (re)schedules the reminders.
    func refresh() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            // Only ask while actually on screen; iOS drops prompts requested in the background.
            guard UIApplication.shared.applicationState == .active else { status = .notAsked; return }
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            status = granted ? .on : .off
        case .denied:
            status = .off
        default:
            status = .on
        }
        if status == .on { await schedule() }
    }

    /// The "Turn on reminders" button: ask if we can, otherwise open iOS Settings.
    func turnOn() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            await refresh()
        } else if settings.authorizationStatus == .denied {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                await UIApplication.shared.open(url)
            }
        } else {
            await refresh()
        }
    }

    /// Fires a sample reminder in 5 seconds so you can see what it looks like.
    func sendTest() async {
        await refresh()
        guard status == .on else { return }
        let content = UNMutableNotificationContent()
        content.title = "Renew Drift"
        content.body = "This is what your renewal reminder looks like. Drift works until \(expiryText)."
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: "renew-test", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }

    private var expiryText: String {
        SigningInfo.expirationDate?.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()) ?? "next week"
    }

    private func schedule() async {
        guard let expiry = SigningInfo.expirationDate else { nextReminder = nil; return }
        center.removePendingNotificationRequests(withIdentifiers: Self.ids)

        let when = expiry.formatted(.dateTime.weekday(.wide).hour().minute())
        let plan: [(String, TimeInterval, String)] = [
            ("renew-48h", 48 * 3600, "Drift stops opening in 2 days (\(when))."),
            ("renew-24h", 24 * 3600, "Drift stops opening tomorrow (\(when))."),
            ("renew-3h", 3 * 3600, "Drift stops opening in 3 hours."),
        ]
        var earliest: Date?
        for (id, before, text) in plan {
            let fire = Self.friendlyTime(expiry.addingTimeInterval(-before), before: expiry)
            guard fire > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Renew Drift"
            content.body = text + " Plug your iPhone into your Mac and double-click “Renew Drift” in the Drift folder."
            content.sound = .default
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            try? await center.add(UNNotificationRequest(
                identifier: id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
            earliest = min(earliest ?? fire, fire)
        }
        nextReminder = earliest
    }

    /// Moves a reminder out of the night (before 9:00 / after 21:00) while
    /// keeping it before the expiry.
    private static func friendlyTime(_ date: Date, before expiry: Date) -> Date {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        var adjusted = date
        if hour < 9 {
            adjusted = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        } else if hour >= 21 {
            adjusted = cal.date(bySettingHour: 19, minute: 0, second: 0, of: date) ?? date
        }
        return adjusted < expiry ? adjusted : date
    }
}
