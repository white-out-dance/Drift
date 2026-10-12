//
//  KeepAlive.swift
//  Drift
//
//  iOS suspends background apps, which would drop the connection holding the
//  simulated location. Silent audio (and optionally background location)
//  keeps Drift running while a spoof, route or schedule is active.
//  Approach adapted from StikDebug (AGPL-3.0).
//

import AVFoundation
import CoreLocation

final class KeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var audioRunning = false
    private var healthTimer: Timer?
    private let locationManager = CLLocationManager()
    private var locationRunning = false
    private(set) var isActive = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.pausesLocationUpdatesAutomatically = false

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleReset),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    var useLocation: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.keepAliveLocation) as? Bool ?? true
    }

    func start() {
        isActive = true
        startAudio()
        if useLocation { startLocation() }
    }

    func stop() {
        isActive = false
        stopAudio()
        stopLocation()
    }

    func requestLocationPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if locationManager.authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    var locationAuthorization: CLAuthorizationStatus { locationManager.authorizationStatus }

    // MARK: Audio

    private func startAudio() {
        guard !audioRunning else { recoverAudio(); return }
        audioRunning = true
        do {
            engine.stop()
            player.stop()
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            engine.attach(player)
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) {
                buffer.frameLength = buffer.frameCapacity // zeroed = silence
                player.scheduleBuffer(buffer, at: nil, options: .loops)
            }
            try engine.start()
            player.play()
        } catch {
            NSLog("Drift KeepAlive audio: \(error.localizedDescription)")
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.recoverAudio() }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func stopAudio() {
        guard audioRunning else { return }
        audioRunning = false
        healthTimer?.invalidate()
        healthTimer = nil
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func recoverAudio() {
        guard audioRunning, !engine.isRunning || !player.isPlaying else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !engine.isRunning { try? engine.start() }
        player.play()
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard audioRunning,
              let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        recoverAudio()
    }

    @objc private func handleReset() {
        guard audioRunning else { return }
        audioRunning = false
        startAudio()
    }

    // MARK: Location

    private func startLocation() {
        guard !locationRunning else { return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationRunning = true
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = false
            locationManager.startUpdatingLocation()
        case .notDetermined:
            locationManager.requestAlwaysAuthorization()
        default:
            break // audio alone still keeps us alive
        }
    }

    private func stopLocation() {
        guard locationRunning else { return }
        locationRunning = false
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if isActive, useLocation { startLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
