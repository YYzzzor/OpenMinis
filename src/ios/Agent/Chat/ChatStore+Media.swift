//
//  ChatStore+Media.swift
//  Minis - 聊天持久化（Agent/Chat）
//
//  媒体文件的保存、读取、删除。
//

import Foundation
import SQLite3
import SwiftAnthropic
import UIKit
import os.log

private let logger = AppLogger(category: "ChatStore")

extension ChatStore {

    // MARK: - Media File Management

    /// Save media data to disk, return a MediaRef.
    /// Files are saved to `Library/MinisChat/minis/<sessionId>/<subdir>/<fileId>.<ext>`.
    func saveMedia(
        data: Data, mimeType: String, sessionId: String,
        originalFileName: String? = nil, subdir: String = "attachments",
        linuxPath: String? = nil
    ) -> MediaRef {
        let fileId = UUID().uuidString
        let ext = Self.fileExtension(for: mimeType)

        let relativePath = "\(sessionId)/\(subdir)/\(fileId).\(ext)"
        let fileURL = minisBaseURL.appendingPathComponent(relativePath)

        let dirURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        do {
            try data.write(to: fileURL)
        } catch {
            logger.error("Failed to write media file: \(error)")
        }

        let ref = MediaRef(
            id: fileId,
            relativePath: relativePath,
            mimeType: mimeType,
            originalFileName: originalFileName,
            linuxPath: linuxPath
        )

        // Mark file dirty for iCloud sync via SessionFile record type
        markDirty(recordType: "SessionFile", recordId: "\(sessionId):\(subdir)/\(fileId).\(ext)")

        return ref
    }

    /// Resolve the on-disk URL for a MediaRef.
    func mediaFileURL(for ref: MediaRef) -> URL {
        minisBaseURL.appendingPathComponent(ref.relativePath)
    }

    /// Load media data from a MediaRef.
    func loadMediaData(_ ref: MediaRef) -> Data? {
        let url = mediaFileURL(for: ref)
        return try? Data(contentsOf: url)
    }

    /// Delete all media for a session.
    func deleteSessionMedia(_ sessionId: String) {
        let fm = FileManager.default

        for subdir in ["browser", "attachments", "images"] {
            let dirURL = minisBaseURL.appendingPathComponent("\(sessionId)/\(subdir)")
            if fm.fileExists(atPath: dirURL.path) {
                try? fm.removeItem(at: dirURL)
            }
        }
    }

    /// Returns a closure that resolves a MediaRef to a file URL.
    func mediaFileURLResolver() -> (MediaRef) -> URL {
        let minis = minisBaseURL
        return { ref in
            minis.appendingPathComponent(ref.relativePath)
        }
    }
}
