//
//  MarkdownLoggers.swift
//  MinisX - Markdown 渲染模块（Views/Chat/Markdown）
//
//  层级：Support
//
//  模块内共用的日志（渲染器、媒体附件、文本视图）。拆分前是单文件里的文件级
//  private 全局变量；现在使用者分在不同文件，改为 internal。category 不变，
//  已有的日志过滤照常匹配：MinisImage、AttachDebug、MarkdownResponder。
//
//  模块地图与约定：Bridge/SelectableMarkdownView.swift。
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

let imgLogger = AppLogger(category: "MinisImage")
let attachLogger = AppLogger(category: "AttachDebug")
/// [T-ios-resign-first-responder-graph-reentry] Deferred responder-chain walks.
let responderLogger = AppLogger(category: "MarkdownResponder")
