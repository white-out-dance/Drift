//
//  PairingFileStore.swift
//  Drift
//
//  The pairing file lives in Documents so the Mac setup tool can drop it in
//  over USB (file sharing), and so it shows up in the Files app.
//

import Foundation
import UniformTypeIdentifiers

enum PairingFileStore {
    static let fileName = "pairingFile.plist"

    static let contentTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) ?? .data,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data) ?? .data,
        .propertyList,
        .xml,
        .data,
    ]

    static var url: URL {
        URL.documentsDirectory.appendingPathComponent(fileName)
    }

    static var existingURL: URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var exists: Bool { existingURL != nil }

    /// Copies a picked or AirDropped file in, after checking it looks like a
    /// RemotePairing record (public_key / private_key / identifier).
    static func importFile(from source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: source)
        try validate(data)

        let fm = FileManager.default
        try fm.createDirectory(at: URL.documentsDirectory, withIntermediateDirectories: true)
        let temp = URL.documentsDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: temp, options: .atomic)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: url)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    static func validate(_ data: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else {
            throw PairingFileError.notAPlist
        }
        if dict["HostPrivateKey"] != nil || dict["DeviceCertificate"] != nil {
            throw PairingFileError.lockdownRecord
        }
        guard let pub = dict["public_key"] as? Data, pub.count == 32,
              let priv = dict["private_key"] as? Data, priv.count == 32,
              let ident = dict["identifier"] as? String, !ident.isEmpty else {
            throw PairingFileError.missingKeys
        }
    }

    static var summary: String? {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let ident = dict["identifier"] as? String else { return nil }
        return ident
    }
}

enum PairingFileError: LocalizedError {
    case notAPlist
    case lockdownRecord
    case missingKeys

    var errorDescription: String? {
        switch self {
        case .notAPlist:
            return "That file isn't a pairing file."
        case .lockdownRecord:
            return "That's an older-style lockdown pairing record. Use the file made by the Drift Mac setup tool (Drift-pairing.plist)."
        case .missingKeys:
            return "That pairing file is missing its keys. Make a new one with the Drift Mac setup tool."
        }
    }
}
