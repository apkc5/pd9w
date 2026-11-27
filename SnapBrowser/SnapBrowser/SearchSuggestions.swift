import Foundation

/// Search suggestions for the address-bar panel (v0.4.5).
///
/// Every supported engine answers on a public JSON endpoint in the
/// OpenSearch shape `["query", ["suggestion", ...]]` — verified
/// against the live services for all four engines while building
/// this (Brave /api/suggest, Google suggestqueries with
/// client=firefox, DuckDuckGo /ac/?type=list, Bing osjson.aspx).
/// DuckDuckGo's non-list shape (`[{"phrase": ...}]`) is also
/// accepted defensively. Any failure — offline, non-200, unexpected
/// JSON — yields an empty list: the panel simply shows no suggestion
/// rows instead of breaking.
///
/// This is only ever called when the user has opted in (Settings →
/// 検索候補を表示, default OFF), because fetching means the typed
/// text leaves the device for the selected search engine.
enum SearchSuggestions {
    static let maxResults = 6

    static func fetch(engine: SearchEngine, query: String) async -> [String] {
        guard let url = endpoint(for: engine, query: query) else { return [] }
        var request = URLRequest(url: url)
        // The endpoints are browser-facing; a browser UA keeps them
        // from answering bot-filter pages instead of JSON.
        request.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data, excluding: query)
    }

    static func endpoint(for engine: SearchEngine, query: String) -> URL? {
        var components: URLComponents?
        switch engine {
        case .brave:
            components = URLComponents(string: "https://search.brave.com/api/suggest")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
        case .google:
            components = URLComponents(string: "https://suggestqueries.google.com/complete/search")
            components?.queryItems = [URLQueryItem(name: "client", value: "firefox"),
                                      URLQueryItem(name: "q", value: query)]
        case .duckduckgo:
            components = URLComponents(string: "https://duckduckgo.com/ac/")
            components?.queryItems = [URLQueryItem(name: "q", value: query),
                                      URLQueryItem(name: "type", value: "list")]
        case .bing:
            components = URLComponents(string: "https://api.bing.com/osjson.aspx")
            components?.queryItems = [URLQueryItem(name: "query", value: query)]
        }
        return components?.url
    }

    /// Extracts the suggestion list. The query itself is dropped (the
    /// panel always shows it as its own first row), as are blanks and
    /// case-insensitive duplicates.
    static func parse(_ data: Data, excluding query: String) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let array = root as? [Any] else { return [] }
        var raw: [String] = []
        if array.count >= 2, let list = array[1] as? [Any] {
            raw = list.compactMap { $0 as? String }
        } else {
            raw = array.compactMap { ($0 as? [String: Any])?["phrase"] as? String }
        }
        var seen = Set<String>()
        var results: [String] = []
        for candidate in raw {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.lowercased() != query.lowercased(),
                  seen.insert(trimmed.lowercased()).inserted else { continue }
            results.append(trimmed)
            if results.count >= maxResults { break }
        }
        return results
    }
}
