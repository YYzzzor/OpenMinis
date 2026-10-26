//
//  MinisToast.swift
//  MinisX - Markdown 渲染模块（Views/Chat/Markdown）
//
//  层级：Support
//
//  全应用共用的一次性 toast（"Saved"、"Table copied" 等），不限于 Markdown。
//  它诞生在 SelectableMarkdownView.swift（表格复制是最早的使用者），所以放在这里。
//
//  模块地图与约定：Bridge/SelectableMarkdownView.swift。
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - MinisToast

/// [T-toast-feedback] Lightweight, self-dismissing toast for one-shot action
/// feedback ("Saved", "Table copied", …). Window-level so it works from both
/// SwiftUI screens and UIKit views (e.g. the markdown table copy actions,
/// which run in a UILabel subclass with no SwiftUI context). Mirrors the
/// capsule style FileBrowserView already uses for its "Copied" toast.
enum MinisToast {
    /// Show a toast with an already-localized message. Safe from any thread.
    /// `systemImage` sets the leading icon (default: success checkmark); pass an
    /// error glyph like "exclamationmark.triangle.fill" for failures.
    static func show(_ message: String, duration: TimeInterval = 1.6,
                     systemImage: String = "checkmark.circle.fill") {
        if Thread.isMainThread {
            present(message, duration: duration, systemImage: systemImage)
        } else {
            DispatchQueue.main.async { present(message, duration: duration, systemImage: systemImage) }
        }
    }

    private static func present(_ message: String, duration: TimeInterval,
                                systemImage: String = "checkmark.circle.fill") {
        guard let window = keyWindow() else { return }

        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false

        let check = UIImageView(image: UIImage(systemName: systemImage))
        check.tintColor = .white
        check.contentMode = .scaleAspectFit
        check.translatesAutoresizingMaskIntoConstraints = false

        let capsule = UIView()
        capsule.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        capsule.layer.cornerRadius = 18
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.alpha = 0

        capsule.addSubview(check)
        capsule.addSubview(label)
        window.addSubview(capsule)

        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 16),
            check.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 16),
            check.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -10),
            capsule.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            capsule.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.bottomAnchor, constant: -48),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: window.leadingAnchor, constant: 24),
            capsule.trailingAnchor.constraint(lessThanOrEqualTo: window.trailingAnchor, constant: -24),
        ])

        UIView.animate(withDuration: 0.25) { capsule.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: duration, options: [.curveEaseIn]) {
            capsule.alpha = 0
        } completion: { _ in
            capsule.removeFromSuperview()
        }
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }
}
