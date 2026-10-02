import Foundation

enum PublicAIProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case gemini = "gemini"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        }
    }
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "publicAIProvider") ?? "openai") ?? .openAI
    }
}

enum PublicAITransport {
    static func send(body: [String: Any], key: String, provider: PublicAIProvider = .selected,
                     timeout: TimeInterval = 60) async throws -> (Data, URLResponse) {
        if provider != .openAI,
           let messages = body["input"] as? [[String: Any]],
           messages.contains(where: { message in
               (message["content"] as? [[String: Any]] ?? []).contains(where: {
                   $0["type"] as? String == "input_file" &&
                   !((($0["file_data"] as? String) ?? "").hasPrefix("data:application/pdf;"))
               })
           }) {
            throw NSError(domain: "PublicAITransport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "所选服务商暂不支持 DOC/DOCX 直传；请转为 PDF 或使用 OpenAI。"])
        }
        let request: URLRequest
        switch provider {
        case .openAI:
            var openAI = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            openAI.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            openAI.httpBody = try JSONSerialization.data(withJSONObject: body)
            request = openAI
        case .anthropic:
            var anthropic = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            anthropic.setValue(key, forHTTPHeaderField: "x-api-key")
            anthropic.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var payload: [String: Any] = [
                "model": "claude-sonnet-5", "max_tokens": body["max_output_tokens"] ?? 2200,
                "system": instructions(from: body),
                "messages": [["role": "user", "content": content(from: body)]]
            ]
            if body["tools"] != nil {
                payload["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]]
            }
            anthropic.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request = anthropic
        case .gemini:
            var gemini = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent")!)
            gemini.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var payload: [String: Any] = [
                "systemInstruction": ["parts": [["text": instructions(from: body)]]],
                "contents": [["role": "user", "parts": geminiParts(from: body)]],
                "generationConfig": ["responseMimeType": body["text"] == nil ? "text/plain" : "application/json"]
            ]
            if body["tools"] != nil { payload["tools"] = [["google_search": [:]]] }
            gemini.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request = gemini
        }
        var outgoing = request
        outgoing.httpMethod = "POST"
        outgoing.timeoutInterval = timeout
        outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: outgoing)
        guard provider != .openAI,
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return (data, response) }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let text: String
        let inputTokens: Int
        let outputTokens: Int
        switch provider {
        case .anthropic:
            text = (raw["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
            let usage = raw["usage"] as? [String: Any] ?? [:]
            inputTokens = usage["input_tokens"] as? Int ?? 0
            outputTokens = usage["output_tokens"] as? Int ?? 0
        case .gemini:
            text = (raw["candidates"] as? [[String: Any]] ?? [])
                .flatMap { ($0["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            let usage = raw["usageMetadata"] as? [String: Any] ?? [:]
            inputTokens = usage["promptTokenCount"] as? Int ?? 0
            outputTokens = usage["candidatesTokenCount"] as? Int ?? 0
        case .openAI:
            return (data, response)
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```(?:json)?\\s*|\\s*```$", with: "", options: .regularExpression)
        let sources = citedSources(raw, provider: provider)
        var output: [[String: Any]] = []
        if !sources.isEmpty {
            output.append(["type": "web_search_call", "action": ["sources": sources.map { ["url": $0] }]])
        }
        output.append(["type": "message", "content": [["type": "output_text", "text": cleaned]]])
        let normalized: [String: Any] = [
            "status": "completed",
            "output": output,
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens]
        ]
        return (try JSONSerialization.data(withJSONObject: normalized), response)
    }

    private static func instructions(from body: [String: Any]) -> String {
        var text = body["instructions"] as? String ?? ""
        if let format = (body["text"] as? [String: Any])?["format"] as? [String: Any],
           let schema = format["schema"],
           let data = try? JSONSerialization.data(withJSONObject: schema),
           let schemaText = String(data: data, encoding: .utf8) {
            text += "\nReturn only a JSON object matching this schema: \(schemaText)"
        }
        text += Locale.current.language.languageCode?.identifier == "zh"
            ? "\n面向用户的文字请使用中文。" : "\nUse English for user-facing text."
        return text
    }

    private static func content(from body: [String: Any]) -> [[String: Any]] {
        if let input = body["input"] as? String { return [["type": "text", "text": input]] }
        let messages = body["input"] as? [[String: Any]] ?? []
        return messages.flatMap { message -> [[String: Any]] in
            let parts = message["content"] as? [[String: Any]] ?? []
            return parts.compactMap { part in
                switch part["type"] as? String {
                case "input_text": return ["type": "text", "text": part["text"] as? String ?? ""]
                case "input_image":
                    guard let url = part["image_url"] as? String,
                          let encoded = url.components(separatedBy: ",").last else { return nil }
                    return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": encoded]]
                case "input_file":
                    guard let file = part["file_data"] as? String,
                          file.hasPrefix("data:application/pdf;"),
                          let encoded = file.components(separatedBy: ",").last else { return nil }
                    return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": encoded]]
                default: return nil
                }
            }
        }
    }

    private static func geminiParts(from body: [String: Any]) -> [[String: Any]] {
        content(from: body).compactMap { item in
            switch item["type"] as? String {
            case "text": return ["text": item["text"] as? String ?? ""]
            case "image":
                guard let source = item["source"] as? [String: Any] else { return nil }
                return ["inline_data": ["mime_type": source["media_type"] ?? "image/jpeg", "data": source["data"] ?? ""]]
            case "document":
                guard let source = item["source"] as? [String: Any] else { return nil }
                return ["inline_data": ["mime_type": "application/pdf", "data": source["data"] ?? ""]]
            default: return nil
            }
        }
    }

    private static func citedSources(_ raw: [String: Any], provider: PublicAIProvider) -> [String] {
        let urls: [String]
        switch provider {
        case .anthropic:
            let blocks = raw["content"] as? [[String: Any]] ?? []
            urls = blocks.flatMap { block -> [String] in
                let citations = block["citations"] as? [[String: Any]] ?? []
                let direct = citations.compactMap { $0["url"] as? String }
                let results = block["content"] as? [[String: Any]] ?? []
                return direct + results.compactMap { $0["url"] as? String }
            }
        case .gemini:
            let candidates = raw["candidates"] as? [[String: Any]] ?? []
            urls = candidates.flatMap { candidate -> [String] in
                let metadata = candidate["groundingMetadata"] as? [String: Any] ?? [:]
                let chunks = metadata["groundingChunks"] as? [[String: Any]] ?? []
                return chunks.compactMap { ($0["web"] as? [String: Any])?["uri"] as? String }
            }
        case .openAI:
            urls = []
        }
        return Array(Set(urls.filter { URLComponents(string: $0)?.scheme == "https" })).sorted()
    }
}
