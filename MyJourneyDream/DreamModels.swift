import Foundation

enum JourneyMode: String, Codable, CaseIterable, Identifiable {
    case walking = "徒步"
    case roadTrip = "自驾"
    case slowStay = "旅居"

    var id: String { rawValue }
    var title: String { NSLocalizedString(rawValue, comment: "Journey mode") }
    var symbol: String {
        switch self {
        case .walking: "figure.hiking"
        case .roadTrip: "car.side.fill"
        case .slowStay: "house.fill"
        }
    }
    var fallbackAsset: String {
        switch self {
        case .walking: "WalkingFallback"
        case .roadTrip: "RoadFallback"
        case .slowStay: "StayFallback"
        }
    }
    var question: String {
        switch self {
        case .walking: String(localized: "哪些步行体验值得专门去？")
        case .roadTrip: String(localized: "哪条路本身值得开？")
        case .slowStay: String(localized: "哪里值得舒服地住上几周？")
        }
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

    enum CodingKeys: String, CodingKey {
        case mode, title, region, season, duration, signatureExperience, whyNow,
             whatYouLove, whatToAccept, routeOrBase, routePlan, longStayValue, confidence, evidence, highlights, photos
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

    init() {
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
        let url = Self.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(library) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
