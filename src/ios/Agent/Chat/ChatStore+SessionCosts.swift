//
//  ChatStore+SessionCosts.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  MinisX 独有：本地会话费用账本（SessionCostLedger）的读写入口。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

extension ChatStore {

    // MARK: - Local Session Costs

    func sessionCostSummary(sessionID: String) -> SessionCostSummary? {
        try? SessionCostLedger.summary(db, sessionID: sessionID)
    }

    func beginSessionCostRequest(_ request: SessionCostRequest) -> Bool {
        (try? SessionCostLedger.begin(db, sessionID: request.sessionID, requestID: request.requestID)) ?? false
    }

    func finishSessionCostRequest(_ request: SessionCostRequest, record: DeepSeekCostRecord) {
        try? SessionCostLedger.finish(db, sessionID: request.sessionID, record: record)
    }
}
