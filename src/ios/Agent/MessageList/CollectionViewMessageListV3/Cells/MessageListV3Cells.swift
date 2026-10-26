//
//  MessageListV3Cells.swift
//  Minis - V3 聊天消息列表（Agent/MessageList/CollectionViewMessageListV3）
//
//  每种行类型一个 SelfSizingCell 子类，使 UICollectionView 只在同类内容间复用 cell。
//
//  文件地图与拆分规则：CollectionViewMessageListV3.swift（本目录）。
//

import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

// MARK: - Per-type Cell Subclasses (enable correct reuse)

final class WholeMessageCellV3: SelfSizingCell {}
final class AssistantHeaderCellV3: SelfSizingCell {}
final class AssistantBlockCellV3: SelfSizingCell {}
final class AssistantFooterCellV3: SelfSizingCell {}
