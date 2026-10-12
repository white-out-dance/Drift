//
//  DeviceLink.swift
//  Drift
//
//  Talks to this iPhone's own developer services through the LocalDevVPN
//  loopback (10.7.0.1) using a RemotePairing pairing file and the idevice
//  library. Connection approach adapted from StikDebug (AGPL-3.0).
//

import Foundation
#if !targetEnvironment(simulator)
import idevice
#endif

enum DeviceLinkError: LocalizedError {
    case noPairingFile
    case badPairingFile(String)
    case vpnOff
    case cellularBlocked
    case vpnUnreachable(String)
    case tunnel(String)
    case developerServices(String)
    case ddi(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noPairingFile:
            return "No pairing file yet. Open Setup and import the pairing file from the Mac setup tool."
        case .badPairingFile(let detail):
            return "The pairing file couldn't be read (\(detail)). Make a new one with the Mac setup tool."
        case .vpnOff:
            return "LocalDevVPN is off. Tap Turn On and Drift will finish the spoof when it's connected."
        case .cellularBlocked:
            return "iOS blocks this connection on cellular data. Turn Cellular Data off for a few seconds (or join Wi-Fi), then turn it back on. Keep LocalDevVPN connected."
        case .vpnUnreachable:
            return "LocalDevVPN is on but the iPhone isn't answering. In LocalDevVPN tap Disconnect, then Connect, and try again. If it still fails, restart the iPhone."
        case .tunnel(let detail):
            return "Connection was refused (\(detail)). If this keeps happening, make a fresh pairing file with the Mac setup tool."
        case .developerServices(let detail):
            return "Developer services aren't available (\(detail)). Check Developer Mode is on, then tap Setup → Mount developer image."
        case .ddi(let detail):
            return "Couldn't mount the developer image: \(detail)"
        case .other(let detail):
            return detail
        }
    }
}

#if !targetEnvironment(simulator)
/// All idevice handles live on one serial queue; never touch them elsewhere.
final class DeviceLink {
    static let shared = DeviceLink()

    private let queue = DispatchQueue(label: "drift.device-link", qos: .userInitiated)
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var locationSimulation: OpaquePointer?

    private init() {}

    static var deviceIP: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKey.deviceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false ? stored! : "10.7.0.1")
    }

    static let remotePairingPort: UInt16 = 49152

    // MARK: - Async API

    func setLocation(latitude: Double, longitude: Double) async throws {
        try await run { try self.setLocationSync(latitude: latitude, longitude: longitude) }
    }

    func clearLocation() async throws {
        try await run { try self.clearLocationSync() }
    }

    func isDeveloperImageMounted() async throws -> Bool {
        try await run { try self.isDDIMountedSync() }
    }

    func mountDeveloperImage(directory: URL, useCryptex: Bool) async throws {
        try await run { try self.mountDDISync(directory: directory, useCryptex: useCryptex) }
    }

    func developerModeEnabled() async throws -> Bool? {
        try await run { try self.developerModeSync() }
    }

    /// Opens the tunnel without touching location, to check that everything is wired up.
    func testConnection() async throws {
        try await run { try self.openTunnelSync() }
    }

    func disconnect() async {
        _ = try? await run { self.closeAllSync() }
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Location (queue only)

    private func setLocationSync(latitude: Double, longitude: Double) throws {
        if let sim = locationSimulation {
            if let err = location_simulation_set(sim, latitude, longitude) {
                idevice_error_free(err)
                closeAllSync() // stale connection, rebuild below
            } else {
                return
            }
        }

        try openTunnelSync()

        var server: OpaquePointer?
        if let err = remote_server_connect_rsd(adapter, handshake, &server) {
            let message = consume(err, fallback: "remote server unavailable")
            closeAllSync()
            throw DeviceLinkError.developerServices(message)
        }

        var sim: OpaquePointer?
        if let err = location_simulation_new(server, &sim) {
            let message = consume(err, fallback: "location service unavailable")
            if let server { remote_server_free(server) }
            closeAllSync()
            throw DeviceLinkError.developerServices(message)
        }
        // The location client now owns the remote server connection.
        locationSimulation = sim

        if let err = location_simulation_set(sim, latitude, longitude) {
            let message = consume(err, fallback: "set location failed")
            closeAllSync()
            throw DeviceLinkError.developerServices(message)
        }
    }

    private func clearLocationSync() throws {
        guard let sim = locationSimulation else {
            // Nothing live in this session. Open a fresh one just to clear,
            // in case a previous session left a location behind.
            try openTunnelSync()
            var server: OpaquePointer?
            if let err = remote_server_connect_rsd(adapter, handshake, &server) {
                let message = consume(err, fallback: "remote server unavailable")
                closeAllSync()
                throw DeviceLinkError.developerServices(message)
            }
            var fresh: OpaquePointer?
            if let err = location_simulation_new(server, &fresh) {
                let message = consume(err, fallback: "location service unavailable")
                if let server { remote_server_free(server) }
                closeAllSync()
                throw DeviceLinkError.developerServices(message)
            }
            let err = location_simulation_clear(fresh)
            location_simulation_free(fresh)
            closeAllSync()
            if let err { throw DeviceLinkError.other(consume(err, fallback: "clear failed")) }
            return
        }

        let err = location_simulation_clear(sim)
        closeAllSync()
        if let err {
            throw DeviceLinkError.other(consume(err, fallback: "clear failed"))
        }
    }

    // MARK: - Tunnel (queue only)

    private func openTunnelSync() throws {
        if adapter != nil, handshake != nil { return }
        closeAllSync()

        guard let pairingURL = PairingFileStore.existingURL else {
            throw DeviceLinkError.noPairingFile
        }

        let ip = Self.deviceIP
        guard Reachability.canConnect(host: ip, port: Self.remotePairingPort, timeout: 3)
                || Reachability.canConnect(host: ip, port: Self.remotePairingPort, timeout: 4) else {
            throw NetworkStatus.diagnose()
        }

        var pairing: OpaquePointer?
        if let err = pairingURL.path.withCString({ rp_pairing_file_read($0, &pairing) }) {
            throw DeviceLinkError.badPairingFile(consume(err, fallback: "unreadable"))
        }
        guard let pairing else { throw DeviceLinkError.badPairingFile("empty") }
        defer { rp_pairing_file_free(pairing) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(Self.remotePairingPort).bigEndian
        guard ip.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw DeviceLinkError.other("Invalid device IP address: \(ip)")
        }

        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let err = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                tunnel_create_rppairing(
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.stride),
                    "Drift",
                    pairing,
                    nil,
                    nil,
                    &newAdapter,
                    &newHandshake
                )
            }
        }
        if let err {
            if let newHandshake { rsd_handshake_free(newHandshake) }
            if let newAdapter { adapter_free(newAdapter) }
            let message = consume(err, fallback: "tunnel failed")
            if !NetworkStatus.wifiConnected && NetworkStatus.cellularUp {
                throw DeviceLinkError.cellularBlocked
            }
            throw DeviceLinkError.tunnel(message)
        }
        guard newAdapter != nil, newHandshake != nil else {
            if let newHandshake { rsd_handshake_free(newHandshake) }
            if let newAdapter { adapter_free(newAdapter) }
            throw DeviceLinkError.tunnel("no tunnel handles")
        }
        adapter = newAdapter
        handshake = newHandshake
    }

    private func closeAllSync() {
        if let locationSimulation {
            location_simulation_free(locationSimulation)
            self.locationSimulation = nil
        }
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }

    // MARK: - Developer disk image (queue only)

    private func isDDIMountedSync() throws -> Bool {
        try openTunnelSync()

        var installed: UnsafeMutablePointer<InstalledCryptexC>?
        let cryptexErr = cryptexd_installed_ddi(adapter, handshake, &installed)
        if let cryptexErr { idevice_error_free(cryptexErr) }
        let hasCryptex = installed != nil
        cryptexd_free_installed_cryptex(installed)
        if hasCryptex { return true }

        var mounter: OpaquePointer?
        if let err = image_mounter_connect_rsd(adapter, handshake, &mounter) {
            let message = consume(err, fallback: "image mounter unavailable")
            closeAllSync()
            throw DeviceLinkError.developerServices(message)
        }
        defer { image_mounter_free(mounter) }

        var devices: UnsafeMutablePointer<plist_t?>?
        var count = 0
        if let err = image_mounter_copy_devices(mounter, &devices, &count) {
            throw DeviceLinkError.developerServices(consume(err, fallback: "couldn't list mounted images"))
        }
        if let devices {
            for index in 0..<count { plist_free(devices[index]) }
            idevice_data_free(
                UnsafeMutableRawPointer(devices).assumingMemoryBound(to: UInt8.self),
                UInt(count * MemoryLayout<plist_t?>.stride)
            )
        }
        return count > 0
    }

    private func mountDDISync(directory: URL, useCryptex: Bool) throws {
        try openTunnelSync()

        if useCryptex {
            var assets: OpaquePointer?
            if let err = directory.path.withCString({ cryptex1_assets_load($0, &assets) }) {
                throw DeviceLinkError.ddi(consume(err, fallback: "couldn't load image files"))
            }
            defer { cryptex1_assets_free(assets) }
            if let err = cryptexd_install_ddi(adapter, handshake, assets, nil) {
                throw DeviceLinkError.ddi(consume(err, fallback: "install failed"))
            }
            return
        }

        let image = try Data(contentsOf: directory.appendingPathComponent("Image.dmg"), options: .mappedIfSafe)
        let trustcache = try Data(contentsOf: directory.appendingPathComponent("Image.dmg.trustcache"), options: .mappedIfSafe)
        let manifest = try Data(contentsOf: directory.appendingPathComponent("BuildManifest.plist"), options: .mappedIfSafe)

        let chipID = try uniqueChipIDSync()

        var mounter: OpaquePointer?
        if let err = image_mounter_connect_rsd(adapter, handshake, &mounter) {
            throw DeviceLinkError.ddi(consume(err, fallback: "image mounter unavailable"))
        }
        defer { image_mounter_free(mounter) }

        let err = image.withUnsafeBytes { imageBuffer in
            trustcache.withUnsafeBytes { trustBuffer in
                manifest.withUnsafeBytes { manifestBuffer in
                    image_mounter_mount_personalized_rsd(
                        mounter,
                        adapter,
                        handshake,
                        imageBuffer.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        trustBuffer.bindMemory(to: UInt8.self).baseAddress,
                        trustcache.count,
                        manifestBuffer.bindMemory(to: UInt8.self).baseAddress,
                        manifest.count,
                        nil,
                        chipID
                    )
                }
            }
        }
        if let err {
            throw DeviceLinkError.ddi(consume(err, fallback: "mount failed"))
        }
    }

    private func uniqueChipIDSync() throws -> UInt64 {
        var client: OpaquePointer?
        if let err = lockdownd_connect_rsd(adapter, handshake, &client) {
            throw DeviceLinkError.ddi(consume(err, fallback: "lockdownd unavailable"))
        }
        defer { lockdownd_client_free(client) }

        var value: plist_t?
        if let err = lockdownd_get_value(client, "UniqueChipID", nil, &value) {
            throw DeviceLinkError.ddi(consume(err, fallback: "couldn't read chip ID"))
        }
        defer { plist_free(value) }
        var chipID: UInt64 = 0
        plist_get_uint_val(value, &chipID)
        guard chipID != 0 else { throw DeviceLinkError.ddi("chip ID was empty") }
        return chipID
    }

    private func developerModeSync() throws -> Bool? {
        try openTunnelSync()
        var client: OpaquePointer?
        if let err = lockdownd_connect_rsd(adapter, handshake, &client) {
            idevice_error_free(err)
            return nil
        }
        defer { lockdownd_client_free(client) }

        var value: plist_t?
        if let err = lockdownd_get_value(client, "DeveloperModeStatus", "com.apple.security.mac.amfi", &value) {
            idevice_error_free(err)
            return nil
        }
        defer { plist_free(value) }
        var flag: UInt8 = 0
        plist_get_bool_val(value, &flag)
        return flag != 0
    }

    // MARK: - Helpers

    private func consume(_ err: UnsafeMutablePointer<IdeviceFfiError>, fallback: String) -> String {
        let message = err.pointee.message.flatMap { String(validatingUTF8: $0) } ?? fallback
        let code = err.pointee.code
        idevice_error_free(err)
        return "\(message) [\(code)]"
    }
}

#else

/// Simulator stand-in so the UI can be previewed without a device. It
/// pretends every call succeeds.
final class DeviceLink {
    static let shared = DeviceLink()
    private init() {}

    static var deviceIP: String {
        let stored = UserDefaults.standard.string(forKey: SettingsKey.deviceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false ? stored! : "10.7.0.1")
    }
    static let remotePairingPort: UInt16 = 49152

    func setLocation(latitude: Double, longitude: Double) async throws {
        try await Task.sleep(for: .milliseconds(250))
        // Simulator-only: launch with SIMCTL_CHILD_DRIFT_SIM_CELLULAR=1 to preview the cellular guide.
        if ProcessInfo.processInfo.environment["DRIFT_SIM_CELLULAR"] == "1" { throw DeviceLinkError.cellularBlocked }
    }
    func clearLocation() async throws {}
    func isDeveloperImageMounted() async throws -> Bool { true }
    func mountDeveloperImage(directory: URL, useCryptex: Bool) async throws {}
    func developerModeEnabled() async throws -> Bool? { true }
    func testConnection() async throws {}
    func disconnect() async {}
}

#endif
