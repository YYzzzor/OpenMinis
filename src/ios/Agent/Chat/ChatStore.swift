//
//  ChatStore.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  ChatStore：基于 SQLite 的存储（一个 actor），保存聊天会话、消息、文件夹、
//  媒体和压缩标记，并提供 iCloud 同步与备份还原需要的记账。
//
//  文件地图（从一个 7500 行的大文件拆出；代码逐字移动，对应上游 1.15 的拆分，
//  只保留 MinisX 现有的代码）：
//
//    ChatStore.swift          本文件：actor 主体——全部存储属性、init / deinit、
//        受保护数据重启保护、备份还原用的 reload / close、同步 zone 名和延迟的同步脏标记
//    ChatStoreModels.swift    持久化的数据模型（ChatSession、ChatFolder、RawMessage、
//        ContentPart、CompactMarker 等）
//    存储
//        ChatStore+Schema           建库、建表、列迁移辅助
//        ChatStore+SessionCRUD      创建会话、part_flags 位掩码
//        ChatStore+SessionList      listSessions、列读取、预览文本
//        ChatStore+Search           会话搜索
//        ChatStore+SessionQueries   sessions 工具的查询、getSession、各类更新
//        ChatStore+Folders          文件夹（分组）
//        ChatStore+SessionDeletion  记忆开关、删除会话（本地 / 云端）
//        ChatStore+Messages         消息增删改查、上下文用量历史锚点
//        ChatStore+Media            媒体文件
//        ChatStore+CompactMarkers   压缩标记
//        ChatStore+Tombstones       删除墓碑（防复活）
//        ChatStore+WebAppShortcuts  网页应用快捷方式
//        ChatStore+Maintenance      裁剪、会话修复
//        ChatStore+UsageStats       token 用量统计
//        ChatStore+SessionCosts     MinisX：本地会话费用账本入口
//        ChatStore+Helpers          共用小工具（排序号、touch、绑定）
//    同步与还原
//        ChatStore+SyncDirty          脏记录、积压、强制同步 / 拉取、会话文件扫描
//        ChatStore+SyncRemoteSessions 入站的会话和消息
//        ChatStore+SyncRemoteRecords  设备、媒体、技能、记忆、服务商配置、环境变量、大小估算
//        ChatStore+BackupRestore      备份还原的写入
//    转换
//        ContentPart+ProviderConversion  [ContentPart] 转 Anthropic / Gemini
//        RawMessage+Conversion           RawMessage 转 ChatMessage / AgentMessage
//
//    上游 1.15 有而 MinisX 没有对应代码的文件不建（+StoredPreview 等）。
//    MinisX 独有的代码：上下文用量历史锚点 contextUsageHistoryAnchor 在 +Messages，
//    本地会话费用账本入口在专属文件 +SessionCosts。
//
//  拆分规则：
//
//  - 存储属性留在本 actor 主体中（扩展不能声明存储属性），顺序与拆分前相同。
//    扩展成员与主体成员的 actor 隔离相同。
//  - 用到日志的文件各自声明文件内的日志（`logger`、`memDiagLogger`、`iCloudLogger`）。
//  - 被其他文件用到的成员去掉了 `private`；它们仍视为 store 内部成员。
//    原来 private 的方法放在扩展里（直接调用）；放在 actor 主体的方法，
//    在未优化的构建中经 actor 的方法表分发。
//  - 新增行为放进对应职责的文件，没有合适的就新建一个 ChatStore+X。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let iCloudLogger = AppLogger(category: "iCloud")
private let logger = AppLogger(category: "ChatStore")

// MARK: - ChatStore Actor

/// Persistent store for chat sessions, messages, and media files.
/// All methods are synchronous SQLite operations (call from background if needed).
actor ChatStore {
    static let shared = ChatStore()

    var db: OpaquePointer?
    /// Base URL for per-session media storage: Library/MinisChat/minis/
    let minisBaseURL: URL

    let dbURL: URL

    // [T-ios-listsessions-cache] Cache the last listSessions() result and only
    // recompute when a mutation that can change the list has fired. listSessions
    // parses every session's parts_json into fresh preview Strings (~1772 String
    // allocations per call); ContentView fires it from many refresh paths, and a
    // malloc_history stack proved these Strings dominated the heap (hundreds of
    // MB) — every redundant call minted a whole new batch that SwiftUI kept
    // referencing across body passes. With this cache, back-to-back calls with
    // no intervening write return the SAME array (no new Strings). Guarded by
    // `sessionListCacheDirty`, set true by every list-affecting mutation below.
    // ChatStore is an actor, so these fields need no extra locking.
    var sessionListCache: [ChatSession]?
    var sessionListCacheDirty = true

    /// [T-ios-listsessions-cache] Mark the cached session list stale. Called by
    /// every mutation that can change what listSessions() returns — the row set
    /// (create/delete), ordering (updated_at via touchSession), or a displayed
    /// field (title/category/pin/model/preview text from new messages).
    /// `internal` rather than `private` so the backup restore path
    /// (ChatStore+BackupRestore.swift) can invalidate after its own row writes —
    /// Swift's `private` is file-scoped, so an extension in another file cannot
    /// see it.
    func invalidateSessionListCache() {
        sessionListCacheDirty = true
    }

    init() {
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let baseURL = libraryURL.appendingPathComponent("MinisChat", isDirectory: true)
        self.dbURL = baseURL.appendingPathComponent("minis.db")
        self.minisBaseURL = baseURL.appendingPathComponent("minis", isDirectory: true)

        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: minisBaseURL, withIntermediateDirectories: true)

        openDatabase()
        createTables()
        armRebootGuardIfDegraded()
    }

    // MARK: - [T-ios-reboot-config-loss] Protected-data reboot guard

    /// True when the DB cannot actually serve queries after open. After a
    /// device reboot iOS can relaunch the app in the background BEFORE first
    /// unlock (BGTask / CloudKit push / location session). minis.db carries
    /// the default completeUntilFirstUserAuthentication protection class, so
    /// sqlite3_open "succeeds" lazily but every statement fails — the session
    /// list reads as empty and the home screen looks freshly installed until
    /// the process is killed. Nothing is deleted (we never drop/recreate on
    /// failure), so a post-unlock reopen fully restores the store.
    private var dbDegraded = false

    private func probeDBUsable() -> Bool {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT count(*) FROM sessions", -1, &stmt, nil)
        sqlite3_finalize(stmt)
        return rc == SQLITE_OK
    }

    private func armRebootGuardIfDegraded() {
        guard !probeDBUsable() else { return }
        dbDegraded = true
        logger.error("[RebootGuard] minis.db unusable after open — likely launched before first unlock; arming post-unlock reopen")
        // Recover when protected data unlocks, plus on every foreground
        // activation (covers the unlock racing observer registration).
        // Observers stay registered after recovery; reopenIfDegraded no-ops.
        for name in [UIApplication.protectedDataDidBecomeAvailableNotification,
                     UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                Task { await ChatStore.shared.reopenIfDegraded() }
            }
        }
    }

    func reopenIfDegraded() {
        guard dbDegraded else { return }
        reloadDatabase()
        guard probeDBUsable() else {
            logger.warning("[RebootGuard] reopen attempt still degraded — will retry on the next unlock/activation signal")
            return
        }
        dbDegraded = false
        invalidateSessionListCache()
        logger.info("[RebootGuard] minis.db reopened after unlock — session store restored")
    }

    /// Initialize with a custom base URL (for testing).
    init(baseURL: URL) {
        self.dbURL = baseURL.appendingPathComponent("minis.db")
        self.minisBaseURL = baseURL.appendingPathComponent("minis", isDirectory: true)

        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: minisBaseURL, withIntermediateDirectories: true)

        openDatabase()
        createTables()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Reload / Close (for backup & restore)

    func closeDatabase() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    func reloadDatabase() {
        closeDatabase()
        openDatabase()
        createTables()
    }

    // MARK: - Sync Zone Name

    /// Zone name for dirty record tracking. Set by CloudSyncEngine on init.
    var syncZoneName: String = ""

    func setSyncZoneName(_ name: String) {
        syncZoneName = name
    }

    // MARK: - Deferred Sync Dirty Marks

    /// When true, markDirty writes to the dirty table but does NOT trigger scheduleSend.
    /// Set during agent processing to defer CloudKit upload triggers while streaming.
    /// Dirty marks are always written to DB immediately (crash-safe); only the
    /// scheduleSend() call is deferred until the agent loop finishes.
    private(set) var syncSendDeferred = false

    func setSyncSendDeferred(_ value: Bool) {
        syncSendDeferred = value
    }

    /// Session IDs touched during agent processing — used to scan file directories
    /// for changes when the agent loop finishes.
    var pendingSyncSessionIds = Set<String>()

    /// Flush deferred sync: scan session file directories and trigger CloudKit upload.
    /// Dirty marks for messages/sessions are already persisted in DB (written at
    /// appendMessage/touchSession time), so this only handles file scanning and
    /// the final scheduleSend trigger.
    func flushPendingSyncDirty() {
        syncSendDeferred = false
        let f0 = CFAbsoluteTimeGetCurrent()
        var fileCount = 0
        for sessionId in pendingSyncSessionIds {
            fileCount += scanAndMarkSessionFiles(sessionId: sessionId)
        }
        let f1 = CFAbsoluteTimeGetCurrent()
        let sessionCount = pendingSyncSessionIds.count
        pendingSyncSessionIds.removeAll()
        iCloudLogger.info("[iCloud] flushPendingSyncDirty: \(sessionCount) sessions, \(fileCount) files — scanFiles=\(String(format: "%.0f", (f1-f0)*1000))ms")
        // Trigger a single debounced send for all the dirty records
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                CloudSyncEngine.shared.scheduleSend()
            }
        }
    }
}
