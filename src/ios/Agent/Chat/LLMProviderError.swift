//
//  LLMProviderError.swift
//  Minis - 模型服务商错误（Agent/Chat）
//
//  从 AIChatViewModel.swift 文件末尾逐字移出。
//

import Foundation

enum LLMProviderError: LocalizedError {
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "No API credentials available"
        }
    }
}
