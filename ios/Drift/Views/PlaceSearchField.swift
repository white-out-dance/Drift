//
//  PlaceSearchField.swift
//  Drift
//

import SwiftUI
import MapKit

/// Search box with a results card underneath. Calls `onPick` with a resolved place.
struct PlaceSearchField: View {
    enum Style { case capsule, field }

    let placeholder: String
    var style: Style = .field
    var autofocus = false
    var onFocusChange: ((Bool) -> Void)? = nil
    let onPick: (Place) -> Void

    @StateObject private var search = PlaceSearch()
    @FocusState private var focused: Bool
    @State private var resolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.driftAccent)
                TextField("", text: $search.query, prompt: Text(placeholder).foregroundColor(.textTertiary))
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { pickFirst() }
                if resolving {
                    ProgressView().controlSize(.small).tint(.white)
                } else if !search.query.isEmpty {
                    Button { search.clear() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: style == .capsule ? 50 : 48)
            .modifier(FieldChrome(style: style))

            if focused && (!search.results.isEmpty || search.coordinateMatch != nil) {
                VStack(alignment: .leading, spacing: 0) {
                    if let match = search.coordinateMatch {
                        resultRow(title: "Go to coordinates",
                                  subtitle: String(format: "%.6f, %.6f", match.latitude, match.longitude),
                                  symbol: "scope") {
                            finish(Place(name: "Dropped pin",
                                         subtitle: String(format: "%.6f, %.6f", match.latitude, match.longitude),
                                         coordinate: match))
                        }
                    }
                    ForEach(Array(search.results.enumerated()), id: \.offset) { index, completion in
                        if index > 0 || search.coordinateMatch != nil {
                            Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 52)
                        }
                        resultRow(title: completion.title, subtitle: completion.subtitle, symbol: "mappin") {
                            Task { await pick(completion) }
                        }
                    }
                }
                .padding(.vertical, 6)
                .glass(20)
            }
        }
        .onAppear { if autofocus { focused = true } }
        .onChange(of: focused) { _, value in onFocusChange?(value) }
    }

    private func resultRow(title: String, subtitle: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.driftAccent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 13)).foregroundStyle(Color.textSecondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickFirst() {
        if let match = search.coordinateMatch {
            finish(Place(name: "Dropped pin",
                         subtitle: String(format: "%.6f, %.6f", match.latitude, match.longitude),
                         coordinate: match))
        } else if let first = search.results.first {
            Task { await pick(first) }
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        resolving = true
        let place = await search.resolve(completion)
        resolving = false
        if let place { finish(place) }
    }

    private func finish(_ place: Place) {
        focused = false
        search.clear()
        onPick(place)
    }
}

private struct FieldChrome: ViewModifier {
    let style: PlaceSearchField.Style
    func body(content: Content) -> some View {
        switch style {
        case .capsule:
            content.glass(25)
        case .field:
            content.background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.rowBackground))
        }
    }
}
