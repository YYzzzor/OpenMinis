import Foundation

private final class WebReadHTMLTableCell {
    var text: String
    let rowSpan: Int
    let columnSpan: Int

    init(text: String, rowSpan: Int, columnSpan: Int) {
        self.text = text
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
    }
}

private final class WebReadHTMLTableBuffer {
    var rows: [[WebReadHTMLTableCell]] = []
    var currentRow: [WebReadHTMLTableCell]?
    var currentCell: WebReadHTMLTableCell?
    var caption = ""
    var isCapturingCaption = false
    var nestedTableDepth = 0
}

private struct WebReadLoadingCandidate {
    let tag: String
    let hasStatusHint: Bool
    let isMainContent: Bool
    var text = ""
    var scalarCount = 0
}

struct WebReadExtraction: Sendable {
    let title: String?
    let markdown: String
    let resources: [WebReadResource]
    let alternateSources: [URL]
    let hasLoadingMarker: Bool
    let hasMainContent: Bool
    let wasTruncated: Bool
    let usedStructuredArticleBody: Bool
}

enum WebReadHTMLExtractor {
    private static let maximumTokenCount = 100_000
    private static let maximumOutputScalars = 120_000
    private static let maximumHTMLNestingDepth = 512
    private static let maximumListDepth = 16
    private static let maximumResolvedLinks = 64
    private static let maximumLinkScalars = 2_048
    private static let maximumTableRows = 256
    private static let maximumTableColumns = 64
    private static let maximumTableSpan = 64
    private static let maximumTableCellsPerRow = 64
    private static let maximumLoadingCandidateScalars = 256
    private static let loadingCandidateTags: Set<String> = ["p", "div", "span", "output", "button", "label"]
    private static let skippedTags: Set<String> = [
        "script", "style", "noscript", "template", "nav", "footer", "aside", "form",
        "svg", "iframe", "object", "video", "audio"
    ]
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"
    ]
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"(?is)<!--.*?-->|<![^>]*>|<[^>]*>|[^<]+"#
    )
    private static let tagNameRegex = try! NSRegularExpression(pattern: #"(?is)^</?\s*([a-z0-9:-]+)"#)
    private static let titleRegex = try! NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#)
    private static let jsonLDRegex = try! NSRegularExpression(
        pattern: #"(?is)<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script\s*>"#
    )
    private static let entityRegex = try! NSRegularExpression(
        pattern: #"(?i)&(?:#x([0-9a-f]+)|#([0-9]+)|(nbsp|amp|lt|gt|quot|39|apos|mdash|ndash|hellip|ldquo|rdquo|lsquo|rsquo));"#
    )
    private static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
        "39": "'", "apos": "'", "mdash": "—", "ndash": "–", "hellip": "…",
        "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’"
    ]
    private static let attributeRegexes: [String: NSRegularExpression] = {
        let names = [
            "href", "rel", "type", "src", "class", "hidden", "aria-hidden", "style",
            "rowspan", "colspan", "role", "aria-live", "aria-busy"
        ]
        return Dictionary(uniqueKeysWithValues: names.map { name in
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let pattern = #"(?is)(?:^|\s)"# + escaped
                + #"(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?(?=\s|/?>|$)"#
            return (name, try! NSRegularExpression(pattern: pattern))
        })
    }()
    private static let backtick = String(UnicodeScalar(96)!)
    private static let fence = String(repeating: backtick, count: 3)

    static func extract(html: String, baseURL: URL, maximumScalars: Int) throws -> WebReadExtraction {
        let scalarLimit = min(max(0, maximumScalars), maximumOutputScalars)
        let title = firstMatch(titleRegex, in: html, group: 1)
            .map(decodeEntities).map(cleanInline)
            .flatMap { $0.isEmpty ? nil : prefixScalars($0, maximum: 256) }
        var body = ""
        var main = ""
        var bodyScalarCount = 0
        var mainScalarCount = 0
        var suppressedElements: [String] = []
        var mainDepth = 0
        var sawMain = false
        var preDepth = 0
        var listDepth = 0
        var tableCells = 0
        var tableCellDepth = 0
        var tableBuffer: WebReadHTMLTableBuffer?
        var tableTextScalarCount = 0
        var loadingCandidates: [WebReadLoadingCandidate] = []
        var activeLoadingCandidateIndexes: [Int] = []
        var bodyHasLoadingPlaceholder = false
        var mainHasLoadingPlaceholder = false
        var links: [String?] = []
        var activeResolvedLinks = 0
        var alternates: [URL] = []
        var images: [WebReadResource] = []
        var processed = 0
        var parserWasTruncated = false
        var htmlDepth = 0

        func appendOutput(_ value: String) {
            let scalars = value.unicodeScalars
            if bodyScalarCount < scalarLimit {
                let retained = String(String.UnicodeScalarView(scalars.prefix(scalarLimit - bodyScalarCount)))
                body += retained
                bodyScalarCount += retained.unicodeScalars.count
                if retained.unicodeScalars.count < scalars.count { parserWasTruncated = true }
            } else if !value.isEmpty {
                parserWasTruncated = true
            }
            if mainDepth > 0 {
                if mainScalarCount < scalarLimit {
                    let retained = String(String.UnicodeScalarView(scalars.prefix(scalarLimit - mainScalarCount)))
                    main += retained
                    mainScalarCount += retained.unicodeScalars.count
                    if retained.unicodeScalars.count < scalars.count { parserWasTruncated = true }
                } else if !value.isEmpty {
                    parserWasTruncated = true
                }
            }
        }

        func append(_ value: String) {
            guard !value.isEmpty else { return }
            if var table = tableBuffer {
                let available = max(0, scalarLimit - tableTextScalarCount)
                let retained = prefixScalars(value, maximum: available)
                if let cell = table.currentCell {
                    cell.text += retained
                } else if table.isCapturingCaption {
                    table.caption += retained
                } else {
                    return
                }
                tableTextScalarCount += retained.unicodeScalars.count
                if retained.unicodeScalars.count < value.unicodeScalars.count {
                    parserWasTruncated = true
                }
                tableBuffer = table
                return
            }
            appendOutput(value)
        }

        func appendBlockBoundary(_ outsideCell: String) {
            append(tableCellDepth > 0 ? " " : outsideCell)
        }

        func parsedTableSpan(_ raw: String?) -> Int {
            guard let raw else { return 1 }
            guard let parsed = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), parsed > 0 else {
                parserWasTruncated = true
                return 1
            }
            if parsed > Self.maximumTableSpan {
                parserWasTruncated = true
                return Self.maximumTableSpan
            }
            return parsed
        }

        func finishTableCell() {
            guard let table = tableBuffer, let cell = table.currentCell else {
                tableCellDepth = 0
                return
            }
            table.currentCell = nil
            if table.currentRow == nil {
                if table.rows.count >= Self.maximumTableRows {
                    parserWasTruncated = true
                    tableCellDepth = 0
                    return
                }
                table.currentRow = []
                parserWasTruncated = true
            }
            if (table.currentRow?.count ?? 0) < Self.maximumTableCellsPerRow {
                table.currentRow?.append(cell)
            } else {
                parserWasTruncated = true
            }
            tableCellDepth = 0
        }

        func finishTableRow() {
            if tableBuffer?.currentCell != nil { finishTableCell() }
            guard let table = tableBuffer, let row = table.currentRow else { return }
            table.currentRow = nil
            if table.rows.count < Self.maximumTableRows {
                table.rows.append(row)
            } else {
                parserWasTruncated = true
            }
        }

        func flushTable() {
            guard let table = tableBuffer else { return }
            if table.nestedTableDepth > 0 { parserWasTruncated = true }
            table.nestedTableDepth = 0
            table.isCapturingCaption = false
            if table.currentCell != nil { finishTableCell() }
            finishTableRow()
            guard let completed = tableBuffer else { return }
            tableBuffer = nil
            tableCellDepth = 0
            let (rendered, wasTruncated) = Self.renderTable(
                completed.rows, caption: completed.caption, maximumScalars: scalarLimit
            )
            if wasTruncated { parserWasTruncated = true }
            guard !rendered.isEmpty else { return }
            append("\n\n")
            append(rendered)
            append("\n\n")
        }

        func finishLoadingCandidates(matching tag: String) {
            guard let index = loadingCandidates.lastIndex(where: { $0.tag == tag }) else { return }
            let finished = loadingCandidates[index...]
            for candidate in finished where Self.isLoadingPlaceholder(candidate.text, allowStatusPrefix: candidate.hasStatusHint) {
                if candidate.isMainContent { mainHasLoadingPlaceholder = true }
                else { bodyHasLoadingPlaceholder = true }
            }
            loadingCandidates.removeSubrange(index...)
            activeLoadingCandidateIndexes.removeAll { $0 >= index }
        }

        let nsHTML = html as NSString
        let searchRange = NSRange(location: 0, length: nsHTML.length)
        tokenRegex.enumerateMatches(in: html, range: searchRange) { match, _, stop in
            guard let match, let range = Range(match.range, in: html) else { return }
            processed += 1
            if processed > maximumTokenCount {
                parserWasTruncated = true
                stop.pointee = true
                return
            }
            if processed.isMultiple(of: 256), Task<Never, Never>.isCancelled {
                stop.pointee = true
                return
            }

            let token = String(html[range])
            if token.hasPrefix("<!--") || token.hasPrefix("<!") { return }
            if token.hasPrefix("<") {
                let closing = token.hasPrefix("</")
                guard let rawTag = firstMatch(tagNameRegex, in: token, group: 1) else { return }
                let tag = rawTag.lowercased()
                let selfClosing = token.hasSuffix("/>") || voidTags.contains(tag)
                if closing {
                    htmlDepth = max(0, htmlDepth - 1)
                } else if !selfClosing {
                    htmlDepth += 1
                    if htmlDepth > maximumHTMLNestingDepth {
                        parserWasTruncated = true
                        stop.pointee = true
                        return
                    }
                }

                if !suppressedElements.isEmpty {
                    if closing {
                        if let matchingIndex = suppressedElements.lastIndex(of: tag) {
                            suppressedElements.removeSubrange(matchingIndex...)
                        }
                    } else if !selfClosing {
                        suppressedElements.append(tag)
                    }
                    return
                }
                let hasHiddenAttribute = attribute("hidden", in: token) != nil
                let isHidden = hasHiddenAttribute
                    || attribute("aria-hidden", in: token)?.lowercased() == "true"
                    || attribute("style", in: token)?.lowercased().contains("display:none") == true
                    || attribute("style", in: token)?.lowercased().contains("visibility:hidden") == true
                if !closing && (skippedTags.contains(tag) || isHidden) {
                    if !selfClosing { suppressedElements.append(tag) }
                    return
                }
                if closing, Self.loadingCandidateTags.contains(tag) {
                    finishLoadingCandidates(matching: tag)
                }
                if !closing && (
                    tag == "progress"
                        || attribute("role", in: token)?.lowercased() == "progressbar"
                        || attribute("aria-busy", in: token)?.lowercased() == "true"
                ) {
                    let belongsToMain = mainDepth > 0 || tag == "main" || tag == "article"
                    if belongsToMain { mainHasLoadingPlaceholder = true }
                    else { bodyHasLoadingPlaceholder = true }
                }
                if !closing, !selfClosing, Self.loadingCandidateTags.contains(tag) {
                    let role = attribute("role", in: token)?.lowercased()
                    let className = attribute("class", in: token)?.lowercased() ?? ""
                    let isStatus = role == "status" || role == "progressbar"
                        || attribute("aria-busy", in: token)?.lowercased() == "true"
                        || attribute("aria-live", in: token)?.lowercased() == "polite"
                        || attribute("aria-live", in: token)?.lowercased() == "assertive"
                        || className.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                            .contains(where: { $0.contains("loading") || $0.contains("spinner") })
                    loadingCandidates.append(WebReadLoadingCandidate(
                        tag: tag, hasStatusHint: isStatus, isMainContent: mainDepth > 0
                    ))
                    activeLoadingCandidateIndexes.append(loadingCandidates.count - 1)
                }
                if tag == "table" {
                    if closing {
                        guard var table = tableBuffer else { return }
                        if table.nestedTableDepth > 0 {
                            table.nestedTableDepth -= 1
                            tableBuffer = table
                            append(" ")
                        } else {
                            flushTable()
                            appendBlockBoundary("\n\n")
                        }
                    } else if var table = tableBuffer {
                        table.nestedTableDepth += 1
                        tableBuffer = table
                        parserWasTruncated = true
                    } else {
                        appendBlockBoundary("\n\n")
                        tableBuffer = WebReadHTMLTableBuffer()
                    }
                    return
                }
                if tag == "caption", tableBuffer != nil {
                    guard tableBuffer?.nestedTableDepth == 0 else { return }
                    if closing {
                        tableBuffer?.isCapturingCaption = false
                        tableCellDepth = 0
                    } else {
                        if tableBuffer?.currentCell != nil { finishTableCell() }
                        tableBuffer?.isCapturingCaption = true
                        tableCellDepth = 1
                    }
                    return
                }
                if tag == "tr", tableBuffer != nil {
                    guard tableBuffer?.nestedTableDepth == 0 else { return }
                    if closing {
                        finishTableRow()
                    } else {
                        finishTableRow()
                        if var table = tableBuffer {
                            if table.rows.count < Self.maximumTableRows {
                                table.currentRow = []
                            } else {
                                parserWasTruncated = true
                            }
                            tableBuffer = table
                        }
                    }
                    return
                }
                if tag == "td" || tag == "th", tableBuffer != nil {
                    guard tableBuffer?.nestedTableDepth == 0 else { return }
                    if closing {
                        finishTableCell()
                    } else {
                        finishTableCell()
                        guard var table = tableBuffer else { return }
                        if table.currentRow == nil {
                            if table.rows.count >= Self.maximumTableRows {
                                parserWasTruncated = true
                                tableBuffer = table
                                return
                            }
                            table.currentRow = []
                            parserWasTruncated = true
                        }
                        if table.currentRow?.count ?? 0 >= Self.maximumTableCellsPerRow {
                            parserWasTruncated = true
                            tableBuffer = table
                            return
                        }
                        table.currentCell = WebReadHTMLTableCell(
                            text: "",
                            rowSpan: parsedTableSpan(attribute("rowspan", in: token)),
                            columnSpan: parsedTableSpan(attribute("colspan", in: token))
                        )
                        tableBuffer = table
                        tableCellDepth = 1
                    }
                    return
                }
                if !closing && (tag == "main" || tag == "article") {
                    sawMain = true
                    mainDepth += 1
                    return
                }
                if closing && (tag == "main" || tag == "article") {
                    mainDepth = max(0, mainDepth - 1)
                    appendBlockBoundary("\n\n")
                    return
                }
                if tag == "link", !closing,
                   let rel = attribute("rel", in: token)?.lowercased(),
                   rel.split(whereSeparator: \.isWhitespace).contains("alternate"),
                   let href = attribute("href", in: token),
                   isDeclaredTextAlternate(type: attribute("type", in: token), href: href),
                   let url = resolve(href, baseURL: baseURL),
                   alternates.count < 3, !alternates.contains(url) {
                    alternates.append(url)
                    return
                }
                if tag == "img", !closing, mainDepth > 0, images.count < 8,
                   let src = attribute("src", in: token), let url = resolve(src, baseURL: baseURL),
                   !images.contains(where: { $0.url == url.absoluteString }) {
                    images.append(WebReadResource(
                        url: url.absoluteString, type: mimeForURL(url), readStatus: "not_read",
                        context: "正文中的图片资源；图片内容未读取。"
                    ))
                    return
                }
                if tag == "a", !closing {
                    if let href = attribute("href", in: token),
                       let url = resolve(href, baseURL: baseURL),
                       activeResolvedLinks < maximumResolvedLinks {
                        append("[")
                        links.append(markdownURL(url))
                        activeResolvedLinks += 1
                    } else {
                        links.append(nil)
                    }
                    return
                }
                if tag == "a", closing, !links.isEmpty {
                    if let url = links.removeLast() {
                        activeResolvedLinks = max(0, activeResolvedLinks - 1)
                        append("](\(url))")
                    }
                    return
                }
                if tag == "br", !closing {
                    append(tableCellDepth > 0 ? " " : "\n")
                    return
                }
                if tag == "hr", !closing {
                    appendBlockBoundary("\n\n---\n\n")
                    return
                }
                if tag == "p" {
                    if tableCellDepth > 0 {
                        if closing { append(" ") }
                    } else {
                        append("\n\n")
                    }
                    return
                }
                if tag == "div", closing { appendBlockBoundary("\n"); return }
                if tag == "blockquote", !closing {
                    append(tableCellDepth > 0 ? "> " : "\n> ")
                    return
                }
                if tag == "blockquote", closing { appendBlockBoundary("\n\n"); return }
                if tag == "pre", !closing {
                    preDepth += 1
                    let language = attribute("class", in: token)?
                        .split(whereSeparator: \.isWhitespace)
                        .first(where: { $0.hasPrefix("language-") })
                        .map { String($0.dropFirst("language-".count)) } ?? ""
                    if tableCellDepth > 0 {
                        append(backtick)
                    } else {
                        append("\n\n" + fence + language + "\n")
                    }
                    return
                }
                if tag == "pre", closing {
                    preDepth = max(0, preDepth - 1)
                    if tableCellDepth > 0 {
                        append(backtick)
                    } else {
                        append("\n" + fence + "\n\n")
                    }
                    return
                }
                if tag == "code", preDepth == 0 { append(backtick); return }
                if tag == "strong" || tag == "b" { append("**"); return }
                if tag == "em" || tag == "i" { append("*"); return }
                if tag == "ul" || tag == "ol" {
                    if closing { listDepth = max(0, listDepth - 1) }
                    else { listDepth = min(maximumListDepth, listDepth + 1) }
                    appendBlockBoundary("\n")
                    return
                }
                if tag == "li" {
                    if closing { appendBlockBoundary("\n") }
                    else {
                        append(String(repeating: "  ", count: min(maximumListDepth, max(0, listDepth - 1))) + "- ")
                    }
                    return
                }
                if tag == "tr" {
                    if closing { append(" |\n") }
                    else { tableCells = 0; append("\n| ") }
                    return
                }
                if tag == "th" || tag == "td" {
                    if closing {
                        tableCellDepth = max(0, tableCellDepth - 1)
                        append(" ")
                    }
                    else {
                        if tableCells > 0 { append(" | ") }
                        tableCells += 1
                        tableCellDepth += 1
                    }
                    return
                }
                if tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) {
                    if tableCellDepth > 0 {
                        if closing { append(" ") }
                        else { append(String(repeating: "#", count: level) + " ") }
                    } else {
                        append(closing ? "\n\n" : "\n\n" + String(repeating: "#", count: level) + " ")
                    }
                }
                return
            }

            // 被跳过的 script、导航和辅助区域中的普通文本不会进入正文。
            guard suppressedElements.isEmpty else { return }
            let decoded = decodeEntities(token)
            let text = preDepth > 0 ? decoded : normalizeTextNode(decoded)
            if !text.isEmpty {
                append(text)
                if preDepth == 0, !activeLoadingCandidateIndexes.isEmpty {
                    var stillCapturing: [Int] = []
                    for index in activeLoadingCandidateIndexes {
                        let remaining = max(0, Self.maximumLoadingCandidateScalars - loadingCandidates[index].scalarCount)
                        guard remaining > 0 else { continue }
                        let retained = prefixScalars(text, maximum: remaining)
                        let retainedCount = retained.unicodeScalars.count
                        loadingCandidates[index].text += retained
                        loadingCandidates[index].scalarCount += retainedCount
                        if loadingCandidates[index].scalarCount < Self.maximumLoadingCandidateScalars {
                            stillCapturing.append(index)
                        }
                    }
                    activeLoadingCandidateIndexes = stillCapturing
                }
            }
        }
        try Task.checkCancellation()
        for candidate in loadingCandidates where Self.isLoadingPlaceholder(candidate.text, allowStatusPrefix: candidate.hasStatusHint) {
            if candidate.isMainContent { mainHasLoadingPlaceholder = true }
            else { bodyHasLoadingPlaceholder = true }
        }
        flushTable()

        let allMarkdown = normalizeMarkdown(body)
        let mainMarkdown = normalizeMarkdown(main)
        let selectedIsMain = sawMain && mainMarkdown.count >= 40
        let selected = selectedIsMain ? mainMarkdown : allMarkdown
        var wasTruncated = parserWasTruncated || selected.unicodeScalars.count > scalarLimit
        var markdown = prefixScalars(selected, maximum: scalarLimit)
        var usedStructuredBody = false
        if markdown.count < 80, let structured = jsonLDArticleBody(from: html),
           !structured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let structuredWasCut = structured.unicodeScalars.count > scalarLimit
            wasTruncated = wasTruncated || structuredWasCut
            markdown = prefixScalars(structured, maximum: scalarLimit)
            usedStructuredBody = true
        }
        markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        return WebReadExtraction(
            title: title, markdown: markdown, resources: images, alternateSources: alternates,
            hasLoadingMarker: selectedIsMain
                ? mainHasLoadingPlaceholder
                : (bodyHasLoadingPlaceholder || mainHasLoadingPlaceholder),
            hasMainContent: sawMain,
            wasTruncated: wasTruncated, usedStructuredArticleBody: usedStructuredBody
        )
    }

    static func text(bytes: Data, mimeType: String?, baseURL: URL, maximumScalars: Int) throws -> WebReadExtraction {
        let scalarLimit = min(max(0, maximumScalars), maximumOutputScalars)
        let raw = String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
        let mime = (mimeType ?? "").lowercased()
        if mime.contains("html")
            || raw.range(of: #"<(html|body|article|main)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return try extract(html: raw, baseURL: baseURL, maximumScalars: maximumScalars)
        }
        if mime.contains("json") || raw.trimmingCharacters(in: .whitespacesAndNewlines).first == "{" {
            let rendered: String
            if let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: encoded, encoding: .utf8) {
                rendered = fence + "json\n" + json + "\n" + fence
            } else { rendered = raw }
            let cut = rendered.unicodeScalars.count > scalarLimit
            return WebReadExtraction(title: nil, markdown: prefixScalars(rendered, maximum: scalarLimit),
                                     resources: [], alternateSources: [], hasLoadingMarker: false,
                                     hasMainContent: false, wasTruncated: cut,
                                     usedStructuredArticleBody: false)
        }
        let normalized = normalizeLineEndings(raw)
        let cut = normalized.unicodeScalars.count > scalarLimit
        return WebReadExtraction(title: nil, markdown: prefixScalars(normalized, maximum: scalarLimit),
                                 resources: [], alternateSources: [], hasLoadingMarker: false,
                                 hasMainContent: false, wasTruncated: cut,
                                 usedStructuredArticleBody: false)
    }

    private static func isDeclaredTextAlternate(type: String?, href: String) -> Bool {
        let mime = (type ?? "").lowercased()
        let ext = URL(string: href)?.pathExtension.lowercased() ?? ""
        return mime.contains("text/markdown") || mime.contains("text/plain")
            || ["md", "markdown", "txt"].contains(ext)
    }

    private static func resolve(_ raw: String, baseURL: URL) -> URL? {
        let decoded = decodeEntities(raw)
        guard decoded.unicodeScalars.count <= maximumLinkScalars else { return nil }
        let value = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func markdownURL(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    private static func mimeForURL(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "svg": "image/svg+xml"
        default: "image/*"
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = attributeRegexes[name],
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        let source = tag as NSString
        for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
            return source.substring(with: match.range(at: index))
        }
        if name == "hidden" { return "" }
        return nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in value: String, group: Int) -> String? {
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)),
              group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func jsonLDArticleBody(from html: String) -> String? {
        var scripts = 0
        var examinedNodes = 0
        var result: String?
        jsonLDRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length)) { match, _, stop in
            guard let match, scripts < 8, !Task<Never, Never>.isCancelled,
                  let range = Range(match.range(at: 1), in: html),
                  let data = String(html[range]).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                if scripts >= 8 { stop.pointee = true }
                return
            }
            scripts += 1
            result = articleBody(in: object, depth: 0, examined: &examinedNodes)
            if result != nil || examinedNodes >= 2_000 { stop.pointee = true }
        }
        return result
    }

    private static func articleBody(in value: Any, depth: Int, examined: inout Int) -> String? {
        guard depth < 16, examined < 2_000 else { return nil }
        examined += 1
        if let object = value as? [String: Any] {
            if let body = object["articleBody"] as? String,
               !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalizeMarkdown(decodeEntities(body))
            }
            for key in ["@graph", "mainEntity", "mainEntityOfPage", "article"] {
                if let nested = object[key],
                   let body = articleBody(in: nested, depth: depth + 1, examined: &examined) { return body }
            }
            for nested in object.values {
                if let body = articleBody(in: nested, depth: depth + 1, examined: &examined) { return body }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let body = articleBody(in: nested, depth: depth + 1, examined: &examined) { return body }
            }
        }
        return nil
    }

    private static func normalizeTextNode(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t\r\n]+"#, with: " ", options: .regularExpression)
    }

    private static func normalizeMarkdown(_ text: String) -> String {
        var lines: [String] = []
        var inCode = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence) {
                inCode.toggle()
                lines.append(trimmed)
            } else if inCode {
                lines.append(line)
            } else {
                let indentation = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let content = String(line.dropFirst(indentation.count))
                lines.append(indentation + content.replacingOccurrences(
                    of: #" {2,}"#, with: " ", options: .regularExpression
                ))
            }
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func renderTable(
        _ rows: [[WebReadHTMLTableCell]],
        caption: String,
        maximumScalars: Int
    ) -> (String, Bool) {
        let rowCount = min(rows.count, maximumTableRows)
        var truncated = rows.count > rowCount
        var grid = Array(
            repeating: Array<String?>(repeating: nil, count: maximumTableColumns),
            count: rowCount
        )
        var width = 0

        for rowIndex in 0..<rowCount {
            var columnCursor = 0
            for cell in rows[rowIndex] {
                let requestedRowSpan = min(max(1, cell.rowSpan), maximumTableSpan)
                let rowSpan = min(requestedRowSpan, rowCount - rowIndex)
                if rowSpan < requestedRowSpan { truncated = true }
                let requestedColumnSpan = min(max(1, cell.columnSpan), maximumTableColumns)
                if requestedColumnSpan != cell.columnSpan { truncated = true }

                var placement: (column: Int, columnSpan: Int)?
                var column = columnCursor
                while column < maximumTableColumns {
                    let columnSpan = min(requestedColumnSpan, maximumTableColumns - column)
                    var available = true
                    for targetRow in rowIndex..<(rowIndex + rowSpan) {
                        for targetColumn in column..<(column + columnSpan) where grid[targetRow][targetColumn] != nil {
                            available = false
                            break
                        }
                        if !available { break }
                    }
                    if available {
                        placement = (column, columnSpan)
                        if columnSpan < requestedColumnSpan { truncated = true }
                        break
                    }
                    column += 1
                }
                guard let placement else {
                    truncated = true
                    break
                }
                if placement.column > columnCursor {
                    for skippedColumn in columnCursor..<placement.column where grid[rowIndex][skippedColumn] == nil {
                        truncated = true
                    }
                }
                for targetRow in rowIndex..<(rowIndex + rowSpan) {
                    for targetColumn in placement.column..<(placement.column + placement.columnSpan) {
                        grid[targetRow][targetColumn] = cell.text
                    }
                }
                width = max(width, placement.column + placement.columnSpan)
                columnCursor = placement.column + placement.columnSpan
            }
        }

        guard width > 0 || !caption.isEmpty else { return ("", truncated) }
        var rendered = ""
        var renderedScalars = 0
        var shouldStop = false
        func appendBounded(_ value: String) -> Bool {
            guard !shouldStop else { return false }
            let remaining = max(0, maximumScalars - renderedScalars)
            let valueCount = value.unicodeScalars.count
            guard valueCount > remaining else {
                rendered += value
                renderedScalars += valueCount
                return true
            }
            rendered += prefixScalars(value, maximum: remaining)
            renderedScalars += remaining
            truncated = true
            shouldStop = true
            return false
        }

        if !caption.isEmpty {
            appendBounded(normalizeMarkdown(caption))
            if rowCount > 0 { appendBounded("\n") }
        }
        if width > 0 {
            for rowIndex in 0..<rowCount {
                if shouldStop { break }
                guard appendBounded("|") else { break }
                for column in 0..<width {
                    guard appendBounded(" "),
                          appendBounded(grid[rowIndex][column] ?? ""),
                          appendBounded(" |") else { break }
                }
                if !shouldStop, rowIndex + 1 < rowCount { appendBounded("\n") }
            }
        }
        return (rendered, truncated)
    }

    private static func isLoadingPlaceholder(_ text: String, allowStatusPrefix: Bool) -> Bool {
        let normalized = normalizeTextNode(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return allowStatusPrefix }
        let lower = normalized.lowercased()
        let withoutTrailingPunctuation = lower.trimmingCharacters(in: CharacterSet(charactersIn: ".…!！。"))
        let exactMarkers: Set<String> = [
            "loading", "please wait", "just a moment", "正在加载", "正在載入", "加载中", "載入中"
        ]
        if exactMarkers.contains(withoutTrailingPunctuation) { return true }
        guard allowStatusPrefix, normalized.unicodeScalars.count <= 80 else { return false }
        return ["loading ", "please wait ", "正在加载", "正在載入", "加载中", "載入中"]
            .contains(where: lower.hasPrefix)
    }

    private static func cleanInline(_ text: String) -> String {
        normalizeTextNode(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func prefixScalars(_ text: String, maximum: Int) -> String {
        let count = max(0, maximum)
        guard text.unicodeScalars.count > count else { return text }
        return String(String.UnicodeScalarView(Array(text.unicodeScalars.prefix(count))))
    }

    static func decodeEntities(_ text: String) -> String {
        let source = text as NSString
        let matches = entityRegex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let decoded = NSMutableString(string: text)
        for match in matches.reversed() {
            let replacement: String?
            if match.range(at: 1).location != NSNotFound {
                let raw = source.substring(with: match.range(at: 1))
                replacement = UInt32(raw, radix: 16)
                    .flatMap { Unicode.Scalar($0) }
                    .map { String($0) }
            } else if match.range(at: 2).location != NSNotFound {
                let raw = source.substring(with: match.range(at: 2))
                replacement = UInt32(raw, radix: 10)
                    .flatMap { Unicode.Scalar($0) }
                    .map { String($0) }
            } else {
                let name = source.substring(with: match.range(at: 3)).lowercased()
                replacement = namedEntities[name]
            }
            if let replacement {
                decoded.replaceCharacters(in: match.range, with: replacement)
            }
        }
        return decoded as String
    }
}
