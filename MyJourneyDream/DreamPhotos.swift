import Foundation

enum DreamPhotos {
    static func search(for experience: JourneyExperience) async -> [JourneyPhoto] {
        let place = searchPlace(experience.region)
        let suffix: String
        switch experience.mode {
        case .walking: suffix = "hiking trail"
        case .roadTrip: suffix = "scenic road"
        case .slowStay: suffix = "old town square"
        }
        let queries = ["\(place) \(suffix)", place]
        for query in queries {
            if let photos = try? await fetch(query: query), !photos.isEmpty {
                return Array(photos.prefix(4))
            }
        }
        return []
    }

    private static func searchPlace(_ region: String) -> String {
        if let start = region.firstIndex(of: "("), let end = region[start...].firstIndex(of: ")") {
            return String(region[region.index(after: start)..<end])
        }
        let known = ["马德拉": "Madeira", "苏格兰高地": "Scottish Highlands",
                     "安达卢西亚": "Andalusia"]
        for (name, translation) in known where region.contains(name) { return translation }
        return region.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespaces) ?? region
    }

    private static func fetch(query: String) async throws -> [JourneyPhoto] {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "12"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|extmetadata|mime"),
            URLQueryItem(name: "iiurlwidth", value: "1200"),
            URLQueryItem(name: "format", value: "json")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        request.setValue("MyJourneyDream/0.1 (travel imagery)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [String: [String: Any]] else { return [] }
        return pages.values.sorted { ($0["index"] as? Int ?? 100) < ($1["index"] as? Int ?? 100) }
            .compactMap { page -> JourneyPhoto? in
                guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                      let mime = info["mime"] as? String,
                      ["image/jpeg", "image/png", "image/webp"].contains(mime),
                      let imageURL = info["thumburl"] as? String,
                      let sourceURL = info["descriptionurl"] as? String,
                      let metadata = info["extmetadata"] as? [String: [String: Any]],
                      let license = metadata["LicenseShortName"]?["value"] as? String,
                      license.hasPrefix("CC ") || license == "Public domain" else { return nil }
                let rawCredit = metadata["Artist"]?["value"] as? String ?? "Wikimedia Commons"
                let credit = rawCredit.replacingOccurrences(of: "<[^>]*>", with: "",
                                                             options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return JourneyPhoto(imageURL: imageURL, sourceURL: sourceURL,
                                    credit: String(credit.prefix(80)), license: license)
            }
    }
}
