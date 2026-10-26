//
//  ContentView+SessionActions.swift
//  Minis - 首页（Views/ContentView）
//
//  删除（含删除信息）、重新生成标题。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

extension ContentView {
    // MARK: - Delete Info

    struct DeleteInfo {
        let sessionCount: Int
        let fileNames: [String]   // first 3 file names
        let totalFileCount: Int
        let totalSize: Int64      // bytes

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        }
    }

    nonisolated static func computeDeleteInfo(for ids: Set<String>, totalSessions: Int) -> DeleteInfo {
        let fm = FileManager.default
        let libBase = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let minisBase = libBase.appendingPathComponent("MinisChat/minis", isDirectory: true)
        let dbPath = libBase.appendingPathComponent("MinisChat/minis.db")

        var totalSize: Int64 = 0
        var allFileNames: [String] = []
        var totalFileCount = 0

        // Estimate DB size contribution (rough: divide DB size by total sessions)
        let totalSessions = max(totalSessions, 1)
        if let dbAttrs = try? fm.attributesOfItem(atPath: dbPath.path),
           let dbSize = dbAttrs[.size] as? Int64 {
            totalSize += dbSize * Int64(ids.count) / Int64(totalSessions)
        }

        for id in ids {
            let sessionDir = minisBase.appendingPathComponent(id, isDirectory: true)
            if let enumerator = fm.enumerator(at: sessionDir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if vals?.isRegularFile == true {
                        totalSize += Int64(vals?.fileSize ?? 0)
                        totalFileCount += 1
                        if allFileNames.count < 3 {
                            allFileNames.append(fileURL.lastPathComponent)
                        }
                    }
                }
            }
        }

        return DeleteInfo(
            sessionCount: ids.count,
            fileNames: allFileNames,
            totalFileCount: totalFileCount,
            totalSize: totalSize
        )
    }

    // MARK: - Actions

    func deleteSession(_ session: ChatSession) {
        // "Currently displayed" must use the same matching as the sidebar
        // highlight (isSessionHighlighted): a session created from a draft this
        // run keeps selectedSessionId at the DRAFT id while the sidebar row
        // carries the real id (newSessionRealId). Comparing only
        // selectedSessionId == session.id missed that case, so deleting the
        // conversation being viewed left the detail pane showing dead content
        // (user report: iPad/macOS split view). Clearing the selection resets
        // the detail pane to the empty state; onChange(selectedSessionId)
        // clears the draft tracking ids.
        if isSessionHighlighted(session.id) {
            selectedSessionId = nil
        }
        ViewModelCache.shared.remove(sessionId: session.id)
        BrowserUseOffloadBridge.releasePool(forSession: session.id)
        withAnimation {
            sessions.removeAll { $0.id == session.id }
        }
        Task {
            await ChatStore.shared.deleteSession(session.id)
            deleteSessionFiles(session.id)
        }
    }

    func deleteSelectedSessions() {
        let ids = selectedIds
        // Same draft-id-aware matching as deleteSession: clear the selection
        // when ANY deleted id is the one currently displayed (including a
        // draft-created session whose selection id differs from its row id).
        if ids.contains(where: { isSessionHighlighted($0) }) {
            selectedSessionId = nil
        }
        for id in ids {
            ViewModelCache.shared.remove(sessionId: id)
            BrowserUseOffloadBridge.releasePool(forSession: id)
        }
        withAnimation {
            sessions.removeAll { ids.contains($0.id) }
        }
        // Clear deleteInfo to signal onDismiss that deletion occurred;
        // isSelecting and selectedIds are reset in sheet's onDismiss to avoid animation conflicts.
        deleteInfo = nil
        let folderToDrop = pendingDeleteFolderId
        pendingDeleteFolderId = nil
        Task {
            for id in ids {
                await ChatStore.shared.deleteSession(id)
                deleteSessionFiles(id)
            }
            // Delete-all-in-folder: the folder is empty now; dissolving it
            // just drops the row (and pushes the FolderV2 tombstone).
            if let fid = folderToDrop {
                _ = await ChatStore.shared.dissolveFolder(fid)
                await MainActor.run { refreshSessionList() }
            }
        }
    }

    /// Remove persistent minis files for a session (Library/MinisChat/minis/<sessionId>/).
    private func deleteSessionFiles(_ sessionId: String) {
        let fm = FileManager.default
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MinisChat/minis", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try? fm.removeItem(at: base)
        BrowserTabPool.deletePersistedData(for: sessionId)
    }

    func regenerateTitle(for session: ChatSession) {
        regenerateTitle(sessionId: session.id)
    }

    func regenerateTitle(sessionId: String) {
        guard regeneratingTitleSessionId == nil else { return }
        regeneratingTitleSessionId = sessionId

        // [T-ios-state-publish-offmain-crash] @MainActor for the @State writes
        Task { @MainActor in
            defer { regeneratingTitleSessionId = nil }
            do {
                try await AIChatViewModel.regenerateSessionTitle(sessionId: sessionId)
                refreshSessionList()
            } catch {
                AppLogger(category: "RegenerateTitle").error(
                    "session=\(sessionId) failed: \(error.localizedDescription) — \(String(describing: error))"
                )
            }
        }
    }
}
