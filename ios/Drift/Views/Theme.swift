//
//  Theme.swift
//  Drift
//
//  Dark map + frosted glass controls + sky-blue primary button.
//

import SwiftUI

extension Color {
    /// Icon / accent blue used on glass buttons.
    static let driftAccent = Color(red: 0.42, green: 0.78, blue: 0.93)
    static let spoofTop = Color(red: 0.52, green: 0.82, blue: 0.94)
    static let spoofBottom = Color(red: 0.30, green: 0.68, blue: 0.86)
    static let liveGreen = Color(red: 0.36, green: 0.85, blue: 0.47)
    static let stopRed = Color(red: 1.0, green: 0.37, blue: 0.33)
    static let destOrange = Color(red: 1.0, green: 0.58, blue: 0.38)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.30)
    static let sheetBackground = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let rowBackground = Color.white.opacity(0.06)
}

struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((tint ?? Color(white: 0.16)).opacity(tint == nil ? 0.45 : 0.20))
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder((tint ?? .white).opacity(tint == nil ? 0.10 : 0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

extension View {
    func glass(_ cornerRadius: CGFloat = 20, tint: Color? = nil) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, tint: tint))
    }
}

/// The big sky-blue "Spoof" button.
struct PrimaryButton: View {
    let title: String
    var systemImage: String = "scope"
    var loading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if loading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: systemImage).font(.system(size: 19, weight: .semibold))
                }
                Text(title).font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [.spoofTop, .spoofBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                    )
            }
            .shadow(color: Color.spoofBottom.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Dim glass placeholder button ("Tap the map or search", "Preparing").
struct DimButton: View {
    let title: String
    var systemImage: String = "scope"
    var loading = false

    var body: some View {
        HStack(spacing: 10) {
            if loading {
                ProgressView().tint(.textSecondary)
            } else {
                Image(systemName: systemImage).font(.system(size: 17, weight: .medium))
            }
            Text(title).font(.system(size: 17, weight: .medium))
        }
        .foregroundStyle(Color.textSecondary)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .glass(18)
    }
}

/// Tinted glass pill used for "Spoofing 00:08" / "Route live" / "Stop".
struct TintedPill<Label: View>: View {
    let tint: Color
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .glass(18, tint: tint)
    }
}

struct CircleGlassButton: View {
    let systemImage: String
    var size: CGFloat = 46
    var tint: Color = .driftAccent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .glass(size / 2)
        }
        .buttonStyle(PressableStyle())
    }
}

struct SmallCircleButton: View {
    let systemImage: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? Color.driftAccent : Color.white.opacity(0.75))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(PressableStyle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// mm:ss (or h:mm:ss) since `start`, ticking every second.
struct ElapsedText: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start)))
                .monospacedDigit()
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Dark sheet chrome shared by Settings / Saved / Schedule.
struct DarkSheet<Content: View>: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .scrollContentBackground(.hidden)
                .background(Color.sheetBackground.ignoresSafeArea())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.8))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.white.opacity(0.12)))
                        }
                    }
                }
        }
        .presentationBackground(Color.sheetBackground)
        .preferredColorScheme(.dark)
    }
}
