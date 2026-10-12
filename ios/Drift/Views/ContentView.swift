//
//  ContentView.swift
//  Drift
//

import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject private var engine: SpoofEngine
    @EnvironmentObject private var library: Library
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var reminders = RenewalReminder.shared

    /// Starts on your real location (falls back to a world view until a fix arrives).
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @StateObject private var locator = LiveLocator()
    @State private var selected: Place?
    @State private var sheet: SheetKind?
    @State private var importError: String?
    @State private var searching = false

    // Route card state
    @State private var routeOpen = false
    @State private var routeStart: Place?
    @State private var routeEnd: Place?
    @State private var routeMode: TravelMode = .walk
    @State private var routePlan: PlannedRoute?
    @State private var routeLoop = false
    @State private var planning = false

    enum SheetKind: Identifiable, Equatable {
        case settings, history, bookmarks, schedule(ScheduledAction?), pickStart, pickEnd
        var id: String {
            switch self {
            case .settings: return "settings"
            case .history: return "history"
            case .bookmarks: return "bookmarks"
            case .schedule: return "schedule"
            case .pickStart: return "pickStart"
            case .pickEnd: return "pickEnd"
            }
        }
    }

    var body: some View {
        ZStack {
            map.ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                if let warning = engine.connectionWarning, !searching, engine.issue == nil {
                    Button { engine.issue = warning } label: {
                        chip("\(warning.code) · \(warning.title) — tap for help", systemImage: "wifi.exclamationmark", tint: .destOrange)
                    }
                    .buttonStyle(.plain)
                }
                if engine.cellularHelp == .connectedTurnAirplaneOff && !searching {
                    chip("Connected. Turn Cellular Data back on", systemImage: "antenna.radiowaves.left.and.right", tint: .liveGreen)
                }
                if let place = engine.resumable, !engine.isActive, !engine.isWorking, !searching {
                    HStack(spacing: 8) {
                        Button { Task { await engine.resume() } } label: {
                            chip("Resume spoof at \(place.name)", systemImage: "arrow.clockwise", tint: .liveGreen)
                        }
                        .buttonStyle(.plain)
                        SmallCircleButton(systemImage: "xmark") { engine.dismissResume() }
                    }
                }
                if SigningInfo.renewalDueSoon && !searching {
                    Button { sheet = .settings } label: {
                        chip("Renew Drift \(SigningInfo.shortCountdown) — plug into your Mac", systemImage: "clock.badge.exclamationmark", tint: .destOrange)
                    }
                    .buttonStyle(.plain)
                }
                if (reminders.status == .off || reminders.status == .notAsked) && !searching {
                    Button { Task { await reminders.turnOn() } } label: {
                        chip("Turn on renewal reminders", systemImage: "bell.badge.fill", tint: .driftAccent)
                    }
                    .buttonStyle(.plain)
                }
                if !PairingFileStore.exists && !searching && sheet == nil {
                    Button { sheet = .settings } label: {
                        chip("Finish setup to start spoofing", systemImage: "exclamationmark.circle.fill", tint: .driftAccent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if !searching {
                    HStack(alignment: .bottom) {
                        Spacer()
                        rightRail
                    }
                    bottomArea
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: bottomKey)
        }
        .sheet(item: $sheet) { kind in
            sheetContent(kind)
        }
        .alert("Pairing file", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .onOpenURL { url in
            // drift:// is LocalDevVPN switching back after connecting.
            guard url.isFileURL else {
                engine.appBecameActive()
                return
            }
            do {
                try PairingFileStore.importFile(from: url)
                sheet = .settings
            } catch {
                importError = error.localizedDescription
            }
        }
        .onAppear {
            if !PairingFileStore.exists { sheet = .settings }
            Task { await reminders.refresh() }
            locator.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await reminders.refresh() }
                engine.appBecameActive()
            }
        }
        .onChange(of: engine.current?.latitude) { _, _ in
            if engine.activeRoute != nil, let c = engine.current {
                withAnimation(.linear(duration: 0.9)) {
                    position = .camera(MapCamera(centerCoordinate: c, distance: 1200, heading: 0, pitch: 45))
                }
            }
        }
        .onChange(of: routeStart) { _, _ in replan() }
        .onChange(of: routeEnd) { _, _ in replan() }
        .onChange(of: routeMode) { _, _ in replan() }
    }

    // MARK: - Map

    private var map: some View {
        MapReader { proxy in
            Map(position: $position) {
                if let route = engine.activeRoute ?? (routeOpen ? routePlan : nil) {
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(Color.driftAccent.opacity(0.35), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(Color(red: 0.62, green: 0.88, blue: 1.0), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                    if engine.activeRoute == nil {
                        Annotation("Start", coordinate: route.start.coordinate, anchor: .center) {
                            EndpointDot(color: .liveGreen)
                        }
                    }
                    Annotation("", coordinate: route.end.coordinate, anchor: .center) {
                        EndpointDot(color: .destOrange)
                    }
                }
                if let selected, !isCurrent(selected), !routeOpen {
                    Annotation("", coordinate: selected.coordinate, anchor: .center) {
                        SelectedRing()
                    }
                }
                if let current = engine.current {
                    Annotation(engine.activeRoute != nil ? "Current" : "", coordinate: current, anchor: .center) {
                        LiveDot()
                    }
                } else {
                    UserAnnotation()
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .all))
            .mapControls {
                MapCompass()
            }
            .onTapGesture { point in
                guard !searching, let coordinate = proxy.convert(point, from: .local) else { return }
                let pin = Place(name: "Dropped pin",
                                subtitle: "",
                                coordinate: coordinate)
                selected = pin
                if routeOpen && engine.activeRoute == nil { routeEnd = pin }
                Task {
                    let place = await PlaceSearch.describe(coordinate)
                    if selected?.latitude == coordinate.latitude {
                        selected = place
                        if routeOpen && routeEnd?.latitude == coordinate.latitude { routeEnd = place }
                    }
                }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            if !searching {
                CircleGlassButton(systemImage: "gearshape.fill", size: 50) { sheet = .settings }
                    .transition(.scale.combined(with: .opacity))
            }
            PlaceSearchField(placeholder: "Search places, addresses", style: .capsule,
                             onFocusChange: { focused in withAnimation(.easeOut(duration: 0.2)) { searching = focused } }) { place in
                select(place)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Right rail

    private var rightRail: some View {
        VStack(spacing: 0) {
            railButton("location") {
                if let c = engine.current {
                    withAnimation { position = .region(region(around: c)) }
                } else {
                    // Not spoofing: jump back to where you really are.
                    withAnimation { position = .userLocation(fallback: .automatic) }
                }
            }
            railDivider
            railButton("point.topleft.down.to.point.bottomright.curvepath", active: routeOpen) { toggleRoute() }
            railDivider
            railButton("clock.arrow.circlepath") { sheet = .history }
            railDivider
            railButton("mappin") { sheet = .bookmarks }
        }
        .frame(width: 54)
        .glass(27)
        .padding(.bottom, 4)
    }

    private func railButton(_ symbol: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.driftAccent)
                .frame(width: 54, height: 54)
                .background(active ? Circle().fill(Color.driftAccent.opacity(0.35)).padding(6) : nil)
        }
        .buttonStyle(PressableStyle())
    }

    private var railDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 30, height: 1)
    }

    // MARK: - Bottom

    /// Changes whenever the bottom layout changes, to drive the spring animation.
    private var bottomKey: String {
        "\(routeOpen)-\(engine.status)-\(selected?.id.uuidString ?? "")-\(searching)"
    }

    @ViewBuilder
    private var bottomArea: some View {
        VStack(spacing: 10) {
            if let deadline = engine.killswitchDeadline, engine.isActive {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                    Text("Auto-stop in")
                    Text(deadline, style: .timer).monospacedDigit()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glass(16)
            }

            if let issue = engine.issue {
                IssueCard(issue: issue) { action in handle(action) }
            } else if let help = engine.cellularHelp, help != .connectedTurnAirplaneOff {
                CellularHelpCard(state: help)
            } else if routeOpen {
                RouteCard(start: $routeStart, end: $routeEnd, mode: $routeMode, loop: $routeLoop,
                          plan: routePlan, planning: planning,
                          pickStart: { sheet = .pickStart }, pickEnd: { sheet = .pickEnd },
                          schedule: { scheduleCurrentRoute() },
                          close: { closeRoute() })
            } else if case .working(let message) = engine.status {
                if let selected { PlaceCard(place: selected, onClose: nil) }
                DimButton(title: message.replacingOccurrences(of: "…", with: ""), loading: true)
            } else if engine.activeRoute != nil {
                liveRouteRow
            } else if let selected, !isCurrent(selected) {
                PlaceCard(place: selected) { self.selected = nil }
                HStack(spacing: 10) {
                    PrimaryButton(title: engine.isActive ? "Move here" : "Spoof") {
                        Task { await engine.teleport(to: selected) }
                    }
                    if engine.isActive {
                        stopSquare
                    }
                }
            } else if engine.isActive {
                spoofingRow
            } else {
                DimButton(title: "Tap the map or search")
            }
        }
    }

    private var spoofingRow: some View {
        HStack(spacing: 10) {
            TintedPill(tint: .liveGreen) {
                HStack(spacing: 14) {
                    Text("Spoofing")
                    if let start = engine.startedAt { ElapsedText(start: start) }
                }
            }
            .layoutPriority(1)
            Button { Task { await engine.stop() } } label: {
                TintedPill(tint: .stopRed) { Text("Stop") }
                    .frame(width: 112)
            }
            .buttonStyle(PressableStyle())
            killswitchMenu
        }
    }

    private var liveRouteRow: some View {
        HStack(spacing: 10) {
            Button { routeOpen = true } label: {
                TintedPill(tint: .liveGreen) {
                    HStack(spacing: 8) {
                        Text(isPaused ? "Paused" : "Route live")
                        Text("·")
                        if let start = engine.routeStartedAt { ElapsedText(start: start) }
                    }
                }
            }
            .buttonStyle(PressableStyle())
            .layoutPriority(1)
            Button { Task { await engine.stop() } } label: {
                TintedPill(tint: .stopRed) { Text("Stop") }
                    .frame(width: 112)
            }
            .buttonStyle(PressableStyle())
            squareButton(isPaused ? "play.fill" : "pause.fill") { engine.togglePause() }
        }
    }

    private var stopSquare: some View {
        Button { Task { await engine.stop() } } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.stopRed)
                .frame(width: 58, height: 58)
                .glass(18, tint: .stopRed)
        }
        .buttonStyle(PressableStyle())
    }

    private var killswitchMenu: some View {
        Menu {
            Section("Auto-stop (killswitch)") {
                Button("In 15 minutes") { armKillswitch(15) }
                Button("In 30 minutes") { armKillswitch(30) }
                Button("In 1 hour") { armKillswitch(60) }
                Button("In 2 hours") { armKillswitch(120) }
                if engine.killswitchDeadline != nil {
                    Button("Turn off", role: .destructive) { engine.disarmKillswitch() }
                }
            }
        } label: {
            Image(systemName: engine.killswitchDeadline == nil ? "timer" : "timer.circle.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 58, height: 58)
                .glass(18)
        }
    }

    private func squareButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 58, height: 58)
                .glass(18)
        }
        .buttonStyle(PressableStyle())
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glass(18, tint: tint)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ kind: SheetKind) -> some View {
        switch kind {
        case .settings:
            SetupView()
        case .history:
            SavedView(kind: .history) { place in sheet = nil; select(place) }
        case .bookmarks:
            SavedView(kind: .bookmarks) { place in sheet = nil; select(place) }
        case .schedule(let action):
            ScheduleView(prefill: action, defaultPlace: selected)
        case .pickStart:
            EndpointPicker(title: "Start", current: currentPlace, selected: selected) { routeStart = $0; sheet = nil }
        case .pickEnd:
            EndpointPicker(title: "Destination", current: currentPlace, selected: selected) { routeEnd = $0; sheet = nil }
        }
    }

    // MARK: - Helpers

    private var isPaused: Bool {
        if case .paused = engine.status { return true }
        return false
    }

    private var currentPlace: Place? {
        if case .holding(let place) = engine.status { return place }
        if let c = engine.current { return Place(name: "Current location", subtitle: "Simulated", coordinate: c) }
        return nil
    }

    private func isCurrent(_ place: Place) -> Bool {
        guard engine.isActive, let c = engine.current else { return false }
        return abs(c.latitude - place.latitude) < 0.00005 && abs(c.longitude - place.longitude) < 0.00005
    }

    private func select(_ place: Place) {
        selected = place
        if routeOpen && engine.activeRoute == nil { routeEnd = place }
        withAnimation { position = .region(region(around: place.coordinate)) }
    }

    private func region(around c: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015))
    }

    private func toggleRoute() {
        if routeOpen { closeRoute(); return }
        if engine.activeRoute == nil {
            routeStart = currentPlace ?? (selected != nil && routeEnd == nil ? nil : routeStart)
            if let selected, routeStart.map({ !$0.isNear(selected) }) ?? true { routeEnd = selected }
        }
        routeOpen = true
    }

    private func closeRoute() {
        routeOpen = false
        if engine.activeRoute == nil { routePlan = nil }
    }

    private func replan() {
        guard routeOpen || routePlan != nil, let start = routeStart, let end = routeEnd, !start.isNear(end, meters: 5) else {
            routePlan = nil
            return
        }
        planning = true
        let mode = routeMode
        Task {
            let plan = await RoutePlanner.plan(from: start, to: end, mode: mode)
            if routeStart == start, routeEnd == end, routeMode == mode {
                routePlan = plan
                planning = false
                fit(plan.coordinates)
            }
        }
    }

    private func fit(_ coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2 - (lats.max()! - lats.min()!) * 0.35,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 2.6, 0.01),
                                    longitudeDelta: max((lons.max()! - lons.min()!) * 1.5, 0.01))
        withAnimation { position = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    private func scheduleCurrentRoute() {
        guard let start = routeStart, let end = routeEnd else { return }
        sheet = .schedule(.route(start: start, end: end, mode: routeMode, kmh: routeMode.savedKmh, loop: routeLoop))
    }

    private func handle(_ action: DriftIssue.Action) {
        switch action {
        case .turnOnVPN:
            engine.issue = nil
            LocalDevVPN.turnOn()
        case .retry:
            Task { await engine.retryLast() }
        case .openDriftSettings:
            engine.issue = nil
            sheet = .settings
        case .openIOSSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    private func armKillswitch(_ minutes: Int) {
        engine.setKillswitch(minutes: minutes)
    }
}

// MARK: - Route card

struct RouteCard: View {
    @EnvironmentObject private var engine: SpoofEngine
    @Binding var start: Place?
    @Binding var end: Place?
    @Binding var mode: TravelMode
    @Binding var loop: Bool
    let plan: PlannedRoute?
    let planning: Bool
    let pickStart: () -> Void
    let pickEnd: () -> Void
    let schedule: () -> Void
    let close: () -> Void

    private var live: PlannedRoute? { engine.activeRoute }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Route").font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Spacer()
                SmallCircleButton(systemImage: "xmark", action: close)
            }

            endpointRow(label: "START", place: live?.start ?? start, color: .liveGreen, action: pickStart)
            endpointRow(label: "DESTINATION", place: live?.end ?? end, color: .destOrange, action: pickEnd)

            HStack(spacing: 10) {
                Menu {
                    Picker("Travel mode", selection: $mode) {
                        ForEach(TravelMode.allCases) { m in
                            Label("\(m.label) · \(Int(m.savedKmh)) km/h", systemImage: m.symbol).tag(m)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: (live?.mode ?? mode).symbol)
                            .foregroundStyle(Color.driftAccent)
                        Text(infoText).foregroundStyle(Color.white.opacity(0.85))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.textTertiary)
                    }
                    .font(.system(size: 15, weight: .medium))
                }
                .disabled(live != nil)
                Spacer()
                Button { loop.toggle() } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(loop ? Color.driftAccent : Color.textTertiary)
                }
                .disabled(live != nil)
                Button(action: schedule) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                .disabled(live != nil || start == nil || end == nil)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.rowBackground))

            if live != nil {
                ProgressView(value: engine.routeProgress).tint(Color.driftAccent)
            }

            Text(plan?.followsRoads == false ? "No road route found, moving in a straight line." : "Road data © Apple Maps")
                .font(.system(size: 11))
                .foregroundStyle(Color.textTertiary)

            actionRow
        }
        .padding(16)
        .glass(26)
    }

    @ViewBuilder
    private var actionRow: some View {
        if live != nil {
            HStack(spacing: 10) {
                TintedPill(tint: .liveGreen) {
                    HStack(spacing: 8) {
                        Text(isPaused ? "Paused" : "Route live")
                        Text("·")
                        if let s = engine.routeStartedAt { ElapsedText(start: s) }
                    }
                }
                .layoutPriority(1)
                Button { Task { await engine.stop() } } label: {
                    TintedPill(tint: .stopRed) { Text("Stop") }
                        .frame(width: 100)
                }
                .buttonStyle(PressableStyle())
                Button { engine.togglePause() } label: {
                    Image(systemName: isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 58, height: 58)
                        .glass(18)
                }
                .buttonStyle(PressableStyle())
            }
        } else if engine.isWorking {
            DimButton(title: "Preparing", loading: true)
        } else if planning {
            DimButton(title: "Finding route", loading: true)
        } else if let plan {
            PrimaryButton(title: "Start route", systemImage: "location.north.line.fill") {
                Task { await engine.startRoute(plan, kmh: plan.mode.savedKmh, loop: loop) }
            }
        } else {
            DimButton(title: end == nil ? "Choose a destination" : "Choose a start", systemImage: "mappin.and.ellipse")
        }
    }

    private var isPaused: Bool {
        if case .paused = engine.status { return true }
        return false
    }

    private var infoText: String {
        let route = live ?? plan
        guard let route else { return (live?.mode ?? mode).label }
        let seconds = route.distance / (route.mode.savedKmh / 3.6)
        return "\(formatDistance(route.distance)) · ETA \(Self.eta(seconds))"
    }

    static func eta(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(minutes, 1))m"
    }

    private func endpointRow(label: String, place: Place?, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(color.opacity(0.35), lineWidth: 4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundStyle(Color.textTertiary)
                    Text(place?.name ?? "Choose…")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(place == nil ? Color.textSecondary : .white)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.rowBackground))
        }
        .buttonStyle(PressableStyle())
        .disabled(live != nil)
    }
}

// MARK: - Place card

struct PlaceCard: View {
    @EnvironmentObject private var library: Library
    let place: Place
    let onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !place.subtitle.isEmpty {
                    Text(place.subtitle)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
                Text(String(format: "%.6f, %.6f", place.latitude, place.longitude))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.textTertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            SmallCircleButton(systemImage: library.isBookmarked(place) ? "bookmark.fill" : "bookmark",
                              filled: library.isBookmarked(place)) {
                library.toggleBookmark(place)
            }
            if let onClose {
                SmallCircleButton(systemImage: "xmark", action: onClose)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(22)
    }
}

// MARK: - Map dots

struct SelectedRing: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.driftAccent, lineWidth: 3.5)
            .background(Circle().fill(Color.white.opacity(0.9)).padding(4))
            .frame(width: 22, height: 22)
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

struct LiveDot: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.liveGreen.opacity(0.3))
                .frame(width: 46, height: 46)
                .scaleEffect(pulse ? 1.1 : 0.55)
                .opacity(pulse ? 0 : 0.9)
            Circle()
                .strokeBorder(Color.liveGreen, lineWidth: 4)
                .background(Circle().fill(Color.white))
                .frame(width: 24, height: 24)
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

struct EndpointDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}

// MARK: - Endpoint picker

struct EndpointPicker: View {
    @EnvironmentObject private var library: Library
    let title: String
    let current: Place?
    let selected: Place?
    let onPick: (Place) -> Void

    var body: some View {
        DarkSheet(title: title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PlaceSearchField(placeholder: "Search places, addresses", style: .field, autofocus: true, onPick: onPick)

                    let quick = [current, selected].compactMap { $0 }
                    if !quick.isEmpty {
                        section("Quick") {
                            ForEach(quick) { place in
                                row(place, symbol: place == current ? "location.fill" : "mappin")
                            }
                        }
                    }
                    if !library.bookmarks.isEmpty {
                        section("Bookmarks") {
                            ForEach(library.bookmarks.prefix(8)) { row($0, symbol: "bookmark.fill") }
                        }
                    }
                    if !library.history.isEmpty {
                        section("Recents") {
                            ForEach(library.history.prefix(8)) { row($0, symbol: "clock.arrow.circlepath") }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).kerning(0.6).foregroundStyle(Color.textTertiary)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.rowBackground))
        }
    }

    private func row(_ place: Place, symbol: String) -> some View {
        Button { onPick(place) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(Color.driftAccent).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).foregroundStyle(.white).lineLimit(1)
                    Text(place.subtitle.isEmpty ? place.coordinateText : place.subtitle)
                        .font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func formatDistance(_ meters: CLLocationDistance) -> String {
    let formatter = MKDistanceFormatter()
    formatter.unitStyle = .abbreviated
    return formatter.string(fromDistance: meters)
}


// MARK: - Cellular help

/// Shown when iOS refuses the connection on cellular data. Flipping Airplane
/// Mode on lets Drift connect; it retries by itself the moment that happens.
struct CellularHelpCard: View {
    @EnvironmentObject private var engine: SpoofEngine
    let state: SpoofEngine.CellularHelp

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.driftAccent)
                Text("One extra step on cellular")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                SmallCircleButton(systemImage: "xmark") { engine.cancelCellularHelp() }
            }
            Text("iOS blocks Drift's connection while you're on cellular data. Switch data off for a few seconds and Drift connects by itself.")
                .font(.system(size: 15))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Swipe down from the top-right corner and turn off Cellular Data (the green antenna), or turn on Airplane Mode")
                step(2, "Wait a few seconds while Drift connects")
                step(3, "Turn Cellular Data back on (or Airplane Mode off). Your spoof keeps running")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.rowBackground))

            HStack(spacing: 10) {
                ProgressView().tint(Color.driftAccent)
                Text(state == .connecting ? "Connecting…" : "Waiting for data to switch off…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                Spacer()
                Button("Try again") { Task { await engine.retryPending() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.driftAccent)
                    .disabled(state == .connecting)
            }
        }
        .padding(18)
        .glass(26)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.driftAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.driftAccent.opacity(0.18)))
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


// MARK: - Issue card

/// Shows exactly what's wrong: code, explanation, the fix, and a one-tap action.
struct IssueCard: View {
    @EnvironmentObject private var engine: SpoofEngine
    let issue: DriftIssue
    let perform: (DriftIssue.Action) -> Void

    private var tint: Color { issue.severity == .warning ? .destOrange : .stopRed }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.severity == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Error \(issue.code)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(tint)
                }
                Spacer()
                SmallCircleButton(systemImage: "xmark") { engine.issue = nil }
            }

            Text(issue.message)
                .font(.system(size: 15))
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(issue.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.driftAccent)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.driftAccent.opacity(0.18)))
                        Text(step)
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.rowBackground))

            if let action = issue.action, let title = issue.actionTitle {
                PrimaryButton(title: title, systemImage: icon(for: action)) { perform(action) }
            }

            if let detail = issue.detail, !detail.isEmpty {
                Text("Details: \(detail)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .glass(26, tint: nil)
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }

    private func icon(for action: DriftIssue.Action) -> String {
        switch action {
        case .turnOnVPN: return "network.badge.shield.half.filled"
        case .retry: return "arrow.clockwise"
        case .openDriftSettings: return "gearshape.fill"
        case .openIOSSettings: return "gear"
        }
    }
}

// MARK: - Live location

/// Asks for location so the map can open on where you really are.
@MainActor
final class LiveLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}
