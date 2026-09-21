import Foundation

enum MathProbe {
    private static func latexToUnicode(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip \text{...} / \textbf{...} / \mathrm{...} / \operatorname{...} wrappers, keep content
        let textPattern = try! NSRegularExpression(pattern: #"\\(?:text|textbf|mathrm|operatorname|mathbf|bold)\{([^}]*)\}"#)
        s = textPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")

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
            // [issue #117-2 follow-up] `\circ` was missing entirely, so the
            // `\command` sweep below deleted it and left `H^\circ` as a bare
            // `H^` — half of the `H^/R` artefact in the user's screenshot.
            // `\deg`/`\prime` are here for the same reason.
            ("\\circ", "°"), ("\\degree", "°"), ("\\deg", "°"),
            ("\\prime", "′"), ("\\angle", "∠"), ("\\perp", "⊥"), ("\\propto", "∝"),
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

        // [issue #117-2 follow-up] Superscripts / subscripts.
        //
        // This used to be two no-ops (`"^" -> "^"`, `"_" -> "_"`), so scripts
        // survived as literal carets and underscores while the brace cleanup
        // just below deleted their grouping. `H^\circ/R\,\text{斜率}` came out
        // as `H^/R_斜率` — unreadable, and `^`/`_` read as division and an
        // underline rather than as scripts.
        //
        // Run BEFORE the brace cleanup: `^{...}` grouping is the only thing
        // that says how far a multi-character script extends, and the two lines
        // below would erase it. Spans are wrapped in private-use sentinels that
        // survive the remaining text passes; `buildAttributedString` turns them
        // into real Unicode script characters where the set covers them, and
        // into baseline-shifted smaller text where it doesn't (CJK, most
        // multi-character spans).
        s = markScripts(in: s)

        // Clean up braces and extra whitespace
        s = s.replacingOccurrences(of: "{", with: "")
        s = s.replacingOccurrences(of: "}", with: "")

        let multiSpace = try! NSRegularExpression(pattern: #" {3,}"#)
        s = multiSpace.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "  ")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Superscript / subscript handling (issue #117-2 follow-up)

    /// Private-use sentinels delimiting a script span. Chosen from the BMP
    /// private-use area so they can't collide with anything a real formula
    /// contains, and so the intervening text passes (command stripping, brace
    /// cleanup, whitespace collapsing) carry them through untouched.
    private static let supOpen: Character = "\u{E000}"
    private static let subOpen: Character = "\u{E001}"
    private static let scriptClose: Character = "\u{E002}"

    /// Rewrite `^{...}` / `_{...}` / `^X` / `_X` into sentinel-delimited spans.
    ///
    /// Scans by hand rather than by regex because the braced form nests
    /// (`^{a^{b}}`) and a regex character class can't match balanced braces.
    /// An unmatched or empty script (a trailing `^`, or `_{}`) is dropped
    /// entirely — a stray caret in the output is exactly the artefact this is
    /// meant to remove.
    private static func markScripts(in input: String) -> String {
        var out = ""
        var i = input.startIndex

        while i < input.endIndex {
            let ch = input[i]
            guard ch == "^" || ch == "_" else {
                out.append(ch)
                i = input.index(after: i)
                continue
            }

            let opener = (ch == "^") ? supOpen : subOpen
            var j = input.index(after: i)
            guard j < input.endIndex else { break }  // trailing '^' / '_' — drop

            if input[j] == "{" {
                // Braced: consume to the matching close brace.
                var depth = 0
                var body = ""
                var closed = false
                while j < input.endIndex {
                    let c = input[j]
                    if c == "{" {
                        depth += 1
                        if depth == 1 { j = input.index(after: j); continue }
                    } else if c == "}" {
                        depth -= 1
                        if depth == 0 { closed = true; j = input.index(after: j); break }
                    }
                    body.append(c)
                    j = input.index(after: j)
                }
                if closed {
                    // Nested scripts inside the body are already marked by the
                    // recursive call; an empty body contributes nothing.
                    let inner = markScripts(in: body)
                    if !inner.isEmpty {
                        out.append(opener); out.append(contentsOf: inner); out.append(scriptClose)
                    }
                    i = j
                    continue
                }
                // Unbalanced braces (truncated / malformed source, common while
                // a formula is still streaming in). Emit the body unmarked
                // rather than scripting the `{` itself — that produced an empty
                // span once the brace cleanup ran, i.e. a script marker around
                // nothing.
                if !body.isEmpty {
                    out.append(contentsOf: markScripts(in: body))
                }
                i = j
                continue
            }

            // Unbraced: a single character is the script (LaTeX's own rule).
            let c = input[j]
            if c != " " {
                out.append(opener); out.append(c); out.append(scriptClose)
            }
            i = input.index(after: j)
        }
        return out
    }

    /// Unicode superscript forms. Only characters with a true dedicated
    /// codepoint are listed — anything absent falls back to baseline-shifted
    /// text, which looks far better than a wrong-looking substitute.
    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ",
    ]

    /// Unicode subscript forms. Note the Latin coverage is much thinner than
    /// the superscript set (no `b`, `c`, `d`, `f`, `g`, `q`, `w`, `y`, `z`),
    /// which is why the baseline-shift fallback matters more here.
    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]
    static func run(_ input: String) -> String {
        latexToUnicode(input).replacingOccurrences(of: String(supOpen), with: "<SUP>")
            .replacingOccurrences(of: String(subOpen), with: "<SUB>")
            .replacingOccurrences(of: String(scriptClose), with: "</SCRIPT>")
    }
}
print("basic", MathProbe.run("x_i^2"))
print("grouped", MathProbe.run("a_{ij}^{10}"))
print("escaped", MathProbe.run("x\\_label \\^ caret"))
print("text literal", MathProbe.run("\\text{snake_case a^b}"))
print("whitespace", MathProbe.run("x^ 2+y_ 1"))
print("command operand", MathProbe.run("x^\\text{hi}_{a\\_b\\{c\\}}"))
print("fraction", MathProbe.run("\\frac{\\text{a}}{\\text{b}}"))
print("sqrt", MathProbe.run("\\sqrt{\\text{a}+1}"))
print("empty trailing", MathProbe.run("x^{}y_"))
print("nested mixed", MathProbe.run("x^{a_b+c}"))
