//
//  CompactSummarySheet.swift
//  Minis - 聊天页（AIChatView）
//
//  压缩摘要 sheet 和它用的可选文本视图。
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

// MARK: - Compact Summary Sheet

struct CompactSummarySheet: View {
    let summary: String
    /// Optional revert action. When provided, a "Revert Compact" button is shown
    /// below the summary; tapping it invokes the closure (typically wired to
    /// AIChatViewModel.revertCompact()) and dismisses the sheet.
    var onRevert: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showRevertConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SelectableTextView(text: summary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                if onRevert != nil {
                    Divider()
                    Button(role: .destructive) {
                        showRevertConfirm = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                            Text("Revert Compact")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Compact Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = summary
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                            .foregroundStyle(copied ? .green : .secondary)
                    }
                }
            }
            .alert("Revert this compact?", isPresented: $showRevertConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Revert", role: .destructive) {
                    let action = onRevert
                    dismiss()
                    action?()
                }
            } message: {
                Text("The summary will be discarded and the messages it covered will become active again. This may push the conversation past the model's context window — if that happens, long-press a message to re-compact from that point.")
            }
        }
        .presentationDetents([.large])
    }
}

/// UITextView wrapper for efficient rendering of long selectable text.
private struct SelectableTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = .label
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        tv.showsVerticalScrollIndicator = true
        tv.alwaysBounceVertical = true
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
        }
    }
}
