import Foundation
import XCTest
@testable import Minis

/// 从同步类型注册表生成 CloudKit 数据结构，与仓库中的 `src/ios/CloudKit/MinisX.ckdb` 比较
/// （Spec：ios-sync-and-conflict-resolution S1–S4）。
///
/// TestFlight 构建使用 Production 环境，那里不会自动创建记录类型和字段；
/// 漏掉一个字段，这种记录在 Production 中就全部保存失败。新增或修改同步字段后，
/// 本测试失败并打印生成文件的路径，把它复制到仓库即可更新。
final class CloudKitSchemaTests: XCTestCase {

    /// 附件字段由 hydrator 加入 PortableRecord.assets，不在注册表的 fieldKinds 中
    /// （ChatStoreSyncHydrators：SessionFile 的 "asset"、Skill 的 "bundleAsset"）。
    /// applyPortable 为每个附件写入 <名>、<名>_size、<名>_mime 三个字段。
    private static let assetFields: [String: [String]] = [
        "SessionFileV2": ["asset"],
        "SkillV2": ["bundleAsset"],
    ]

    /// 与 ICloudSharedZoneTransport.fetchRecentV2 中的 typesAndKeys 保持一致：
    /// 这些日期字段被用作查询条件和排序，必须可查询、可排序。
    private static let recentQueryDateKeys: [String: String] = [
        "SessionV2": "createdAt",
        "MessageV2": "createdAt",
        "CompactMarkerV2": "createdAt",
        "SessionFileV2": "updatedAt",
        "FolderV2": "updatedAt",
        "SkillV2": "updatedAt",
        "ProviderConfigV2": "updatedAt",
        "ProviderInstanceV3": "updatedAt",
        "ProviderModelEntryV3": "updatedAt",
        "ProviderModelGroupV3": "updatedAt",
        "ProviderThinkingRuleV3": "updatedAt",
        "MCPServersV2": "updatedAt",
        "MCPServerItem": "updatedAt",
        "EnvVarItem": "updatedAt",
        "SoulV2": "updatedAt",
        "MemoryGlobalV2": "updatedAt",
        "MemoryDailyV2": "updatedAt",
    ]

    /// fetchSessionPortables 按 sessionId 查询这三种类型。
    private static let sessionIdQueryTypes: Set<String> = ["SessionV2", "MessageV2", "CompactMarkerV2"]

    private static var schemaURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CloudKit/MinisX.ckdb")
    }

    func testCommittedSchemaMatchesRegistry() throws {
        let generated = try Self.generateSchema()
        let committed = try? String(contentsOf: Self.schemaURL, encoding: .utf8)
        if committed != generated {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("MinisX.ckdb")
            try generated.write(to: out, atomically: true, encoding: .utf8)
            XCTFail("MinisX.ckdb 与注册表不一致。生成的文件：\(out.path)，复制到 \(Self.schemaURL.path) 后重新部署（Spec S5）。")
        }
    }

    // MARK: - 生成

    private static func generateSchema() throws -> String {
        SyncedTypesBootstrap.registerAll()
        let registry = SyncableTypeRegistry.shared
        let types = registry.allRecordTypes.sorted()

        // 查询用到的类型和字段必须在注册表中，否则索引写到了不存在的字段上。
        for (type, key) in recentQueryDateKeys {
            let keys = registry.metadata(for: type)?.fieldKinds.map(\.cloudKey) ?? []
            XCTAssertTrue(keys.contains(key), "\(type) 没有查询用的日期字段 \(key)")
        }
        for type in sessionIdQueryTypes {
            let keys = registry.metadata(for: type)?.fieldKinds.map(\.cloudKey) ?? []
            XCTAssertTrue(keys.contains("sessionId"), "\(type) 没有查询用的 sessionId 字段")
        }

        // 记录类型按名字排序（含 Users），与 cktool export-schema 的输出顺序一致，便于逐行比较。
        var blocks: [(name: String, text: String)] = [("Users", usersBlock)]
        for type in types {
            guard let meta = registry.metadata(for: type) else { continue }
            var fields: [String: String] = [:]
            for f in meta.fieldKinds {
                fields[f.cloudKey] = try cloudKitType(of: f.kind, type: type, key: f.cloudKey)
            }
            for name in assetFields[type] ?? [] {
                fields[name] = "ASSET"
                fields[name + "_size"] = "INT64"
                fields[name + "_mime"] = "STRING"
            }
            fields["syncSchemaVersion"] = "INT64"
            fields["syncMinimumCompatibleVersion"] = "INT64"
            if let key = recentQueryDateKeys[type] { fields[key, default: ""] += " QUERYABLE SORTABLE" }
            if sessionIdQueryTypes.contains(type) { fields["sessionId", default: ""] += " QUERYABLE" }

            var lines = systemFields
            lines += fields.keys.sorted().map { "\"\($0)\" \(fields[$0]!)" }
            lines += ["GRANT WRITE TO \"_creator\"", "GRANT CREATE TO \"_icloud\"", "GRANT READ TO \"_world\""]
            blocks.append((type, recordType(type, lines)))
        }
        let ordered = blocks.sorted { $0.name < $1.name }.map(\.text)
        return "DEFINE SCHEMA\n\n" + ordered.joined(separator: "\n\n") + "\n"
    }

    /// 映射见 Spec S2。只列出注册表实际用到的 kind；出现新 kind 时先补映射。
    private static func cloudKitType(of kind: FieldKind, type: String, key: String) throws -> String {
        switch kind {
        case .string: return "STRING"
        case .int:    return "INT64"
        case .date:   return "TIMESTAMP"
        default:
            throw NSError(domain: "CloudKitSchemaTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(type).\(key) 的 kind \(kind) 没有 CloudKit 映射，先补 Spec S2",
            ])
        }
    }

    /// 系统字段。记录名（___recordID）可查询：MigrationEngine 用 TRUEPREDICATE 查询 SessionV2。
    private static let systemFields = [
        "\"___createTime\" TIMESTAMP",
        "\"___createdBy\" REFERENCE",
        "\"___etag\" STRING",
        "\"___modTime\" TIMESTAMP",
        "\"___modifiedBy\" REFERENCE",
        "\"___recordID\" REFERENCE QUERYABLE",
    ]

    /// 系统记录类型 Users，原样取自空容器导出的数据结构。
    private static let usersBlock = recordType("Users", [
        "\"___createTime\" TIMESTAMP",
        "\"___createdBy\" REFERENCE",
        "\"___etag\" STRING",
        "\"___modTime\" TIMESTAMP",
        "\"___modifiedBy\" REFERENCE",
        "\"___recordID\" REFERENCE",
        "roles LIST<INT64>",
        "GRANT WRITE TO \"_creator\"",
        "GRANT READ TO \"_world\"",
    ])

    private static func recordType(_ name: String, _ lines: [String]) -> String {
        "    RECORD TYPE \(name) (\n" + lines.map { "        \($0)" }.joined(separator: ",\n") + "\n    );"
    }
}
