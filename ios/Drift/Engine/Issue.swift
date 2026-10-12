//
//  Issue.swift
//  Drift
//
//  Every problem Drift can hit, each with its own code, a plain explanation,
//  the exact fix, and (when possible) a one-tap action.
//

import Foundation

struct DriftIssue: Identifiable, Equatable {
    enum Severity { case error, warning }
    enum Action: Equatable {
        case turnOnVPN          // opens LocalDevVPN, it switches back to Drift
        case retry              // try the last spoof again
        case openDriftSettings  // Drift's Setup screen
        case openIOSSettings    // the iOS Settings app (Drift's page)
    }

    let id = UUID()
    let code: String
    let title: String
    let message: String
    let steps: [String]
    let action: Action?
    var severity: Severity = .error
    var detail: String?

    static func == (lhs: DriftIssue, rhs: DriftIssue) -> Bool {
        lhs.code == rhs.code && lhs.detail == rhs.detail && lhs.title == rhs.title
    }

    var actionTitle: String? {
        switch action {
        case .turnOnVPN: return "Turn on LocalDevVPN"
        case .retry: return "Try again"
        case .openDriftSettings: return "Open Setup"
        case .openIOSSettings: return "Open Settings"
        case nil: return nil
        }
    }
}

extension DriftIssue {
    static let noPairingFile = DriftIssue(
        code: "D01", title: "No pairing file",
        message: "Drift needs a pairing file to talk to your iPhone, and it doesn't have one.",
        steps: ["Plug the iPhone into your Mac", "Open Drift for Mac › Setup › Make pairing file", "It's copied into Drift automatically"],
        action: .openDriftSettings)

    static func badPairingFile(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D02", title: "Pairing file is damaged",
            message: "The pairing file inside Drift can't be read.",
            steps: ["Plug the iPhone into your Mac", "Open Drift for Mac › Setup › Make pairing file"],
            action: .openDriftSettings, detail: detail)
    }

    static let vpnOff = DriftIssue(
        code: "D03", title: "LocalDevVPN is off",
        message: "Drift reaches your iPhone through LocalDevVPN, and it isn't connected.",
        steps: ["Tap Turn on LocalDevVPN below", "Drift finishes the spoof by itself once it's connected"],
        action: .turnOnVPN)

    static let cellularBlocked = DriftIssue(
        code: "D04", title: "Blocked on cellular",
        message: "iOS refuses to start Drift's connection while you're on cellular data.",
        steps: ["Turn Cellular Data off for a few seconds (or join Wi-Fi)", "Turn it back on once Drift says Connected"],
        action: .retry)

    static func notAnswering(_ detail: String? = nil) -> DriftIssue {
        DriftIssue(
            code: "D05", title: "iPhone isn't answering",
            message: "LocalDevVPN is on, but your iPhone's developer service didn't respond.",
            steps: ["Open LocalDevVPN, tap Disconnect, then Connect", "Come back and tap Try again", "Still failing? Restart the iPhone"],
            action: .retry, detail: detail)
    }

    static func pairingRejected(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D06", title: "Pairing was rejected",
            message: "Your iPhone no longer trusts Drift's pairing file. This happens after an iOS update, a reset, or sometimes at random.",
            steps: ["Plug the iPhone into your Mac", "Open Drift for Mac › Setup › Make pairing file", "Try again"],
            action: .openDriftSettings, detail: detail)
    }

    static func timedOut(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D07", title: "Connection timed out",
            message: "Drift started connecting but your iPhone stopped responding halfway.",
            steps: ["In LocalDevVPN tap Disconnect, then Connect", "Tap Try again", "If it keeps happening, restart the iPhone"],
            action: .retry, detail: detail)
    }

    static func connectFailed(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D08", title: "Couldn't connect",
            message: "Drift couldn't open its connection to your iPhone.",
            steps: ["Make sure LocalDevVPN says Connected", "Tap Try again", "Still failing? Restart the iPhone"],
            action: .retry, detail: detail)
    }

    static func developerServices(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D09", title: "Developer services unavailable",
            message: "Your iPhone's location-simulation service didn't start.",
            steps: ["Check Settings › Privacy & Security › Developer Mode is On", "In Drift, tap the gear › Mount developer image now", "Tap Try again"],
            action: .retry, detail: detail)
    }

    static func developerImage(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D10", title: "Developer image failed",
            message: "Drift couldn't set up Apple's developer image, which it needs after every iPhone restart.",
            steps: ["Make sure you have internet (Wi-Fi is best)", "Tap Try again", "If it keeps failing, plug into your Mac and use Drift for Mac › Setup › Mount developer image"],
            action: .retry, detail: detail)
    }

    static let needsInternetAfterRestart = DriftIssue(
        code: "D11", title: "Needs internet once",
        message: "After an iPhone restart, Drift has to download and verify Apple's developer image, which needs internet.",
        steps: ["Join Wi-Fi (you can turn Wi-Fi on even in Airplane Mode)", "Tap Try again"],
        action: .retry)

    static let developerModeOff = DriftIssue(
        code: "D12", title: "Developer Mode is off",
        message: "Location simulation only works with Developer Mode switched on.",
        steps: ["Open Settings › Privacy & Security › Developer Mode", "Turn it on and let the iPhone restart", "After it boots, tap Turn On and enter your passcode"],
        action: .openIOSSettings)

    static func connectionDropped(_ cause: DriftIssue) -> DriftIssue {
        var issue = DriftIssue(
            code: "D20", title: "Connection dropped",
            message: "The spoof lost its connection and Drift is retrying every few seconds. Your real location may show until it reconnects. Likely cause: \(cause.title) (\(cause.code)).",
            steps: cause.steps,
            action: cause.action)
        issue.severity = .warning
        return issue
    }

    static func stopFailed(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D21", title: "Couldn't restore real location",
            message: "Drift stopped, but couldn't reach your iPhone to switch the GPS back.",
            steps: ["Turn on LocalDevVPN and tap Stop again", "Or restart the iPhone, which always clears it"],
            action: .turnOnVPN, detail: detail)
    }

    static func other(_ detail: String) -> DriftIssue {
        DriftIssue(
            code: "D99", title: "Something went wrong",
            message: "Drift hit an error it doesn't recognise.",
            steps: ["Tap Try again", "If it repeats, screenshot this and send it over"],
            action: .retry, detail: detail)
    }

    /// Maps any error from the connection layer to the right issue.
    static func from(_ error: Error) -> DriftIssue {
        guard let link = error as? DeviceLinkError else { return .other(error.localizedDescription) }
        switch link {
        case .noPairingFile: return .noPairingFile
        case .badPairingFile(let d): return .badPairingFile(d)
        case .vpnOff: return .vpnOff
        case .cellularBlocked: return .cellularBlocked
        case .vpnUnreachable: return .notAnswering()
        case .tunnel(let d):
            let text = d.lowercased()
            if text.contains("pair") || text.contains("verify") || text.contains("auth") || text.contains("srp") || text.contains("public_key") {
                return .pairingRejected(d)
            }
            if text.contains("timeout") || text.contains("timed out") { return .timedOut(d) }
            if text.contains("refused") || text.contains("reset") || text.contains("unreachable") { return .notAnswering(d) }
            return .connectFailed(d)
        case .developerServices(let d):
            if d.lowercased().contains("developermode") || d.lowercased().contains("developer mode") { return .developerModeOff }
            return .developerServices(d)
        case .ddi(let d):
            let text = d.lowercased()
            if text.contains("internet once") || text.contains("offline") || text.contains("not connected to the internet") {
                return .needsInternetAfterRestart
            }
            if text.contains("developermode") || text.contains("developer mode") { return .developerModeOff }
            return .developerImage(d)
        case .other(let d): return .other(d)
        }
    }
}
