import Foundation

enum JourneyMode: String, Codable, CaseIterable, Identifiable {
    case backpack = "背包"
    case roadTrip = "自驾"
    case slowStay = "旅居"

    var id: String { rawValue }
    var title: String { NSLocalizedString(rawValue, comment: "Journey mode") }
    var symbol: String {
        switch self {
        case .backpack: "backpack.fill"
        case .roadTrip: "car.side.fill"
        case .slowStay: "house.fill"
        }
    }
    var fallbackAsset: String {
        switch self {
        case .backpack: "WalkingFallback"
        case .roadTrip: "RoadFallback"
        case .slowStay: "StayFallback"
        }
    }
    var question: String {
        switch self {
        case .backpack: String(localized: "背上行囊，下一站去哪里？")
        case .roadTrip: String(localized: "哪条路本身值得开？")
        case .slowStay: String(localized: "哪里值得舒服地住上几周？")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "徒步" || value == "walking" || value == "backpack" {
            self = .backpack
        } else if let mode = Self(rawValue: value) {
            self = mode
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown journey mode")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct EvidenceLink: Codable, Identifiable {
    var title: String
    var url: String
    var role: String
    var id: String { url }
}

struct JourneyRouteStage: Codable, Identifiable {
    var day: String
    var place: String
    var experience: String
    var transfer: String
    var landmarks: String? = nil
    var timing: String? = nil
    var alternative: String? = nil
    var id: String { "\(day)-\(place)" }
}

struct JourneyPhoto: Codable, Identifiable {
    var imageURL: String
    var sourceURL: String
    var credit: String
    var license: String
    var id: String { sourceURL }
}

struct JourneyExperience: Codable, Identifiable {
    var id = UUID()
    var mode: JourneyMode
    var title: String
    var region: String
    var season: String
    var duration: String
    var signatureExperience: String
    var whyNow: String
    var whatYouLove: String
    var whatToAccept: String
    var routeOrBase: String
    var routePlan: [JourneyRouteStage]? = nil
    var longStayValue: String
    var confidence: String
    var evidence: [EvidenceLink]
    var highlights: [String]?
    var photos: [JourneyPhoto]? = nil
    var researchedAt = Date()
    var isDemo: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case mode, title, region, season, duration, signatureExperience, whyNow,
             whatYouLove, whatToAccept, routeOrBase, routePlan, longStayValue, confidence, evidence, highlights, photos, isDemo
    }
}

struct PreparationStep: Codable, Identifiable {
    var id = UUID()
    var phase: String
    var title: String
    var rationale: String
    var sourceURL: String
    var isDone = false
}

struct ConfirmedJourney: Codable, Identifiable {
    var id = UUID()
    var title: String
    var destination: String
    var start: Date
    var end: Date
    var companions: String
    var preparation: [PreparationStep] = []
}

struct DreamLibrary: Codable {
    var experiences: [JourneyExperience] = []
    var favorites: [JourneyExperience]? = nil
    var journeys: [ConfirmedJourney] = []
    var notes: String = ""
    var lastDiscoveryAt: Date?
}

@MainActor
@Observable
final class DreamStore {
    var library: DreamLibrary { didSet { save() } }

    var favoriteExperiences: [JourneyExperience] { library.favorites ?? [] }

    func isFavorite(_ id: UUID) -> Bool { favoriteExperiences.contains { $0.id == id } }

    func toggleFavorite(_ experience: JourneyExperience) {
        var favorites = favoriteExperiences
        if let index = favorites.firstIndex(where: { $0.id == experience.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(experience, at: 0)
        }
        library.favorites = favorites
    }

    private var isPreview = false

    init(previewLibrary: DreamLibrary? = nil) {
        if let previewLibrary { library = previewLibrary; isPreview = true; return }
        let url = Self.storageURL
        library = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(DreamLibrary.self, from: $0)
        } ?? DreamLibrary()
    }

    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DreamLibrary.json")
    }

    private func save() {
        guard !isPreview else { return }
        let url = Self.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(library) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
extension JourneyExperience {
    var localizedDemo: JourneyExperience {
        let builtInTitles = ["背包慢游马德拉", "Backpack through Madeira", "城堡、荒野与威士忌之路", "Castles, wilderness, and whisky roads", "住进西班牙南部", "Live in southern Spain", "云上山脊与雾森林", "Cloud ridges and misty forests"]
        guard isDemo == true || (evidence.isEmpty && builtInTitles.contains(title)) else { return self }
        var copy = self
        copy.title = PublicLanguage.demoText(title)
        copy.region = PublicLanguage.demoText(region)
        copy.season = PublicLanguage.demoText(season)
        copy.duration = PublicLanguage.demoText(duration)
        copy.signatureExperience = PublicLanguage.demoText(signatureExperience)
        copy.whyNow = PublicLanguage.demoText(whyNow)
        copy.whatYouLove = PublicLanguage.demoText(whatYouLove)
        copy.whatToAccept = PublicLanguage.demoText(whatToAccept)
        copy.routeOrBase = PublicLanguage.demoText(routeOrBase)
        copy.longStayValue = PublicLanguage.demoText(longStayValue)
        copy.confidence = PublicLanguage.demoText(confidence)
        copy.highlights = highlights?.map(PublicLanguage.demoText)
        copy.routePlan = routePlan?.map { stage in
            var value = stage
            value.day = PublicLanguage.demoText(stage.day)
            value.place = PublicLanguage.demoText(stage.place)
            value.experience = PublicLanguage.demoText(stage.experience)
            value.transfer = PublicLanguage.demoText(stage.transfer)
            value.landmarks = stage.landmarks.map(PublicLanguage.demoText)
            value.timing = stage.timing.map(PublicLanguage.demoText)
            value.alternative = stage.alternative.map(PublicLanguage.demoText)
            return value
        }
        return copy
    }
}
