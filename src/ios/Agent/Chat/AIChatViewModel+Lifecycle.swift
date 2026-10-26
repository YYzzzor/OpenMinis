//
//  AIChatViewModel+Lifecycle.swift
//  Minis - AIChatViewModel 扩展（Agent/Chat）
//
//  生命周期：长时间后台的浏览器任务标记、富文本缓存失效。
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

    /// [T-tool-bg-suspended-hint] On foreground return, mark still-running
    /// browser tool blocks that spanned the just-ended background period and
    /// have now run longer than `bgHintBrowserThreshold`. Skips entirely when
    /// enhanced background is already effective (nothing to suggest) — same
    /// gate as the BackgroundInterruptionTracker banner. In-memory only.
    @MainActor
    func markLongBackgroundBrowserTasks() {
        defer { bgHintBackgroundEntryDate = nil }
        guard let _ = bgHintBackgroundEntryDate else { return }
        guard !BackgroundKeepAliveManager.shared.enhancedBackgroundEffective else { return }
        let now = Date()
        for msg in messages where msg.role == .assistant {
            for block in msg.blocks {
                guard case .browserTool = block.kind else { continue }
                guard case .running = block.toolStatus else { continue }
                guard let start = block.toolStartTime,
                      now.timeIntervalSince(start) > Self.bgHintBrowserThreshold else { continue }
                block.wasBackgroundSuspended = true
            }
        }
    }

    /// Clear all cached attributed strings so they re-render with the new font size.
    /// Called by the coordinator before reconfiguring cells to guarantee ordering.
    @MainActor
    func invalidateAttributedStringCaches() {
        for msg in messages {
            for block in msg.blocks {
                if block.cachedAttributedString != nil {
                    block.cachedAttributedString = nil
                }
            }
        }
        if !transitionSuspended { objectWillChange.send() }
    }

}
