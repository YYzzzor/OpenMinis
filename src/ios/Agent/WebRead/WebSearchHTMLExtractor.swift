import Foundation

enum WebSearchHTMLExtractor {
    private struct Anchor {
        let range: Range<String.Index>
        let title: String
        let rawURL: String
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"(?is)<[^>]+>"#)
    private static let anchorRegex = try! NSRegularExpression(
        pattern: #"(?is)<a\b([^>]*)>(.*?)</a\s*>"#
    )
    private static let openingTagRegex = try! NSRegularExpression(
        pattern: #"(?is)</?\s*([a-z][a-z0-9:-]*)\b([^>]*)>"#
    )
    private static let snippetOpeningRegex = try! NSRegularExpression(
        pattern: #"(?is)<([a-z][a-z0-9:-]*)\b(?=[^>]*\bclass\s*=\s*(['"])[^'"]*(?:result-snippet|result__snippet)[^'"]*\2)[^>]*>"#
    )
    private static let formOpeningRegex = try! NSRegularExpression(
        pattern: #"(?is)<form\b([^>]*)>"#
    )
    private static let inputRegex = try! NSRegularExpression(
        pattern: #"(?is)<input\b([^>]*)>"#
    )
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"(?is)<!--.*?-->|</?[a-z][^>]*>|[^<]+"#
    )

    static func extract(html: String, baseURL: URL, maximumResults: Int) -> WebSearchExtraction {
        let source = html as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        let lower = html.lowercased()
        let verificationRequired = isVerificationPage(lower)

        var anchors: [Anchor] = []
        var rejectedAnchors = 0
        var resultsTruncated = false
        for match in anchorRegex.matches(in: html, range: fullRange) {
            guard match.numberOfRanges >= 3,
                  let attributesRange = Range(match.range(at: 1), in: html),
                  let fullMatchRange = Range(match.range, in: html) else { continue }
            let attributes = String(html[attributesRange])
            let classes = attribute("class", in: attributes)?.lowercased() ?? ""
            guard classes.split(whereSeparator: \.isWhitespace).contains(where: {
                $0 == "result-link" || $0 == "result__a"
            }) else { continue }

            guard let innerRange = Range(match.range(at: 2), in: html),
                  let rawURL = attribute("href", in: attributes) else {
                rejectedAnchors += 1
                continue
            }

            let title = normalizedText(String(html[innerRange]))
            guard !title.isEmpty else {
                rejectedAnchors += 1
                continue
            }
            if anchors.count >= max(0, maximumResults) {
                resultsTruncated = true
                break
            }
            anchors.append(Anchor(range: fullMatchRange, title: title, rawURL: rawURL))
        }

        var results: [WebSearchEntry] = []
        var seenURLs: Set<String> = []
        let resultLimit = max(0, maximumResults)
        for index in anchors.indices {
            guard results.count < resultLimit else { break }
            let anchor = anchors[index]
            guard let resolvedURL = resolveResultURL(anchor.rawURL, baseURL: baseURL) else {
                rejectedAnchors += 1
                continue
            }
            let regionEnd = index + 1 < anchors.count ? anchors[index + 1].range.lowerBound : html.endIndex
            let region = String(html[anchor.range.upperBound..<regionEnd])
            let snippet = firstSnippet(in: region)
            let canonicalURL = resolvedURL.absoluteString
            guard seenURLs.insert(canonicalURL).inserted else { continue }
            results.append(WebSearchEntry(
                title: anchor.title,
                snippet: snippet,
                url: canonicalURL
            ))
        }

        let noResults = explicitlyNoResults(lower)
        let nextPage = nextPage(in: html, baseURL: baseURL)
        return WebSearchExtraction(
            results: results,
            hasResultStructure: !anchors.isEmpty || noResults,
            explicitlyNoResults: noResults,
            verificationRequired: verificationRequired,
            resultsTruncated: resultsTruncated,
            resultAnchors: anchors.count,
            rejectedResultAnchors: rejectedAnchors,
            nextPageURL: nextPage.url,
            nextPageMethod: nextPage.method,
            nextPageStart: nextPage.start,
            nextPageParameters: nextPage.parameters
        )
    }

    private static func firstSnippet(in region: String) -> String? {
        let fullRange = NSRange(location: 0, length: (region as NSString).length)
        guard let opening = snippetOpeningRegex.firstMatch(in: region, range: fullRange),
              opening.numberOfRanges >= 2,
              let tagRange = Range(opening.range(at: 1), in: region),
              let bodyStart = Range(opening.range, in: region)?.upperBound else { return nil }
        let tagName = String(region[tagRange]).lowercased()
        guard let body = innerText(in: region, after: bodyStart, untilClosing: tagName) else { return nil }
        let normalized = normalizedText(body)
        return normalized.isEmpty ? nil : normalized
    }

    private static func innerText(in html: String, after start: String.Index, untilClosing tagName: String) -> String? {
        let suffix = String(html[start...])
        let suffixNSString = suffix as NSString
        let matches = tokenRegex.matches(in: suffix, range: NSRange(location: 0, length: suffixNSString.length))
        var sameTagDepth = 1
        var textParts: [String] = []
        for match in matches {
            guard let tokenRange = Range(match.range, in: suffix) else { continue }
            let token = String(suffix[tokenRange])
            if token.hasPrefix("<!--") {
                continue
            }
            if token.hasPrefix("<"), let parsed = openingTag(token) {
                if parsed.name == tagName {
                    if parsed.isClosing {
                        sameTagDepth -= 1
                        if sameTagDepth == 0 {
                            return textParts.joined(separator: " ")
                        }
                    } else if !parsed.isVoid {
                        sameTagDepth += 1
                    }
                }
            } else if !token.hasPrefix("<") {
                textParts.append(token)
            }
        }
        return nil
    }

    private static func openingTag(_ token: String) -> (name: String, isClosing: Bool, isVoid: Bool)? {
        let ns = token as NSString
        guard let match = openingTagRegex.firstMatch(in: token, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let name = ns.substring(with: match.range(at: 1)).lowercased()
        let isClosing = token.dropFirst().first == "/"
        let isVoid = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"].contains(name)
            || token.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>")
        return (name, isClosing, isVoid)
    }

    private static func nextPage(in html: String, baseURL: URL) -> (url: String?, method: String?, start: Int?, parameters: [WebSearchFormField]?) {
        let ns = html as NSString
        let range = NSRange(location: 0, length: ns.length)
        for match in formOpeningRegex.matches(in: html, range: range) {
            guard let attributesRange = Range(match.range(at: 1), in: html) else { continue }
            let attributes = String(html[attributesRange])
            let classes = attribute("class", in: attributes)?.lowercased() ?? ""
            guard classes.split(whereSeparator: \.isWhitespace).contains("next_form"),
                  let rawAction = attribute("action", in: attributes),
                  let action = URL(string: WebReadHTMLExtractor.decodeEntities(rawAction), relativeTo: baseURL)?.absoluteURL,
                  isHTTPURL(action) else { continue }

            let formEnd = match.range.location + match.range.length
            let nextFormStart = ns.range(of: "</form", options: [.caseInsensitive], range: NSRange(location: formEnd, length: ns.length - formEnd))
            let end = nextFormStart.location == NSNotFound ? ns.length : nextFormStart.location
            let formBody = ns.substring(with: NSRange(location: formEnd, length: end - formEnd))
            let inputNS = formBody as NSString
            var start: Int?
            var parameters: [WebSearchFormField] = []
            for input in inputRegex.matches(in: formBody, range: NSRange(location: 0, length: inputNS.length)) {
                guard let inputAttrs = Range(input.range(at: 1), in: formBody) else { continue }
                let item = String(formBody[inputAttrs])
                guard let name = attribute("name", in: item),
                      let raw = attribute("value", in: item),
                      name.unicodeScalars.count <= 128 else { continue }
                parameters.append(WebSearchFormField(name: name, value: WebReadHTMLExtractor.decodeEntities(raw)))
                if name.lowercased() == "s" { start = Int(raw) }
            }
            return (action.absoluteString, (attribute("method", in: attributes) ?? "GET").uppercased(), start, parameters.isEmpty ? nil : parameters)
        }
        return (nil, nil, nil, nil)
    }

    private static func resolveResultURL(_ raw: String, baseURL: URL) -> URL? {
        let decoded = WebReadHTMLExtractor.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              isHTTPURL(link), link.user == nil, link.password == nil else { return nil }
        if let host = link.host?.lowercased(), host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com"),
           let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
           let target = components.queryItems?.first(where: { $0.name.lowercased() == "uddg" })?.value,
           let destination = URL(string: target), isHTTPURL(destination),
           destination.user == nil, destination.password == nil {
            return destination
        }
        guard let host = link.host?.lowercased(), host != "duckduckgo.com", !host.hasSuffix(".duckduckgo.com") else {
            return nil
        }
        return link
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    private static func explicitlyNoResults(_ lowerHTML: String) -> Bool {
        let hasNoResultsClass = lowerHTML.range(of: #"class\s*=\s*['"][^'"]*(?:no-results|noresults|no_results)[^'"]*['"]"#, options: .regularExpression) != nil
        let phrases = [
            "no results found", "no results for", "no results.",
            "没有找到结果", "未找到结果", "找不到结果"
        ]
        return hasNoResultsClass || phrases.contains(where: lowerHTML.contains)
    }

    private static func isVerificationPage(_ lowerHTML: String) -> Bool {
        let structuralPatterns = [
            #"(?is)<form\b[^>]*(?:id|class)\s*=\s*['"][^'"]*(?:challenge-form|captcha|anomaly)[^'"]*['"]"#,
            #"(?is)<(?:div|section|iframe)\b[^>]*(?:id|class)\s*=\s*['"][^'"]*(?:anomaly-modal|cf-chl-|captcha-container|hcaptcha|recaptcha)[^'"]*['"]"#,
            #"(?is)<input\b[^>]*(?:name|id|class)\s*=\s*['"][^'"]*(?:captcha|challenge|cf-turnstile)[^'"]*['"]"#,
            #"(?is)<(?:title|h1|h2)\b[^>]*>\s*(?:verify you are human|confirm this search was made by a human|complete the following challenge|unusual traffic|are you a robot)\b"#
        ]
        return structuralPatterns.contains { lowerHTML.range(of: $0, options: .regularExpression) != nil }
    }

    private static func normalizedText(_ html: String) -> String {
        let withoutTags = tagRegex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: (html as NSString).length),
            withTemplate: " "
        )
        let decoded = WebReadHTMLExtractor.decodeEntities(withoutTags)
        return decoded
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attribute(_ name: String, in tagOrAttributes: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?is)(?:^|\s)"# + escaped + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tagOrAttributes, range: NSRange(location: 0, length: (tagOrAttributes as NSString).length)) else { return nil }
        let ns = tagOrAttributes as NSString
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return ns.substring(with: match.range(at: index))
        }
        return nil
    }
}
