//
//  DriftLiveActivity.swift
//  DriftActivity
//
//  Lock Screen + Dynamic Island card, shown only while spoofing or moving.
//

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct DriftActivityBundle: WidgetBundle {
    var body: some Widget {
        DriftLiveActivity()
    }
}

struct DriftLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriftActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(white: 0.08).opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        IconBadge(state: state, size: 34)
                        Text(state.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(state.kind == .holding ? Color.activityGreen : Color.activityAccent)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: state)
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(state.kind == .holding ? Color.activityGreen : .white)
                        .frame(maxWidth: 90, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(state.placeName)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if !state.detail.isEmpty {
                                Text(state.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if state.kind != .holding {
                            ProgressView(value: state.progress)
                                .tint(Color.activityAccent)
                        }
                        StopButton(height: 40)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: state.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(state.kind == .holding ? Color.activityGreen : Color.activityAccent)
            } compactTrailing: {
                TimerText(state: state)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state.kind == .holding ? Color.activityGreen : Color.activityAccent)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: state.symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(state.kind == .holding ? Color.activityGreen : Color.activityAccent)
            }
            .keylineTint(state.kind == .holding ? Color.activityGreen : Color.activityAccent)
        }
    }
}

private struct LockScreenView: View {
    let state: DriftActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(state: state, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title.uppercased())
                        .font(.system(size: 11, weight: .heavy))
                        .kerning(0.6)
                        .foregroundStyle(state.kind == .holding ? Color.activityGreen : Color.activityAccent)
                    Text(state.placeName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !state.detail.isEmpty {
                        Text(state.detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    TimerText(state: state)
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(state.kind == .holding ? Color.activityGreen : .white)
                        .multilineTextAlignment(.trailing)
                    Text(state.kind == .holding ? "active" : (state.paused ? "paused" : "to arrive"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: 96, alignment: .trailing)
            }
            if state.kind != .holding {
                ProgressView(value: state.progress)
                    .tint(Color.activityAccent)
            }
            StopButton(height: 38)
        }
        .padding(16)
    }
}

private struct IconBadge: View {
    let state: DriftActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        let tint = state.kind == .holding ? Color.activityGreen : Color.activityAccent
        Image(systemName: state.symbol)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.18)))
            .overlay(Circle().stroke(tint.opacity(0.45), lineWidth: 1))
    }
}

/// Counts up while holding; counts down to arrival while moving.
private struct TimerText: View {
    let state: DriftActivityAttributes.ContentState

    var body: some View {
        if state.kind != .holding, !state.paused, let arrival = state.arrival, arrival > .now {
            Text(timerInterval: Date.now...arrival, countsDown: true)
        } else if state.kind != .holding {
            Text("\(Int(state.progress * 100))%")
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
        }
    }
}

private struct StopButton: View {
    let height: CGFloat

    var body: some View {
        Button(intent: StopSpoofIntent()) {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.activityRed)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.activityRed.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.activityRed.opacity(0.45), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
