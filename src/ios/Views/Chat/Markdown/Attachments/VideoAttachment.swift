//
//  VideoAttachment.swift
//  MinisX - Markdown 渲染模块（Views/Chat/Markdown）
//
//  层级：Attachments
//
//  Markdown 视频链接：缩略图卡片。点击由 Media/MediaPreviewPresentation.swift
//  里的 VideoTapGesture 处理。
//
//  模块地图与约定：Bridge/SelectableMarkdownView.swift。
//

import AVFoundation
import Combine
import CoreText
import Photos
import SwiftUI
import UIKit

// MARK: - Video Attachment

final class VideoAttachment: NSTextAttachment {
    let source: String
    let theme: SelectableMarkdownTheme
    private(set) var thumbnail: UIImage?
    private var isLoading = false
    private var resolvedURL: URL?
    var onLoad: (() -> Void)?

    init(source: String, theme: SelectableMarkdownTheme) {
        self.source = source
        self.theme = theme
        super.init(data: nil, ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    private static let placeholderHeight: CGFloat = 200

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = min(lineFrag.width, 400)
        if let thumb = thumbnail {
            let aspect = thumb.size.height / max(thumb.size.width, 1)
            let h = min(width * aspect, UIScreen.main.bounds.height / 2)
            // +24 for filename label below
            return CGRect(x: 0, y: 0, width: lineFrag.width, height: h + 24)
        }
        // [T-ios-video-squish] No thumbnail yet — use the recorded display
        // size (track-metadata probe or a previous run's thumbnail) so a
        // portrait video's placeholder already has the right aspect ratio
        // instead of the fixed 200pt box. Mirrors ImageAttachment's
        // recorded-size fallback (8f9ffc437).
        if let known = NativeMediaImageCache.shared.size(forSource: source),
           known.width > 0 {
            let aspect = known.height / known.width
            let h = min(width * aspect, UIScreen.main.bounds.height / 2)
            return CGRect(x: 0, y: 0, width: lineFrag.width, height: h + 24)
        }
        return CGRect(x: 0, y: 0, width: lineFrag.width, height: Self.placeholderHeight)
    }

    func beginLoadingIfNeeded() {
        guard thumbnail == nil, !isLoading else { return }
        isLoading = true

        let src = source
        Task.detached(priority: .userInitiated) {
            var fileURL: URL?
            if let url = URL(string: src), url.scheme == "minis" {
                fileURL = resolveMinisFileURLForNativeText(url: url)
            } else if let url = URL(string: src) {
                fileURL = url
            }

            guard let fileURL else {
                await MainActor.run { self.isLoading = false }
                return
            }

            // Check thumbnail cache
            let cacheKey = fileURL.path
            if let cached = NativeMediaImageCache.shared.image(for: "thumb:" + cacheKey) {
                await MainActor.run {
                    self.thumbnail = cached
                    self.resolvedURL = fileURL
                    self.isLoading = false
                    self.onLoad?()
                    // Cell-side height re-measure: attachmentBounds now returns
                    // aspect-fit height instead of the 200pt placeholder, so
                    // the surrounding cell must invalidate its cached height.
                    // Without this, the cell stays at the placeholder height
                    // until some unrelated event (scroll, reconfigure) forces
                    // a re-measure (the "appears half-rendered, then snaps
                    // 10s later" bug).
                    NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: src)
                }
                return
            }

            let asset = AVAsset(url: fileURL)

            // [T-ios-video-squish] Probe the video track's display size BEFORE
            // generating the thumbnail. Track metadata (naturalSize +
            // preferredTransform) is read from the container header — far
            // lighter than AVAssetImageGenerator, which spins up a decoder for
            // a real frame. Recording it now lets attachmentBounds return the
            // true aspect ratio while the (slow) thumbnail is still cooking —
            // the 8f9ffc437 header-probe idea applied to video. Orientation is
            // handled by applying preferredTransform (portrait phone captures
            // store a landscape naturalSize + 90° transform).
            if NativeMediaImageCache.shared.size(forSource: src) == nil,
               let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                let displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))
                if displaySize.width > 0, displaySize.height > 0 {
                    NativeMediaImageCache.shared.recordSize(displaySize, forSource: src)
                    imgLogger.info("[MinisVideo][Probe] track size=\(Int(displaySize.width))x\(Int(displaySize.height)) src=\(src) — publishing before thumbnail generation")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: src)
                    }
                }
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)

            var thumb: UIImage?
            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                thumb = UIImage(cgImage: cgImage)
            } catch {
                // Fallback: no thumbnail
            }

            if let thumb {
                NativeMediaImageCache.shared.set(thumb, for: "thumb:" + cacheKey)
                // Durable size record (the in-memory thumb cache dies on cold
                // start; the recorded size persists in UserDefaults). Also
                // covers assets whose track probe failed.
                NativeMediaImageCache.shared.recordSize(thumb.size, forSource: src)
            }

            await MainActor.run {
                self.thumbnail = thumb
                self.resolvedURL = fileURL
                self.isLoading = false
                self.onLoad?()
                if thumb != nil {
                    NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: src)
                }
            }
        }
    }

    func makeView(width: CGFloat) -> UIView {
        let maxW = min(width, 400)
        if let thumb = thumbnail {
            return makeThumbnailView(thumb, maxWidth: maxW, totalWidth: width)
        } else {
            return makePlaceholderView(maxWidth: maxW, totalWidth: width)
        }
    }

    private func makeThumbnailView(_ thumb: UIImage, maxWidth: CGFloat, totalWidth: CGFloat) -> UIView {
        let aspect = thumb.size.height / max(thumb.size.width, 1)
        let h = min(maxWidth * aspect, UIScreen.main.bounds.height / 2)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: totalWidth, height: h + 24))
        container.backgroundColor = .clear

        let thumbView = UIImageView(image: thumb)
        thumbView.contentMode = .scaleAspectFill
        thumbView.frame = CGRect(x: 0, y: 0, width: maxWidth, height: h)
        thumbView.layer.cornerRadius = 8
        thumbView.clipsToBounds = true
        container.addSubview(thumbView)

        // Dark overlay
        let overlay = UIView(frame: thumbView.frame)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        overlay.layer.cornerRadius = 8
        overlay.clipsToBounds = true
        container.addSubview(overlay)

        // Play icon
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let playIcon = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig))
        playIcon.tintColor = .white.withAlphaComponent(0.9)
        playIcon.sizeToFit()
        playIcon.center = CGPoint(x: maxWidth / 2, y: h / 2)
        container.addSubview(playIcon)

        // Filename label with film icon
        let filename = source.components(separatedBy: "/").last ?? source
        let filmIconCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let filmIcon = UIImageView(image: UIImage(systemName: "film", withConfiguration: filmIconCfg))
        filmIcon.tintColor = .secondaryLabel
        filmIcon.frame = CGRect(x: 0, y: h + 6, width: 14, height: 12)
        container.addSubview(filmIcon)

        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = CGRect(x: 18, y: h + 4, width: maxWidth - 18, height: 16)
        container.addSubview(label)

        // Tap to play
        container.isUserInteractionEnabled = true
        let tap = VideoTapGesture(target: nil, action: nil)
        tap.fileURL = resolvedURL
        tap.addTarget(tap, action: #selector(VideoTapGesture.handleTap))
        container.addGestureRecognizer(tap)

        return container
    }

    private func makePlaceholderView(maxWidth: CGFloat, totalWidth: CGFloat) -> UIView {
        let h = Self.placeholderHeight
        let container = UIView(frame: CGRect(x: 0, y: 0, width: totalWidth, height: h))

        let bg = UIView(frame: CGRect(x: 0, y: 0, width: maxWidth, height: h))
        bg.backgroundColor = .secondarySystemBackground
        bg.layer.cornerRadius = 8
        bg.clipsToBounds = true
        container.addSubview(bg)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let icon = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig))
        icon.tintColor = .tertiaryLabel
        icon.sizeToFit()
        icon.center = CGPoint(x: bg.bounds.midX, y: bg.bounds.midY - 12)
        bg.addSubview(icon)

        let filename = source.components(separatedBy: "/").last ?? source
        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = CGRect(x: 8, y: icon.frame.maxY + 8, width: bg.bounds.width - 16, height: 16)
        bg.addSubview(label)

        return container
    }
}
