import Foundation
import Security

enum DreamThinkingDepth: String, CaseIterable, Identifiable {
    case quick = "快速", balanced = "中度", deep = "深度"
    var id: Self { self }
    var title: String { NSLocalizedString(rawValue, comment: "Research depth") }
    var effort: String {
        switch self {
        case .quick: "low"
        case .balanced: "medium"
        case .deep: "high"
        }
    }
}

final class DreamResearchTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var responseIDs = Set<String>()
    private var tokens = 0
    private var cancelled = false

    var tokenCount: Int {
        lock.lock(); defer { lock.unlock() }
        return tokens
    }
    func register(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        responseIDs.insert(id)
        return !cancelled
    }
    func complete(_ id: String, usage: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        responseIDs.remove(id)
        tokens += usage?["total_tokens"] as? Int ?? 0
    }
    func cancel() -> [String] {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        return Array(responseIDs)
    }
}

enum DreamResearchError: LocalizedError {
    case missingKey, invalidKey, invalidResponse, noVerifiedResults, researchTimedOut
    var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "请先在设置中填写 API Key。")
        case .invalidKey: String(localized: "API Key 无效，或此密钥无法使用当前模型。")
        case .invalidResponse: String(localized: "研究结果暂时无法读取，请稍后重试。")
        case .noVerifiedResults: String(localized: "这次没有找到足够可核对的来源，请换个时间或条件。")
        case .researchTimedOut: String(localized: "研究时间较长，这次未能完成。请稍后重试；已有推荐会保留。")
        }
    }
}

enum DreamKeychain {
    private static var account: String { "MyJourneyDreamPublic.\(PublicAIProvider.selected.rawValue)Key" }
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

enum DreamResearch {
    static var isDemoMode: Bool {
        PublicDemo.enabled || ProcessInfo.processInfo.arguments.contains("-DemoRecommendations")
    }

    static func fallbackRecommendations(modes: Set<JourneyMode>) -> [JourneyExperience] {
        demoExperiences.filter { modes.contains($0.mode) }.map { experience in
            var item = experience
            item.confidence = String(localized: "通用灵感示例；尚未根据你的要求完成 AI 推荐或实时核对。")
            return item
        }
    }

    struct InputDecision {
        let confirmedJourney: ConfirmedJourney?
        let clarification: String
    }

    private struct ParsedInput: Decodable {
        let intent: String
        let title: String
        let destination: String
        let startDate: String
        let endDate: String
        let companions: String
        let clarification: String
    }
    private struct ResearchResponse {
        let text: String
        let sourceURLs: Set<String>
    }
    private struct QuickJourney: Decodable {
        let mode: JourneyMode
        let title: String
        let region: String
        let month: String
        let duration: String
        let reason: String
        let highlights: [String]
    }
    private struct QuickJourneyBatch: Decodable { let journeys: [QuickJourney] }
    private struct ResearchBatch: Decodable { let experiences: [JourneyExperience] }
    private struct PreparationBatch: Decodable { let steps: [PreparationStep] }

    static func verifyKey(_ candidate: String) async throws {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DreamResearchError.missingKey }
        let body: [String: Any] = ["model": "gpt-6-astra", "store": false,
                                   "reasoning": ["effort": "low"],
                                   "input": "Reply with OK.", "max_output_tokens": 256]
        let (data, response) = try await PublicAITransport.send(body: body, key: key, timeout: 30)
        guard let http = response as? HTTPURLResponse else { throw DreamResearchError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw DreamResearchError.invalidKey }
            throw NSError(domain: "DreamResearch", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("验证暂不可用（HTTP %@），未保存密钥。", comment: ""), String(describing: http.statusCode))])
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? String == "completed" else { throw DreamResearchError.invalidKey }
    }

    static func classify(_ text: String, depth: DreamThinkingDepth = .balanced,
                         tracker: DreamResearchTracker? = nil) async throws -> InputDecision {
        let fields = ["intent", "title", "destination", "startDate", "endDate",
                      "companions", "clarification"]
        var properties = Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": "string"] as [String: Any]) })
        properties["intent"] = ["type": "string", "enum": ["confirmed", "discover"]]
        let schema: [String: Any] = ["type": "object", "properties": properties,
            "required": fields, "additionalProperties": false]
        let prompt = """
        Classify this Chinese or English travel request by INTENT, not merely by mentioning a place
        and time. "I want to go to Japan next month" / "我想下个月去日本" is discover: Japan and
        next month are recommendation constraints, not a confirmed booking. Approximate windows
        such as next month, October, or autumn must remain discover when phrased as wishes.
        Choose confirmed only when the user clearly says the journey is decided/booked or asks
        to prepare an already decided journey. For confirmed, extract a concise title,
        destination, precise dates as YYYY-MM-DD and companions. Infer year from today's date
        (\(Date.now.ISO8601Format())) only when unambiguous. If an explicitly confirmed trip
        lacks precise dates, leave them empty and ask for dates in clarification; never invent.
        If a single precise date is given, use it for start and end. For discover, leave all other
        fields empty, including clarification: continue to research using the original user text.
        Input: \(text)
        """
        let output = try await respond(prompt, schema: schema, web: false, depth: depth, tracker: tracker)
        let parsed = try JSONDecoder().decode(ParsedInput.self, from: Data(output.text.utf8))
        guard parsed.intent == "confirmed" else {
            return InputDecision(confirmedJourney: nil, clarification: "")
        }
        let tentativeWords = ["我想", "想去", "考虑", "推荐", "适合", "有没有", "want to", "thinking of"]
        let confirmedWords = ["已确定", "已经确定", "订好了", "已预订", "确认了", "booked", "confirmed"]
        let lowered = text.lowercased()
        if tentativeWords.contains(where: lowered.contains) &&
            !confirmedWords.contains(where: lowered.contains) {
            return InputDecision(confirmedJourney: nil, clarification: "")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard !parsed.destination.isEmpty,
              let start = formatter.date(from: parsed.startDate),
              let end = formatter.date(from: parsed.endDate), end >= start else {
            return InputDecision(confirmedJourney: nil,
                                 clarification: parsed.clarification.isEmpty
                                 ? "请补充已确定旅行的地点和起止日期。" : parsed.clarification)
        }
        let trip = ConfirmedJourney(title: parsed.title.isEmpty ? parsed.destination : parsed.title,
                                    destination: parsed.destination, start: start, end: end,
                                    companions: parsed.companions)
        return InputDecision(confirmedJourney: trip, clarification: parsed.clarification)
    }

    static func discover(modes: [JourneyMode], request: String, profile: String,
                         depth: DreamThinkingDepth = .balanced,
                         tracker: DreamResearchTracker? = nil) async throws -> [JourneyExperience] {
        if ProcessInfo.processInfo.arguments.contains("-SimulateDiscoveryTimeout") {
            try await Task.sleep(for: .seconds(2))
            throw DreamResearchError.researchTimedOut
        }
        if isDemoMode {
            try await Task.sleep(for: .seconds(2))
            return demoExperiences.filter { modes.contains($0.mode) }
        }
        let requestedModes = JourneyMode.allCases.filter { modes.contains($0) }
        guard !requestedModes.isEmpty else { throw DreamResearchError.invalidResponse }
        let count = requestedModes.count
        let prompt = """
        Return exactly \(count) concise travel Journey idea(s) in the app output language, one for each of these modes:
        \(requestedModes.map(\.rawValue).joined(separator: ", ")). Do not return other modes.
        Backpack means independent travel with a light pack, public transport, local accommodation,
        culture and optional scenic walks; it is not limited to hiking or wilderness camping.
        This is the fast inspiration pass, so do not browse, cite, verify, or produce a detailed itinerary.
        Each idea needs only a memorable name, region (include a searchable Latin-script place name
        in parentheses where applicable), recommended month, duration, one-sentence reason,
        and exactly three short highlights. Respect the user's request and profile, avoid places already
        visited when possible, and favor travel windows in the next 4–8 weeks unless specified otherwise.
        Today: \(Date.now.formatted(date: .long, time: .omitted)).
        User: \(request.isEmpty ? "Give me fresh seasonal inspiration." : request)
        Profile: \(profile)
        """
        let item: [String: Any] = ["type": "object", "properties": [
            "mode": ["type": "string", "enum": requestedModes.map(\.rawValue)],
            "title": ["type": "string"], "region": ["type": "string"],
            "month": ["type": "string"], "duration": ["type": "string"],
            "reason": ["type": "string"],
            "highlights": ["type": "array", "minItems": 3, "maxItems": 3,
                           "items": ["type": "string"]]],
            "required": ["mode", "title", "region", "month", "duration", "reason", "highlights"],
            "additionalProperties": false]
        let schema: [String: Any] = ["type": "object", "properties": [
            "journeys": ["type": "array", "minItems": count, "maxItems": count, "items": item]],
            "required": ["journeys"], "additionalProperties": false]
        let response = try await respond(prompt, schema: schema, web: false, depth: .quick,
                                         tracker: tracker, background: false, timeout: 30,
                                         model: "gpt-6-luna")
        let parsed: [QuickJourney]
        do {
            parsed = try JSONDecoder().decode(QuickJourneyBatch.self,
                                               from: Data(response.text.utf8)).journeys
        } catch {
            throw DreamResearchError.invalidResponse
        }
        let unique = Dictionary(grouping: parsed, by: \.mode)
        guard requestedModes.allSatisfy({ unique[$0]?.count == 1 }) else {
            throw DreamResearchError.invalidResponse
        }
        return requestedModes.compactMap { journeyMode in
            guard let quick = unique[journeyMode]?.first, quick.highlights.count == 3 else { return nil }
            return JourneyExperience(mode: quick.mode, title: quick.title, region: quick.region,
                season: quick.month, duration: quick.duration, signatureExperience: quick.reason,
                whyNow: "", whatYouLove: quick.highlights.joined(separator: " · "), whatToAccept: "",
                routeOrBase: "", longStayValue: "", confidence: "详细资料正在补充",
                evidence: [], highlights: quick.highlights)
        }
    }

    static func enrich(_ seed: JourneyExperience, request: String, profile: String,
                       depth: DreamThinkingDepth = .balanced,
                       tracker: DreamResearchTracker? = nil) async throws -> JourneyExperience {
        if isDemoMode {
            var enriched = seed
            enriched.whyNow = String(localized: "这是固定的离线灵感，不代表当前季节已适合出行。")
            enriched.routeOrBase = String(localized: "选择一处交通方便的基地，安排核心体验与机动日。")
            enriched.whatToAccept = String(localized: "开放、天气、交通和价格均未实时核验，请勿直接用于预订。")
            enriched.longStayValue = seed.mode == .slowStay
                ? String(localized: "比较长住价格、厨房、洗衣、网络、医疗与日常交通。") : ""
            enriched.routePlan = [
                JourneyRouteStage(day: String(localized: "抵达日"), place: seed.region,
                    experience: String(localized: "熟悉周边，轻松散步，确认交通与补给。"),
                    transfer: String(localized: "示例路线，实际交通待核验。")),
                JourneyRouteStage(day: String(localized: "中间几天"), place: seed.region,
                    experience: seed.whatYouLove,
                    transfer: String(localized: "每天保留休息与天气机动时间。")),
                JourneyRouteStage(day: String(localized: "返程日"), place: seed.region,
                    experience: String(localized: "整理行李，预留交通缓冲。"),
                    transfer: String(localized: "示例路线，实际交通待核验。"))
            ]
            enriched.evidence = []
            enriched.confidence = PublicDemo.notice
            return enriched
        }
        let routeDetail: String
        switch depth {
        case .quick:
            routeDetail = "QUICK: provide a usable chronological route skeleton with at least 2 stages; group days where useful. Keep timing and alternative empty unless verified."
        case .balanced:
            routeDetail = "MEDIUM: provide a substantially fuller route: at least 5 chronological stages and normally one stage per day for trips up to 10 days; for longer trips cover each 2-3 day block. Every stage must name a real city/area and at least one specific attraction, trail, viewpoint or neighborhood in landmarks, with concrete morning/afternoon priorities, realistic transfer mode and approximate time, plus lodging base. Include timing and a practical alternative where relevant. Cover every travel day without gaps."
        case .deep:
            routeDetail = "DEEP: provide a comprehensive day-by-day route covering every travel day, including arrival and departure. Each day must name the actual place/base and specific attractions, trails, viewpoints or neighborhoods in landmarks, with morning/afternoon/evening priorities, realistic transfer mode/time, pacing and booking or access constraints where verifiable. Include a timing plan and a weather/closure fallback for each day. Identify uncertain details instead of inventing opening hours, prices or reservations."
        }
        let prompt = """
        Enrich this already-visible Journey without changing its mode or core destination:
        \(seed.mode.rawValue) · \(seed.title) · \(seed.region) · \(seed.season) · \(seed.duration).
        User: \(request). Profile: \(profile). Search current sources and return exactly one experience.
        Verify mutable access, season and safety facts with directly relevant sources. \(routeDetail)
        Each routePlan stage needs day range, specific place/base, concrete activity,
        transfer/logistics, specific named landmarks, timing and alternative (empty strings only when not applicable).
        For backpack journeys prioritize independent travel with a light pack, public transport,
        local stays, cultural experiences and optional scenic walks. Do not assume mountaineering
        or wilderness camping. Include realistic transfer details, lodging bases and packing needs.
        If the route includes hiking, include trail and
        daily difficulty when verifiable; for driving include road and drive time when verifiable;
        for slow stay show residential bases and day trips without unnecessary accommodation changes.
        Explain why now, what to love, what to accept, confidence and uncertainty. Never invent facts or links.
        Use the app output language for descriptions and require at least two independent sources.
        """
        let researchTimeout: TimeInterval = depth == .deep ? 180 : (depth == .balanced ? 120 : 90)
        let researched = try await respond(prompt, schema: experienceSchema, web: true,
                                           depth: depth, tracker: tracker, timeout: researchTimeout)
        let batch: ResearchBatch
        do {
            batch = try JSONDecoder().decode(ResearchBatch.self, from: Data(researched.text.utf8))
        } catch {
            throw DreamResearchError.invalidResponse
        }
        guard var item = batch.experiences.first, item.mode == seed.mode else {
            throw DreamResearchError.invalidResponse
        }
        let durationDays = Int(seed.duration.prefix(while: \.isNumber)) ?? 7
        let minimumStages: Int
        switch depth {
        case .quick: minimumStages = 2
        case .balanced: minimumStages = min(durationDays, durationDays <= 10 ? durationDays : max(5, (durationDays + 2) / 3))
        case .deep: minimumStages = min(durationDays, 21)
        }
        guard let plan = item.routePlan, plan.count >= minimumStages,
              plan.allSatisfy({ !$0.day.isEmpty && !$0.place.isEmpty &&
                                !$0.experience.isEmpty && !$0.transfer.isEmpty &&
                                (depth == .quick || !($0.landmarks ?? "").isEmpty) }) else {
            throw DreamResearchError.invalidResponse
        }
        item.id = seed.id
        item.highlights = seed.highlights
        item.photos = seed.photos
        item.evidence = item.evidence.filter { researched.sourceURLs.contains(normalizedURL($0.url)) }
        guard Set(item.evidence.map { normalizedURL($0.url) }).count >= 2 else {
            throw DreamResearchError.noVerifiedResults
        }
        return item
    }

    static func prepare(_ trip: ConfirmedJourney, depth: DreamThinkingDepth = .balanced,
                        tracker: DreamResearchTracker? = nil) async throws -> [PreparationStep] {
        let prompt = """
        Research preparation for a CONFIRMED journey, not destination recommendations.
        Journey: \(trip.title), \(trip.destination), \(trip.start.ISO8601Format()) to
        \(trip.end.ISO8601Format()); companions: \(trip.companions).
        Create a chronological preparation timeline: now, one month before, one week before,
        48 hours before, departure day. Include only relevant actionable items: official entry/visa,
        transport and booking checks, daylight/season/weather recheck, activity reservations, packing,
        health/safety and local transport. Verify mutable legal/safety claims against official current
        sources and provide URLs. If not verified, frame it as a task to check, not a fact. Avoid
        prescribing medicines or pretending a future forecast is available.
        """
        let step: [String: Any] = ["type": "object", "properties": [
            "phase": ["type": "string"], "title": ["type": "string"],
            "rationale": ["type": "string"], "sourceURL": ["type": "string"]],
            "required": ["phase", "title", "rationale", "sourceURL"],
            "additionalProperties": false]
        let schema: [String: Any] = ["type": "object", "properties": [
            "steps": ["type": "array", "items": step]], "required": ["steps"],
            "additionalProperties": false]
        let output = try await respond(prompt, schema: schema, web: true, depth: depth, tracker: tracker)
        let proposed = try JSONDecoder().decode(PreparationBatch.self, from: Data(output.text.utf8)).steps
        return proposed.map { step in
            var checked = step
            if !output.sourceURLs.contains(normalizedURL(step.sourceURL)) {
                checked.sourceURL = ""
                checked.rationale += String(localized: "（本项尚无已核对来源，请出发前自行确认。）")
            }
            return checked
        }
    }

    private static var experienceSchema: [String: Any] {
        let source: [String: Any] = ["type": "object", "properties": [
            "title": ["type": "string"], "url": ["type": "string"],
            "role": ["type": "string"]],
            "required": ["title", "url", "role"], "additionalProperties": false]
        let routeStage: [String: Any] = ["type": "object", "properties": [
            "day": ["type": "string"], "place": ["type": "string"],
            "experience": ["type": "string"], "transfer": ["type": "string"],
            "landmarks": ["type": "string"],
            "timing": ["type": "string"], "alternative": ["type": "string"]],
            "required": ["day", "place", "experience", "transfer", "landmarks", "timing", "alternative"],
            "additionalProperties": false]
        let fields = ["title", "region", "season", "duration", "signatureExperience", "whyNow",
                      "whatYouLove", "whatToAccept", "routeOrBase", "longStayValue", "confidence"]
        var properties = Dictionary(uniqueKeysWithValues: fields.map { ($0, ["type": "string"] as [String: Any]) })
        properties["mode"] = ["type": "string", "enum": JourneyMode.allCases.map(\.rawValue)]
        properties["evidence"] = ["type": "array", "items": source]
        properties["routePlan"] = ["type": "array", "items": routeStage]
        return ["type": "object", "properties": ["experiences": ["type": "array", "items": [
            "type": "object", "properties": properties,
            "required": fields + ["mode", "evidence", "routePlan"], "additionalProperties": false]]],
                "required": ["experiences"], "additionalProperties": false]
    }

    private static var demoExperiences: [JourneyExperience] {
        [
            JourneyExperience(mode: .backpack, title: String(localized: "背包慢游马德拉"), region: String(localized: "葡萄牙 · 马德拉"),
                season: String(localized: "10 月"), duration: String(localized: "7 天"), signatureExperience: String(localized: "轻装走访老城与海岸，穿插一两次自然漫步。"),
                whyNow: "", whatYouLove: String(localized: "云海 · 月桂林 · 黑沙海滩"), whatToAccept: "", routeOrBase: "",
                longStayValue: "", confidence: String(localized: "等待深度研究"), evidence: [],
                highlights: [String(localized: "Pico 山脊云海"), String(localized: "Fanal 雾森林"), String(localized: "天然海水池")]),
            JourneyExperience(mode: .roadTrip, title: String(localized: "城堡、荒野与威士忌之路"), region: String(localized: "英国 · 苏格兰高地"),
                season: String(localized: "9 月"), duration: String(localized: "8 天"), signatureExperience: String(localized: "把公路本身变成旅程，放慢节奏穿过高地与海岸。"),
                whyNow: "", whatYouLove: String(localized: "荒野公路 · 小镇 · 威士忌"), whatToAccept: "", routeOrBase: "",
                longStayValue: "", confidence: String(localized: "等待深度研究"), evidence: [],
                highlights: [String(localized: "Applecross 山路"), String(localized: "Torridon 荒野"), String(localized: "高地庄园夜晚")]),
            JourneyExperience(mode: .slowStay, title: String(localized: "住进西班牙南部"), region: String(localized: "西班牙 · 安达卢西亚"),
                season: String(localized: "11 月"), duration: String(localized: "21 天"), signatureExperience: String(localized: "少换住所，用固定咖啡馆和散步路线建立生活感。"),
                whyNow: "", whatYouLove: String(localized: "街区生活 · Tapas · 近郊慢游"), whatToAccept: "", routeOrBase: "",
                longStayValue: "", confidence: String(localized: "等待深度研究"), evidence: [],
                highlights: [String(localized: "塞维利亚街区"), String(localized: "格拉纳达黄昏"), String(localized: "固定早餐店")])
        ]
    }

    private static func normalizedURL(_ value: String) -> String {
        guard var parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty else { return "" }
        parts.scheme = "https"
        parts.host = host
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter {
            let name = $0.name.lowercased()
            return !name.hasPrefix("utm_") && !["fbclid", "gclid", "ref"].contains(name)
        }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return (parts.url?.absoluteString ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func respond(_ prompt: String, schema: [String: Any], web: Bool,
                                depth: DreamThinkingDepth, tracker: DreamResearchTracker?,
                                background: Bool = true, timeout: TimeInterval = 45,
                                model: String = "gpt-6-astra") async throws -> ResearchResponse {
        guard let key = DreamKeychain.read(), !key.isEmpty else { throw DreamResearchError.missingKey }
        guard !PublicDemo.enabled else {
            throw NSError(domain: "OfflineDemo", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "演示模式不会处理你的输入，请关闭演示模式以获取真实 AI 结果。")])
        }
        guard PublicAIConsent.granted else {
            throw NSError(domain: "AIConsent", code: 1, userInfo: [NSLocalizedDescriptionKey:
                NSLocalizedString("请先在设置中同意向所选 AI 服务商发送资料。", comment: "AI consent required")])
        }
        let localizedPrompt = prompt + (PublicLanguage.isChinese
            ? "\nUse Simplified Chinese for all user-facing strings."
            : "\nUse natural English for all user-facing strings, regardless of earlier language instructions.")
        var body: [String: Any] = ["model": model, "store": false,
            "background": background, "reasoning": ["effort": depth.effort],
            "input": localizedPrompt, "text": ["format": ["type": "json_schema", "name": "dream_result",
                                           "strict": true, "schema": schema]]]
        if !background { body["max_output_tokens"] = 1800 }
        if web {
            body["tools"] = [["type": "web_search"]]
            body["tool_choice"] = "required"
            body["include"] = ["web_search_call.action.sources"]
        }
        if PublicAIProvider.selected != .openAI {
            body["max_output_tokens"] = background ? 8_000 : 1_800
            let (data, urlResponse) = try await PublicAITransport.send(body: body, key: key, timeout: timeout)
            guard let http = urlResponse as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw requestError(urlResponse, data: data)
            }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let output = root["output"] as? [[String: Any]],
                  let message = output.first(where: { $0["type"] as? String == "message" }),
                  let content = message["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else {
                throw DreamResearchError.invalidResponse
            }
            let sources = Set(output.filter { $0["type"] as? String == "web_search_call" }
                .flatMap { (($0["action"] as? [String: Any])?["sources"] as? [[String: Any]] ?? [])
                    .compactMap { $0["url"] as? String }.map(normalizedURL) })
            return ResearchResponse(text: text, sourceURLs: sources)
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        let initialData: Data
        let initialResponse: URLResponse
        do {
            (initialData, initialResponse) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw DreamResearchError.researchTimedOut
        }
        guard let http = initialResponse as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw requestError(initialResponse, data: initialData)
        }
        guard var root = try JSONSerialization.jsonObject(with: initialData) as? [String: Any],
              let id = root["id"] as? String, id.hasPrefix("resp_"),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            throw DreamResearchError.invalidResponse
        }
        if let tracker, !tracker.register(id) {
            await cancelResponses([id], key: key)
            throw CancellationError()
        }
        if Task.isCancelled {
            await cancelResponses([id], key: key)
            throw CancellationError()
        }
        // The research itself runs on the API server; the phone only polls for its result.
        // Keep the app-side wait generous without changing the user's data-retention choice.
        let deadline = Date.now.addingTimeInterval(background ? timeout : 1)
        while ["queued", "in_progress"].contains(root["status"] as? String ?? "") {
            guard Date.now < deadline else { throw DreamResearchError.researchTimedOut }
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(4))
            var pollURL = URLComponents(string: "https://api.openai.com/v1/responses/\(id)")!
            if web {
                // The retrieve endpoint expects an array, even for a single include value.
                pollURL.queryItems = [URLQueryItem(name: "include[]", value: "web_search_call.action.sources")]
            }
            var poll = URLRequest(url: pollURL.url!)
            poll.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            poll.timeoutInterval = 30
            var received = false
            for attempt in 0..<3 {
                do {
                    let (data, response) = try await URLSession.shared.data(for: poll)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw requestError(response, data: data)
                    }
                    guard let updated = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw DreamResearchError.invalidResponse
                    }
                    root = updated
                    received = true
                    break
                } catch let error as URLError {
                    guard (error.code == .timedOut || error.code == .networkConnectionLost),
                          attempt < 2 else { throw DreamResearchError.researchTimedOut }
                    try await Task.sleep(for: .seconds(2))
                }
            }
            guard received else { throw DreamResearchError.researchTimedOut }
        }
        guard root["status"] as? String == "completed",
              let output = root["output"] as? [[String: Any]] else { throw DreamResearchError.invalidResponse }
        tracker?.complete(id, usage: root["usage"] as? [String: Any])
        var sources = Set<String>()
        for item in output where item["type"] as? String == "web_search_call" {
            let action = item["action"] as? [String: Any] ?? [:]
            for source in action["sources"] as? [[String: Any]] ?? [] {
                if let url = source["url"] as? String { sources.insert(normalizedURL(url)) }
            }
        }
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                for annotation in part["annotations"] as? [[String: Any]] ?? [] {
                    if let url = annotation["url"] as? String { sources.insert(normalizedURL(url)) }
                }
                if let text = part["text"] as? String { return ResearchResponse(text: text, sourceURLs: sources) }
            }
        }
        throw DreamResearchError.invalidResponse
    }

    static func cancel(_ tracker: DreamResearchTracker) async {
        guard let key = DreamKeychain.read() else { return }
        await cancelResponses(tracker.cancel(), key: key)
    }

    private static func cancelResponses(_ ids: [String], key: String) async {
        for id in ids {
            guard id.hasPrefix("resp_"),
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { continue }
            var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses/\(id)/cancel")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private static func requestError(_ response: URLResponse, data: Data) -> NSError {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let apiError = payload?["error"] as? [String: Any]
        let apiMessage = (apiError?["message"] as? String ?? "")
            .replacingOccurrences(of: "\n", with: " ")
        let apiParameter = apiError?["param"] as? String
        let message: String
        switch code {
        case 401, 403: message = String(localized: "API Key 无效或没有模型权限，请在设置中重新验证。")
        case 429: message = String(localized: "AI 请求过于频繁或额度不足，请稍后重试。")
        case 400 where !apiMessage.isEmpty:
            message = String(format: NSLocalizedString("AI 请求参数被拒绝（HTTP 400%@）：%@", comment: ""), apiParameter.map { " · \($0)" } ?? "", String(apiMessage.prefix(240)))
        default: message = String(format: NSLocalizedString("AI 请求失败（HTTP %@）。请稍后重试。", comment: ""), String(code))
        }
        return NSError(domain: "DreamResearch", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}
