//
//  ContentView+SidebarToolbar.swift
//  Minis - 首页（Views/ContentView）
//
//  工具栏、同步副标题（migrationSubtitle）和标题旁的同步指示器。
//
//  ContentView 文件地图见 ContentView/ContentView.swift。
//

import SwiftUI

extension ContentView {
    // MARK: - Sidebar Toolbar

    /// Refresh cadence for the sidebar migration subtitle, in seconds.
    private static let migrationSubtitleRefreshInterval: UInt64 = 5

    /// [T-ios-migration-timer-sessionlist-uaf-crash] Self-cancelling refresh loop
    /// for `migrationSubtitle`, driven by `.task` on the identity-stable sidebar
    /// Group. Replaces the process-lived `Timer.publish().autoconnect()` +
    /// `.onReceive` that AttributeGraph could tear down mid-transaction (UAF).
    ///
    /// SwiftUI cancels this Task when the Group's identity ends, so the loop stops
    /// cleanly with no dangling subscription. It parks (no refresh, cheap poll)
    /// while the app is backgrounded — the crash reproduced with the app in the
    /// background, and a hidden sidebar has nothing to display anyway.
    @MainActor
    func migrationSubtitleLoop() async {
        // Mirror the old `.onAppear { refreshMigrationSubtitle() }`: refresh once
        // immediately so the subtitle is correct as soon as the sidebar appears.
        refreshMigrationSubtitle()
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.migrationSubtitleRefreshInterval * 1_000_000_000)
            } catch {
                return  // cancelled during sleep
            }
            // Skip the refresh while backgrounded; keep looping so it resumes on
            // return to foreground without needing a separate scene-phase wake.
            // Read the process-level flag (kept current by the scenePhase observer)
            // rather than the `@Environment(\.scenePhase)` captured in this `.task`
            // closure's `self` snapshot, which would be stale.
            let backgrounded: Bool
            if #available(iOS 17.0, *) {
                backgrounded = SyncCore.shared.isAppInBackground
            } else {
                backgrounded = false
            }
            if !backgrounded {
                refreshMigrationSubtitle()
            }
        }
    }

    private func refreshMigrationSubtitle() {
        guard #available(iOS 17.0, *), SyncV2Bootstrap.isEnabled else {
            if migrationSubtitle != nil { migrationSubtitle = nil }
            return
        }
        Task { @MainActor in
            // Engine reports paused first regardless of dirty queue.
            if SyncCore.shared.pausedUntil != nil {
                if migrationSubtitle != .paused { migrationSubtitle = .paused }
                return
            }
            let counts = await ChatStore.shared.countDirtyRecords()
            let byType = Self.formatV2DirtyByType(counts.byType)
            let engineUp = SyncCore.shared.isRunning
            // Engine down but dirty queue is non-empty → stalled, not
            // syncing. The rotating icon would lie about progress.
            if !engineUp, !byType.isEmpty {
                if migrationSubtitle != .waiting { migrationSubtitle = .waiting }
                return
            }
            if let summary = await MigrationEngine.shared.progressSummary() {
                let pct = summary.pushTotal > 0 ? Int(Double(summary.pushDone) * 100.0 / Double(summary.pushTotal)) : 0
                let next: SyncSubtitleState = engineUp
                    ? .migrating(percent: pct, byType: byType)
                    : .waiting
                if migrationSubtitle != next { migrationSubtitle = next }
                return
            }
            if !byType.isEmpty {
                let next: SyncSubtitleState = engineUp ? .syncing(byType: byType) : .waiting
                if migrationSubtitle != next { migrationSubtitle = next }
            } else {
                // No active sync work — hide the subtitle entirely so the
                // "Minis" title sits at its normal size.
                if migrationSubtitle != nil { migrationSubtitle = nil }
            }
        }
    }

    /// Map v2 dirty-by-type counts → display capsules. Only types with
    /// dirty>0 are returned, sorted by count desc, top 3.
    private static func formatV2DirtyByType(_ byType: [String: Int]) -> [(label: String, count: Int)] {
        let labels: [String: String] = [
            "SessionV2": "Ses",
            "MessageV2": "Msg",
            "SessionFileV2": "Fil",
            "CompactMarkerV2": "Cmp",
            "ProviderConfigV2": "Prv",
            "EnvVarV2": "Env",
            "SyncDeviceV2": "Dev",
            "SkillV2": "Skl",
        ]
        return byType
            .compactMap { (k, v) -> (String, Int)? in
                guard v > 0, let label = labels[k] else { return nil }
                return (label, v)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map { (label: $0.0, count: $0.1) }
    }

    /// Tiny indicator next to the "Minis" title showing the sync state.
    @ViewBuilder
    private func titleSyncIndicator(for state: SyncSubtitleState?) -> some View {
        switch state {
        case .none, .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green)
        case .paused:
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
        case .migrating, .syncing:
            PulseRotateIcon()
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func syncSubtitleView(_ state: SyncSubtitleState) -> some View {
        HStack(spacing: 5) {
            switch state {
            case .paused:
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Sync paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .migrating(let pct, let byType):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(pct)%")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                ForEach(byType.indices, id: \.self) { i in
                    syncTypeChip(label: byType[i].label, count: byType[i].count)
                }
            case .syncing(let byType):
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(byType.indices, id: \.self) { i in
                    syncTypeChip(label: byType[i].label, count: byType[i].count)
                }
            case .upToDate:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.green)
                Text("Up to date")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .waiting:
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Waiting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func syncTypeChip(label: String, count: Int) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(formatCompact(count))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Compact integer formatting: 89,401 → "89k", 1,234 → "1.2k", 740 → "740".
    private func formatCompact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 10_000 {
            let v = Double(n) / 1000.0
            return String(format: "%.1fk", v)
        }
        return "\(n / 1000)k"
    }

    @ToolbarContentBuilder
    var sidebarToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if isSelecting {
                Text(selectedIds.isEmpty ? "Select Sessions" : "\(selectedIds.count) Selected")
                    .font(.headline)
            } else {
                let canOpenSync: Bool = {
                    if #available(iOS 17.0, *) { return SyncV2Bootstrap.isEnabled }
                    return false
                }()
                // Title text comes from SOUL.md (falls back to "Minis"). The
                // leading sync indicator floats as an overlay so it doesn't
                // take layout space — title stays perfectly centered in the
                // navigation bar regardless of whether the indicator is visible.
                // When iCloud sync isn't enabled the title is a plain Text;
                // wrapping it in a `.disabled` Button would drain SwiftUI's
                // default disabled-button tint into the label and render the
                // SOUL name grey, which read as a styling bug rather than the
                // intended "no sync detail to open" state.
                // [T-ios-soul-name-sidebar-stale] The `.onReceive(soulMdChanged)`
                // that refreshes `soulName` used to live HERE. It was moved to the
                // stable `sessionList(useNavigationLinks:)` body for the SAME reason
                // the migration timer was (see the T-ios-migration-timer note below):
                // this toolbar principal item rebuilds on every canOpenSync /
                // soulName / migrationSubtitle / isSelecting change, so a sink
                // attached here gets torn down and re-created constantly and can
                // drop a .soulMdChanged notification that arrives during the gap.
                // This Text now only READS `soulName`.
                let titleLabel = Text(soulName)
                    .font(.system(size: 18.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .overlay(alignment: .leading) {
                        if canOpenSync {
                            Button {
                                activeToolSheet = .syncMigrationDetail
                            } label: {
                                titleSyncIndicator(for: migrationSubtitle)
                                    .contentShape(Rectangle())
                                    .padding(4)
                            }
                            .buttonStyle(.plain)
                            .offset(x: -27)
                        }
                    }
                // [T-ios-migration-timer-toolbar-uaf-crash] The migration-subtitle
                // refresh driver used to live HERE, on this `titleLabel` Text inside
                // the churny toolbar principal item. That item rebuilds whenever
                // canOpenSync / soulName / migrationSubtitle / isSelecting change, so
                // AttributeGraph repeatedly tore down the driver's sink — a
                // use-after-free release in the setBody transaction (EXC_BAD_ACCESS,
                // build 309). The driver now lives on the stable
                // `sessionList(useNavigationLinks:)` body (identity-stable across the
                // sidebar lifetime) as a `.task` async loop, not a Combine timer sink
                // (see migrationSubtitleLoop, T-ios-migration-timer-sessionlist-uaf-crash);
                // this Text only READS the `migrationSubtitle` @State.

                if canOpenSync {
                    Button {
                        activeToolSheet = .syncMigrationDetail
                    } label: {
                        titleLabel
                    }
                    .buttonStyle(.plain)
                } else {
                    titleLabel
                }
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button("Cancel") {
                    isSelecting = false
                    selectedIds.removeAll()
                }
            } else {
                Button {
                    activeToolSheet = .settings
                } label: {
                    Image(systemName: "gear")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isSelecting {
                Button(selectedIds.count == sessions.count ? "Deselect All" : "Select All") {
                    if selectedIds.count == sessions.count {
                        selectedIds.removeAll()
                    } else {
                        selectedIds = Set(sessions.map(\.id))
                    }
                }
            } else if hasAlarms {
                Button {
                    showAlarmList = true
                } label: {
                    Image(systemName: "alarm")
                        .font(.system(size: 15, weight: .medium))
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !isSelecting {
                Menu {
                    Button {
                        showTerminal = true
                    } label: {
                        Label("Shell Terminal", systemImage: "terminal")
                    }
                    Button {
                        activeToolSheet = .rootfsManagement
                    } label: {
                        Label("Rootfs Management", systemImage: "externaldrive")
                    }
                    Divider()
                    Button {
                        activeToolSheet = .browser
                    } label: {
                        Label("Open Browser", systemImage: "globe")
                    }
                    Button {
                        activeToolSheet = .browserManagement
                    } label: {
                        Label("Browser Settings", systemImage: "globe.badge.chevron.backward")
                    }
                    #if DEBUG
                    Divider()
                    // [debug] Keep Screen Awake — disables auto-lock while the app
                    // is foregrounded. Tap toggles; a checkmark shows the current
                    // state. Memory-only (not persisted). DEBUG builds only.
                    Button {
                        keepScreenAwake.toggle()
                        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
                    } label: {
                        Label("Keep Screen Awake", systemImage: keepScreenAwake ? "checkmark.circle.fill" : "sun.max")
                    }
                    #endif
                } label: {
                    Image("TerminalCircle")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
            }
        }
    }
}
