import Foundation

enum UpdateChecker {
    static let repo = "MikkelIJ/MW"

    struct Result {
        let latestTag: String
        let isNewer: Bool
        let htmlURL: URL
    }

    /// Returns the running app's CFBundleShortVersionString, or "0" if missing.
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    static func check(completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            completion(.failure(Err.badURL)); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MW-app", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error { return completion(.failure(error)) }
            guard let data,
                  let http = resp as? HTTPURLResponse else {
                return completion(.failure(Err.badResponse))
            }
            guard (200..<300).contains(http.statusCode) else {
                return completion(.failure(Err.http(http.statusCode)))
            }
            do {
                let payload = try JSONDecoder().decode(GHRelease.self, from: data)
                let latest = payload.tag_name
                let pageURL = URL(string: payload.html_url)
                    ?? URL(string: "https://github.com/\(repo)/releases/latest")!
                let newer = compare(current: currentVersion, latestTag: latest) == .orderedAscending
                completion(.success(Result(latestTag: latest, isNewer: newer, htmlURL: pageURL)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Compares "0.1" vs "v0.2.0" by stripping a leading "v" and doing
    /// numeric, component-wise comparison. Missing components count as 0.
    static func compare(current: String, latestTag: String) -> ComparisonResult {
        let a = parse(current)
        let b = parse(latestTag)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func parse(_ s: String) -> [Int] {
        let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }

    private struct GHRelease: Decodable {
        let tag_name: String
        let html_url: String
    }

    enum Err: LocalizedError {
        case badURL, badResponse, http(Int)
        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid update URL."
            case .badResponse: return "Unexpected response from GitHub."
            case .http(let code): return "GitHub returned HTTP \(code)."
            }
        }
    }
}
