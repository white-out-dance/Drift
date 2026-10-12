//
//  NetworkStatus.swift
//  Drift
//
//  Explains *why* the loopback connection failed. iOS lockdown refuses
//  connections when the phone is on cellular with no Wi-Fi (it assumes they
//  come from the cellular side), so the fix the user needs depends on which
//  interfaces are up.
//

import Foundation
import Darwin
import Network
import UIKit

enum NetworkStatus {
    /// True when LocalDevVPN's tunnel interface is up.
    static var loopbackVPNUp: Bool {
        // LocalDevVPN gives its utun interface 10.7.1.1 (older builds 10.7.0.0)
        // and routes the peer 10.7.0.1 into the tunnel. The peer itself is never
        // assigned to an interface, so match the private /16 instead.
        let target = DeviceLink.deviceIP
        let prefix = target.split(separator: ".").prefix(2).joined(separator: ".") + "."
        return addresses().contains { name, address in
            (name.hasPrefix("utun") || name.hasPrefix("ipsec")) && (address == target || address.hasPrefix(prefix))
        }
    }

    /// True when Wi-Fi has a real (non link-local) IPv4 address.
    static var wifiConnected: Bool {
        addresses().contains { name, address in
            name == "en0" && !address.hasPrefix("169.254.")
        }
    }

    /// True when cellular data has an address.
    static var cellularUp: Bool {
        addresses().contains { name, _ in name.hasPrefix("pdp_ip") }
    }

    private static func addresses() -> [(String, String)] {
        var result: [(String, String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                result.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
            }
        }
        return result
    }

    /// The error to show when the phone's developer services can't be reached.
    static func diagnose() -> DeviceLinkError {
        if !loopbackVPNUp { return .vpnOff }
        if !wifiConnected && cellularUp { return .cellularBlocked }
        return .vpnUnreachable(DeviceLink.deviceIP)
    }
}

extension Notification.Name {
    static let driftNetworkChanged = Notification.Name("driftNetworkChanged")
}

/// Posts `.driftNetworkChanged` (debounced) whenever the phone moves between
/// Wi-Fi, cellular, hotspot or Airplane Mode, so Drift can reconnect.
final class NetworkWatcher {
    static let shared = NetworkWatcher()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "drift.network-watcher")
    private var lastSignature = ""
    private var pending: DispatchWorkItem?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in self?.handle(path) }
        monitor.start(queue: queue)
    }

    private func handle(_ path: NWPath) {
        let physical = path.availableInterfaces.filter { $0.type != .other }.map { "\($0.type)" }.joined(separator: ",")
        let signature = "\(path.status)|\(physical)"
        guard signature != lastSignature else { return }
        lastSignature = signature
        pending?.cancel()
        let work = DispatchWorkItem {
            NotificationCenter.default.post(name: .driftNetworkChanged, object: nil)
        }
        pending = work
        // Let interfaces settle (VPN re-routes, addresses arrive) before reacting.
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

extension NetworkStatus {
    /// Airplane Mode (or no connectivity at all): no cellular data and no Wi-Fi.
    static var offline: Bool { !wifiConnected && !cellularUp }
}

enum LocalDevVPN {
    static let appStoreURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!
    /// Turns the tunnel on, then LocalDevVPN switches back to Drift.
    static let enableURL = URL(string: "localdevvpn://enable?scheme=drift")!

    @MainActor static var isInstalled: Bool {
        UIApplication.shared.canOpenURL(URL(string: "localdevvpn://")!)
    }

    @MainActor static func turnOn() {
        UIApplication.shared.open(isInstalled ? enableURL : appStoreURL)
    }
}
