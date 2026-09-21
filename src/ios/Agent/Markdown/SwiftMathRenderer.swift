import SwiftMath
import UIKit

private let logger = AppLogger(category: "SwiftMathRenderer")

/// Renders LaTeX math formulas to UIImage using SwiftMath (pure native, no WebView).
enum SwiftMathRenderer {

    /// LRU-style cache keyed by "D:<latex>" or "I:<latex>".
    private static let cache = NSCache<NSString, SwiftMathRenderResult>()
    private static let cacheSetup: Void = { cache.countLimit = 256 }()

    /// Render a LaTeX formula synchronously. Returns nil on parse error.
    static func render(latex: String, displayMode: Bool, fontSize: CGFloat = 17) -> SwiftMathRenderResult? {
        _ = cacheSetup

        let key = cacheKey(latex: latex, displayMode: displayMode, fontSize: fontSize) as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let preprocessed = preprocessLatex(latex)

        // Use MTMathUILabel for rendering — more reliable on iOS 18 than MTMathImage.
        let label = MTMathUILabel()
        label.latex = preprocessed
        label.fontSize = fontSize
        label.textColor = UIColor.label
        label.labelMode = displayMode ? .display : .text
        label.textAlignment = displayMode ? .center : .left
        label.backgroundColor = .clear

        // Check for parse errors before rendering.
        if let error = label.error {
            logger.warning("parse error for '\(latex.prefix(60))': \(error.localizedDescription)")
            return nil
        }

        // Force layout to get intrinsic size.
        label.sizeToFit()
        let size = label.intrinsicContentSize
        guard size.width > 0, size.height > 0 else {
            logger.warning("zero size for '\(latex.prefix(60))'")
            return nil
        }

        // Add horizontal padding — MTMathUILabel.intrinsicContentSize sometimes
        // underreports width, causing inline formulas to overlap with following text.
        let hPad: CGFloat = 4
        let pixelSize = CGSize(width: ceil(size.width + hPad), height: ceil(size.height))
        label.frame = CGRect(origin: .zero, size: pixelSize)

        // Render the label to an image.
        // MTMathUILabel draws in a flipped CG coordinate system, so
        // we flip the context before rendering via the CALayer.
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.saveGState()
            cgCtx.translateBy(x: 0, y: pixelSize.height)
            cgCtx.scaleBy(x: 1, y: -1)
            label.layer.render(in: cgCtx)
            cgCtx.restoreGState()
        }

        let result = SwiftMathRenderResult(image: image, size: pixelSize)
        cache.setObject(result, forKey: key)
        return result
    }

    // MARK: - Internal

    private static func cacheKey(latex: String, displayMode: Bool, fontSize: CGFloat) -> String {
        (displayMode ? "D:" : "I:") + "\(Int(fontSize)):" + latex
    }

    /// Normalize LaTeX commands that SwiftMath doesn't support well.
    private static func preprocessLatex(_ latex: String) -> String {
        var s = latex
            .trimmingCharacters(in: .whitespacesAndNewlines)

        s = s.replacingOccurrences(of: "\\dots", with: "\\ldots")
        s = s.replacingOccurrences(of: "\\implies", with: "\\Rightarrow")
        s = s.replacingOccurrences(of: "\\iff", with: "\\Leftrightarrow")
        s = s.replacingOccurrences(of: "\\dfrac", with: "\\frac")
        s = s.replacingOccurrences(of: "\\tfrac", with: "\\frac")
        s = s.replacingOccurrences(of: "\\begin{align}", with: "\\begin{aligned}")
        s = s.replacingOccurrences(of: "\\end{align}", with: "\\end{aligned}")
        s = s.replacingOccurrences(of: "\\begin{align*}", with: "\\begin{aligned}")
        s = s.replacingOccurrences(of: "\\end{align*}", with: "\\end{aligned}")
        s = s.replacingOccurrences(of: "\\begin{gather}", with: "\\begin{gathered}")
        s = s.replacingOccurrences(of: "\\end{gather}", with: "\\end{gathered}")
        s = s.replacingOccurrences(of: "\\begin{gather*}", with: "\\begin{gathered}")
        s = s.replacingOccurrences(of: "\\end{gather*}", with: "\\end{gathered}")
        s = s.replacingOccurrences(of: "\\text{", with: "\\mathrm{")
        s = s.replacingOccurrences(of: "\\textbf{", with: "\\mathbf{")
        s = s.replacingOccurrences(of: "\\operatorname{", with: "\\mathrm{")
        s = s.replacingOccurrences(of: "\\bold{", with: "\\mathbf{")
        s = s.replacingOccurrences(of: "\\displaystyle", with: "")

        return s
    }

    // MARK: - Unicode Fallback

    /// Render a LaTeX formula to UIImage by converting to Unicode text
    /// and drawing with the system font. Handles CJK inside \text{} and
    /// common math operators that SwiftMath's Latin Modern font can't show.
    static func renderFallback(latex: String, displayMode: Bool, fontSize: CGFloat = 17) -> SwiftMathRenderResult? {
        let key = ("F:" + cacheKey(latex: latex, displayMode: displayMode, fontSize: fontSize)) as NSString
        if let cached = cache.object(forKey: key) { return cached }

        guard let attributed = fallbackAttributedString(latex: latex, fontSize: fontSize) else {
            return nil
        }

        let constraintWidth: CGFloat = displayMode ? 600 : 2000
        let boundingRect = attributed.boundingRect(
            with: CGSize(width: constraintWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let pixelSize = CGSize(width: ceil(boundingRect.width) + 4, height: ceil(boundingRect.height) + 2)
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        let image = renderer.image { _ in
            // baselineOffset 可能让排版边界出现负原点；按实际边界平移后再绘制，
            // 避免上标顶部或下标底部被图片边缘裁切。
            let drawRect = CGRect(
                x: 2 - boundingRect.minX,
                y: 1 - boundingRect.minY,
                width: boundingRect.width,
                height: boundingRect.height
            )
            attributed.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
        }
        let result = SwiftMathRenderResult(image: image, size: pixelSize)
        cache.setObject(result, forKey: key)
        return result
    }

    /// 构造 Unicode fallback 的最终排版结果。保留为模块内可见，便于测试在
    /// SwiftMath 失败时真正使用的字号和基线属性，而不是只比较转换后的字符串。
    static func fallbackAttributedString(latex: String, fontSize: CGFloat = 17) -> NSAttributedString? {
        let unicode = latexToUnicode(latex)
        guard !unicode.isEmpty else { return nil }

        let textFont = UIFont.systemFont(ofSize: fontSize)
        let mathFont = UIFont(name: "STIXTwoMath-Regular", size: fontSize) ?? textFont
        let result = buildAttributedString(unicode, textFont: textFont, mathFont: mathFont)
        return result.length > 0 ? result : nil
    }

    private enum ScriptPosition {
        case superscript
        case subscripted
    }

    private static let fallbackLiteralUnderscore: Character = "\u{E000}"
    private static let fallbackLiteralCaret: Character = "\u{E001}"
    private static let fallbackTextGroupStart: Character = "\u{E002}"
    private static let fallbackTextGroupEnd: Character = "\u{E003}"

    private static func buildAttributedString(_ text: String, textFont: UIFont, mathFont: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let textColor = UIColor.label
        let chars = Array(text)
        var index = 0

        while index < chars.count {
            let ch = chars[index]

            // 转义后的脚本标记和花括号是普通字符，不参与 fallback 结构解析。
            if ch == "\\", index + 1 < chars.count,
               isFallbackEscapedLiteral(chars[index + 1]) {
                appendFallbackCharacter(
                    chars[index + 1],
                    position: nil,
                    to: result,
                    textFont: textFont,
                    mathFont: mathFont,
                    textColor: textColor
                )
                index += 2
                continue
            }

            if ch == "^" || ch == "_" {
                let position: ScriptPosition = ch == "^" ? .superscript : .subscripted
                let parsed = parseScriptGroup(chars, startingAt: index + 1)
                if !parsed.text.isEmpty {
                    appendFallbackText(
                        parsed.text,
                        position: position,
                        to: result,
                        textFont: textFont,
                        mathFont: mathFont,
                        textColor: textColor
                    )
                }
                // 即使脚本为空或标记位于末尾，也要消费语法字符，避免重新显示 ^/_。
                index = parsed.nextIndex
                continue
            }

            if ch == fallbackTextGroupStart || ch == fallbackTextGroupEnd {
                index += 1
                continue
            }

            // 非脚本分组的花括号只是 LaTeX 结构字符，不显示到 fallback 中。
            if ch != "{" && ch != "}" {
                appendFallbackText(
                    String(ch),
                    position: nil,
                    to: result,
                    textFont: textFont,
                    mathFont: mathFont,
                    textColor: textColor
                )
            }
            index += 1
        }
        return result
    }

    private static func parseScriptGroup(_ chars: [Character], startingAt start: Int) -> (text: String, nextIndex: Int) {
        var operandStart = start
        while operandStart < chars.count, chars[operandStart].isWhitespace {
            operandStart += 1
        }
        guard operandStart < chars.count else { return ("", operandStart) }
        if chars[operandStart] == "\\", operandStart + 1 < chars.count,
           isFallbackEscapedLiteral(chars[operandStart + 1]) {
            return (String(chars[operandStart...operandStart + 1]), operandStart + 2)
        }
        if chars[operandStart] == fallbackTextGroupStart {
            var index = operandStart + 1
            var text = ""
            while index < chars.count, chars[index] != fallbackTextGroupEnd {
                text.append(chars[index])
                index += 1
            }
            if index < chars.count { index += 1 }
            return (text, index)
        }
        guard chars[operandStart] == "{" else {
            return (String(chars[operandStart]), operandStart + 1)
        }

        var depth = 1
        var index = operandStart + 1
        var text = ""
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count,
               isFallbackEscapedLiteral(chars[index + 1]) {
                text.append(ch)
                text.append(chars[index + 1])
                index += 2
                continue
            }
            if ch == "{" {
                depth += 1
                if depth > 1 { text.append(ch) }
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return (text, index + 1) }
                text.append(ch)
            } else {
                text.append(ch)
            }
            index += 1
        }

        // 未闭合分组按剩余内容排版；主渲染已经失败时仍尽量给出可读结果。
        return (text, index)
    }

    private static func appendFallbackText(
        _ text: String,
        position: ScriptPosition?,
        to result: NSMutableAttributedString,
        textFont: UIFont,
        mathFont: UIFont,
        textColor: UIColor
    ) {
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count,
               isFallbackEscapedLiteral(chars[index + 1]) {
                appendFallbackCharacter(
                    chars[index + 1],
                    position: position,
                    to: result,
                    textFont: textFont,
                    mathFont: mathFont,
                    textColor: textColor
                )
                index += 2
                continue
            }
            if ch == "^" || ch == "_" {
                let nested = parseScriptGroup(chars, startingAt: index + 1)
                if !nested.text.isEmpty {
                    appendFallbackText(
                        nested.text,
                        position: position,
                        to: result,
                        textFont: textFont,
                        mathFont: mathFont,
                        textColor: textColor
                    )
                }
                index = nested.nextIndex
                continue
            }
            if ch != "{" && ch != "}" {
                appendFallbackCharacter(
                    ch,
                    position: position,
                    to: result,
                    textFont: textFont,
                    mathFont: mathFont,
                    textColor: textColor
                )
            }
            index += 1
        }
    }

    private static func appendFallbackCharacter(
        _ character: Character,
        position: ScriptPosition?,
        to result: NSMutableAttributedString,
        textFont: UIFont,
        mathFont: UIFont,
        textColor: UIColor
    ) {
        let visibleCharacter: Character
        switch character {
        case fallbackLiteralUnderscore:
            visibleCharacter = "_"
        case fallbackLiteralCaret:
            visibleCharacter = "^"
        default:
            visibleCharacter = character
        }

        for scalar in visibleCharacter.unicodeScalars {
            let baseFont = scalar.properties.isAlphabetic && !scalar.properties.isMath
                ? textFont
                : mathFont
            var attributes: [NSAttributedString.Key: Any] = [
                .font: baseFont,
                .foregroundColor: textColor,
            ]
            if let position {
                attributes[.font] = baseFont.withSize(baseFont.pointSize * 0.72)
                attributes[.baselineOffset] = position == .superscript
                    ? baseFont.pointSize * 0.38
                    : -baseFont.pointSize * 0.22
            }
            result.append(NSAttributedString(string: String(scalar), attributes: attributes))
        }
    }

    private static func isFallbackEscapedLiteral(_ character: Character) -> Bool {
        character == "_" || character == "^" || character == "{" || character == "}" || character == "\\"
    }

    /// Convert common LaTeX to Unicode text. Not exhaustive — covers the
    /// operators, Greek letters, and \text{} that appear in everyday formulas.
    private static func latexToUnicode(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip \text{...} / \textbf{...} / \mathrm{...} / \operatorname{...} wrappers, keep content
        let textPattern = try! NSRegularExpression(pattern: #"\\(?:text|textbf|mathrm|operatorname|mathbf|bold)\{([^}]*)\}"#)
        let textMatches = textPattern.matches(in: s, range: NSRange(s.startIndex..., in: s))
        let mutableText = NSMutableString(string: s)
        let sourceText = s as NSString
        for match in textMatches.reversed() where match.numberOfRanges > 1 {
            let content = sourceText.substring(with: match.range(at: 1))
            let protectedContent = protectFallbackTextMarkers(content)
            // 使用不会参与 LaTeX 花括号匹配的内部标记，使 x^\text{hi} 仍把 hi
            // 整体视为上标，同时不干扰后续 \frac 与 \sqrt 的既有转换。
            let grouped = "\(fallbackTextGroupStart)\(protectedContent)\(fallbackTextGroupEnd)"
            mutableText.replaceCharacters(in: match.range, with: grouped)
        }
        s = mutableText as String

        // \frac{a}{b} → a/b
        let fracPattern = try! NSRegularExpression(pattern: #"\\(?:frac|dfrac|tfrac)\{([^}]*)\}\{([^}]*)\}"#)
        s = fracPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1/$2")

        // \sqrt{x} → √x
        let sqrtPattern = try! NSRegularExpression(pattern: #"\\sqrt\{([^}]*)\}"#)
        s = sqrtPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "√($1)")

        let replacements: [(String, String)] = [
            ("\\div", "÷"), ("\\times", "×"), ("\\cdot", "·"),
            ("\\pm", "±"), ("\\mp", "∓"), ("\\leq", "≤"), ("\\geq", "≥"),
            ("\\neq", "≠"), ("\\approx", "≈"), ("\\equiv", "≡"),
            ("\\infty", "∞"), ("\\sum", "∑"), ("\\prod", "∏"),
            ("\\int", "∫"), ("\\partial", "∂"), ("\\nabla", "∇"),
            ("\\forall", "∀"), ("\\exists", "∃"),
            ("\\in", "∈"), ("\\notin", "∉"), ("\\subset", "⊂"), ("\\supset", "⊃"),
            ("\\cup", "∪"), ("\\cap", "∩"),
            ("\\to", "→"), ("\\rightarrow", "→"), ("\\leftarrow", "←"),
            ("\\Rightarrow", "⇒"), ("\\Leftarrow", "⇐"), ("\\Leftrightarrow", "⇔"),
            ("\\implies", "⇒"), ("\\iff", "⇔"),
            ("\\ldots", "…"), ("\\cdots", "⋯"), ("\\vdots", "⋮"),
            ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
            ("\\epsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"), ("\\theta", "θ"),
            ("\\iota", "ι"), ("\\kappa", "κ"), ("\\lambda", "λ"), ("\\mu", "μ"),
            ("\\nu", "ν"), ("\\xi", "ξ"), ("\\pi", "π"), ("\\rho", "ρ"),
            ("\\sigma", "σ"), ("\\tau", "τ"), ("\\upsilon", "υ"), ("\\phi", "φ"),
            ("\\chi", "χ"), ("\\psi", "ψ"), ("\\omega", "ω"),
            ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
            ("\\Xi", "Ξ"), ("\\Pi", "Π"), ("\\Sigma", "Σ"), ("\\Phi", "Φ"),
            ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
            ("\\quad", "  "), ("\\qquad", "    "), ("\\,", " "),
            ("\\;", " "), ("\\!", ""),
            ("\\displaystyle", ""), ("\\left", ""), ("\\right", ""),
            ("\\big", ""), ("\\Big", ""), ("\\bigg", ""), ("\\Bigg", ""),
        ]
        for (cmd, repl) in replacements {
            s = s.replacingOccurrences(of: cmd, with: repl)
        }

        // Strip remaining \command sequences (e.g. \mathrm, \mathbf without braces)
        let cmdPattern = try! NSRegularExpression(pattern: #"\\[a-zA-Z]+"#)
        s = cmdPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")

        let multiSpace = try! NSRegularExpression(pattern: #" {3,}"#)
        s = multiSpace.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "  ")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func protectFallbackTextMarkers(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count {
                result.append(ch)
                result.append(chars[index + 1])
                index += 2
                continue
            }
            if ch == "_" {
                result.append(fallbackLiteralUnderscore)
            } else if ch == "^" {
                result.append(fallbackLiteralCaret)
            } else {
                result.append(ch)
            }
            index += 1
        }
        return result
    }
}

// MARK: - Render Result

final class SwiftMathRenderResult: NSObject {
    let image: UIImage
    let size: CGSize

    init(image: UIImage, size: CGSize) {
        self.image = image
        self.size = size
    }
}
