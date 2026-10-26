//
//  MoveToSessionSheet.swift
//  Minis - 聊天页（AIChatView）
//
//  把输入框内容移到另一个会话的选择 sheet。
//
//  AIChatView 文件地图见 AIChatView/AIChatView.swift。
//

import AVFoundation
import AVKit
import Combine
import GameController
import PhotosUI
import QuickLook
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - Move To Session Sheet

struct MoveToSessionSheet: View {
    let currentSessionId: String?
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ChatSession] = []
    @State private var searchText = ""
    @State private var searchMatchedIds: Set<String>?
    @State private var searchTask: Task<Void, Never>?

    /// Prefix used by ContentView for draft session IDs.
    private static let newSessionPrefix = "__new__"

    private var isSearching: Bool { !searchText.isEmpty }

    private var displayedSessions: [ChatSession] {
        let filtered = sessions.filter { $0.id != currentSessionId }
        guard let matchedIds = searchMatchedIds else { return filtered }
        return filtered.filter { matchedIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !isSearching {
                    Button {
                        let newId = "\(Self.newSessionPrefix)\(UUID().uuidString)"
                        dismiss()
                        onSelect(newId)
                    } label: {
                        Label(AppLocalized("New Chat"), systemImage: "plus.bubble")
                    }
                }

                Section(isSearching ? AppLocalized("Results") : AppLocalized("Recent")) {
                    ForEach(displayedSessions) { session in
                        Button {
                            dismiss()
                            onSelect(session.id)
                        } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 4) {
                                    highlightedText(
                                        session.title ?? AppLocalized("New Chat"),
                                        font: .system(size: 16, weight: .semibold),
                                        color: Color(UIColor.label)
                                    )
                                    .lineLimit(1)
                                    highlightedText(
                                        session.lastMessage ?? AppLocalized("No messages yet"),
                                        font: .system(size: 14),
                                        color: Color(UIColor.secondaryLabel)
                                    )
                                    .lineLimit(1)
                                }
                                Spacer(minLength: 1)
                                Text(relativeDate(session.updatedAt))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(UIColor.tertiaryLabel))
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: AppLocalized("Search chats..."))
            .onChange(of: searchText) { _ in scheduleSearch() }
            .navigationTitle(AppLocalized("Move to…"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                }
            }
        }
        .task {
            sessions = ChatStore.shared.listSessions()
        }
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            searchMatchedIds = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let results = await ChatStore.shared.searchSessions(query: query)
            if !Task.isCancelled {
                searchMatchedIds = Set(results.map(\.session.id))
            }
        }
    }

    // MARK: - Highlight

    @ViewBuilder
    private func highlightedText(_ text: String, font: Font, color: Color) -> some View {
        if isSearching, let query = Optional(searchText.trimmingCharacters(in: .whitespaces)),
           !query.isEmpty, text.range(of: query, options: .caseInsensitive) != nil {
            buildHighlighted(text, query: query, font: font, color: color)
        } else {
            Text(text).font(font).foregroundStyle(color)
        }
    }

    private func buildHighlighted(_ text: String, query: String, font: Font, color: Color) -> Text {
        let lower = text.lowercased()
        let lowerQ = query.lowercased()
        var result = Text("")
        var current = text.startIndex

        while current < text.endIndex,
              let range = lower.range(of: lowerQ, range: current..<lower.endIndex) {
            if current < range.lowerBound {
                result = result + Text(text[current..<range.lowerBound])
                    .font(font).foregroundColor(color)
            }
            result = result + Text(text[range])
                .font(font).foregroundColor(.accentColor).bold()
            current = range.upperBound
        }
        if current < text.endIndex {
            result = result + Text(text[current..<text.endIndex])
                .font(font).foregroundColor(color)
        }
        return result
    }

    // MARK: - Relative Date

    private func relativeDate(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let seconds = Int(now.timeIntervalSince(date))
        if calendar.isDateInToday(date) {
            if seconds < 60 {
                return AppLocalized("Just now")
            } else if seconds < 3600 {
                let mins = seconds / 60
                return "\(mins) min ago"
            } else {
                let hrs = seconds / 3600
                return "\(hrs) hr ago"
            }
        } else if calendar.isDateInYesterday(date) {
            return AppLocalized("Yesterday")
        } else {
            let diff = calendar.dateComponents([.day], from: date, to: now)
            if let days = diff.day, days < 7 {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE"
                return formatter.string(from: date)
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
    }
}
