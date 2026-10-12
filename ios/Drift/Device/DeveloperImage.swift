//
//  DeveloperImage.swift
//  Drift
//
//  Downloads Apple's developer disk image (mirrored by doronz88/DeveloperDiskImage)
//  and mounts it on this iPhone. iOS unmounts it on every reboot, so Drift
//  re-mounts automatically before spoofing. File list adapted from StikDebug.
//

import Foundation

enum DeveloperImage {
    static let directory = URL.applicationSupportDirectory.appendingPathComponent("DDI", isDirectory: true)

    static var usesCryptex: Bool {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion > 26 || (v.majorVersion == 26 && v.minorVersion >= 4)
    }

    private static var methodMarker: URL { directory.appendingPathComponent("MountMethod") }
    private static var method: String { usesCryptex ? "cryptex" : "personalized" }

    private static let base = "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/"

    private static var files: [String] {
        let common = ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
        return usesCryptex ? common + ["Image.dmg.cryptex_info", "Image.dmg.root_hash"] : common
    }

    private static var folder: String {
        usesCryptex ? "Xcode_iOS_DDI_Cryptex/" : "Xcode_iOS_DDI_Personalized/"
    }

    static var filesReady: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
            && (try? String(contentsOf: methodMarker, encoding: .utf8)) == method
    }

    static func downloadIfNeeded(progress: @escaping @Sendable (String) -> Void) async throws {
        if filesReady { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: methodMarker)

        for (index, name) in files.enumerated() {
            progress("Downloading developer image \(index + 1)/\(files.count)…")
            guard let url = URL(string: base + folder + name) else { continue }
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DeviceLinkError.ddi("download failed for \(name)")
            }
            let destination = directory.appendingPathComponent(name)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: temp, to: destination)
        }
        try method.write(to: methodMarker, atomically: true, encoding: .utf8)
    }

    /// Mounts if needed. Returns true if a mount was performed.
    @discardableResult
    static func ensureMounted(progress: @escaping @Sendable (String) -> Void) async throws -> Bool {
        progress("Checking developer image…")
        if try await DeviceLink.shared.isDeveloperImageMounted() { return false }
        try await downloadIfNeeded(progress: progress)
        progress("Mounting developer image…")
        try await DeviceLink.shared.mountDeveloperImage(directory: directory, useCryptex: usesCryptex)
        // The tunnel is reused, but services appear after mount; reconnect fresh.
        await DeviceLink.shared.disconnect()
        return true
    }
}
