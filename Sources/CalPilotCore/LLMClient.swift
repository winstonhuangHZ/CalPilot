import Foundation

/// The seam the agent talks to, so the turn loop can be exercised without a network.
public protocol LLMChatClient {
    var modelName: String { get }
    func complete(
        messages: [LLMClient.Message],
        tools: [LLMClient.ToolDefinition],
        options: LLMClient.Options
    ) async throws -> LLMClient.Completion
    func chat(messages: [LLMClient.Message], options: LLMClient.Options) async throws -> String
}

public extension LLMChatClient {
    func chat(messages: [LLMClient.Message], options: LLMClient.Options = .init()) async throws -> String {
        let completion = try await complete(messages: messages, tools: [], options: options)
        guard let content = completion.content, !content.isEmpty else {
            throw LLMClient.LLMError.emptyResponse
        }
        return content
    }
}

/// Minimal client for any OpenAI-compatible `/chat/completions` endpoint
/// (OpenAI, DeepSeek, Moonshot, Together, Ollama, LM Studio, ...).
public struct LLMClient: LLMChatClient {
    public var modelName: String { model }
    public struct Message: Codable {
        public var role: String
        public var content: String?
        public var toolCalls: [ToolCall]?
        public var toolCallID: String?
        public var name: String?

        enum CodingKeys: String, CodingKey {
            case role, content, name
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        public init(
            role: String,
            content: String?,
            toolCalls: [ToolCall]? = nil,
            toolCallID: String? = nil,
            name: String? = nil
        ) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
            self.name = name
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            try container.encodeIfPresent(content, forKey: .content)
            try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
            try container.encodeIfPresent(name, forKey: .name)
        }

        public static func system(_ content: String) -> Message { Message(role: "system", content: content) }
        public static func user(_ content: String) -> Message { Message(role: "user", content: content) }
        public static func assistant(_ content: String) -> Message { Message(role: "assistant", content: content) }
        public static func tool(callID: String, name: String, content: String) -> Message {
            Message(role: "tool", content: content, toolCallID: callID, name: name)
        }
    }

    public struct ToolCall: Codable, Hashable {
        public struct Function: Codable, Hashable {
            public var name: String
            public var arguments: String

            public init(name: String, arguments: String) {
                self.name = name
                self.arguments = arguments
            }
        }
        public var id: String
        public var type: String
        public var function: Function

        public init(id: String, type: String = "function", function: Function) {
            self.id = id
            self.type = type
            self.function = function
        }

        /// Parsed `arguments` payload; empty object when the model sent nothing usable.
        public var arguments: [String: JSONValue] {
            guard let data = function.arguments.data(using: .utf8),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let object = value.objectValue
            else { return [:] }
            return object
        }
    }

    public struct ToolDefinition: Codable {
        public struct Function: Codable {
            public var name: String
            public var description: String
            public var parameters: JSONValue
        }
        public var type: String = "function"
        public var function: Function

        public init(name: String, description: String, parameters: JSONValue) {
            self.function = Function(name: name, description: description, parameters: parameters)
        }
    }

    /// A structured completion: either assistant text, tool calls, or both.
    public struct Completion {
        public var content: String?
        public var toolCalls: [ToolCall]
        public var finishReason: String?
        public var usage: TokenUsage?

        public var text: String { content ?? "" }
        public var wantsTools: Bool { !toolCalls.isEmpty }

        public init(
            content: String?,
            toolCalls: [ToolCall],
            finishReason: String? = nil,
            usage: TokenUsage? = nil
        ) {
            self.content = content
            self.toolCalls = toolCalls
            self.finishReason = finishReason
            self.usage = usage
        }
    }

    /// Token accounting, including the provider-specific prompt-cache split.
    public struct TokenUsage: Codable, Equatable {
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var cacheHitTokens: Int?
        public var cacheMissTokens: Int?

        /// Fraction of the input served from the provider's prefix cache.
        public var cacheHitRatio: Double? {
            guard let hit = cacheHitTokens else { return nil }
            let miss = cacheMissTokens ?? (promptTokens.map { max(0, $0 - hit) } ?? 0)
            let total = hit + miss
            guard total > 0 else { return nil }
            return Double(hit) / Double(total)
        }

        public init(
            promptTokens: Int? = nil,
            completionTokens: Int? = nil,
            cacheHitTokens: Int? = nil,
            cacheMissTokens: Int? = nil
        ) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.cacheHitTokens = cacheHitTokens
            self.cacheMissTokens = cacheMissTokens
        }

        public mutating func add(_ other: TokenUsage) {
            func plus(_ a: Int?, _ b: Int?) -> Int? {
                guard a != nil || b != nil else { return nil }
                return (a ?? 0) + (b ?? 0)
            }
            promptTokens = plus(promptTokens, other.promptTokens)
            completionTokens = plus(completionTokens, other.completionTokens)
            cacheHitTokens = plus(cacheHitTokens, other.cacheHitTokens)
            cacheMissTokens = plus(cacheMissTokens, other.cacheMissTokens)
        }
    }

    public struct Options {
        public var temperature: Double
        public var maxTokens: Int?
        public var jsonMode: Bool
        public var timeout: TimeInterval

        public init(temperature: Double = 0.2, maxTokens: Int? = nil, jsonMode: Bool = true, timeout: TimeInterval = 120) {
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.jsonMode = jsonMode
            self.timeout = timeout
        }
    }

    public enum LLMError: Error, CustomStringConvertible {
        case badEndpoint(String)
        case http(status: Int, body: String)
        case emptyResponse
        case decoding(String)
        case toolsUnsupported(String)

        public var description: String {
            switch self {
            case let .badEndpoint(url):
                return "The configured base URL is not valid: \(url)"
            case let .http(status, body):
                let trimmed = body.count > 800 ? String(body.prefix(800)) + "…" : body
                return "The language model endpoint returned HTTP \(status): \(trimmed)"
            case .emptyResponse:
                return "The language model returned an empty response."
            case let .decoding(message):
                return "Could not understand the language model response: \(message)"
            case let .toolsUnsupported(detail):
                return "This endpoint does not support tool calling: \(detail)"
            }
        }
    }

    public let config: AppConfig
    public let apiKey: String
    public let model: String

    public init(config: AppConfig, apiKey: String, model: String? = nil) {
        self.config = config
        self.apiKey = apiKey
        self.model = model ?? config.model
    }

    public var endpoint: URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var path = config.chatPath
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(string: base + path)
    }

    // MARK: - Chat

    /// Single-shot text completion (used by the planner and the doctor check).
    public func chat(messages: [Message], options: Options = Options()) async throws -> String {
        let completion = try await complete(messages: messages, tools: [], options: options)
        guard let content = completion.content, !content.isEmpty else {
            throw LLMError.emptyResponse
        }
        return content
    }

    /// Full completion with optional tool calling. Falls back gracefully when the
    /// endpoint rejects `tools` or `response_format`.
    public func complete(
        messages: [Message],
        tools: [ToolDefinition] = [],
        options: Options = Options()
    ) async throws -> Completion {
        guard let endpoint else { throw LLMError.badEndpoint(config.baseURL) }
        func body(jsonMode: Bool) -> RequestBody {
            RequestBody(
                model: model,
                messages: messages,
                temperature: options.temperature,
                max_tokens: options.maxTokens,
                response_format: jsonMode ? ["type": "json_object"] : nil,
                tools: tools.isEmpty ? nil : tools,
                tool_choice: tools.isEmpty ? nil : "auto",
                stream: false
            )
        }
        do {
            return try await send(body(jsonMode: options.jsonMode), to: endpoint, options: options)
        } catch let LLMError.http(status, responseBody) {
            let lower = responseBody.lowercased()
            let mentionsTools = lower.contains("tool") || lower.contains("function")
            if !tools.isEmpty, [400, 404, 422, 500].contains(status), mentionsTools {
                throw LLMError.toolsUnsupported(
                    responseBody.count > 300 ? String(responseBody.prefix(300)) + "…" : responseBody
                )
            }
            // Some OpenAI-compatible servers reject `response_format`; retry in plain mode.
            if options.jsonMode, status == 400 || status == 422 {
                var relaxed = options
                relaxed.jsonMode = false
                return try await send(body(jsonMode: false), to: endpoint, options: relaxed)
            }
            throw LLMError.http(status: status, body: responseBody)
        }
    }

    private func send(_ body: RequestBody, to endpoint: URL, options: Options) async throws -> Completion {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = options.timeout
        // Byte-stable encoding is what makes the provider's prefix cache hit at all:
        // identical payloads must serialize to identical bytes across process launches.
        request.httpBody = try Self.payloadEncoder.encode(body)

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = options.timeout
        sessionConfig.timeoutIntervalForResource = options.timeout + 30
        let session = URLSession(configuration: sessionConfig)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw LLMError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let choice = decoded.choices.first
        else {
            throw LLMError.emptyResponse
        }
        let completion = Completion(
            content: choice.message.content,
            toolCalls: choice.message.tool_calls ?? [],
            finishReason: choice.finish_reason,
            usage: decoded.usage?.normalized(withPromptTotal: decoded.usage?.prompt_tokens)
        )
        guard completion.content?.isEmpty == false || completion.wantsTools else {
            throw LLMError.emptyResponse
        }
        return completion
    }

    /// Cheap reachability check used by `calpilot doctor`.
    public func ping() async throws -> String {
        let reply = try await chat(
            messages: [
                .system("You answer with bare JSON only."),
                .user(#"Reply with {"ok": true} and nothing else."#),
            ],
            options: Options(temperature: 0, maxTokens: 32, jsonMode: true, timeout: 30)
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Wire types

    /// `.sortedKeys` makes nested tool schemas (plain dictionaries) byte-stable too.
    private static let payloadEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private struct RequestBody: Encodable {
        var model: String
        var messages: [Message]
        var temperature: Double
        var max_tokens: Int?
        var response_format: [String: String]?
        var tools: [ToolDefinition]?
        var tool_choice: String?
        var stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream, tools
            case max_tokens
            case response_format
            case tool_choice
        }

        /// Optional fields are omitted rather than emitted as `null`, so a tool-less
        /// request stays byte-identical to a plain OpenAI request.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encode(temperature, forKey: .temperature)
            try container.encode(stream, forKey: .stream)
            try container.encodeIfPresent(max_tokens, forKey: .max_tokens)
            try container.encodeIfPresent(response_format, forKey: .response_format)
            try container.encodeIfPresent(tool_choice, forKey: .tool_choice)
            try container.encodeIfPresent(tools, forKey: .tools)
        }
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Reply: Decodable {
                var content: String?
                var tool_calls: [ToolCall]?
            }
            var message: Reply
            var finish_reason: String?
        }

        /// Relays report different subsets; `prompt_cache_hit_tokens` comes from
        /// DeepSeek, `prompt_tokens_details.cached_tokens` from OpenAI.
        struct Usage: Decodable {
            struct PromptDetails: Decodable {
                var cached_tokens: Int?
            }
            var prompt_tokens: Int?
            var completion_tokens: Int?
            var total_tokens: Int?
            var prompt_cache_hit_tokens: Int?
            var prompt_cache_miss_tokens: Int?
            var prompt_tokens_details: PromptDetails?
            var cache_creation_input_tokens: Int?
            var cache_read_input_tokens: Int?

            func normalized(withPromptTotal total: Int?) -> TokenUsage {
                let hit = prompt_cache_hit_tokens
                    ?? prompt_tokens_details?.cached_tokens
                    ?? cache_read_input_tokens
                var miss = prompt_cache_miss_tokens
                if miss == nil, let hit, let total {
                    miss = max(0, total - hit)
                }
                return TokenUsage(
                    promptTokens: total,
                    completionTokens: completion_tokens,
                    cacheHitTokens: hit,
                    cacheMissTokens: miss
                )
            }
        }

        var choices: [Choice]
        var usage: Usage?
    }
}

// MARK: - JSON extraction

public enum JSONExtraction {
    /// Pulls the first JSON object out of a model reply, tolerating ```json fences
    /// and trailing prose.
    public static func firstObject(in raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fenceStart = text.range(of: "```") {
            let afterFence = text[fenceStart.upperBound...]
            let body = afterFence.hasPrefix("json") ? afterFence.dropFirst(4) : afterFence
            if let fenceEnd = body.range(of: "```") {
                text = String(body[..<fenceEnd.lowerBound])
            }
        }
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if escaped {
                escaped = false
            } else if char == "\\" && inString {
                escaped = true
            } else if char == "\"" {
                inString.toggle()
            } else if !inString {
                if char == "{" { depth += 1 }
                if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
