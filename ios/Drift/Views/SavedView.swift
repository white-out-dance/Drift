//
//  SavedView.swift
//  Drift
//

import SwiftUI

struct SavedView: View {
    enum Kind { case history, bookmarks }

    @EnvironmentObject private var library: Library
    @EnvironmentObject private var engine: SpoofEngine
    @Environment(\.dismiss) private var dismiss
    let kind: Kind
    let onSelect: (Place) -> Void

    private var items: [Place] { kind == .bookmarks ? library.bookmarks : library.history }

    var body: some View {
        DarkSheet(title: kind == .bookmarks ? "Bookmarks" : "History") {
            List {
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: kind == .bookmarks ? "bookmark" : "clock.arrow.circlepath")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(Color.driftAccent)
                        Text(kind == .bookmarks ? "No bookmarks yet" : "No history yet")
                            .font(.headline).foregroundStyle(.white)
                        Text(kind == .bookmarks ? "Tap the bookmark on a place to keep it here." : "Places you spoof to show up here.")
                            .font(.subheadline).foregroundStyle(Color.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
                ForEach(items) { place in
                    Button { onSelect(place) } label: { row(place) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.rowBackground)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(place) } label: { Label("Delete", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                dismiss()
                                Task { await engine.teleport(to: place) }
                            } label: { Label("Spoof", systemImage: "scope") }
                                .tint(Color.spoofBottom)
                        }
                        .contextMenu {
                            Button { dismiss(); Task { await engine.teleport(to: place) } } label: {
                                Label("Spoof here now", systemImage: "scope")
                            }
                            Button { library.toggleBookmark(place) } label: {
                                Label(library.isBookmarked(place) ? "Remove bookmark" : "Bookmark", systemImage: "bookmark")
                            }
                            Button { UIPasteboard.general.string = place.coordinateText } label: {
                                Label("Copy coordinates", systemImage: "doc.on.doc")
                            }
                        }
                }
                if kind == .history && !items.isEmpty {
                    Button("Clear history", role: .destructive) { library.history.removeAll() }
                        .listRowBackground(Color.rowBackground)
                }
            }
        }
    }

    private func row(_ place: Place) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .bookmarks ? "bookmark.fill" : "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.driftAccent)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).foregroundStyle(.white).lineLimit(1)
                Text(place.subtitle.isEmpty ? place.coordinateText : place.subtitle)
                    .font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
            }
            Spacer()
            if kind == .history {
                Text(place.date, style: .relative).font(.caption2).foregroundStyle(Color.textTertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func delete(_ place: Place) {
        if kind == .bookmarks {
            library.bookmarks.removeAll { $0.id == place.id }
        } else {
            library.history.removeAll { $0.id == place.id }
        }
    }
}
