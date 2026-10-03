import Foundation
import SwiftUI

enum PublicLanguage {
    static func errorDescription(_ error: Error) -> String {
        if let network = error as? URLError {
            switch network.code {
            case .timedOut: return String(localized: "网络请求超时，请稍后重试。")
            case .notConnectedToInternet: return String(localized: "当前没有网络连接，请联网后重试。")
            default: return String(localized: "无法连接到服务，请检查网络后重试。")
            }
        }
        if error is DecodingError { return String(localized: "无法读取返回资料，请重试。") }
        let message = error.localizedDescription
        if !isChinese && message.range(of: "[\\p{Han}]", options: .regularExpression) != nil {
            return String(localized: "请求未能完成，请检查连接和账户设置后重试。")
        }
        return message
    }
    static var qaScrollBottom: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-LocalizationBottom")
#else
        false
#endif
    }
    static func weather(_ rawValue: String) -> String {
        let names = ["blizzard": "暴风雪", "blowingDust": "扬尘", "blowingSnow": "吹雪", "breezy": "微风", "clear": "晴朗", "cloudy": "阴天", "drizzle": "毛毛雨", "flurries": "小阵雪", "foggy": "有雾", "freezingDrizzle": "冻毛毛雨", "freezingRain": "冻雨", "frigid": "严寒", "hail": "冰雹", "haze": "霾", "heavyRain": "大雨", "heavySnow": "大雪", "hot": "炎热", "hurricane": "飓风", "isolatedThunderstorms": "局地雷暴", "mostlyClear": "大部晴朗", "mostlyCloudy": "大部多云", "partlyCloudy": "局部多云", "rain": "雨", "scatteredThunderstorms": "零星雷暴", "sleet": "冰粒", "smoky": "烟雾", "snow": "雪", "strongStorms": "强风暴", "sunFlurries": "晴间阵雪", "sunShowers": "太阳雨", "thunderstorms": "雷暴", "tropicalStorm": "热带风暴", "windy": "大风", "wintryMix": "雨雪混合"]
        return names[rawValue].map { NSLocalizedString($0, comment: "Weather") } ?? String(localized: "天气暂不可用")
    }
    static func demoText(_ value: String) -> String {
        for language in ["en", "zh-Hans"] {
            guard let folder = Bundle.main.path(forResource: language, ofType: "lproj"),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("Localizable.strings")),
                  let table = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] else { continue }
            if table[value] != nil { return NSLocalizedString(value, comment: "Demo") }
            if let key = table.first(where: { $0.value == value })?.key { return NSLocalizedString(key, comment: "Demo") }
        }
        return value
    }
    // Use the app's selected language, not the language of an input query.
    static var code: String { Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh" : "en" }
    static var isChinese: Bool { code == "zh" }
    static var locale: Locale {
        let region = Locale.current.region?.identifier ?? "US"
        return Locale(identifier: (isChinese ? "zh_Hans_" : "en_") + region)
    }
    static var speechLocale: Locale { Locale(identifier: isChinese ? "zh-CN" : "en-US") }
    static var aiInstruction: String {
        let language = isChinese ? "Simplified Chinese" : "natural English"
        return "\nOUTPUT LANGUAGE: Use \(language) for all user-facing prose, labels, warnings, summaries and suggestions, regardless of the input language or earlier language instructions. Preserve original proper names, postal addresses, identifiers, JSON keys and schema enum values. Machine-only search queries must retain their required search language."
    }
}


enum PublicAIProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case deepSeek = "deepseek"
    case qwen = "qwen"
    case kimi = "kimi"
    case zhipu = "zhipu"
    case doubao = "doubao"
    case ernie = "ernie"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .gemini: "Google Gemini"
        case .deepSeek: "DeepSeek"
        case .qwen: String(localized: "通义千问 / Qwen")
        case .kimi: "Kimi"
        case .zhipu: String(localized: "智谱 / GLM")
        case .doubao: String(localized: "豆包 / Doubao")
        case .ernie: String(localized: "文心 / ERNIE")
        }
    }
    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "publicAIProvider") ?? "openai") ?? .openAI
    }

    var usesChatCompletions: Bool {
        switch self {
        case .openAI, .anthropic, .gemini: false
        default: true
        }
    }

    var supportsWebResearch: Bool {
        self == .openAI || self == .anthropic || self == .gemini || self == .qwen
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-6-luna"
        case .anthropic: "claude-sonnet-5"
        case .gemini: "gemini-3.5-flash"
        case .deepSeek: "deepseek-flash"
        case .qwen: "qwen-plus"
        case .kimi: "kimi-k3"
        case .zhipu: "glm-5.3"
        case .doubao: "doubao-seed-2-1-pro-260628"
        case .ernie: "ernie-4.5-turbo-128k"
        }
    }

    func model(hasImages: Bool = false) -> String {
        let override = UserDefaults.standard.string(forKey: "publicAIModel.\(rawValue)")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !override.isEmpty { return override }
        if hasImages {
            switch self {
            case .qwen: return "qwen-vl-plus"
            case .zhipu: return "glm-5.3-flash"
            case .ernie: return "ernie-4.5-turbo-vl"
            default: break
            }
        }
        return defaultModel
    }

    var chatEndpoint: URL {
        let address: String
        switch self {
        case .deepSeek: address = "https://api.deepseek.com/chat/completions"
        case .qwen:
            switch UserDefaults.standard.string(forKey: "publicAIRegion.qwen") ?? "cn" {
            case "us": address = "https://dashscope-us.aliyuncs.com/compatible-mode/v1/chat/completions"
            case "sg": address = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
            default: address = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
            }
        case .kimi: address = "https://api.moonshot.cn/v1/chat/completions"
        case .zhipu: address = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .doubao: address = "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        case .ernie: address = "https://qianfan.baidubce.com/v2/chat/completions"
        default: preconditionFailure("Provider does not use Chat Completions")
        }
        return URL(string: address)!
    }
}


enum PublicDemo {
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "publicDemoMode") as? Bool) ?? true
    }
    static var title: String { String(localized: "离线演示") }
    static var notice: String { String(localized: "离线演示 · 示例内容，非实时推荐") }
}

struct PublicDemoSettings: View {
    @AppStorage("publicDemoMode") private var enabled = true
    var body: some View {
        Toggle(String(localized: "离线演示模式"), isOn: $enabled)
        Text(String(localized: "演示无需网络或密钥。关闭后可使用定位与 AI；需要有效密钥并同意发送资料。"))
            .font(.footnote).foregroundStyle(.secondary)
    }
}

struct PublicAIConfigurationView: View {
    let provider: PublicAIProvider
    @State private var model = ""
    @AppStorage("publicAIRegion.qwen") private var qwenRegion = "cn"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PublicDemoSettings()
            TextField(String(localized: "模型（可选）") + ": " + provider.defaultModel, text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: model) { _, value in
                    UserDefaults.standard.set(value, forKey: "publicAIModel.\(provider.rawValue)")
                }
            if provider == .qwen {
                Picker(String(localized: "服务地域"), selection: $qwenRegion) {
                    Text(String(localized: "中国大陆")).tag("cn")
                    Text(String(localized: "新加坡")).tag("sg")
                    Text(String(localized: "美国")).tag("us")
                }
                Text(String(localized: "密钥必须与所选服务地域一致。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text(String(localized: "留空使用默认模型。豆包也可填写已开通的模型或接入点 ID；图片请求会自动使用默认视觉模型，指定模型时请确认其支持图片。"))
                .font(.footnote).foregroundStyle(.secondary)
            if !provider.supportsWebResearch {
                Text(String(localized: "此接入支持文本与兼容模型的图片功能；暂不支持应用内实时联网核验。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { loadModel() }
        .onChange(of: provider) { _, _ in loadModel() }
    }

    private func loadModel() {
        model = UserDefaults.standard.string(forKey: "publicAIModel.\(provider.rawValue)") ?? ""
    }
}

enum PublicAIConsent {
    static var granted: Bool {
        UserDefaults.standard.bool(forKey: "publicAIConsent.\(PublicAIProvider.selected.rawValue)")
    }
    static func set(_ granted: Bool) {
        UserDefaults.standard.set(granted, forKey: "publicAIConsent.\(PublicAIProvider.selected.rawValue)")
    }
}

enum PublicAITransport {
    static func send(body: [String: Any], key: String, provider: PublicAIProvider = .selected,
                     timeout: TimeInterval = 60) async throws -> (Data, URLResponse) {
        var body = body
        body["instructions"] = (body["instructions"] as? String ?? "") + PublicLanguage.aiInstruction
        if provider.usesChatCompletions {
            return try await sendChat(body: body, key: key, provider: provider, timeout: timeout)
        }
        if provider != .openAI,
           let messages = body["input"] as? [[String: Any]],
           messages.contains(where: { message in
               (message["content"] as? [[String: Any]] ?? []).contains(where: {
                   $0["type"] as? String == "input_file" &&
                   !((($0["file_data"] as? String) ?? "").hasPrefix("data:application/pdf;"))
               })
           }) {
            throw NSError(domain: "PublicAITransport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "所选服务商暂不支持 DOC/DOCX 直传；请转为 PDF 或使用 OpenAI。")])
        }
        let request: URLRequest
        switch provider {
        case .openAI:
            var openAI = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
            openAI.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            var payload = body
            let override = UserDefaults.standard.string(forKey: "publicAIModel.openai") ?? ""
            if !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { payload["model"] = override }
            openAI.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request = openAI
        case .anthropic:
            var anthropic = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            anthropic.setValue(key, forHTTPHeaderField: "x-api-key")
            anthropic.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var payload: [String: Any] = [
                "model": provider.model(), "max_tokens": body["max_output_tokens"] ?? 8000,
                "system": instructions(from: body),
                "messages": [["role": "user", "content": content(from: body)]]
            ]
            if body["tools"] != nil {
                payload["tools"] = [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]]
            }
            anthropic.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request = anthropic
        case .gemini:
            var gemini = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(provider.model()):generateContent")!)
            gemini.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            var payload: [String: Any] = [
                "systemInstruction": ["parts": [["text": instructions(from: body)]]],
                "contents": [["role": "user", "parts": geminiParts(from: body)]],
                "generationConfig": ["responseMimeType": body["text"] == nil ? "text/plain" : "application/json"]
            ]
            if body["tools"] != nil { payload["tools"] = [["google_search": [:]]] }
            gemini.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request = gemini
        default: preconditionFailure("Chat provider handled above")
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
        default: preconditionFailure("Chat provider handled above")
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

    private static func sendChat(body: [String: Any], key: String, provider: PublicAIProvider,
                                 timeout: TimeInterval) async throws -> (Data, URLResponse) {
        let wantsWeb = body["tools"] != nil
        guard !wantsWeb || provider.supportsWebResearch else {
            throw NSError(domain: "PublicAITransport", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "所选服务商暂不支持实时联网核验，请选择通义千问、OpenAI、Claude 或 Gemini。")])
        }
        var parts: [[String: Any]] = []
        if let input = body["input"] as? String {
            parts = [["type": "text", "text": input]]
        } else {
            let messages = body["input"] as? [[String: Any]] ?? []
            for message in messages {
                for part in message["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "input_text": parts.append(["type": "text", "text": part["text"] as? String ?? ""])
                    case "input_image":
                        if let image = part["image_url"] as? String {
                            parts.append(["type": "image_url", "image_url": ["url": image]])
                        }
                    case "input_file":
                        throw NSError(domain: "PublicAITransport", code: 3, userInfo: [NSLocalizedDescriptionKey:
                            String(localized: "此接入暂不支持文件直传；请使用照片或文字，或切换支持文件的服务商。")])
                    default: break
                    }
                }
            }
        }
        let hasImages = parts.contains { $0["type"] as? String == "image_url" }
        var payload: [String: Any] = [
            "model": provider.model(hasImages: hasImages), "stream": false,
            "max_tokens": body["max_output_tokens"] ?? 8000,
            "messages": [["role": "system", "content": instructions(from: body)],
                         ["role": "user", "content": parts]]
        ]
        if let format = (body["text"] as? [String: Any])?["format"] as? [String: Any],
           format["schema"] != nil, provider == .deepSeek || provider == .qwen || provider == .zhipu {
            payload["response_format"] = ["type": "json_object"]
        }
        let nativeQwen = provider == .qwen && wantsWeb
        var endpoint = provider.chatEndpoint
        if nativeQwen {
            endpoint = URL(string: endpoint.absoluteString.replacingOccurrences(
                of: "/compatible-mode/v1/chat/completions", with: "/api/v1/services/aigc/text-generation/generation"))!
            let messages = payload["messages"] as? [[String: Any]] ?? []
            let textMessages = messages.map { message -> [String: Any] in
                if let parts = message["content"] as? [[String: Any]] {
                    return ["role": message["role"] ?? "user", "content": parts.compactMap { $0["text"] as? String }.joined(separator: "\n")]
                }
                return message
            }
            payload = ["model": provider.model(), "input": ["messages": textMessages],
                       "parameters": ["max_tokens": body["max_output_tokens"] ?? 8000,
                                      "result_format": "message", "enable_search": true,
                                      "search_options": ["forced_search": true, "enable_source": true,
                                                         "enable_citation": false]]]
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return (data, response) }
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let responseRoot = nativeQwen ? (raw["output"] as? [String: Any] ?? [:]) : raw
        let choice = (responseRoot["choices"] as? [[String: Any]])?.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^```(?:json)?\\s*|\\s*```$", with: "", options: .regularExpression)
        let searchInfo = responseRoot["search_info"] as? [String: Any] ?? [:]
        let results = searchInfo["search_results"] as? [[String: Any]] ?? []
        var output: [[String: Any]] = []
        if !results.isEmpty {
            output.append(["type": "web_search_call", "action": ["sources": results.compactMap { item -> [String: String]? in
                guard let url = item["url"] as? String, URLComponents(string: url)?.scheme == "https" else { return nil }
                return ["url": url]
            }]])
        }
        output.append(["type": "message", "content": [["type": "output_text", "text": text]]])
        let usage = raw["usage"] as? [String: Any] ?? [:]
        let normalized: [String: Any] = [
            "status": choice["finish_reason"] as? String == "length" ? "incomplete" : "completed",
            "output": output,
            "usage": ["input_tokens": usage["prompt_tokens"] as? Int ?? 0,
                      "output_tokens": usage["completion_tokens"] as? Int ?? usage["output_tokens"] as? Int ?? 0]
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
        text += PublicLanguage.aiInstruction
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
        default: urls = []
        }
        return Array(Set(urls.filter { URLComponents(string: $0)?.scheme == "https" })).sorted()
    }
}
