import Foundation
import WebKit
import UIKit

@MainActor
final class WebReadRenderer: NSObject, WebReadRendering, WKNavigationDelegate, WKUIDelegate {
    private static let maximumRedirects = 8
    private static let maximumMainFrameNavigations = maximumRedirects + 1
    private static let maximumSubframeNavigations = 32
    private static let maximumReadinessChecks = 80
    private static let readinessInterval: TimeInterval = 0.5
    private static let maximumTargetWait: TimeInterval = 8
    private static let extractionDeadlineReserve: TimeInterval = 0.5
    private static let maximumTargetScalars = 512

    private var operations: [String: Operation] = [:]
    private let maximumMainResponseBytes: Int

    init(maximumMainResponseBytes: Int = WebReadConfiguration.conservative.maximumResponseBytes) {
        self.maximumMainResponseBytes = max(1, maximumMainResponseBytes)
        super.init()
    }

    @MainActor
    private final class Operation {
        let callID: String
        let requestedURL: URL
        let deadline: Date
        let queryTarget: String?
        let waitForTarget: Bool
        let preserveSearchStructure: Bool
        let targetWaitDeadline: Date
        var webView: WKWebView?
        var continuation: CheckedContinuation<WebReadRenderedPage, Error>?
        var pendingEvaluation: CheckedContinuation<Any?, Error>?
        var evaluationID = 0
        var monitorTask: Task<Void, Never>?
        var deadlineTask: Task<Void, Never>?
        var foregroundObserver: NSObjectProtocol?
        var latestReadiness: ReadinessSnapshot?
        var responseReceivedAt: Date?
        var mainFrameNavigationCount = 0
        var subframeNavigationCount = 0
        var hasCommittedDocument = false
        var isCapturing = false
        var isFinished = false

        init(
            callID: String,
            requestedURL: URL,
            deadline: Date,
            queryTarget: String?,
            waitForTarget: Bool,
            preserveSearchStructure: Bool,
            targetWaitDeadline: Date
        ) {
            self.callID = callID
            self.requestedURL = requestedURL
            self.deadline = deadline
            self.queryTarget = queryTarget
            self.waitForTarget = waitForTarget
            self.preserveSearchStructure = preserveSearchStructure
            self.targetWaitDeadline = targetWaitDeadline
        }
    }

    private struct ReadinessSnapshot {
        let hasBody: Bool
        let hasText: Bool
        let isReady: Bool
        let isLoadingShell: Bool
        let targetFound: Bool
    }

    func render(
        url: URL,
        callID: String,
        deadline: Date,
        queryTarget: String?,
        waitForTarget: Bool,
        preserveSearchStructure: Bool = false
    ) async throws -> WebReadRenderedPage {
        guard Self.isAllowedURL(url), !callID.isEmpty else {
            throw WebReadFailure.restricted
        }
        guard deadline > Date() else {
            throw WebReadFailure.deadlineExceeded
        }
        guard operations.isEmpty else {
            throw WebReadFailure.resourceLimit
        }

        let normalizedTarget = queryTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = normalizedTarget?.isEmpty == false ? normalizedTarget : nil
        if let target, target.unicodeScalars.count > Self.maximumTargetScalars {
            throw WebReadFailure.resourceLimit
        }
        let shouldWaitForTarget = waitForTarget
        guard !Task.isCancelled else {
            throw WebReadFailure.cancelled
        }

        let now = Date()
        let extractionReserve = min(Self.extractionDeadlineReserve, max(0, deadline.timeIntervalSince(now) / 2))
        let targetWaitDeadline: Date
        if shouldWaitForTarget {
            targetWaitDeadline = min(
                now.addingTimeInterval(Self.maximumTargetWait),
                deadline.addingTimeInterval(-extractionReserve)
            )
        } else {
            targetWaitDeadline = deadline
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let operation = Operation(
            callID: callID,
            requestedURL: url,
            deadline: deadline,
            queryTarget: target,
            waitForTarget: shouldWaitForTarget,
            preserveSearchStructure: preserveSearchStructure,
            targetWaitDeadline: targetWaitDeadline
        )
        operation.webView = webView
        operations[callID] = operation

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<WebReadRenderedPage, Error>) in
                guard self.isActive(operation) else {
                    continuation.resume(throwing: WebReadFailure.cancelled)
                    return
                }
                operation.continuation = continuation
                guard !Task.isCancelled else {
                    self.finish(operation, throwing: WebReadFailure.cancelled)
                    return
                }
                self.observeForegroundResume(operation)
                self.start(operation)
            }
        }, onCancel: {
            Task { @MainActor [weak self, weak operation] in
                guard let self, let operation else { return }
                self.finish(operation, throwing: WebReadFailure.cancelled)
            }
        })
    }

    func cancel(callID: String) {
        guard let operation = operations[callID] else { return }
        finish(operation, throwing: WebReadFailure.cancelled)
    }

    private func start(_ operation: Operation) {
        guard isActive(operation), let webView = operation.webView else { return }

        operation.deadlineTask = Task { @MainActor [weak self, weak operation] in
            guard let self, let operation else { return }
            let remaining = operation.deadline.timeIntervalSinceNow
            if remaining > 0 {
                let nanos = UInt64(min(remaining, 3_600) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
            guard !Task.isCancelled, self.isActive(operation) else { return }
            self.deadlineReached(operation)
        }

        operation.monitorTask = Task { @MainActor [weak self, weak operation] in
            guard let self, let operation else { return }
            await self.monitor(operation)
        }

        var request = URLRequest(
            url: operation.requestedURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: max(1, min(30, operation.deadline.timeIntervalSinceNow))
        )
        request.httpMethod = "GET"
        webView.load(request)
    }

    private func observeForegroundResume(_ operation: Operation) {
        operation.foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self, weak operation] _ in
            Task { @MainActor in
                guard let self, let operation, self.isActive(operation) else { return }
                if Date() >= operation.deadline {
                    self.deadlineReached(operation)
                }
            }
        }
    }

    private func monitor(_ operation: Operation) async {
        var checkCount = 0
        while isActive(operation), !Task.isCancelled {
            let now = Date()
            if now >= operation.deadline {
                deadlineReached(operation)
                return
            }

            // 请求地址会早于新文档出现。提交前的 about:blank 不能作为可读正文返回。
            guard operation.hasCommittedDocument else {
                await Self.pause(for: min(Self.readinessInterval, max(0.01, operation.deadline.timeIntervalSinceNow)))
                continue
            }

            if operation.waitForTarget,
               now >= operation.targetWaitDeadline,
               operation.latestReadiness?.hasBody == true {
                await capture(operation, targetWaitExpired: true)
                return
            }

            guard checkCount < Self.maximumReadinessChecks else {
                if operation.waitForTarget, operation.latestReadiness?.hasBody == true {
                    await capture(operation, targetWaitExpired: true)
                } else {
                    finish(operation, throwing: WebReadFailure.deadlineExceeded)
                }
                return
            }

            guard let webView = operation.webView, let currentURL = webView.url else {
                checkCount += 1
                await Self.pause(for: Self.readinessInterval)
                continue
            }
            guard Self.isAllowedURL(currentURL) else {
                finish(operation, throwing: WebReadFailure.restricted)
                return
            }

            do {
                let script = try Self.readinessScript(target: operation.queryTarget)
                let value = try await evaluate(script, in: operation)
                guard isActive(operation) else { return }
                guard Date() < operation.deadline else {
                    deadlineReached(operation)
                    return
                }
                guard let snapshot = Self.readinessSnapshot(from: value) else {
                    finish(operation, throwing: WebReadFailure.transport("DOM readiness check returned an invalid result"))
                    return
                }
                operation.latestReadiness = snapshot
                checkCount += 1

                if operation.waitForTarget {
                    if operation.queryTarget != nil, snapshot.targetFound {
                        await capture(operation, targetWaitExpired: false)
                        return
                    }
                    if operation.queryTarget == nil, snapshot.isReady, !snapshot.isLoadingShell {
                        await capture(operation, targetWaitExpired: false)
                        return
                    }
                } else if snapshot.isReady, !snapshot.isLoadingShell {
                    await capture(operation, targetWaitExpired: false)
                    return
                }
            } catch {
                guard isActive(operation) else { return }
                if Date() >= operation.deadline {
                    deadlineReached(operation)
                    return
                }
                if checkCount >= Self.maximumReadinessChecks {
                    finish(operation, throwing: WebReadFailure.transport("DOM readiness check failed"))
                    return
                }
                checkCount += 1
            }

            let remaining = operation.deadline.timeIntervalSinceNow
            if operation.waitForTarget {
                let targetRemaining = operation.targetWaitDeadline.timeIntervalSinceNow
                if targetRemaining <= 0, operation.latestReadiness?.hasBody == true {
                    await capture(operation, targetWaitExpired: true)
                    return
                }
                await Self.pause(for: min(Self.readinessInterval, max(0.01, min(remaining, targetRemaining))))
            } else {
                await Self.pause(for: min(Self.readinessInterval, max(0.01, remaining)))
            }
        }
    }

    private func deadlineReached(_ operation: Operation) {
        guard isActive(operation) else { return }
        finish(operation, throwing: WebReadFailure.deadlineExceeded)
    }

    private func capture(_ operation: Operation, targetWaitExpired: Bool) async {
        guard isActive(operation), !operation.isCapturing else { return }
        guard Date() < operation.deadline else {
            deadlineReached(operation)
            return
        }
        operation.isCapturing = true

        do {
            let script = try Self.renderedPageScript(
                target: operation.queryTarget,
                preserveSearchStructure: operation.preserveSearchStructure
            )
            let value = try await evaluate(script, in: operation)
            guard isActive(operation) else { return }
            guard Date() < operation.deadline else {
                finish(operation, throwing: WebReadFailure.deadlineExceeded)
                return
            }
            guard
                let fields = value as? [String: Any],
                let html = fields["html"] as? String,
                let rawURL = fields["url"] as? String,
                let finalURL = URL(string: rawURL),
                Self.isAllowedURL(finalURL),
                let truncated = fields["truncated"] as? Bool,
                let hasLoadingIndicator = fields["hasLoadingIndicator"] as? Bool
            else {
                finish(operation, throwing: WebReadFailure.transport("DOM extraction returned an invalid result"))
                return
            }

            let titleValue = (fields["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = titleValue?.isEmpty == false ? titleValue : nil
            let targetFound = operation.queryTarget == nil ? nil : (fields["targetFound"] as? Bool ?? false)
            let page = WebReadRenderedPage(
                title: title,
                finalURL: finalURL,
                html: html,
                retrievedAt: operation.responseReceivedAt ?? Date(),
                htmlWasTruncated: truncated,
                targetFound: targetFound,
                targetWaitExpired: targetWaitExpired && operation.queryTarget != nil && targetFound != true,
                hasLoadingIndicator: hasLoadingIndicator
            )
            finish(operation, returning: page)
        } catch {
            if isActive(operation) {
                if Date() >= operation.deadline {
                    finish(operation, throwing: WebReadFailure.deadlineExceeded)
                } else {
                    finish(operation, throwing: WebReadFailure.transport("DOM extraction failed"))
                }
            }
        }
    }

    private func evaluate(_ script: String, in operation: Operation) async throws -> Any? {
        guard isActive(operation), let webView = operation.webView else {
            throw WebReadFailure.cancelled
        }
        guard operation.pendingEvaluation == nil else {
            throw WebReadFailure.resourceLimit
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Any?, Error>) in
            guard self.isActive(operation) else {
                continuation.resume(throwing: WebReadFailure.cancelled)
                return
            }
            operation.evaluationID += 1
            let evaluationID = operation.evaluationID
            operation.pendingEvaluation = continuation
            webView.evaluateJavaScript(script) { [weak self, weak operation] value, error in
                Task { @MainActor in
                    guard
                        let self,
                        let operation,
                        self.isActive(operation),
                        operation.evaluationID == evaluationID,
                        let pending = operation.pendingEvaluation
                    else {
                        return
                    }
                    operation.pendingEvaluation = nil
                    if error != nil {
                        pending.resume(throwing: WebReadFailure.transport("DOM evaluation failed"))
                    } else {
                        pending.resume(returning: value)
                    }
                }
            }
        }
    }

    private func finish(_ operation: Operation, returning page: WebReadRenderedPage) {
        finish(operation, result: .success(page))
    }

    private func finish(_ operation: Operation, throwing error: Error) {
        finish(operation, result: .failure(error))
    }

    private func finish(
        _ operation: Operation,
        result: Result<WebReadRenderedPage, Error>
    ) {
        guard !operation.isFinished else { return }
        operation.isFinished = true
        operation.monitorTask?.cancel()
        operation.deadlineTask?.cancel()
        if let observer = operation.foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            operation.foregroundObserver = nil
        }

        if let pending = operation.pendingEvaluation {
            operation.pendingEvaluation = nil
            if case .failure(let error) = result {
                pending.resume(throwing: error)
            } else {
                pending.resume(throwing: WebReadFailure.cancelled)
            }
        }

        if let webView = operation.webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            operation.webView = nil
        }
        if operations[operation.callID] === operation {
            operations.removeValue(forKey: operation.callID)
        }

        guard let continuation = operation.continuation else { return }
        operation.continuation = nil
        switch result {
        case .success(let page):
            continuation.resume(returning: page)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func isActive(_ operation: Operation) -> Bool {
        !operation.isFinished && operations[operation.callID] === operation
    }

    private static func pause(for interval: TimeInterval) async {
        guard interval > 0 else { return }
        let nanos = UInt64(min(interval, 60) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }

    private static func isAllowedURL(_ url: URL) -> Bool {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil
        else {
            return false
        }
        return true
    }

    private static func readinessSnapshot(from value: Any?) -> ReadinessSnapshot? {
        guard
            let fields = value as? [String: Any],
            let hasBody = fields["hasBody"] as? Bool,
            let hasText = fields["hasText"] as? Bool,
            let isReady = fields["isReady"] as? Bool,
            let isLoadingShell = fields["isLoadingShell"] as? Bool
        else {
            return nil
        }
        return ReadinessSnapshot(
            hasBody: hasBody,
            hasText: hasText,
            isReady: isReady,
            isLoadingShell: isLoadingShell,
            targetFound: fields["targetFound"] as? Bool ?? false
        )
    }

    private static func javascriptString(_ value: String?) throws -> String {
        guard let value else { return "null" }
        let data = try JSONSerialization.data(withJSONObject: [value])
        guard let encoded = String(data: data, encoding: .utf8), encoded.count >= 2 else {
            throw WebReadFailure.transport("could not encode the fixed DOM target")
        }
        return String(encoded.dropFirst().dropLast())
    }

    private static func readinessScript(target: String?) throws -> String {
        let targetLiteral = try javascriptString(target)
        return """
        (function() {
            var target = \(targetLiteral);
            var body = document.querySelector("main, article") || document.body;
            var readyState = document.readyState || "loading";
            var hasBody = !!body;
            var maxNodes = 12000;
            var maxText = 600000;
            var scanned = 0;
            var nodeCount = 0;
            var carry = "";
            var targetFound = false;
            var candidateTexts = new Map();
            var normalizedTarget = target == null
                ? null
                : String(target).normalize("NFKC").replace(/\\s+/g, " ").trim().toLowerCase();

            function isExcluded(node) {
                var element = node.parentElement;
                while (element) {
                    var tag = String(element.tagName || "").toLowerCase();
                    if (tag === "script" || tag === "style" || tag === "noscript" ||
                        tag === "template" || tag === "nav" || tag === "footer" ||
                        tag === "aside" || tag === "form" || tag === "svg" ||
                        tag === "iframe" || tag === "object" || tag === "video" || tag === "audio" || element.hidden || element.hasAttribute("inert") ||
                        String(element.getAttribute("aria-hidden") || "").toLowerCase() === "true") {
                        return true;
                    }
                    var inlineStyle = String(element.getAttribute("style") || "").slice(0, 4096);
                    if (/(?:^|;)\\s*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden)/i.test(inlineStyle)) {
                        return true;
                    }
                    if (element === body) break;
                    element = element.parentElement;
                }
                return false;
            }

            if (body) {
                var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
                var node;
                while ((node = walker.nextNode()) && nodeCount < maxNodes && scanned < maxText) {
                    nodeCount += 1;
                    if (isExcluded(node)) continue;
                    var raw = node.nodeValue || "";
                    if (!raw) continue;
                    var part = raw.slice(0, maxText - scanned);
                    scanned += part.length;
                    var normalizedPart = part.normalize("NFKC").replace(/\\s+/g, " ").toLowerCase();
                    if (normalizedTarget) {
                        var probe = carry + normalizedPart;
                        if (probe.indexOf(normalizedTarget) >= 0) {
                            targetFound = true;
                            break;
                        }
                        carry = probe.slice(Math.max(0, probe.length - normalizedTarget.length + 1));
                    }
                    var candidateParent = node.parentElement;
                    while (candidateParent && candidateParent !== body) {
                        var candidateTag = String(candidateParent.tagName || "").toLowerCase();
                        if (["p", "div", "output", "button", "label"].indexOf(candidateTag) >= 0) break;
                        candidateParent = candidateParent.parentElement;
                    }
                    if (candidateParent && candidateParent !== body && candidateTexts.size < maxNodes) {
                        var existingCandidateText = candidateTexts.get(candidateParent) || "";
                        var candidateRoom = Math.max(0, 256 - existingCandidateText.length);
                        if (candidateRoom > 0) {
                            candidateTexts.set(candidateParent, existingCandidateText + part.slice(0, candidateRoom));
                        }
                    }
                }
            }

            function isExcludedElement(element) {
                var current = element;
                while (current) {
                    var tag = String(current.tagName || "").toLowerCase();
                    if (tag === "script" || tag === "style" || tag === "noscript" ||
                        tag === "template" || tag === "nav" || tag === "footer" ||
                        tag === "aside" || tag === "form" || tag === "svg" ||
                        tag === "iframe" || tag === "object" || tag === "video" || tag === "audio" || current.hidden ||
                        current.hasAttribute("inert") ||
                        String(current.getAttribute("aria-hidden") || "").toLowerCase() === "true") {
                        return true;
                    }
                    var inlineStyle = String(current.getAttribute("style") || "").slice(0, 4096);
                    if (/(?:^|;)\\s*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden)/i.test(inlineStyle)) {
                        return true;
                    }
                    if (current === body) break;
                    current = current.parentElement;
                }
                return false;
            }

            var busy = !!(body && body.matches && body.matches(
                '[aria-busy="true"], [role="progressbar"], progress'
            ));
            if (body && !busy) {
                var busyWalker = document.createTreeWalker(body, NodeFilter.SHOW_ELEMENT);
                var busyElement;
                var inspectedBusyElements = 0;
                while ((busyElement = busyWalker.nextNode()) && inspectedBusyElements < maxNodes) {
                    inspectedBusyElements += 1;
                    var busyTag = String(busyElement.tagName || "").toLowerCase();
                    var isBusyElement = busyTag === "progress"
                        || String(busyElement.getAttribute("role") || "").toLowerCase() === "progressbar"
                        || String(busyElement.getAttribute("aria-busy") || "").toLowerCase() === "true";
                    if (isBusyElement && !isExcludedElement(busyElement)) {
                        busy = true;
                        break;
                    }
                }
            }
            var hasStandaloneLoadingText = false;
            var placeholder = /^(loading|please wait|just a moment|正在加载|正在載入|加载中|載入中)([. …!！。]*)$/;
            candidateTexts.forEach(function(candidateText) {
                if (placeholder.test(String(candidateText || "").replace(/\\s+/g, " ").trim().toLowerCase())) {
                    hasStandaloneLoadingText = true;
                }
            });
            var isLoadingShell = busy || hasStandaloneLoadingText;
            var isReady = hasBody && readyState !== "loading" &&
                ((scanned > 0 && !isLoadingShell) || readyState === "complete");
            return {
                hasBody: hasBody,
                hasText: scanned > 0,
                isReady: isReady,
                isLoadingShell: isLoadingShell,
                targetFound: normalizedTarget == null ? false : targetFound
            };
        })()
        """
    }

    private static func renderedPageScript(target: String?, preserveSearchStructure: Bool) throws -> String {
        let targetLiteral = try javascriptString(target)
        let readinessSnapshot = try readinessScript(target: nil)
        return """
        (function() {
            var readiness = \(readinessSnapshot);
            var target = \(targetLiteral);
            var preserveSearchStructure = \(preserveSearchStructure ? "true" : "false");
            var body = document.body || document.documentElement;
            var targetRoot = document.querySelector("main, article") || body;
            var maxHTML = 524288;
            var maxNodes = 12000;
            var html = "";
            var wasTruncated = false;
            var limitReached = false;
            var visited = 0;
            var chunks = [];
            var length = 0;
            var normalizedTarget = target == null
                ? null
                : String(target).normalize("NFKC").replace(/\\s+/g, " ").trim().toLowerCase();
            var targetCarry = "";
            var targetFound = false;
            var voidTags = {
                area: true, base: true, br: true, col: true, embed: true, hr: true,
                img: true, input: true, link: true, meta: true, param: true, source: true,
                track: true, wbr: true
            };
            var allowedAttributes = [
                "href", "src", "alt", "title", "id", "class", "role", "aria-label",
                "colspan", "rowspan", "scope", "datetime", "width", "height",
                "type", "autocomplete", "name", "placeholder", "required", "disabled", "readonly",
                "action", "method", "value"
            ];

            function isHiddenElement(element) {
                if (!element) return false;
                if (element.hidden || element.hasAttribute("inert") ||
                    String(element.getAttribute("aria-hidden") || "").toLowerCase() === "true") {
                    return true;
                }
                var inlineStyle = String(element.getAttribute("style") || "").slice(0, 4096);
                return /(?:^|;)\\s*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden)/i.test(inlineStyle);
            }

            function append(value) {
                if (limitReached || !value) return;
                var room = maxHTML - length;
                if (value.length > room) {
                    chunks.push(value.slice(0, Math.max(0, room)));
                    length = maxHTML;
                    wasTruncated = true;
                    limitReached = true;
                    return;
                }
                chunks.push(value);
                length += value.length;
            }

            function escapeText(value) {
                return String(value).replace(/[&<>"]/g, function(ch) {
                    return ch === "&" ? "&amp;" :
                        ch === "<" ? "&lt;" :
                        ch === ">" ? "&gt;" : "&quot;";
                });
            }

            function escapedCharacter(ch) {
                return ch === "&" ? "&amp;" :
                    ch === "<" ? "&lt;" :
                    ch === ">" ? "&gt;" :
                    ch === '"' ? "&quot;" : ch;
            }

            function recordIncludedText(value) {
                if (!normalizedTarget || targetFound || !value) return;
                var normalized = String(value).normalize("NFKC").replace(/\\s+/g, " ").toLowerCase();
                var probe = targetCarry + normalized;
                if (probe.indexOf(normalizedTarget) >= 0) {
                    targetFound = true;
                    return;
                }
                targetCarry = probe.slice(Math.max(0, probe.length - normalizedTarget.length + 1));
            }

            function appendText(value, includeTarget) {
                var offset = 0;
                while (offset < value.length && !limitReached) {
                    var piece = value.slice(offset, offset + 2048);
                    var escaped = escapeText(piece);
                    var room = maxHTML - length;
                    if (escaped.length <= room) {
                        append(escaped);
                        if (includeTarget) recordIncludedText(piece);
                        offset += piece.length;
                        continue;
                    }

                    var included = "";
                    var encoded = "";
                    for (var i = 0; i < piece.length; i += 1) {
                        var character = escapedCharacter(piece.charAt(i));
                        if (encoded.length + character.length > room) break;
                        included += piece.charAt(i);
                        encoded += character;
                    }
                    append(encoded);
                    if (includeTarget) recordIncludedText(included);
                    offset += included.length;
                    wasTruncated = true;
                    limitReached = true;
                }
                if (offset < value.length) wasTruncated = true;
            }

            function openingTag(element) {
                var tag = String(element.tagName || "").toLowerCase();
                if (!/^[a-z][a-z0-9-]*$/.test(tag)) return "";
                var output = "<" + tag;
                for (var i = 0; i < allowedAttributes.length; i += 1) {
                    var name = allowedAttributes[i];
                    if (!element.hasAttribute(name)) continue;
                    var isNextForm = preserveSearchStructure && tag === "form" &&
                        String(element.getAttribute("class") || "").split(/\\s+/).indexOf("next_form") >= 0;
                    var isNextHiddenInput = preserveSearchStructure && tag === "input" &&
                        String(element.getAttribute("type") || "").toLowerCase() === "hidden" &&
                        !!element.closest("form.next_form");
                    if ((name === "action" || name === "method") && !isNextForm) continue;
                    if (name === "value" && !isNextHiddenInput) continue;
                    var value = element.getAttribute(name) || "";
                    if (name !== "href" || !preserveSearchStructure) {
                      if (value.length > 2048) {
                        value = value.slice(0, 2048);
                        wasTruncated = true;
                      }
                    }
                    output += " " + name + "=\\"" + escapeText(value) + "\\"";
                }
                return output + ">";
            }

            function serialize(root) {
                if (!root) return;
                var stack = [{ node: root, next: null, opened: false }];
                while (stack.length && !limitReached) {
                    var frame = stack[stack.length - 1];
                    var node = frame.node;
                    if (!frame.opened) {
                        frame.opened = true;
                        visited += 1;
                        if (visited > maxNodes) {
                            wasTruncated = true;
                            break;
                        }
                        if (node.nodeType === Node.TEXT_NODE) {
                            if (!isHiddenElement(node.parentElement)) {
                                var outsideContent = node.parentElement && node.parentElement.closest(
                                    "nav, footer, aside, form, svg, iframe, object, video, audio"
                                );
                                appendText(node.nodeValue || "", !outsideContent && targetRoot.contains(node));
                            }
                            stack.pop();
                            continue;
                        }
                        if (node.nodeType !== Node.ELEMENT_NODE) {
                            stack.pop();
                            continue;
                        }
                        var tagName = String(node.tagName || "").toLowerCase();
                        if (tagName === "script" || tagName === "style" ||
                            tagName === "noscript" || tagName === "template" ||
                            isHiddenElement(node)) {
                            stack.pop();
                            continue;
                        }
                        var start = openingTag(node);
                        if (!start) {
                            stack.pop();
                            continue;
                        }
                        append(start);
                        if (voidTags[tagName]) {
                            stack.pop();
                            continue;
                        }
                        frame.next = node.firstChild;
                    } else if (frame.next) {
                        var child = frame.next;
                        frame.next = child.nextSibling;
                        stack.push({ node: child, next: null, opened: false });
                    } else {
                        var closingTag = String(node.tagName || "").toLowerCase();
                        append("</" + closingTag + ">");
                        stack.pop();
                    }
                }
                if (stack.length) wasTruncated = true;
            }

            serialize(body);
            html = chunks.join("");
            var title = String(document.title || "");
            if (title.length > 512) title = "";
            return {
                title: title,
                url: location.href,
                html: html,
                truncated: wasTruncated,
                targetFound: normalizedTarget == null ? false : targetFound,
                hasLoadingIndicator: !!readiness.isLoadingShell
            };
        })()
        """
    }

    private func actionPolicy(
        for action: WKNavigationAction,
        in webView: WKWebView
    ) -> WKNavigationActionPolicy {
        guard let operation = operation(for: webView), isActive(operation) else {
            return .cancel
        }
        guard Date() < operation.deadline else {
            finish(operation, throwing: WebReadFailure.deadlineExceeded)
            return .cancel
        }
        guard let targetFrame = action.targetFrame else {
            return .cancel
        }
        guard let url = action.request.url, Self.isAllowedURL(url) else {
            if targetFrame.isMainFrame {
                finish(operation, throwing: WebReadFailure.restricted)
            }
            return .cancel
        }
        guard !action.shouldPerformDownload else {
            return .cancel
        }

        if targetFrame.isMainFrame {
            switch action.navigationType {
            case .linkActivated, .formSubmitted, .formResubmitted, .backForward:
                return .cancel
            default:
                break
            }
            operation.mainFrameNavigationCount += 1
            guard operation.mainFrameNavigationCount <= Self.maximumMainFrameNavigations else {
                finish(operation, throwing: WebReadFailure.restricted)
                return .cancel
            }
        } else {
            operation.subframeNavigationCount += 1
            guard operation.subframeNavigationCount <= Self.maximumSubframeNavigations else {
                return .cancel
            }
        }
        return .allow
    }

    private func responsePolicy(
        for navigationResponse: WKNavigationResponse,
        in webView: WKWebView
    ) -> WKNavigationResponsePolicy {
        guard let operation = operation(for: webView), isActive(operation) else {
            return .cancel
        }
        guard Date() < operation.deadline else {
            finish(operation, throwing: WebReadFailure.deadlineExceeded)
            return .cancel
        }

        let isMainFrame = navigationResponse.isForMainFrame
        guard
            let url = navigationResponse.response.url,
            Self.isAllowedURL(url),
            navigationResponse.canShowMIMEType
        else {
            if isMainFrame {
                finish(operation, throwing: WebReadFailure.restricted)
            }
            return .cancel
        }

        if let httpResponse = navigationResponse.response as? HTTPURLResponse {
            if isMainFrame {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    finish(operation, throwing: WebReadFailure.restricted)
                    return .cancel
                }
                if httpResponse.statusCode >= 400 {
                    finish(operation, throwing: WebReadFailure.transport("HTTP response was unsuccessful"))
                    return .cancel
                }
                // 这里只能拒绝已声明超限的响应，不能保证限制 WebKit 子资源的实际传输量。
                if httpResponse.expectedContentLength > Int64(maximumMainResponseBytes) {
                    finish(operation, throwing: WebReadFailure.responseTooLarge)
                    return .cancel
                }
            }
            let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            let mimeType = httpResponse.mimeType?.lowercased() ?? ""
            let isDownload = disposition.contains("attachment")
            let isUnsupportedDocument =
                mimeType == "application/pdf" ||
                mimeType.hasPrefix("image/") ||
                mimeType.hasPrefix("audio/") ||
                mimeType.hasPrefix("video/") ||
                mimeType == "application/octet-stream"
            if isDownload || isUnsupportedDocument {
                if isMainFrame {
                    finish(operation, throwing: WebReadFailure.restricted)
                }
                return .cancel
            }
            if isMainFrame {
                operation.responseReceivedAt = Date()
            }
        }
        return .allow
    }

    private func operation(for webView: WKWebView) -> Operation? {
        operations.values.first { $0.webView === webView }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(actionPolicy(for: navigationAction, in: webView))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        decisionHandler(actionPolicy(for: navigationAction, in: webView), preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(responsePolicy(for: navigationResponse, in: webView))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationResponsePolicy, WKWebpagePreferences) -> Void
    ) {
        decisionHandler(responsePolicy(for: navigationResponse, in: webView), preferences)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        guard let operation = operation(for: webView), isActive(operation) else { return }
        operation.hasCommittedDocument = false
        operation.latestReadiness = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        guard let operation = operation(for: webView), isActive(operation) else { return }
        operation.hasCommittedDocument = true
        operation.latestReadiness = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        guard let operation = operation(for: webView), isActive(operation) else { return }
        finish(operation, throwing: WebReadFailure.transport("page navigation failed"))
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        guard let operation = operation(for: webView), isActive(operation) else { return }
        finish(operation, throwing: WebReadFailure.transport("page navigation failed"))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let operation = operation(for: webView), isActive(operation) else { return }
        finish(operation, throwing: WebReadFailure.transport("WebKit content process terminated"))
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let operation = operation(for: webView), isActive(operation) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            let challengeHost = challenge.protectionSpace.host.lowercased()
            let mainHost = webView.url?.host?.lowercased()
            if challengeHost == mainHost {
                finish(operation, throwing: WebReadFailure.restricted)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(false)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        completionHandler(nil)
    }
}
