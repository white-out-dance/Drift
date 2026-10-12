//
//  SetupView.swift
//  Drift
//

import SwiftUI
import CoreLocation

@MainActor
final class SetupChecks: ObservableObject {
    enum State: Equatable {
        case unknown, checking, ok(String), problem(String)
    }

    @Published var pairing: State = .unknown
    @Published var connection: State = .unknown
    @Published var developerMode: State = .unknown
    @Published var image: State = .unknown
    @Published var running = false

    func refreshPairing() {
        if PairingFileStore.exists {
            pairing = .ok("Imported")
        } else {
            pairing = .problem("Not imported yet")
        }
    }

    func runAll() async {
        running = true
        defer { running = false }
        refreshPairing()
        guard PairingFileStore.exists else {
            connection = .problem("D01 · Import the pairing file first")
            return
        }

        connection = .checking
        do {
            try await DeviceLink.shared.testConnection()
            connection = .ok("Connected to this iPhone")
        } catch {
            let issue = DriftIssue.from(error)
            connection = .problem("\(issue.code) · \(issue.title). \(issue.steps.first ?? "")")
            developerMode = .unknown
            image = .unknown
            return
        }

        developerMode = .checking
        if let enabled = try? await DeviceLink.shared.developerModeEnabled() {
            developerMode = enabled ? .ok("On") : .problem("D12 · Off. Settings › Privacy & Security › Developer Mode")
        } else {
            developerMode = .ok("Couldn't read (usually fine)")
        }

        image = .checking
        do {
            let mounted = try await DeviceLink.shared.isDeveloperImageMounted()
            image = mounted ? .ok("Mounted") : .problem("Not mounted yet. Drift mounts it automatically when you spoof")
        } catch {
            let issue = DriftIssue.from(error)
            image = .problem("\(issue.code) · \(issue.title)")
        }
    }

    func mountNow() async {
        image = .checking
        do {
            let didMount = try await DeveloperImage.ensureMounted { message in
                Task { @MainActor [weak self] in self?.image = .ok(message) }
            }
            image = .ok(didMount ? "Mounted just now" : "Already mounted")
        } catch {
            let issue = DriftIssue.from(error)
            image = .problem("\(issue.code) · \(issue.title). \(issue.steps.first ?? "")")
        }
    }
}

struct SetupView: View {
    @StateObject private var checks = SetupChecks()
    @EnvironmentObject private var library: Library
    @ObservedObject private var reminders = RenewalReminder.shared
    @State private var importing = false
    @State private var message: String?
    @State private var showSchedule = false

    @AppStorage(SettingsKey.killswitchMinutes) private var killswitch = 0
    @AppStorage(SettingsKey.jitter) private var jitter = false
    @AppStorage(SettingsKey.keepAliveLocation) private var keepAliveLocation = true
    @AppStorage(SettingsKey.deviceIP) private var deviceIP = "10.7.0.1"
    @AppStorage(SettingsKey.walkKmh) private var walkKmh = 5.0
    @AppStorage(SettingsKey.bikeKmh) private var bikeKmh = 16.0
    @AppStorage(SettingsKey.driveKmh) private var driveKmh = 50.0

    var body: some View {
        DarkSheet(title: "Settings") {
            Form {
                Section {
                    statusRow("Pairing file", symbol: "key.fill", state: checks.pairing)
                    statusRow("Connection", symbol: "antenna.radiowaves.left.and.right", state: checks.connection)
                    statusRow("Developer Mode", symbol: "hammer.fill", state: checks.developerMode)
                    statusRow("Developer image", symbol: "externaldrive.fill", state: checks.image)
                    Button {
                        Task { await checks.runAll() }
                    } label: {
                        HStack {
                            Text("Check connection")
                            Spacer()
                            if checks.running { ProgressView() }
                        }
                    }
                    .disabled(checks.running)
                } header: {
                    Text("Status")
                } footer: {
                    Text("Turn on LocalDevVPN before spoofing. It's a loopback tunnel to this iPhone's own developer services and carries no internet traffic.")
                }
                .listRowBackground(Color.rowBackground)

                Section {
                    Button(PairingFileStore.exists ? "Replace pairing file" : "Import pairing file") { importing = true }
                    Button("Mount developer image now") { Task { await checks.mountNow() } }
                        .disabled(checks.running || !PairingFileStore.exists)
                    Button {
                        LocalDevVPN.turnOn()
                    } label: {
                        HStack {
                            Text(LocalDevVPN.isInstalled ? "Turn on LocalDevVPN" : "Get LocalDevVPN")
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption)
                        }
                    }
                } header: {
                    Text("Connection setup")
                } footer: {
                    Text("The pairing file comes from Drift for Mac (Setup › Make pairing file). It's copied in over USB automatically, or AirDrop Drift-pairing.plist and open it with Drift.")
                }
                .listRowBackground(Color.rowBackground)

                Section {
                    Picker("Killswitch", selection: $killswitch) {
                        Text("Off").tag(0)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                        Text("2 hours").tag(120)
                        Text("4 hours").tag(240)
                        Text("8 hours").tag(480)
                    }
                    Button {
                        showSchedule = true
                    } label: {
                        HStack {
                            Text("Scheduling").foregroundStyle(.white)
                            Spacer()
                            Text(library.jobs.isEmpty ? "None" : "\(library.jobs.count) pending")
                                .foregroundStyle(Color.textSecondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textTertiary)
                        }
                    }
                    Toggle("Natural GPS jitter", isOn: $jitter)
                    Toggle("Keep alive with location", isOn: $keepAliveLocation)
                    if keepAliveLocation {
                        Button(locationButtonTitle) { KeepAlive.shared.requestLocationPermission() }
                    }
                } header: {
                    Text("Spoofing")
                } footer: {
                    Text("Killswitch stops spoofing automatically after that long. Jitter adds a few metres of wobble so a held spot looks like a real phone.")
                }
                .listRowBackground(Color.rowBackground)

                Section("Route speeds") {
                    speedStepper("Walk", symbol: "figure.walk", value: $walkKmh, range: 2...9)
                    speedStepper("Bike", symbol: "bicycle", value: $bikeKmh, range: 6...40)
                    speedStepper("Drive", symbol: "car.fill", value: $driveKmh, range: 15...140)
                }
                .listRowBackground(Color.rowBackground)

                Section {
                    LabeledContent("Device IP") {
                        TextField("10.7.0.1", text: $deviceIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    if PairingFileStore.exists {
                        Button("Remove pairing file", role: .destructive) {
                            PairingFileStore.remove()
                            checks.refreshPairing()
                        }
                    }
                } header: {
                    Text("Advanced")
                }
                .listRowBackground(Color.rowBackground)

                Section {
                    if let expiry = SigningInfo.expirationDate {
                        LabeledContent("Works until") {
                            Text(expiry.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                                .foregroundStyle(SigningInfo.renewalDueSoon ? Color.destOrange : Color.textSecondary)
                        }
                        LabeledContent("Renew") {
                            Text(SigningInfo.shortCountdown)
                                .foregroundStyle(SigningInfo.renewalDueSoon ? Color.destOrange : Color.textSecondary)
                        }
                    }
                    LabeledContent("Reminders") {
                        switch reminders.status {
                        case .on: Text("On").foregroundStyle(Color.liveGreen)
                        case .off: Text("Off").foregroundStyle(Color.destOrange)
                        case .notAsked, .unknown: Text("Not set up").foregroundStyle(Color.destOrange)
                        }
                    }
                    if let next = reminders.nextReminder {
                        LabeledContent("Next reminder") {
                            Text(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    if reminders.status == .on {
                        Button("Send test reminder") { Task { await reminders.sendTest() } }
                    } else {
                        Button(reminders.status == .off ? "Turn on reminders in iOS Settings" : "Turn on reminders") {
                            Task { await reminders.turnOn() }
                        }
                    }
                } header: {
                    Text("Keeping Drift installed")
                } footer: {
                    Text("Free Apple IDs sign apps for 7 days. You'll get a reminder 2 days, 1 day and 3 hours before. To renew, plug the iPhone into your Mac and double-click “Renew Drift” in the Drift folder. It takes about a minute and keeps all your places and settings.")
                }
                .listRowBackground(Color.rowBackground)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: PairingFileStore.contentTypes) { result in
                switch result {
                case .success(let url):
                    do {
                        try PairingFileStore.importFile(from: url)
                        checks.refreshPairing()
                        Task { await checks.runAll() }
                    } catch {
                        message = error.localizedDescription
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
            .alert("Pairing file", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(isPresented: $showSchedule) {
                ScheduleView(prefill: nil, defaultPlace: nil)
            }
            .onAppear {
                checks.refreshPairing()
                if PairingFileStore.exists { Task { await checks.runAll() } }
                Task { await reminders.refresh() }
            }
        }
    }

    private var locationButtonTitle: String {
        switch KeepAlive.shared.locationAuthorization {
        case .authorizedAlways: return "Location: Always ✓"
        case .authorizedWhenInUse: return "Allow location “Always”"
        case .denied, .restricted: return "Location denied (audio keep-alive still works)"
        default: return "Allow location access"
        }
    }

    private func speedStepper(_ title: String, symbol: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        Stepper(value: value, in: range, step: 1) {
            HStack {
                Image(systemName: symbol).foregroundStyle(Color.driftAccent).frame(width: 24)
                Text(title)
                Spacer()
                Text("\(Int(value.wrappedValue)) km/h").monospacedDigit().foregroundStyle(Color.textSecondary)
            }
        }
    }

    private func statusRow(_ title: String, symbol: String, state: SetupChecks.State) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.driftAccent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.white)
                switch state {
                case .unknown:
                    Text("Not checked").font(.caption).foregroundStyle(Color.textSecondary)
                case .checking:
                    Text("Checking…").font(.caption).foregroundStyle(Color.textSecondary)
                case .ok(let detail):
                    Text(detail).font(.caption).foregroundStyle(Color.liveGreen)
                case .problem(let detail):
                    Text(detail).font(.caption).foregroundStyle(Color.destOrange)
                }
            }
            Spacer()
            switch state {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.liveGreen)
            case .problem: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.destOrange)
            case .checking: ProgressView()
            case .unknown: EmptyView()
            }
        }
    }
}
