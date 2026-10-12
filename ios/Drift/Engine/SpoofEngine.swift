//
//  SpoofEngine.swift
//  Drift
//

import Foundation
import CoreLocation
import UserNotifications
import UIKit

@MainActor
final class SpoofEngine: ObservableObject {
    enum Status: Equatable {
        case idle
        case working(String)
        case holding(Place)
        case moving(PlannedRoute)
        case paused(PlannedRoute)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var current: CLLocationCoordinate2D?
    @Published private(set) var routeProgress: Double = 0
    @Published private(set) var routeRemaining: TimeInterval = 0
    @Published private(set) var killswitchDeadline: Date?
    /// Set while a running spoof has lost its connection (Drift keeps retrying).
    @Published private(set) var connectionWarning: DriftIssue?
    /// When the current spoof session began (drives the "Spoofing 00:08" timer).
    @Published private(set) var startedAt: Date?
    /// When the current route began (drives "Route live 00:02").
    @Published private(set) var routeStartedAt: Date?
    /// The problem to show the user, with its code, fix and action.
    @Published var issue: DriftIssue?

    /// Guided Airplane Mode flow for when iOS blocks the connection on cellular.
    enum CellularHelp: Equatable { case waitingForAirplane, connecting, connectedTurnAirplaneOff }
    @Published private(set) var cellularHelp: CellularHelp?
    /// A spoof that was running when Drift was last closed, offered for resuming.
    @Published private(set) var resumable: Place?

    let library: Library

    private enum PendingAction {
        case teleport(Place)
        case route(PlannedRoute, Double, Bool)
    }
    private var pendingAction: PendingAction?
    /// The last spoof the user asked for, for "Try again".
    private var lastAttempt: PendingAction?
    private var networkObserver: NSObjectProtocol?
    private var cellularRetryTask: Task<Void, Never>?
    private static let heldKey = "driftHeldPlace"

    private var resendTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var ticker: Timer?
    private var ddiReady = false
    private var routePaused = false
    private var busy = false

    init(library: Library) {
        self.library = library
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        refreshKeepAlive()

        NetworkWatcher.shared.start()
        networkObserver = NotificationCenter.default.addObserver(
            forName: .driftNetworkChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        if let data = UserDefaults.standard.data(forKey: Self.heldKey),
           let place = try? JSONDecoder().decode(Place.self, from: data) {
            resumable = place
        }
        DriftIntentBridge.stopHandler = { [weak self] in await self?.stop() }
        LiveActivityController.shared.endLeftovers()
    }

    var isActive: Bool {
        switch status {
        case .holding, .moving, .paused: return true
        default: return false
        }
    }

    var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    var activeRoute: PlannedRoute? {
        switch status {
        case .moving(let r), .paused(let r): return r
        default: return nil
        }
    }

    // MARK: - Public actions

    func teleport(to place: Place) async {
        guard !busy else { return }
        lastAttempt = .teleport(place)
        busy = true
        defer { busy = false }
        cancelRoute()
        resendTask?.cancel()

        let previous = status
        status = .working("Connecting…")
        do {
            try await send(place.coordinate, allowMount: true)
            current = place.coordinate
            status = .holding(place)
            routeStartedAt = nil
            if !isActiveStatus(previous) || startedAt == nil { startedAt = Date() }
            library.record(place)
            armKillswitchIfNeeded(wasActive: isActiveStatus(previous))
            startHolding(at: place.coordinate)
            refreshKeepAlive()
            remember(place)
            connected()
            syncLiveActivity(force: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch DeviceLinkError.cellularBlocked {
            status = isActiveStatus(previous) ? previous : .idle
            if isActiveStatus(previous), let coordinate = current { startHolding(at: coordinate) }
            needAirplane(for: .teleport(place))
        } catch DeviceLinkError.vpnOff {
            status = isActiveStatus(previous) ? previous : .idle
            if isActiveStatus(previous), let coordinate = current { startHolding(at: coordinate) }
            cellularHelp = nil
            pendingAction = .teleport(place)
            report(DeviceLinkError.vpnOff)
        } catch {
            status = isActiveStatus(previous) ? previous : .idle
            if isActiveStatus(previous), let coordinate = current { startHolding(at: coordinate) }
            cellularHelp = nil
            pendingAction = nil
            report(error)
        }
    }

    /// Re-applies the spoof that was running when Drift last closed.
    func resume() async {
        guard let place = resumable else { return }
        await teleport(to: place)
    }

    func dismissResume() {
        resumable = nil
        UserDefaults.standard.removeObject(forKey: Self.heldKey)
    }

    func cancelCellularHelp() {
        cellularHelp = nil
        pendingAction = nil
        cellularRetryTask?.cancel()
    }

    /// Drift came back to the foreground (e.g. LocalDevVPN switched back after
    /// connecting): finish whatever was waiting.
    func appBecameActive() {
        if pendingAction != nil, cellularHelp == nil, NetworkStatus.loopbackVPNUp {
            Task { await retryPending() }
        }
    }

    /// "Try again" from the Airplane Mode card.
    func retryPending() async {
        guard let pending = pendingAction, !busy else { return }
        if cellularHelp != nil { cellularHelp = .connecting }
        switch pending {
        case .teleport(let place): await teleport(to: place)
        case .route(let route, let kmh, let loop): await startRoute(route, kmh: kmh, loop: loop)
        }
    }

    func startRoute(_ route: PlannedRoute, kmh: Double, loop: Bool) async {
        guard !busy, let first = route.coordinates.first else { return }
        lastAttempt = .route(route, kmh, loop)
        busy = true
        defer { busy = false }
        cancelRoute()
        resendTask?.cancel()

        let previous = status
        status = .working("Connecting…")
        do {
            try await send(first, allowMount: true)
            current = first
            library.record(route.start)
            armKillswitchIfNeeded(wasActive: isActiveStatus(previous))
            routePaused = false
            status = .moving(route)
            routeStartedAt = Date()
            if !isActiveStatus(previous) || startedAt == nil { startedAt = Date() }
            refreshKeepAlive()
            playRoute(route, metersPerSecond: kmh / 3.6, loop: loop)
            connected()
            syncLiveActivity(force: true)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch DeviceLinkError.cellularBlocked {
            status = .idle
            needAirplane(for: .route(route, kmh, loop))
        } catch DeviceLinkError.vpnOff {
            status = .idle
            cellularHelp = nil
            pendingAction = .route(route, kmh, loop)
            report(DeviceLinkError.vpnOff)
        } catch {
            status = .idle
            cellularHelp = nil
            pendingAction = nil
            report(error)
        }
    }

    func togglePause() {
        switch status {
        case .moving(let route):
            routePaused = true
            status = .paused(route)
            if let current { startHolding(at: current) }
        case .paused(let route):
            resendTask?.cancel()
            routePaused = false
            status = .moving(route)
        default:
            break
        }
        syncLiveActivity(force: true)
    }

    func stop() async {
        cancelRoute()
        resendTask?.cancel()
        resendTask = nil
        killswitchDeadline = nil
        connectionWarning = nil
        status = .working("Restoring real location…")
        do {
            try await DeviceLink.shared.clearLocation()
        } catch {
            issue = .stopFailed(error.localizedDescription)
        }
        status = .idle
        current = nil
        startedAt = nil
        routeStartedAt = nil
        cellularHelp = nil
        pendingAction = nil
        cellularRetryTask?.cancel()
        dismissResume()
        LiveActivityController.shared.end()
        refreshKeepAlive()
    }

    // MARK: - Scheduling

    func schedule(_ job: ScheduledJob) {
        library.jobs.append(job)
        library.jobs.sort { $0.fireDate < $1.fireDate }
        requestNotificationPermission()
        let content = UNMutableNotificationContent()
        content.title = "Drift"
        content.body = "Scheduled: \(job.action.title). Keep Drift open in the background."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, job.fireDate.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: trigger))
        refreshKeepAlive()
    }

    func cancel(_ job: ScheduledJob) {
        library.jobs.removeAll { $0.id == job.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [job.id.uuidString])
        refreshKeepAlive()
    }

    private func run(_ job: ScheduledJob) async {
        switch job.action {
        case .teleport(let place):
            await teleport(to: place)
        case .route(let start, let end, let mode, let kmh, let loop):
            let route = await RoutePlanner.plan(from: start, to: end, mode: mode)
            await startRoute(route, kmh: kmh, loop: loop)
        }
    }

    // MARK: - Internals

    private func isActiveStatus(_ s: Status) -> Bool {
        switch s {
        case .holding, .moving, .paused: return true
        default: return false
        }
    }

    private func send(_ coordinate: CLLocationCoordinate2D, allowMount: Bool) async throws {
        if allowMount && !ddiReady {
            do {
                try await DeveloperImage.ensureMounted { message in
                    Task { @MainActor [weak self] in self?.status = .working(message) }
                }
            } catch DeviceLinkError.cellularBlocked {
                throw DeviceLinkError.cellularBlocked
            } catch DeviceLinkError.vpnOff {
                throw DeviceLinkError.vpnOff
            } catch let error where NetworkStatus.offline {
                _ = error
                throw DeviceLinkError.ddi("after an iPhone restart Drift needs internet once to set up. Join Wi-Fi (you can leave Airplane Mode on and just turn Wi-Fi on), then tap Spoof again.")
            }
            ddiReady = true
            status = .working("Setting location…")
        }
        do {
            try await DeviceLink.shared.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        } catch DeviceLinkError.developerServices where allowMount {
            // Probably rebooted since we last mounted. Mount and retry once.
            ddiReady = false
            try await DeveloperImage.ensureMounted { message in
                Task { @MainActor [weak self] in self?.status = .working(message) }
            }
            ddiReady = true
            try await DeviceLink.shared.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
    }

    /// Re-sends the held position every few seconds so the simulation never lapses.
    private func startHolding(at coordinate: CLLocationCoordinate2D) {
        resendTask?.cancel()
        resendTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, let self else { return }
                let point = self.jittered(coordinate)
                do {
                    try await DeviceLink.shared.setLocation(latitude: point.latitude, longitude: point.longitude)
                    if failures > 0 { self.connectionWarning = nil }
                    failures = 0
                } catch {
                    failures += 1
                    if failures >= 2 {
                        self.connectionWarning = SpoofEngine.dropIssue()
                    }
                }
            }
        }
    }

    /// Mirrors the current spoof onto the Lock Screen / Dynamic Island.
    private func syncLiveActivity(force: Bool = false) {
        let start = startedAt ?? Date()
        switch status {
        case .holding(let place):
            LiveActivityController.shared.show(.init(
                kind: .holding, paused: false,
                placeName: place.name,
                detail: place.subtitle.isEmpty ? place.coordinateText : place.subtitle,
                startedAt: start, progress: 0, arrival: nil), force: force)
        case .moving(let route), .paused(let route):
            var paused = false
            if case .paused = status { paused = true }
            let kind: DriftActivityAttributes.ContentState.Kind
            switch route.mode {
            case .walk: kind = .walk
            case .bike: kind = .bike
            case .drive: kind = .drive
            }
            LiveActivityController.shared.show(.init(
                kind: kind, paused: paused,
                placeName: route.end.name,
                detail: "From \(route.start.name)",
                startedAt: start, progress: routeProgress,
                arrival: paused ? nil : Date().addingTimeInterval(routeRemaining)), force: force)
        default:
            break
        }
    }

    private func needAirplane(for action: PendingAction) {
        let firstTime = cellularHelp == nil
        pendingAction = action
        cellularHelp = .waitingForAirplane
        if firstTime { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        guard cellularRetryTask == nil || cellularRetryTask!.isCancelled else { return }
        // Keep trying every few seconds: the moment Cellular Data or Airplane
        // Mode flips, the connection is allowed and the spoof goes through.
        cellularRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.cellularHelp == .waitingForAirplane, self.pendingAction != nil else { break }
                await self.retryPending()
            }
            self?.cellularRetryTask = nil
        }
    }

    private func connected() {
        pendingAction = nil
        resumable = nil
        issue = nil
        cellularRetryTask?.cancel()
        if cellularHelp != nil {
            cellularHelp = NetworkStatus.offline ? .connectedTurnAirplaneOff : nil
        }
    }

    private func remember(_ place: Place) {
        if let data = try? JSONEncoder().encode(place) {
            UserDefaults.standard.set(data, forKey: Self.heldKey)
        }
    }

    /// Wi-Fi / cellular / hotspot / Airplane Mode changed.
    private func networkChanged() {
        if cellularHelp == .connectedTurnAirplaneOff && !NetworkStatus.offline {
            cellularHelp = nil
        }
        // Waiting for the Airplane Mode trick (or Wi-Fi): try the spoof again now.
        if cellularHelp == .waitingForAirplane, pendingAction != nil {
            Task { await retryPending() }
            return
        }
        // A spoof is running: push the position straight away so a dropped
        // connection rebuilds on the new network instead of waiting for the next tick.
        if isActive, let point = current, !busy {
            Task {
                do {
                    try await DeviceLink.shared.setLocation(latitude: point.latitude, longitude: point.longitude)
                    connectionWarning = nil
                } catch {
                    connectionWarning = SpoofEngine.dropIssue()
                }
            }
        }
    }

    nonisolated static func dropIssue() -> DriftIssue {
        if !NetworkStatus.loopbackVPNUp { return .connectionDropped(.vpnOff) }
        if !NetworkStatus.wifiConnected && NetworkStatus.cellularUp { return .connectionDropped(.cellularBlocked) }
        return .connectionDropped(.notAnswering())
    }

    /// "Try again" on an issue card: repeat the last spoof the user asked for.
    func retryLast() async {
        issue = nil
        if pendingAction != nil { await retryPending(); return }
        guard let attempt = lastAttempt else { return }
        switch attempt {
        case .teleport(let place): await teleport(to: place)
        case .route(let route, let kmh, let loop): await startRoute(route, kmh: kmh, loop: loop)
        }
    }

    private func jittered(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard UserDefaults.standard.bool(forKey: SettingsKey.jitter) else { return c }
        let meters = Double.random(in: 0...3)
        let bearing = Double.random(in: 0..<(2 * .pi))
        let dLat = meters * cos(bearing) / 111_320
        let dLon = meters * sin(bearing) / (111_320 * max(cos(c.latitude * .pi / 180), 0.01))
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    private func playRoute(_ route: PlannedRoute, metersPerSecond: Double, loop: Bool) {
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            var path = route.coordinates
            repeat {
                let samples = RoutePlanner.samples(along: path, metersPerSecond: metersPerSecond)
                var index = 1
                var failures = 0
                while index < samples.count {
                    guard let self, !Task.isCancelled else { return }
                    if self.routePaused {
                        try? await Task.sleep(for: .milliseconds(500))
                        continue
                    }
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, !self.routePaused else { continue }
                    let point = samples[index]
                    do {
                        try await DeviceLink.shared.setLocation(latitude: point.latitude, longitude: point.longitude)
                        failures = 0
                        self.connectionWarning = nil
                        self.current = point
                        self.routeProgress = Double(index) / Double(max(samples.count - 1, 1))
                        self.routeRemaining = Double(samples.count - 1 - index)
                        self.syncLiveActivity()
                        index += 1
                    } catch {
                        failures += 1
                        if failures >= 2 {
                            self.connectionWarning = SpoofEngine.dropIssue()
                        }
                    }
                }
                path.reverse()
            } while loop && !Task.isCancelled

            guard let self, !Task.isCancelled else { return }
            let arrived = route.end
            self.routeStartedAt = nil
            self.status = .holding(arrived)
            self.current = arrived.coordinate
            self.library.record(arrived)
            self.remember(arrived)
            self.startHolding(at: arrived.coordinate)
            self.syncLiveActivity(force: true)
        }
    }

    private func cancelRoute() {
        routeTask?.cancel()
        routeTask = nil
        routePaused = false
        routeProgress = 0
        routeRemaining = 0
    }

    private func armKillswitchIfNeeded(wasActive: Bool) {
        let minutes = UserDefaults.standard.integer(forKey: SettingsKey.killswitchMinutes)
        guard minutes > 0 else { killswitchDeadline = nil; return }
        if !wasActive || killswitchDeadline == nil {
            killswitchDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
            requestNotificationPermission()
        }
    }

    func extendKillswitch(minutes: Int) {
        guard let deadline = killswitchDeadline else { return }
        killswitchDeadline = deadline.addingTimeInterval(TimeInterval(minutes * 60))
    }

    func disarmKillswitch() {
        killswitchDeadline = nil
    }

    /// Sets the auto-stop for the current session only.
    func setKillswitch(minutes: Int) {
        guard minutes > 0 else { killswitchDeadline = nil; return }
        killswitchDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        requestNotificationPermission()
    }

    private func tick() {
        if let deadline = killswitchDeadline, Date() >= deadline, isActive {
            killswitchDeadline = nil
            notify("Killswitch: spoofing stopped and your real location is back.")
            Task { await stop() }
            return
        }
        if let due = library.jobs.first(where: { $0.fireDate <= Date() }), !busy {
            library.jobs.removeAll { $0.id == due.id }
            notify("Starting scheduled: \(due.action.title)")
            Task { await run(due) }
        }
    }

    private func refreshKeepAlive() {
        let needed = isActive || isWorking || !library.jobs.isEmpty
        if needed && !KeepAlive.shared.isActive {
            KeepAlive.shared.start()
        } else if !needed && KeepAlive.shared.isActive {
            KeepAlive.shared.stop()
        }
    }

    private func report(_ error: Error) {
        issue = DriftIssue.from(error)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Drift"
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
