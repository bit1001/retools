import Foundation

enum AIStreamEvent: Equatable, Sendable {
    case text(String)
    case imageSource(String)
    case image(Data)
    case finished(limited: Bool)
}

struct AISSEDecoder {
    let provider: AIProvider
    var maximumEventBytes = 1_000_000
    private var lines: [String] = []
    private var byteCount = 0
    private var limited = false
    private var images: [Int: String] = [:]
    private(set) var ended = false
    // Synthesized memberwise init is private (private stored properties); expose an internal one.
    init(provider: AIProvider, maximumEventBytes: Int = 1_000_000) {
        self.provider = provider
        self.maximumEventBytes = maximumEventBytes
    }
    mutating func feed(_ input: String) throws -> [AIStreamEvent] {
        var line = input
        if line.hasPrefix("\u{feff}") { line.removeFirst() }
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty { return try flush() }
        guard line.hasPrefix("data:") else { return [] }
        var data = String(line.dropFirst(5)); if data.hasPrefix(" ") { data.removeFirst() }
        byteCount += data.utf8.count
        guard byteCount <= maximumEventBytes else { throw WorkspaceFailure("接口返回的单条数据过大。") }
        lines.append(data); return []
    }
    mutating func flush() throws -> [AIStreamEvent] {
        guard !lines.isEmpty else { return [] }
        let payload = lines.joined(separator: "\n"); lines.removeAll(keepingCapacity: true); byteCount = 0
        if payload == "[DONE]" { ended = true; return imageEvents() + [.finished(limited: limited)] }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { throw WorkspaceFailure("接口返回了无效的流式数据。") }
        if let error = object["error"] { throw WorkspaceFailure(AIChatClient.errorMessage(error)) }
        if provider == .openAI {
            let choices = object["choices"] as? [[String: Any]] ?? []
            guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return [] }
            var events: [AIStreamEvent] = []
            if let delta = choice["delta"] as? [String: Any] {
                if let text = delta["content"] as? String, !text.isEmpty { events.append(.text(text)) }
                else if let refusal = delta["refusal"] as? String, !refusal.isEmpty { events.append(.text(refusal)) }
                let blocks = (delta["images"] as? [[String: Any]] ?? []) + (delta["content"] as? [[String: Any]] ?? [])
                for (offset, block) in blocks.enumerated() {
                    guard let source = AIChatClient.imageSources(["content": [block]]).first else { continue }
                    let index = block["index"] as? Int ?? offset
                    guard (0..<4).contains(index) else { throw WorkspaceFailure("接口一次返回的图片过多。") }
                    if source.hasPrefix("data:") || source.hasPrefix("https://") { images[index] = source }
                    else { images[index, default: ""] += source }
                }
            }
            if let reason = choice["finish_reason"] as? String {
                ended = true; events += imageEvents(); events.append(.finished(limited: reason == "length"))
            }
            return events
        }
        switch object["type"] as? String {
        case "content_block_start":
            if let block = object["content_block"] as? [String: Any], block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty { return [.text(text)] }
            if let block = object["content_block"] as? [String: Any], let source = AIChatClient.imageSources(["content": [block]]).first { images[object["index"] as? Int ?? 0] = source }
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String { return [.text(text)] }
        case "message_delta": limited = (object["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens"
        case "message_stop": ended = true; return imageEvents() + [.finished(limited: limited)]
        default: break
        }
        return []
    }
    private mutating func imageEvents() -> [AIStreamEvent] {
        let events = images.keys.sorted().compactMap { images[$0] }.map(AIStreamEvent.imageSource)
        images.removeAll(); return events
    }
}

struct AISSEByteDecoder {
    private var decoder: AISSEDecoder
    private var line = Data()
    private var afterCR = false
    private let maximumLineBytes: Int
    var ended: Bool { decoder.ended }
    init(provider: AIProvider, maximumEventBytes: Int = 1_000_000) { decoder = AISSEDecoder(provider: provider, maximumEventBytes: maximumEventBytes); maximumLineBytes = maximumEventBytes }
    mutating func feed(_ byte: UInt8) throws -> [AIStreamEvent] {
        if byte == 13 { afterCR = true; return try flushLine() }
        if byte == 10 {
            if afterCR { afterCR = false; return [] }
            return try flushLine()
        }
        afterCR = false
        guard line.count < maximumLineBytes else { throw WorkspaceFailure("接口返回的单行数据过大。") }
        line.append(byte); return []
    }
    private mutating func flushLine() throws -> [AIStreamEvent] {
        guard let text = String(data: line, encoding: .utf8) else { throw WorkspaceFailure("接口返回了无效的 UTF-8 数据。") }
        line.removeAll(keepingCapacity: true)
        return try decoder.feed(text)
    }
    mutating func finish() throws -> [AIStreamEvent] {
        var events: [AIStreamEvent] = []
        if !line.isEmpty { events += try flushLine() }
        events += try decoder.flush()
        return events
    }
}

protocol AIChatStreaming: Sendable {
    func stream(connection: AIChatConnection, key: String, messages: [AIChatMessage], attachmentsDirectory: URL?) -> AsyncThrowingStream<AIStreamEvent, Error>
}

final class AIHTTPRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct AIChatClient: AIChatStreaming {
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 600
            configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration, delegate: AIHTTPRedirectGuard(), delegateQueue: nil)
        }
    }
    /// 图像接口（非流式）可以交给后台会话完成。
    static func isNativeImage(_ connection: AIChatConnection) -> Bool {
        connection.provider == .openAI && ["/images/generations", "/images/edits", "/images"].contains(where: connection.url.path.hasSuffix)
    }

    /// 后台图像请求的结果：文字与要下载的图片地址；失败时抛出与前台一致的说明。
    static func backgroundResult(status: Int, body: Data) throws -> (text: String, images: [String]) {
        guard (200..<300).contains(status) else {
            if status == 0 { throw WorkspaceFailure(String(decoding: body.prefix(2000), as: UTF8.self)) }
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let detail = object?["error"].map(errorMessage) ?? (object?["message"] as? String)
            throw WorkspaceFailure("API 返回 HTTP \(status)" + (detail.map { "：" + $0 } ?? "，请检查地址、模型与密钥。"))
        }
        var text = "", images: [String] = []
        for event in try completeResponse(body, provider: .openAI) {
            switch event {
            case .text(let value): text += value
            case .imageSource(let source): images.append(source)
            default: break
            }
        }
        if images.isEmpty { images = imageLinks(in: text) }
        return (text, images)
    }

    static func request(connection: AIChatConnection, key: String, messages: [AIChatMessage], attachmentsDirectory: URL? = nil) throws -> URLRequest {
        guard !key.contains(where: \.isNewline) else { throw WorkspaceFailure("API Key 含有换行，请重新填写。") }
        if connection.provider == .openAI, ["/images/generations", "/images/edits", "/images"].contains(where: connection.url.path.hasSuffix) { return try AIRequestContent.nativeImageRequest(connection: connection, key: key, messages: messages, directory: attachmentsDirectory) }
        let turns = try AIRequestContent.messages(messages, provider: connection.provider, directory: attachmentsDirectory)
        guard !turns.isEmpty else { throw WorkspaceFailure("请先输入消息。") }
        var body: [String: Any] = ["model": connection.model, "messages": turns, "stream": true]
        var request = URLRequest(url: connection.url); request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if connection.provider == .openAI {
            if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            if !connection.systemPrompt.isEmpty { body["messages"] = [["role": "system", "content": connection.systemPrompt]] + turns }
            if connection.outputModalities?.contains("image") == true || AIModelRouting.requestsImageOutput(connection.model) { body["modalities"] = ["text", "image"] }
        } else {
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue(connection.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            body["max_tokens"] = connection.maxTokens
            if !connection.systemPrompt.isEmpty { body["system"] = connection.systemPrompt }
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= (connection.provider == .anthropic ? 32_000_000 : 70_000_000) else { throw WorkspaceFailure("这段对话或附件过大，请减少附件或新建对话。") }
        request.httpBody = data; return request
    }
    static func errorMessage(_ value: Any) -> String {
        if let error = value as? [String: Any], let message = error["message"] as? String { return String(message.prefix(1000)) }
        return String((value as? String ?? "接口返回了错误。").prefix(1000))
    }
    static func completeResponse(_ data: Data, provider: AIProvider) throws -> [AIStreamEvent] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkspaceFailure("接口未返回支持的对话格式，请检查请求地址。") }
        if let error = object["error"] { throw WorkspaceFailure(errorMessage(error)) }
        let text: String, limited: Bool
        var sources: [String] = []
        if let data = object["data"] as? [[String: Any]] {
            for item in data {
                if let image = item["b64_json"] as? String { sources.append("data:image/png;base64," + image) }
                else if let url = item["url"] as? String { sources.append(url) }
            }
        }
        if provider == .openAI {
            let choice = (object["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            text = message?["content"] as? String ?? (message?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? message?["refusal"] as? String ?? ""
            limited = choice?["finish_reason"] as? String == "length"
            if let message { sources += imageSources(message) }
        } else {
            text = (object["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            limited = object["stop_reason"] as? String == "max_tokens"
            sources += imageSources(object)
        }
        guard !text.isEmpty || !sources.isEmpty else { throw WorkspaceFailure("接口没有返回可显示的内容，请检查模型配置。") }
        guard sources.count <= 4 else { throw WorkspaceFailure("接口一次返回的图片过多。") }
        return (text.isEmpty ? [] : [.text(text)]) + sources.map(AIStreamEvent.imageSource) + [.finished(limited: limited)]
    }
    static func imageSources(_ object: [String: Any]) -> [String] {
        let blocks = (object["images"] as? [[String: Any]] ?? []) + (object["content"] as? [[String: Any]] ?? [])
        return blocks.compactMap { block in
            if let value = (block["image_url"] as? [String: Any])?["url"] as? String { return value }
            if let value = block["image_url"] as? String { return value }
            if block["type"] as? String == "image", let source = block["source"] as? [String: Any] {
                if let data = source["data"] as? String { return "data:\(source["media_type"] as? String ?? "image/png");base64," + data }
                return source["url"] as? String
            }
            return nil
        }
    }
    /// 回答文字中的图片链接：Markdown 图片 ![…](…)、指向图片文件的链接和 data:image 内容。
    /// 部分中转接口把生成结果（包括 GIF）写成文字链接，而不是图片字段。
    static func imageLinks(in text: String) -> [String] {
        let patterns = [#"!\[[^\]]*\]\(\s*<?((?:https?://|data:image/)[^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#,
                        #"(?i)\bhttps?://[^\s)\]>"'，。]+?\.(?:png|jpe?g|gif|webp|heic|avif)(?:\?[^\s)\]>"'，。]*)?(?=[\s)\]>"'，。]|$)"#]
        var links: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: text, range: range) {
                let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
                guard let found = Range(group, in: text) else { continue }
                let link = String(text[found])
                if !links.contains(link) { links.append(link) }
            }
        }
        return Array(links.prefix(4))
    }
    func imageData(_ source: String, relativeTo base: URL) async throws -> Data {
        if source.hasPrefix("data:image/"), let comma = source.range(of: ";base64,") {
            guard source.utf8.count <= 45_000_000, let data = Data(base64Encoded: String(source[comma.upperBound...]), options: .ignoreUnknownCharacters), data.count <= AIChatFiles.maximumFileBytes else { throw WorkspaceFailure("接口返回的图片编码无效或过大。") }
            return data
        }
        // 明文 http 会被系统拦截，改用 https 尝试。
        guard let resolved = URL(string: source, relativeTo: base)?.absoluteURL, var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { throw WorkspaceFailure("接口返回了无效的图片地址。") }
        if parts.scheme == "http" { parts.scheme = "https" }
        guard let url = parts.url, parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil else { throw WorkspaceFailure("接口返回了无效的图片地址。") }
        var request = URLRequest(url: url); request.timeoutInterval = 120
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw WorkspaceFailure("无法下载模型返回的图片。") }
        return try await withTaskCancellationHandler {
            var data = Data()
            for try await byte in bytes { try Task.checkCancellation(); guard data.count < AIChatFiles.maximumFileBytes else { throw WorkspaceFailure("生成图片超过大小限制。") }; data.append(byte) }
            return data
        } onCancel: { bytes.task.cancel() }
    }
    func stream(connection: AIChatConnection, key: String, messages: [AIChatMessage], attachmentsDirectory: URL? = nil) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.request(connection: connection, key: key, messages: messages, attachmentsDirectory: attachmentsDirectory)
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    try await withTaskCancellationHandler {
                    guard let response = response as? HTTPURLResponse else { throw WorkspaceFailure("没有收到有效的 API 响应。") }
                    if !(200..<300).contains(response.statusCode) {
                        var data = Data()
                        for try await byte in bytes { if data.count >= 65536 { break }; data.append(byte) }
                        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let detail = object?["error"].map(Self.errorMessage) ?? (object?["message"] as? String)
                        throw WorkspaceFailure("API 返回 HTTP \(response.statusCode)" + (detail.map { "：" + $0 } ?? ((300..<400).contains(response.statusCode) ? "：请填写重定向后的最终 API 地址。" : "，请检查地址、模型与密钥。")))
                    }
                    var replyText = "", imageCount = 0
                    // 回答结束前，如果没有收到图片字段，就把文字里的图片链接当作生成结果下载。
                    func emit(_ event: AIStreamEvent) async throws {
                        switch event {
                        case .text(let text): replyText += text; continuation.yield(event)
                        case .imageSource(let source):
                            imageCount += 1; guard imageCount <= 4 else { throw WorkspaceFailure("接口一次返回的图片过多。") }
                            continuation.yield(.image(try await imageData(source, relativeTo: connection.url)))
                        case .finished:
                            if imageCount == 0 {
                                for link in Self.imageLinks(in: replyText) {
                                    if let data = try? await imageData(link, relativeTo: connection.url) { imageCount += 1; continuation.yield(.image(data)) }
                                }
                            }
                            continuation.yield(event)
                        default: continuation.yield(event)
                        }
                    }
                    let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    if !contentType.contains("text/event-stream") {
                        // 非流式回答（图像接口或未开启流式的中转），按完整 JSON 读取；Content-Type 标错时也能识别。
                        var data = Data()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            guard data.count < 60_000_000 else { throw WorkspaceFailure("接口响应过大。") }
                            data.append(byte)
                        }
                        let first = data.first { ![0x20, 0x09, 0x0a, 0x0d].contains($0) }
                        if first == UInt8(ascii: "{") || contentType.contains("json") {
                            for event in try Self.completeResponse(data, provider: connection.provider) { try await emit(event) }
                        } else {
                            var decoder = AISSEByteDecoder(provider: connection.provider, maximumEventBytes: 45_000_000)
                            for byte in data { for event in try decoder.feed(byte) { try await emit(event) }; if decoder.ended { break } }
                            for event in try decoder.finish() { try await emit(event) }
                            guard decoder.ended || !replyText.isEmpty || imageCount > 0 else { throw WorkspaceFailure("接口未返回支持的对话格式，请检查请求地址。") }
                        }
                    } else {
                        var decoder = AISSEByteDecoder(provider: connection.provider, maximumEventBytes: 45_000_000), totalCount = 0
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            totalCount += 1
                            guard totalCount <= 80_000_000 else { throw WorkspaceFailure("接口响应过大。") }
                            for event in try decoder.feed(byte) {
                                try await emit(event)
                                guard replyText.utf8.count <= 2_000_000 else { throw WorkspaceFailure("回答过长，已保留收到的内容。") }
                            }
                            if decoder.ended { break }
                        }
                        for event in try decoder.finish() {
                            try await emit(event)
                            guard replyText.utf8.count <= 2_000_000 else { throw WorkspaceFailure("回答过长，已保留收到的内容。") }
                        }
                        guard decoder.ended else { throw WorkspaceFailure("连接在回答完成前中断，已保留收到的内容。") }
                        guard !replyText.isEmpty || imageCount > 0 else { throw WorkspaceFailure("接口没有返回可显示的内容，请检查模型配置。") }
                    }
                    } onCancel: { bytes.task.cancel() }
                    continuation.finish()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { continuation.finish(throwing: CancellationError()) }
                    else { continuation.finish(throwing: WorkspaceFailure(AuthDiagnostics.sanitized(error.localizedDescription, secrets: [key]))) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
