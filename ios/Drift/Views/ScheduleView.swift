//
//  ScheduleView.swift
//  Drift
//

import SwiftUI

struct ScheduleView: View {
    @EnvironmentObject private var engine: SpoofEngine
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss

    let prefill: ScheduledAction?
    let defaultPlace: Place?

    @State private var kind = 0 // 0 teleport, 1 route
    @State private var target: Place?
    @State private var routeStart: Place?
    @State private var mode: TravelMode = .walk
    @State private var loop = false
    @State private var fireDate = Date().addingTimeInterval(15 * 60)
    @State private var picking: Pick?

    enum Pick: String, Identifiable { case target, start; var id: String { rawValue } }

    var body: some View {
        DarkSheet(title: "Schedule") {
            Form {
                if !library.jobs.isEmpty {
                    Section("Scheduled") {
                        ForEach(library.jobs) { job in
                            HStack {
                                Image(systemName: "clock.fill").foregroundStyle(Color.driftAccent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.action.title).foregroundStyle(.white)
                                    Text(job.fireDate, format: .dateTime.weekday().hour().minute())
                                        .font(.caption).foregroundStyle(Color.textSecondary)
                                }
                                Spacer()
                                Text(job.fireDate, style: .relative).font(.caption).foregroundStyle(Color.textTertiary)
                            }
                            .swipeActions { Button("Cancel", role: .destructive) { engine.cancel(job) } }
                        }
                    }
                    .listRowBackground(Color.rowBackground)
                }

                Section("New") {
                    Picker("Action", selection: $kind) {
                        Text("Teleport").tag(0)
                        Text("Route").tag(1)
                    }
                    .pickerStyle(.segmented)

                    if kind == 1 {
                        pickRow(title: "Start", place: routeStart, pick: .start)
                    }
                    pickRow(title: kind == 0 ? "Place" : "Destination", place: target, pick: .target)

                    if kind == 1 {
                        Picker("Mode", selection: $mode) {
                            ForEach(TravelMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                        Toggle("Loop", isOn: $loop)
                    }

                    DatePicker("When", selection: $fireDate, in: Date()...)
                }
                .listRowBackground(Color.rowBackground)

                Section {
                    PrimaryButton(title: "Schedule", systemImage: "calendar.badge.clock") {
                        save()
                        dismiss()
                    }
                    .disabled(target == nil || (kind == 1 && routeStart == nil))
                    .opacity(target == nil || (kind == 1 && routeStart == nil) ? 0.5 : 1)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Keep Drift open in the background (don't swipe it away) so the schedule can fire. You'll get a notification when it starts.")
                        .foregroundStyle(Color.textTertiary)
                }
            }
            .sheet(item: $picking) { pick in
                EndpointPicker(title: pick == .target ? "Choose place" : "Start",
                               current: nil, selected: defaultPlace) { place in
                    if pick == .target { target = place } else { routeStart = place }
                    picking = nil
                }
            }
            .onAppear(perform: applyPrefill)
        }
    }

    private func applyPrefill() {
        if let prefill {
            switch prefill {
            case .teleport(let place):
                kind = 0; target = place
            case .route(let start, let end, let m, _, let l):
                kind = 1; routeStart = start; target = end; mode = m; loop = l
            }
        } else {
            target = target ?? defaultPlace
            if routeStart == nil, case .holding(let place) = engine.status { routeStart = place }
        }
    }

    private func pickRow(title: String, place: Place?, pick: Pick) -> some View {
        Button { picking = pick } label: {
            HStack {
                Text(title).foregroundStyle(.white)
                Spacer()
                Text(place?.name ?? "Choose").foregroundStyle(place == nil ? Color.driftAccent : Color.textSecondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.textTertiary)
            }
        }
    }

    private func save() {
        guard let target else { return }
        let action: ScheduledAction
        if kind == 0 {
            action = .teleport(target)
        } else {
            guard let routeStart else { return }
            action = .route(start: routeStart, end: target, mode: mode, kmh: mode.savedKmh, loop: loop)
        }
        engine.schedule(ScheduledJob(fireDate: fireDate, action: action))
    }
}
