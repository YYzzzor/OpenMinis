//
//  AIChatViewModel+ThinkingLevel.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  会话级思考强度：设置、默认值、待应用值的写回。
//  代码从 AIChatViewModel.swift 逐字移出。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UIKit
import os.log

extension AIChatViewModel {

    /// Set thinking level — persists if session exists, otherwise holds in memory.
    func setThinkingLevel(_ level: ThinkingLevel) {
        let maxLevel = resolveCurrentEntry()?.effectiveMaxThinkingLevel ?? .xhigh
        let clamped = level == .off ? level : min(level, maxLevel)
        if let sid = sessionId {
            var cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) ?? SessionInferenceConfig()
            cfg.thinkingLevel = clamped
            ProviderConfigStore.shared.setInferenceConfig(cfg, for: sid)
        } else {
            pendingThinkingLevel = clamped
        }
        if !transitionSuspended { objectWillChange.send() }
    }

    /// Default thinking level inherited from the active default primary group, or .off.
    private var defaultGroupThinkingLevel: ThinkingLevel {
        let store = ProviderConfigStore.shared
        guard let groupId = store.defaultPrimaryGroupId,
              let group = store.group(for: groupId) else { return .off }
        return group.defaultThinkingLevel ?? .off
    }

    /// Current thinking level for this session.
    ///
    /// [T-ios-stale-thinking-level-display] The stored value can exceed the
    /// active model's current ceiling — e.g. a session/group config persisted
    /// `.ultra` (or `.max`) while a model's `effectiveMaxThinkingLevel` was higher,
    /// then the catalog cap was tightened (sol/terra .ultra→.max, etc.). The write
    /// path (`setThinkingLevel`) clamps, but a value persisted under a looser cap
    /// is never rewritten, so a raw read would surface a level the model no longer
    /// supports — the "is thinking…" pill would show "Ultra/极限" when the user's
    /// effective (and wire-sent) level is really "Max". Clamp on read so the
    /// displayed level always matches what will actually be requested (the request
    /// path re-clamps per-model too — AgentProvider: min(level, catalogMax)).
    var currentThinkingLevel: ThinkingLevel {
        let stored: ThinkingLevel = {
            if let sid = sessionId, let cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) {
                return cfg.thinkingLevel
            }
            return pendingThinkingLevel ?? defaultGroupThinkingLevel
        }()
        guard stored.isEnabled else { return stored }
        guard let entry = resolveCurrentEntry() else { return min(stored, .xhigh) }
        let clamped = min(stored, entry.effectiveMaxThinkingLevel)
        // [T-thinking-levels-data-driven] The offered set can be SPARSE (a model
        // declaring ["high","max"] offers only High/Max), and a level persisted
        // before that was known — or carried over from another model — may not
        // be in it. Snap onto the nearest offered tier at or below, mirroring
        // `clampEffort`'s prefer-downgrade rule, so the pill and the checkmark
        // agree with the value actually sent.
        let levels = entry.selectableThinkingLevels
        guard !levels.isEmpty, !levels.contains(clamped) else { return clamped }
        return levels.last(where: { $0 <= clamped }) ?? levels[0]
    }

    /// Flush pending thinking level to the store once sessionId is available.
    /// Returns `true` if a user-chosen level was written, so the caller can
    /// keep the group-default seeding (createInitialBinding) from clobbering it.
    ///
    /// [T-first-msg-thinking-level-clobber] Note the `pending != .off` guard:
    /// `.off` is indistinguishable from "unset" in SessionInferenceConfig, so a
    /// user who explicitly picks Off before the first send still inherits the
    /// group default. That pre-existing limitation is unchanged here — this fix
    /// only stops a real (enabled) override from being overwritten.
    @discardableResult
    func flushPendingThinkingLevel() -> Bool {
        guard let pending = pendingThinkingLevel, pending != .off, let sid = sessionId else { return false }
        var cfg = ProviderConfigStore.shared.inferenceConfig(for: sid) ?? SessionInferenceConfig()
        cfg.thinkingLevel = pending
        ProviderConfigStore.shared.setInferenceConfig(cfg, for: sid)
        pendingThinkingLevel = nil
        return true
    }

}
