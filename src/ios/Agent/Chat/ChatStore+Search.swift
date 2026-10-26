//
//  ChatStore+Search.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  按关键词搜索会话（searchSessions）。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

extension ChatStore {

    /// Search sessions by keyword across title and message text content.
    /// Returns matching sessions with a snippet of the first matching message (if matched in messages).
    struct SearchResult {
        let session: ChatSession
        /// The matched text snippet from messages, or nil if only title matched.
        let matchSnippet: String?
        /// Whether the title matched the query.
        let titleMatched: Bool
    }

    func searchSessions(query: String) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        let likePattern = "%\(query)%"
        // Find sessions where title matches OR any message text contains the query
        let sql = """
            SELECT DISTINCT s.id, s.title, s.model_id, s.created_at, s.updated_at, s.category,
                   (SELECT m2.parts_json FROM messages m2
                    WHERE m2.session_id = s.id AND m2.parts_json LIKE ?
                    ORDER BY m2.sort_order DESC LIMIT 1)
            FROM sessions s
            LEFT JOIN messages m ON m.session_id = s.id
            WHERE s.title LIKE ? OR m.parts_json LIKE ?
            GROUP BY s.id
            ORDER BY s.updated_at DESC
            """
        var stmt: OpaquePointer?
        var results: [SearchResult] = []

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (likePattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (likePattern as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (likePattern as NSString).utf8String, -1, nil)

            let lowerQuery = query.lowercased()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let modelId = String(cString: sqlite3_column_text(stmt, 2))
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let category = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let matchedPartsJSON = sqlite3_column_text(stmt, 6).map { String(cString: $0) }

                let titleMatched = title?.lowercased().contains(lowerQuery) == true
                let snippet = matchedPartsJSON.flatMap { extractTextFromPartsJSON($0) }

                let session = ChatSession(
                    id: id, title: title, category: category, modelId: modelId,
                    createdAt: createdAt, updatedAt: updatedAt, lastMessage: snippet
                )
                results.append(SearchResult(session: session, matchSnippet: snippet, titleMatched: titleMatched))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
}
