//
//  UIViewHelpers.swift
//  Minis - 聊天页（AIChatView）
//
//  UIView 辅助：沿响应链找最近的 UIViewController。扩展保持 private，
//  因为 SelectableMarkdownView.swift 里有同名的另一个扩展。
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

// MARK: - UIView helpers

private extension UIView {
    /// Walk the responder chain to find the nearest UIViewController.
    var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}
