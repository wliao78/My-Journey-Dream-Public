import SwiftUI
import UIKit

private enum DreamPalette {
    static let background = Color(red: 0.055, green: 0.045, blue: 0.17)
    static let card = Color(red: 0.32, green: 0.25, blue: 0.50).opacity(0.48)
    static let ink = Color(red: 0.98, green: 0.96, blue: 1.0)
    static let accent = Color(red: 0.91, green: 0.73, blue: 1.0)
    static let muted = Color(red: 0.77, green: 0.72, blue: 0.84)
    static var backdrop: some View { ZStack {
        LinearGradient(
            colors: [Color(red: 0.35, green: 0.24, blue: 0.62),
                     Color(red: 0.20, green: 0.14, blue: 0.43), background],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        RadialGradient(colors: [Color(red: 0.66, green: 0.39, blue: 0.78).opacity(0.42), .clear],
                       center: .topTrailing, startRadius: 10, endRadius: 330)
    } }
}

struct DreamHomeView: View {
    @Bindable var store: DreamStore
    @State private var query = ""
    @State private var activeRequest = ""
    @State private var loading = false
    @State private var submitting = false
    @State private var updatingModes = Set(JourneyMode.allCases)
    @State private var thinkingDepth: DreamThinkingDepth = .balanced
    @State private var researchStartedAt = Date.now
    @State private var researchTracker: DreamResearchTracker?
    @State private var activeResearchTask: Task<Void, Never>?
    @State private var status: String?
    @State private var showSettings = false
    @State private var showJourneys = false
    @State private var showFavorites = false
    @State private var proposedJourney: ConfirmedJourney?
    @State private var speechBaseText = ""
    @State private var didStartOnLaunch = false
    @StateObject private var speech = DreamSpeechInput()
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compact = geometry.size.height < 700
                let spacing: CGFloat = compact ? 8 : 12
                VStack(alignment: .leading, spacing: spacing) {
                    header(compact: compact)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(loading ? DreamPalette.accent : DreamPalette.muted)
                            .frame(width: 6, height: 6)
                        Text(status ?? String(localized: "为你准备背包、自驾与旅居灵感"))
                            .lineLimit(1)
                            .font(.caption)
                            .foregroundStyle(DreamPalette.muted)
                        Spacer(minLength: 0)
                        if loading {
                            Button(String(localized: "停止")) { stopResearch() }
                                .font(.caption.weight(.semibold))
                        }
                    }
                    HStack {
                        Text(String(localized: "此刻的灵感"))
                            .font(.system(size: compact ? 19 : 22, weight: .bold, design: .rounded))
                        Spacer()
                        Button(String(localized: "换一组"), systemImage: "arrow.clockwise") { startDiscovery() }
                            .font(.caption.weight(.semibold))
                            .disabled(loading)
                    }
                    ForEach(JourneyMode.allCases) { mode in
                        Group {
                            if loading && updatingModes.contains(mode) {
                                JourneySkeletonCard(mode: mode)
                            } else if let experience = store.library.experiences.first(where: { $0.mode == mode })?.localizedDemo {
                                NavigationLink {
                                    ExperienceDetailView(store: store, experienceID: experience.id,
                                                         request: activeRequest)
                                } label: {
                                    ExperienceCard(experience: experience, compact: compact)
                                }
                                .buttonStyle(.plain)
                            } else {
                                emptyCard(mode: mode)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    aiInputBar
                }
                .padding(.horizontal, compact ? 16 : 20)
                .padding(.top, compact ? 10 : 16)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DreamPalette.backdrop.ignoresSafeArea()
                .onTapGesture { dismissKeyboard() })
            .foregroundStyle(DreamPalette.ink)
            .tint(DreamPalette.accent)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(String(localized: "完成")) { dismissKeyboard() }
                }
            }
            .sheet(isPresented: $showSettings) { DreamSettingsView(store: store) }
            .sheet(item: $proposedJourney) { draft in
                NewJourneyView(store: store, draft: draft, onSaved: prepareNewJourney)
            }
            .sheet(isPresented: $showJourneys) { JourneyCollectionView(store: store) }
            .sheet(isPresented: $showFavorites) { FavoriteJourneysView(store: store) }
            .onChange(of: speech.transcript) { _, transcript in
                if speech.isRecording {
                    query = [speechBaseText, transcript].filter { !$0.isEmpty }.joined(separator: " ")
                }
            }
            .onDisappear { speech.stop() }
            .task {
                guard !didStartOnLaunch else { return }
                didStartOnLaunch = true
                if store.library.experiences.isEmpty {
                    store.library.experiences = DreamResearch.fallbackRecommendations(modes: Set(JourneyMode.allCases))
                }
                status = PublicDemo.enabled ? PublicDemo.notice : String(localized: "请选择思考程度，再开始推荐")

            }
        }
    }

    private func startDiscovery(tracker existingTracker: DreamResearchTracker? = nil,
                                modes: Set<JourneyMode> = Set(JourneyMode.allCases),
                                request: String? = nil) {
        guard !loading else { return }
        guard DreamKeychain.read() != nil || DreamResearch.isDemoMode else {
            status = String(localized: "请先在设置中填写并验证 API Key。")
            showSettings = true
            return
        }
        let tracker = existingTracker ?? DreamResearchTracker()
        researchTracker = tracker
        if existingTracker == nil { researchStartedAt = .now }
        let discoveryRequest = request ?? activeRequest
        activeRequest = discoveryRequest
        updatingModes = modes
        loading = true
        status = modes.count == 3 ? String(localized: "正在寻找你的下一段旅程…") : String(format: NSLocalizedString("正在更新%@方案…", comment: ""), String(describing: modes.map(\.title).sorted().joined(separator: "、")))
        activeResearchTask = Task { await discover(tracker: tracker, modes: modes, request: discoveryRequest) }
    }

    private func startSubmission() {
        if PublicDemo.enabled { status = String(localized: "演示模式不会处理你的输入，请关闭演示模式以获取真实 AI 结果。"); return }
        guard !loading, !submitting else { return }
        submitting = true
        speech.stop()
        dismissKeyboard()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            finishSubmission()
        }
    }

    private func dismissKeyboard() {
        inputFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func finishSubmission() {
        submitting = false
        let submitted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty, !loading else { return }
        speechBaseText = ""
        query = ""
        activeRequest = submitted
        let confirmedSignals = ["已确定", "已经确定", "订好了", "已预订", "确认了",
                                "booked", "confirmed"]
        if !confirmedSignals.contains(where: submitted.lowercased().contains) {
            startDiscovery(modes: modesMentioned(in: submitted), request: submitted)
            return
        }
        let tracker = DreamResearchTracker()
        researchTracker = tracker
        researchStartedAt = .now
        updatingModes = modesMentioned(in: submitted)
        loading = true
        activeResearchTask = Task { await submitInput(submitted, tracker: tracker) }
    }

    private func modesMentioned(in input: String) -> Set<JourneyMode> {
        let text = input.lowercased()
        let keywords: [(JourneyMode, [String])] = [
            (.backpack, ["背包", "背包客", "backpack", "徒步", "步道", "hiking", "trekking"]),
            (.roadTrip, ["自驾", "公路旅行", "road trip", "driving"]),
            (.slowStay, ["旅居", "长住", "慢旅行", "slow stay"])
        ]
        let matched = Set(keywords.compactMap { mode, words in
            words.contains(where: text.contains) ? mode : nil
        })
        return matched.isEmpty ? Set(JourneyMode.allCases) : matched
    }

    private func stopResearch() {
        guard let tracker = researchTracker else { return }
        activeResearchTask?.cancel()
        Task { await DreamResearch.cancel(tracker) }
        loading = false
        status = String(localized: "已停止研究；已完成的推荐会保留。")
    }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "我的旅程 — 梦游"))
                    .font(.system(size: compact ? 25 : 29, weight: .bold, design: .rounded))
                Text(String(localized: "下一次，去经历什么？"))
                    .font(.subheadline).foregroundStyle(.white.opacity(0.62))
            }
            Spacer()
            Button { showFavorites = true } label: {
                Image(systemName: "heart.fill")
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(DreamPalette.accent.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(String(localized: "收藏的旅程"))
            Button { showJourneys = true } label: {
                Image(systemName: "checklist")
                    .font(.headline)
                    .frame(width: 38, height: 38)
            .background(DreamPalette.accent.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(String(localized: "已确定旅行与准备"))
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(DreamPalette.accent.opacity(0.12), in: Circle())
            }
            .accessibilityLabel(String(localized: "设置与旅行画像"))
        }
    }

    private var aiInputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(DreamPalette.accent)
                .padding(.bottom, 8)
            ZStack(alignment: .topLeading) {
                if query.isEmpty {
                    Text(String(localized: "想去哪、何时去，或想怎样旅行…"))
                        .foregroundStyle(DreamPalette.muted.opacity(0.65))
                        .padding(.top, 7)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $query)
                    .scrollContentBackground(.hidden)
                    .frame(height: draftEditorHeight)
                    .focused($inputFocused)
                    .accessibilityLabel(String(localized: "旅行要求草稿，可滚动查看完整内容"))
            }
            Button {
                inputFocused = false
                if !speech.isRecording { speechBaseText = query }
                Task { await speech.toggle() }
            } label: {
                Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                    .foregroundStyle(speech.isRecording ? .red : DreamPalette.accent)
            }
            .accessibilityLabel(speech.isRecording ? String(localized: "停止语音输入") : String(localized: "开始语音输入"))
            Button { startSubmission() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title3)
            }
            .disabled(loading || submitting || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(String(localized: "确认发送旅行要求"))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .background(DreamPalette.card, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(DreamPalette.accent.opacity(0.3)))
        .padding(.top, 2)
    }

    private var draftEditorHeight: CGFloat {
        if query.isEmpty && !inputFocused && !speech.isRecording { return 30 }
        let lines = query.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { count, line in
            let width = line.reduce(0.0) { total, character in
                total + (String(character).utf8.count == 1 ? 0.55 : 1.0)
            }
            return count + max(1, Int(ceil(width / 14)))
        }
        return min(136, max(38, CGFloat(lines) * 22 + 16))
    }

    private func emptyCard(mode: JourneyMode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(mode.title, systemImage: mode.symbol)
                .font(.caption.bold()).foregroundStyle(DreamPalette.accent)
            Text(mode.question).font(.headline)
            Text(String(localized: "等待下一段旅程"))
                .font(.caption).foregroundStyle(DreamPalette.muted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .background(DreamPalette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func discover(tracker: DreamResearchTracker, modes: Set<JourneyMode>, request: String) async {
        do {
            let result = try await DreamResearch.discover(modes: Array(modes), request: request,
                                                           profile: store.library.notes,
                                                           depth: thinkingDepth, tracker: tracker)
            try Task.checkCancellation()
            guard researchTracker === tracker else { return }
            let preserved = store.library.experiences.filter { !modes.contains($0.mode) }
            store.library.experiences = JourneyMode.allCases.compactMap { mode in
                result.first(where: { $0.mode == mode }) ?? preserved.first(where: { $0.mode == mode })
            }
            store.library.lastDiscoveryAt = .now
            loading = false
            status = modes.count == 3 ? String(localized: "3 个备选方案已就绪 · 点进感兴趣的方案继续深度研究")
                : String(format: NSLocalizedString("已更新%@方案 · 其他卡片保持不变", comment: ""), String(describing: modes.map(\.title).sorted().joined(separator: "、")))
            for experience in result {
                Task {
                    let photos = await DreamPhotos.search(for: experience)
                    guard !photos.isEmpty,
                          let index = store.library.experiences.firstIndex(where: { $0.id == experience.id }) else { return }
                    store.library.experiences[index].photos = photos
                }
            }
        } catch {
            if researchTracker === tracker && !Task.isCancelled && !(error is CancellationError) {
                let missingModes = modes.filter { mode in
                    !store.library.experiences.contains(where: { $0.mode == mode })
                }
                if !missingModes.isEmpty {
                    let fallback = DreamResearch.fallbackRecommendations(modes: missingModes)
                    store.library.experiences = JourneyMode.allCases.compactMap { mode in
                        store.library.experiences.first(where: { $0.mode == mode })
                            ?? fallback.first(where: { $0.mode == mode })
                    }
                    status = String(localized: "连接超时 · 已显示通用灵感，可换一组重试")
                } else {
                    status = String(localized: "更新未完成，原有推荐已保留 · 请重试")
                }
            }
            if researchTracker === tracker { loading = false }
        }
    }

    private func submitInput(_ submitted: String, tracker: DreamResearchTracker) async {
        speech.stop()
        inputFocused = false
        status = String(localized: "正在理解你的要求…")
        do {
            let decision = try await DreamResearch.classify(submitted, depth: thinkingDepth,
                                                             tracker: tracker)
            try Task.checkCancellation()
            guard researchTracker === tracker else { return }
            loading = false
            if let journey = decision.confirmedJourney {
                proposedJourney = journey
                status = String(localized: "已识别为确定旅行，请核对地点和日期。")
            } else if !decision.clarification.isEmpty {
                status = decision.clarification
            } else {
                status = nil
                startDiscovery(tracker: tracker, modes: modesMentioned(in: submitted), request: submitted)
            }
        } catch {
            if researchTracker === tracker {
                loading = false
                if !Task.isCancelled && !(error is CancellationError) {
                    status = PublicLanguage.errorDescription(error)
                }
            }
        }
    }

    private func prepareNewJourney(_ journey: ConfirmedJourney) {
        Task {
            do {
                let steps = try await DreamResearch.prepare(journey)
                guard let index = store.library.journeys.firstIndex(where: { $0.id == journey.id }) else { return }
                store.library.journeys[index].preparation = steps
                status = String(localized: "已为确定旅行生成准备时间线。")
            } catch {
                status = String(format: NSLocalizedString("旅行已保存；准备时间线暂未生成：%@", comment: ""), String(describing: PublicLanguage.errorDescription(error)))
            }
        }
    }
}

private struct JourneySkeletonCard: View {
    let mode: JourneyMode

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(String(format: NSLocalizedString("%@旅程", comment: "Journey mode card"), mode.title), systemImage: mode.symbol)
                .font(.caption.bold())
                .foregroundStyle(DreamPalette.accent)
            skeletonLine(width: 0.62, height: 18)
            skeletonLine(width: 0.82, height: 13)
            Spacer(minLength: 0)
            skeletonLine(width: 0.72, height: 13)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .background(DreamPalette.card, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: NSLocalizedString("正在生成%@旅程推荐", comment: ""), String(describing: mode.title)))
    }

    private func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: height / 2)
                .fill(.white.opacity(0.12))
                .frame(width: proxy.size.width * width, height: height)
        }
        .frame(height: height)
    }
}

private struct ExperienceCard: View {
    let experience: JourneyExperience
    let compact: Bool
    var body: some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                Label(experience.mode.title, systemImage: experience.mode.symbol)
                    .font(.caption.bold())
                    .foregroundStyle(DreamPalette.accent)
                Text(experience.title)
                    .font(.system(size: compact ? 15 : 17, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text("\(experience.region) · \(experience.season) · \(experience.duration)")
                    .font(.caption2)
                    .foregroundStyle(DreamPalette.muted)
                    .lineLimit(2)
                Text(experience.signatureExperience)
                    .font(.system(size: compact ? 11 : 12))
                    .foregroundStyle(DreamPalette.ink.opacity(0.88))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !compact, let highlights = experience.highlights, !highlights.isEmpty {
                    Text(highlights.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DreamPalette.accent.opacity(0.9))
                        .lineLimit(2)
                }
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(DreamPalette.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            JourneyPhotoView(photo: experience.photos?.first, mode: experience.mode)
                .frame(width: compact ? 98 : 118)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    if experience.photos?.first == nil {
                        Text(String(localized: "灵感示意"))
                            .font(.system(size: 9))
                            .padding(4)
                            .background(.black.opacity(0.5), in: Capsule())
                            .padding(5)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(compact ? 12 : 15)
        .background(
            LinearGradient(colors: [DreamPalette.card, DreamPalette.card.opacity(0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.09)))
    }
}

private struct JourneyPhotoView: View {
    let photo: JourneyPhoto?
    let mode: JourneyMode

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let photo, let url = URL(string: photo.imageURL) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            fallback
                        }
                    }
                } else {
                    fallback
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityLabel(photo == nil ? String(format: NSLocalizedString("%@灵感示意图", comment: ""), String(describing: mode.title)) : String(format: NSLocalizedString("%@目的地照片", comment: ""), String(describing: mode.title)))
    }

    private var fallback: some View {
        Image(mode.fallbackAsset).resizable().scaledToFill()
    }
}

private struct ExperienceDetailView: View {
    @Bindable var store: DreamStore
    let experienceID: UUID
    let request: String
    @State private var researching = false
    @State private var researchError: String?
    @State private var thinkingDepth: DreamThinkingDepth = .quick
    @State private var didStartInitialResearch = false

    private var experience: JourneyExperience? {
        (store.library.experiences.first(where: { $0.id == experienceID })
            ?? store.favoriteExperiences.first(where: { $0.id == experienceID }))?.localizedDemo
    }

    var body: some View {
        Group {
            if let experience {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                photoGallery(experience)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            store.toggleFavorite(experience)
                        } label: {
                            Image(systemName: store.isFavorite(experience.id) ? "heart.fill" : "heart")
                                .font(.headline)
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .accessibilityLabel(store.isFavorite(experience.id) ? String(localized: "取消收藏") : String(localized: "收藏旅程"))
                        .padding(10)
                    }
                if researching {
                    Label(String(format: NSLocalizedString("正在%@研究路线、季节与实用信息…", comment: ""), String(describing: thinkingDepth.title)), systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DreamPalette.accent)
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                } else if PublicDemo.enabled {
                    Text(PublicDemo.notice)
                        .font(.caption).foregroundStyle(DreamPalette.accent)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(experience.evidence.isEmpty ? String(localized: "快速研究暂未完成，可重试或选择其他档位") : String(localized: "路线已就绪，可选择档位重新研究"))
                            .font(.caption.bold()).foregroundStyle(DreamPalette.accent)
                        Picker(String(localized: "研究深度"), selection: $thinkingDepth) {
                            ForEach(DreamThinkingDepth.allCases) { depth in
                                Text(depth.title).tag(depth)
                            }
                        }
                        .pickerStyle(.segmented)
                        if let researchError {
                            Text(String(format: NSLocalizedString("备选方案已保留，深度研究暂未完成：%@", comment: ""), String(describing: researchError)))
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        HStack {
                            Button(experience.evidence.isEmpty ? String(localized: "重新获取路线") : String(localized: "按所选档位重新研究"),
                                   systemImage: "sparkles") {
                                Task { await research() }
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer(minLength: 8)
                            Button {
                                store.toggleFavorite(experience)
                            } label: {
                                Image(systemName: store.isFavorite(experience.id) ? "heart.fill" : "heart")
                                    .font(.headline)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel(store.isFavorite(experience.id) ? String(localized: "取消收藏") : String(localized: "收藏旅程"))
                        }
                    }
                    .padding(14)
                    .background(DreamPalette.card, in: RoundedRectangle(cornerRadius: 15))
                }
                routeSection(experience)
                detail(String(localized: "为什么现在"), experience.whyNow)
                detail(String(localized: "核心体验"), experience.signatureExperience)
                detail(String(localized: "你会喜欢"), experience.whatYouLove)
                detail(String(localized: "需要接受 · 反证检查"), experience.whatToAccept)
                if experience.mode == .slowStay { detail(String(localized: "长住性价比"), experience.longStayValue) }
                detail(String(localized: "可信度与缺口"), experience.confidence)
                Text(String(localized: "依据")).font(.headline)
                ForEach(experience.evidence) { evidence in
                    if let url = URL(string: evidence.url), url.scheme == "https" {
                        Link(destination: url) {
                            Label("\(evidence.role) · \(evidence.title)", systemImage: "arrow.up.right.square")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                Text(String(localized: "资料会变化；出行前请重新核对官方安全、交通、季节和预约信息。"))
                    .font(.footnote).foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(20)
                }.defaultScrollAnchor(PublicLanguage.qaScrollBottom ? .bottom : .top)
            } else {
                ContentUnavailableView(String(localized: "方案不存在"), systemImage: "questionmark.folder")
            }
        }.defaultScrollAnchor(PublicLanguage.qaScrollBottom ? .bottom : .top)
        .background(DreamPalette.backdrop.ignoresSafeArea())
        .foregroundStyle(DreamPalette.ink)
        .tint(DreamPalette.accent)
        .task {
            guard !didStartInitialResearch else { return }
            didStartInitialResearch = true
            if experience?.routePlan?.isEmpty != false {
                thinkingDepth = .quick
                await research()
            }
        }
    }

    private func research() async {
        guard !researching, let seed = experience else { return }
        researching = true
        defer { researching = false }
        researchError = nil
        do {
            let enriched = try await DreamResearch.enrich(seed, request: request,
                                                           profile: store.library.notes,
                                                           depth: thinkingDepth)
            try Task.checkCancellation()
            if let index = store.library.experiences.firstIndex(where: { $0.id == experienceID }) {
                store.library.experiences[index] = enriched
            }
            if let index = store.library.favorites?.firstIndex(where: { $0.id == experienceID }) {
                store.library.favorites?[index] = enriched
            }
        } catch where error is CancellationError {
            return
        } catch {
            researchError = PublicLanguage.errorDescription(error)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.bold()).foregroundStyle(DreamPalette.accent)
            Text(value.isEmpty ? String(localized: "暂无可靠资料") : value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DreamPalette.card, in: RoundedRectangle(cornerRadius: 15))
    }

    private func routeSection(_ experience: JourneyExperience) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(experience.mode == .slowStay ? String(localized: "旅居安排") : String(localized: "详细路线"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.title3.bold())
                .foregroundStyle(DreamPalette.accent)
            if let plan = experience.routePlan, !plan.isEmpty {
                if !experience.routeOrBase.isEmpty {
                    Text(experience.routeOrBase)
                        .font(.subheadline)
                        .foregroundStyle(DreamPalette.muted)
                }
                ForEach(plan) { stage in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DreamPalette.accent)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(stage.day) · \(stage.place)")
                                .font(.subheadline.bold())
                            if let landmarks = stage.landmarks, !landmarks.isEmpty {
                                Label(landmarks, systemImage: "mappin.and.ellipse")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(DreamPalette.accent)
                            }
                            Text(stage.experience).font(.subheadline)
                            Text(stage.transfer)
                                .font(.caption)
                                .foregroundStyle(DreamPalette.muted)
                            if let timing = stage.timing, !timing.isEmpty {
                                Label(timing, systemImage: "clock")
                                    .font(.caption)
                                    .foregroundStyle(DreamPalette.muted)
                            }
                            if let alternative = stage.alternative, !alternative.isEmpty {
                                Label(alternative, systemImage: "arrow.triangle.branch")
                                    .font(.caption)
                                    .foregroundStyle(DreamPalette.muted)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(researching ? String(localized: "正在整理每天的地点、体验与转场…") : String(localized: "路线暂未生成，可在下方重试。"))
                    .font(.subheadline)
                    .foregroundStyle(DreamPalette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DreamPalette.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func photoGallery(_ experience: JourneyExperience) -> some View {
        VStack(spacing: 7) {
            JourneyPhotoView(photo: experience.photos?.first, mode: experience.mode)
                .frame(height: 215)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(experience.mode.title, systemImage: experience.mode.symbol)
                            .font(.caption.bold())
                        Text(experience.title)
                            .font(.title2.bold())
                        Text("\(experience.region) · \(experience.season) · \(experience.duration)")
                            .font(.caption)
                    }
                    .shadow(color: .black, radius: 8)
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.8)],
                                               startPoint: .top, endPoint: .bottom))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                }
            HStack(spacing: 7) {
                ForEach(1..<4) { index in
                    JourneyPhotoView(photo: experience.photos.flatMap { $0.indices.contains(index) ? $0[index] : nil },
                                     mode: experience.mode)
                        .frame(height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            if let photos = experience.photos, !photos.isEmpty {
                DisclosureGroup(String(format: NSLocalizedString("图片来源与授权 · %@ 张", comment: ""), String(describing: photos.count))) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(photos) { photo in
                            if let source = URL(string: photo.sourceURL) {
                                Link("\(photo.credit) · \(photo.license)", destination: source)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(String(localized: "图片为灵感示意；目的地照片载入后自动更新。"))
                    .font(.caption2)
                    .foregroundStyle(DreamPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DreamSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("publicAIProvider") private var providerID = PublicAIProvider.openAI.rawValue
    @Bindable var store: DreamStore
    @State private var key = ""
    @State private var note = ""
    @State private var saved = false
    @State private var verifying = false
    @State private var verificationMessage: String?
    @State private var aiConsent = PublicAIConsent.granted
    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "AI 服务")) {
                    Picker(String(localized: "服务商"), selection: $providerID) {
                        ForEach(PublicAIProvider.allCases) { provider in
                            Text(provider.title).tag(provider.rawValue)
                        }
                    }
                    .onChange(of: providerID) { _, _ in
                        key = ""
                        aiConsent = PublicAIConsent.granted
                        saved = false
                        verificationMessage = nil
                    }
                    SecureField("API Key", text: $key)
                        .textInputAutocapitalization(.never)
                    PublicAIConfigurationView(provider: PublicAIProvider.selected)
                    Button(verifying ? String(localized: "正在验证…") : String(localized: "验证并保存 API Key")) {
                        verifying = true
                        verificationMessage = nil
                        Task {
                            do {
                                try await DreamResearch.verifyKey(key)
                                DreamKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
                                key = ""
                                saved = true
                                verificationMessage = String(localized: "验证成功，已保存到本机钥匙串。")
                            } catch {
                                verificationMessage = PublicLanguage.errorDescription(error)
                            }
                            verifying = false
                        }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || verifying)
                    if let verificationMessage { Text(verificationMessage).font(.footnote) }
                    if saved || DreamKeychain.read() != nil { Text(String(localized: "密钥已保存在本机钥匙串")) }
                    Toggle(String(localized: "同意向所选 AI 服务商发送资料"), isOn: $aiConsent)
                        .onChange(of: aiConsent) { _, value in PublicAIConsent.set(value) }
                    Text(String(localized: "开始研究后，旅行画像、目的地、日期、同行人及输入内容会发送给所选服务商。可随时关闭；关闭后仍可浏览演示灵感。"))
                        .font(.footnote)
                }
                Section(String(localized: "旅行画像")) {
                    TextField(String(localized: "去过哪里、喜欢什么、体力与预算偏好…"), text: $note, axis: .vertical)
                        .lineLimit(5...10)
                    Text(String(localized: "画像仅保存在本机；发起研究时会作为推荐条件发送给 AI。"))
                        .font(.footnote)
                }
                Section(String(localized: "隐私与支持")) {
                    Link("隐私政策", destination: URL(string: "https://wliao78.github.io/My-Journey-Support/#privacy-" + (PublicLanguage.isChinese ? "zh" : "en"))!)
                    Link(String(localized: "使用支持"), destination: URL(string: "https://wliao78.github.io/My-Journey-Support/#support")!)
                    Link(String(localized: "联系开发者"), destination: URL(string: "mailto:tinyworm@gmail.com")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DreamPalette.backdrop.ignoresSafeArea())
            .tint(DreamPalette.accent)
            .navigationTitle(String(localized: "设置"))
            .toolbar { Button(String(localized: "完成")) { store.library.notes = note; dismiss() } }
            .onAppear { note = store.library.notes }
        }
    }
}

private struct NewJourneyView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: DreamStore
    @State private var title = ""
    @State private var destination = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(7 * 86_400)
    @State private var companions = ""
    let onSaved: ((ConfirmedJourney) -> Void)?

    init(store: DreamStore, draft: ConfirmedJourney? = nil,
         onSaved: ((ConfirmedJourney) -> Void)? = nil) {
        self.store = store
        self.onSaved = onSaved
        _title = State(initialValue: draft?.title ?? "")
        _destination = State(initialValue: draft?.destination ?? "")
        _start = State(initialValue: draft?.start ?? Date())
        _end = State(initialValue: draft?.end ?? Date().addingTimeInterval(7 * 86_400))
        _companions = State(initialValue: draft?.companions ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "旅行名称"), text: $title)
                TextField(String(localized: "地点 / 地区"), text: $destination)
                DatePicker(String(localized: "开始"), selection: $start, displayedComponents: .date)
                DatePicker(String(localized: "结束"), selection: $end, in: start..., displayedComponents: .date)
                TextField(String(localized: "同行人（可留空）"), text: $companions)
            }
            .scrollContentBackground(.hidden)
            .background(DreamPalette.backdrop.ignoresSafeArea())
            .tint(DreamPalette.accent)
            .navigationTitle(String(localized: "已确定的旅行"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "加入")) {
                        let journey = ConfirmedJourney(title: title,
                            destination: destination, start: start, end: end, companions: companions)
                        store.library.journeys.append(journey)
                        onSaved?(journey)
                        dismiss()
                    }
                    .disabled(title.isEmpty || destination.isEmpty)
                }
            }
        }
    }
}

private struct FavoriteJourneysView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: DreamStore

    var body: some View {
        NavigationStack {
            List {
                if store.favoriteExperiences.isEmpty {
                    ContentUnavailableView(String(localized: "还没有收藏的旅程"), systemImage: "heart",
                                           description: Text(String(localized: "打开感兴趣的方案，点右上角爱心收藏。")))
                }
                ForEach(store.favoriteExperiences.map(\.localizedDemo)) { experience in
                    NavigationLink {
                        ExperienceDetailView(store: store, experienceID: experience.id, request: "")
                    } label: {
                        HStack(spacing: 12) {
                            JourneyPhotoView(photo: experience.photos?.first, mode: experience.mode)
                                .frame(width: 72, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(experience.title).font(.headline)
                                Text("\(experience.mode.title) · \(experience.region)")
                                    .font(.caption).foregroundStyle(DreamPalette.muted)
                            }
                        }
                    }
                    .listRowBackground(DreamPalette.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(DreamPalette.backdrop.ignoresSafeArea())
            .foregroundStyle(DreamPalette.ink)
            .tint(DreamPalette.accent)
            .navigationTitle(String(localized: "收藏的旅程"))
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "完成")) { dismiss() } } }
        }
    }
}

private struct JourneyCollectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: DreamStore
    @State private var showNewJourney = false

    var body: some View {
        NavigationStack {
            List {
                if store.library.journeys.isEmpty {
                    ContentUnavailableView(String(localized: "还没有已确定旅行"), systemImage: "suitcase",
                                           description: Text(String(localized: "在首页输入地点和日期，或手动添加。")))
                }
                ForEach(store.library.journeys) { journey in
                    NavigationLink {
                        PreparationView(store: store, journeyID: journey.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(journey.title).font(.headline)
                            Text("\(journey.destination) · \(journey.start.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DreamPalette.backdrop.ignoresSafeArea())
            .tint(DreamPalette.accent)
            .navigationTitle(String(localized: "已确定旅行"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "添加"), systemImage: "plus") { showNewJourney = true }
                }
                ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "完成")) { dismiss() } }
            }
            .sheet(isPresented: $showNewJourney) { NewJourneyView(store: store) }
        }
    }
}

private struct PreparationView: View {
    @Bindable var store: DreamStore
    let journeyID: UUID
    @State private var loading = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            if let index = store.library.journeys.firstIndex(where: { $0.id == journeyID }) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(store.library.journeys[index].title).font(.largeTitle.bold())
                    Text("\(store.library.journeys[index].destination) · \(store.library.journeys[index].start.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(.white.opacity(0.65))
                    Button(loading ? String(localized: "正在研究…") : String(localized: "生成准备时间线"), systemImage: "sparkles") {
                        Task { await prepare() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading)
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    ForEach(store.library.journeys[index].preparation.indices, id: \.self) { stepIndex in
                        let step = store.library.journeys[index].preparation[stepIndex]
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.phase).font(.caption.bold()).foregroundStyle(DreamPalette.accent)
                            Button {
                                store.library.journeys[index].preparation[stepIndex].isDone.toggle()
                            } label: {
                                Label(step.title, systemImage: step.isDone ? "checkmark.circle.fill" : "circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Text(step.rationale).font(.caption).foregroundStyle(.white.opacity(0.7))
                            if let url = URL(string: step.sourceURL), url.scheme == "https" {
                                Link(String(localized: "核对来源"), destination: url).font(.caption)
                            }
                        }
                        .padding(14)
                        .background(DreamPalette.card, in: RoundedRectangle(cornerRadius: 15))
                    }
                }
                .padding(20)
            }
        }
        .background(DreamPalette.backdrop.ignoresSafeArea())
        .foregroundStyle(DreamPalette.ink)
        .tint(DreamPalette.accent)
    }

    private func prepare() async {
        guard let trip = store.library.journeys.first(where: { $0.id == journeyID }) else { return }
        loading = true
        defer { loading = false }
        do {
            let steps = try await DreamResearch.prepare(trip)
            guard let index = store.library.journeys.firstIndex(where: { $0.id == journeyID }) else { return }
            store.library.journeys[index].preparation = steps
            message = String(localized: "请逐项核对；尚未核实的事项按提示自行确认。")
        } catch {
            message = PublicLanguage.errorDescription(error)
        }
    }
}
#if DEBUG
@MainActor
enum PublicLocalizationQA {
    static var screen: AnyView? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-LocalizationQA"), args.indices.contains(index + 1) else { return nil }
        let route = args[index + 1]
        let experiences = DreamResearch.fallbackRecommendations(modes: Set(JourneyMode.allCases))
        let trip = ConfirmedJourney(title: "Demo trip", destination: "Paris", start: .now,
            end: .now.addingTimeInterval(604800), companions: "")
        let library = DreamLibrary(experiences: experiences, favorites: [experiences[0]], journeys: [trip])
        let store = DreamStore(previewLibrary: library)
        switch route {
        case "settings": return AnyView(DreamSettingsView(store: store))
        case "new-trip": return AnyView(NewJourneyView(store: store))
        case "favorites": return AnyView(FavoriteJourneysView(store: store))
        case "journeys": return AnyView(JourneyCollectionView(store: store))
        case "preparation": return AnyView(NavigationStack { PreparationView(store: store, journeyID: trip.id) })
        default:
            let mode: JourneyMode = route == "road" ? .roadTrip : route == "stay" ? .slowStay : .backpack
            let item = experiences.first { $0.mode == mode }!
            return AnyView(NavigationStack { ExperienceDetailView(store: store, experienceID: item.id, request: "") })
        }
    }
}
#endif
