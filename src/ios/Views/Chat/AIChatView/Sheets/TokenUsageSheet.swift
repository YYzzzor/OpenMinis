//
//  TokenUsageSheet.swift
//  Minis - 聊天页（AIChatView）
//
//  Token 用量 sheet。MinisX 独有：SessionBillingSection（DeepSeek 会话费用）。
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

// MARK: - Token Usage Sheet

struct TokenUsageSheet: View {
    @ObservedObject var vm: AIChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let s = vm.sessionTokenStats

                Section {
                    let contextUsage = vm.currentContextUsage
                    StatRow(label: "Context Used", value: contextUsage.map { formatted($0.usedTokens) } ?? "—", icon: "text.alignleft")
                    if let window = vm.currentModelContextWindow {
                        StatRow(label: "Context Window", value: formatted(window), icon: "arrow.left.and.right")
                    }
                    if let maxOut = vm.currentModelMaxOutputTokens {
                        StatRow(label: "Max Output", value: formatted(maxOut), icon: "arrow.up.to.line")
                    }
                } header: {
                    Text("Context")
                } footer: {
                    Text("Based on the last valid request's input, including cache. Excludes your draft, the reply, and later tool results. Preserved when switching sessions or restarting the app. If model or context changes invalidate it, a new request must report usage.", comment: "Explains the context indicator's last-request measurement and unavailable state")
                }

                Section("Tokens (Session Total)") {
                    let inputTotal = s.input + s.cacheRead + s.cacheWrite
                    StatRow(label: "Input (incl. cache)", value: formatted(inputTotal), icon: "arrow.down.circle")
                    StatRow(label: "Output", value: formatted(s.output), icon: "arrow.up.circle")
                }

                Section("Cache (Session Total)") {
                    StatRow(label: "Cache Read", value: formatted(s.cacheRead), icon: "arrow.triangle.2.circlepath")
                    StatRow(label: "Cache Write", value: formatted(s.cacheWrite), icon: "square.and.arrow.down")
                    // [T-ios-token-usage-cache-hit-rate] Cache hit rate = cache read
                    // over total input (incl. cache) — the same denominator as the
                    // "Input (incl. cache)" row above (input + cacheRead + cacheWrite).
                    // Shows how much of this session's input was served from cache.
                    let totalInput = s.input + s.cacheRead + s.cacheWrite
                    if totalInput > 0 && s.cacheRead > 0 {
                        let hitRate = Double(s.cacheRead) / Double(totalInput) * 100
                        StatRow(label: "Cache Hit Rate", value: String(format: "%.1f%%", hitRate), icon: "percent")
                    }
                }

                if vm.showsSessionBilling {
                    SessionBillingSection(vm: vm)
                }

                Section("Speed") {
                    let speed = vm.sessionOutputTokensPerSecond
                    StatRow(label: "Output Speed", value: speed > 0 ? String(format: "%.1f tok/s", speed) : "—", icon: "speedometer")
                }

                if let thinkingInfo = vm.currentModelThinkingInfo {
                    Section("Thinking") {
                        StatRow(label: "Thinking", value: thinkingInfo.enabled ? "On" : "Off", icon: "lightbulb", customIcon: Image("ThinkingIcon"))
                        if thinkingInfo.enabled {
                            StatRow(label: "Level", value: thinkingInfo.level, icon: "slider.horizontal.3")
                        }
                        StatRow(label: "Supported", value: thinkingInfo.supported ? "Yes" : "No", icon: "checkmark.circle")
                    }
                }

                Section("Agent Loop") {
                    StatRow(label: "Total Loops", value: "\(s.loopCount)", icon: "repeat")
                }
            }
            .navigationTitle("Session Token Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func formatted(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

/// 查询状态只刷新费用分区；凭据变化与页面退出由 task 生命周期取消旧请求。
private struct SessionBillingSection: View {
    @ObservedObject var vm: AIChatViewModel
    @ObservedObject private var providers = ProviderConfigStore.shared
    @StateObject private var balance = DeepSeekBalanceModel()
    @State private var refreshRevision = 0

    private struct QueryIdentity: Hashable {
        let account: DeepSeekAccountIdentity?
        let sessionID: String?
        let refresh: Int
    }

    var body: some View {
        let account = vm.deepSeekAccountIdentity
        let query = QueryIdentity(account: account, sessionID: vm.sessionId, refresh: refreshRevision)
        Section {
            StatRow(label: "Estimated Session Cost", value: account == nil ? "—" : money(vm.sessionCostSummary?.estimatedAmountCNY), icon: "yensign.circle")
            StatRow(label: "Account Balance", value: balance.isCurrent(account) ? money(balance.amountCNY) : "—", icon: "creditcard")
        } header: {
            Text("Fees and Balance")
        } footer: {
            if account != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Estimated in CNY from this session's recorded chat requests, including tool loops. Excludes title generation, compaction and other tool services. Unavailable when usage or pricing is incomplete.")
                    HStack {
                        if balance.isCurrent(account) && balance.isLoading {
                            Text("Fetching balance…")
                        } else if balance.isCurrent(account) && balance.hasFailed {
                            Text("CNY balance unavailable")
                        } else if balance.isCurrent(account), let date = balance.updatedAt {
                            Text("Balance updated")
                            Text(date, style: .time)
                        }
                        Spacer()
                        Button("Refresh Balance") { refreshRevision &+= 1 }
                            .disabled(balance.isLoading)
                    }
                }
            }
        }
        .task(id: query) {
            // 读取 revisions 让修改 Key / Provider 的同页状态及时失效。
            _ = providers.authRevision
            _ = providers.configRevision
            await balance.refresh(identity: account, force: refreshRevision > 0) {
                vm.deepSeekBalanceKey(for: account)
            }
        }
    }

    private func money(_ amount: Decimal?) -> String {
        guard let amount else { return "—" }
        if amount > 0 && amount < Decimal(string: "0.0001")! { return "<¥0.0001" }
        return Self.currencyFormatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.currencyCode = "CNY"
        formatter.currencySymbol = "¥"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter
    }()
}

private struct StatRow: View {
    let label: LocalizedStringKey
    let value: String
    let icon: String
    var customIcon: Image?

    var body: some View {
        HStack {
            if let customIcon {
                Label {
                    Text(label)
                } icon: {
                    customIcon
                        .resizable()
                        .frame(width: 14, height: 14)
                }
            } else {
                Label(label, systemImage: icon)
            }
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
