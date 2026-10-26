//
//  MarkdownUIKitHelpers.swift
//  MinisX - Markdown 渲染模块（Views/Chat/Markdown）
//
//  层级：Support
//
//  模块内共用的小扩展：UIFont.withTraits（粗体 / 斜体）、[InlineNode].plainText
//  （行内节点拍平成纯文本）。UIView 的响应链辅助方法留在
//  Media/MediaPreviewPresentation.swift，原因见该文件头注释。
//
//  模块地图与约定：Bridge/SelectableMarkdownView.swift。
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - UIFont+Traits

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = fontDescriptor.withSymbolicTraits(combined) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}

// MARK: - InlineNode Plain Text Helper

extension Array where Element == InlineNode {
    var plainText: String {
        map { node -> String in
            switch node {
            case .text(let t): return t
            case .code(let c): return c
            case .emphasis(let ch), .strong(let ch), .strikethrough(let ch): return ch.plainText
            case .link(_, let ch), .image(_, let ch): return ch.plainText
            case .softBreak: return " "
            case .lineBreak: return "\n"
            case .html(let h): return h
            case .inlineMath(let latex): return latex
            }
        }.joined()
    }
}
