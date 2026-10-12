//
//  DriftApp.swift
//  Drift
//

import SwiftUI

@main
struct DriftApp: App {
    @StateObject private var library: Library
    @StateObject private var engine: SpoofEngine

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.keepAliveLocation: true,
            SettingsKey.jitter: false,
            SettingsKey.killswitchMinutes: 0,
        ])
        let library = Library()
        _library = StateObject(wrappedValue: library)
        _engine = StateObject(wrappedValue: SpoofEngine(library: library))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(engine)
                .tint(.driftAccent)
                .preferredColorScheme(.dark)
        }
    }
}
