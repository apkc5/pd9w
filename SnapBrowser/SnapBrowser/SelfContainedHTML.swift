import Foundation
import WebKit

/// Builds a self-contained HTML copy of the current page, mirroring the
/// Android v0.3.5 approach:
///  1. In-page JS freezes a DOM clone: scripts/iframes stripped, same-origin
///     CSS inlined from cssRules, images and CSS url()s replaced by tokens.
///  2. Native code fetches each tokenised resource (with the web view's
///     cookies) and swaps the token for a data URI — or, for CSS, for the
///     fetched stylesheet text with its own url()/@import resolved.
/// Caps: 5 MB per resource (3 MB for CSS), 40 MB total, 800 resources
/// (raised in v0.4.13 from 3/2 MB, 25 MB, 500). Anything that fails falls
/// back to the original URL (needs network) or, for stylesheets, to
/// nothing — the rest of the page still renders offline.
/// v0.4.13 capture widening: srcset candidates (the browser's pick via
/// currentSrc, else the largest candidate), style-attribute url()s
/// (backgrounds), video posters, and @font-face fonts (which ride the
/// CSS url() pipeline) are tokenised too; and before freezing, the
/// page is scrolled through once (primeLazyLoads) so lazy-loaded
/// images have actually fired. Fetches run in bounded parallel
/// batches (6) — including the url()/@import references INSIDE a
/// stylesheet, which used to be fetched one by one.
enum SelfContainedHTML {

    struct Result {
        var data: Data
        var inlined: Int
        var total: Int
    }

    struct Resource {
        var token: String
        var url: String
        var kind: String // "img" | "css" | "other"
    }

    enum BuildError: Error {
        case freezeFailed
        case emptyHTML
    }

    // MARK: - Freeze script

    /// Runs in the page. Stores the frozen HTML (base64 of UTF-8) on
    /// window.__snapB64 and returns the resource list as a JSON string.
    private static let freezeJS = """
    (function() {
      var resources = [];
      function abs(u) { try { return new URL(u, document.baseURI).href; } catch (e) { return null; } }
      function bestSrcset(ss) {
        if (!ss) { return null; }
        var parts = ss.split(','), best = null, bestScore = -1;
        for (var i2 = 0; i2 < parts.length; i2++) {
          var t = parts[i2].replace(/^\\s+|\\s+$/g, '');
          if (!t) { continue; }
          var seg = t.split(/\\s+/);
          var score = 1;
          if (seg.length > 1) {
            var d = seg[seg.length - 1];
            if (d.slice(-1) === 'w') { score = parseFloat(d) || 1; }
            else if (d.slice(-1) === 'x') { score = (parseFloat(d) || 1) * 100000; }
          }
          if (score > bestScore) { bestScore = score; best = seg[0]; }
        }
        return best;
      }
      function tokenFor(url, kind) {
        if (resources.length >= 800) { return url; }
        var t = 'snapres://k' + (resources.length + 1) + '.';
        resources.push({ token: t, url: url, kind: kind });
        return t;
      }
      function tokenizeCSS(css) {
        css = css.replace(/@import\\s+(?:url\\(\\s*)?['"]?([^'")\\s;]+)['"]?\\s*\\)?\\s*;/g, function(m, u) {
          var a = abs(u); if (!a) { return ''; }
          return tokenFor(a, 'css');
        });
        css = css.replace(/url\\(\\s*(['"]?)([^'")]+)\\1\\s*\\)/g, function(m, q, u) {
          u = u.replace(/^\\s+|\\s+$/g, '');
          if (!u || u.indexOf('data:') === 0 || u.indexOf('snapres:') === 0) { return m; }
          var a = abs(u); if (!a) { return m; }
          return 'url(' + tokenFor(a, 'other') + ')';
        });
        return css;
      }
      var root = document.documentElement.cloneNode(true);
      var head = root.querySelector('head');
      if (head && !root.querySelector('base')) {
        var b = document.createElement('base');
        b.setAttribute('href', document.baseURI);
        head.insertBefore(b, head.firstChild);
      }
      if (head && !root.querySelector('meta[charset]')) {
        var mc = document.createElement('meta');
        mc.setAttribute('charset', 'utf-8');
        head.insertBefore(mc, head.firstChild);
      }
      var sheetInfos = [];
      for (var i = 0; i < document.styleSheets.length; i++) {
        var sh = document.styleSheets[i];
        var txt = null;
        try {
          var r = sh.cssRules;
          if (r) { var parts = []; for (var j = 0; j < r.length; j++) { parts.push(r[j].cssText); } txt = parts.join('\\n'); }
        } catch (e) { txt = null; }
        sheetInfos.push({ css: txt, href: sh.href || null });
      }
      var styleEls = root.querySelectorAll('link[rel~="stylesheet"], style');
      for (var k = 0; k < styleEls.length && k < sheetInfos.length; k++) {
        var el = styleEls[k];
        var info = sheetInfos[k];
        if (info.css !== null) {
          var st = document.createElement('style');
          st.textContent = tokenizeCSS(info.css);
          el.replaceWith(st);
        } else if (el.tagName === 'LINK' && info.href) {
          var st2 = document.createElement('style');
          st2.textContent = tokenFor(info.href, 'css');
          el.replaceWith(st2);
        }
      }
      var liveImgs = document.querySelectorAll('img');
      var cloneImgs = root.querySelectorAll('img');
      for (var m = 0; m < cloneImgs.length && m < liveImgs.length; m++) {
        var li = liveImgs[m];
        var ci = cloneImgs[m];
        // currentSrc is the candidate the browser actually picked
        // (srcset/picture resolution included); if it never picked
        // one (lazy image not yet fired), fall back to the largest
        // srcset candidate, then the data-* lazy chain.
        var src = li.currentSrc || bestSrcset(li.getAttribute('srcset')) || li.getAttribute('data-src') || li.getAttribute('data-lazy') || li.getAttribute('data-original') || li.src || '';
        ci.removeAttribute('srcset');
        if (src && src.indexOf('data:') !== 0) {
          var a2 = abs(src);
          if (a2) { ci.setAttribute('src', tokenFor(a2, 'img')); }
        }
      }
      var sources = root.querySelectorAll('source');
      for (var n = 0; n < sources.length; n++) { sources[n].removeAttribute('srcset'); }
      // Inline style url()s (background-image etc.): the attribute
      // is copied into the clone verbatim, so tokenise it in place.
      var styled = root.querySelectorAll('[style]');
      for (var v = 0; v < styled.length; v++) {
        var stv = styled[v].getAttribute('style');
        if (stv && stv.indexOf('url(') >= 0) {
          styled[v].setAttribute('style', tokenizeCSS(stv));
        }
      }
      // Video posters are still images — capture them like images.
      // (The video itself stays a live reference, as before.)
      var vids = root.querySelectorAll('video');
      for (var w = 0; w < vids.length; w++) {
        var poster = vids[w].getAttribute('poster');
        if (poster && poster.indexOf('data:') !== 0) {
          var pa = abs(poster);
          if (pa) { vids[w].setAttribute('poster', tokenFor(pa, 'img')); }
        }
      }
      var kill = root.querySelectorAll('script, noscript, object, embed, form');
      for (var p = 0; p < kill.length; p++) { kill[p].remove(); }
      var frames = root.querySelectorAll('iframe');
      for (var q2 = 0; q2 < frames.length; q2++) {
        var d = document.createElement('div');
        d.textContent = '[iframe]';
        d.setAttribute('style', 'border:1px solid #999;padding:8px;color:#666;font-size:12px;');
        frames[q2].replaceWith(d);
      }
      var all = root.querySelectorAll('*');
      for (var r2 = 0; r2 < all.length; r2++) {
        var at = all[r2].attributes;
        for (var s = at.length - 1; s >= 0; s--) {
          if (at[s].name.toLowerCase().indexOf('on') === 0) { all[r2].removeAttribute(at[s].name); }
        }
        if (all[r2].tagName === 'A') {
          var h = all[r2].getAttribute('href');
          if (h && h.toLowerCase().indexOf('javascript:') === 0) { all[r2].setAttribute('href', '#'); }
        }
      }
      var html = '<!DOCTYPE html>\\n' + root.outerHTML;
      var bytes = new TextEncoder().encode(html);
      var bin = '';
      var CH = 32768;
      for (var t2 = 0; t2 < bytes.length; t2 += CH) {
        bin += String.fromCharCode.apply(null, bytes.subarray(t2, Math.min(t2 + CH, bytes.length)));
      }
      window.__snapB64 = btoa(bin);
      window.__snapHTML = null;
      return JSON.stringify(resources);
    })()
    """

    // MARK: - Lazy-load priming (v0.4.13)

    /// Scrolls the page through once, top to bottom, so lazy-loaded
    /// images (IntersectionObserver / scroll handlers) actually fire
    /// BEFORE the freeze reads currentSrc — an unfired lazy image
    /// would otherwise archive as its placeholder. Time-capped
    /// (~5 s of scrolling, at most 50 steps), then the original
    /// scroll position is restored and given a short settle window
    /// for the fired loads to land. Best-effort: any failure is
    /// ignored by the caller and the freeze proceeds regardless.
    private static let preScrollJS = """
    (async function() {
      var startX = window.scrollX || 0;
      var startY = window.scrollY || 0;
      var budget = 5000, stepDelay = 110, t0 = Date.now();
      var vh = window.innerHeight || 800;
      var total = Math.max(
        document.body ? document.body.scrollHeight : 0,
        document.documentElement ? document.documentElement.scrollHeight : 0);
      var steps = Math.min(50, Math.ceil(total / (vh * 0.9)));
      for (var i = 1; i <= steps; i++) {
        window.scrollTo(startX, i * vh * 0.9);
        await new Promise(function(r) { setTimeout(r, stepDelay); });
        if (Date.now() - t0 > budget) { break; }
      }
      window.scrollTo(startX, startY);
      await new Promise(function(r) { setTimeout(r, 350); });
      return steps;
    })()
    """

    static func primeLazyLoads(in webView: WKWebView) async {
        _ = try? await webView.evaluateJavaScript(preScrollJS)
    }

    // MARK: - Build

    static func build(from webView: WKWebView) async throws -> Result {
        // NOTE: the caller (BrowserTab.snap) primes lazy loads once
        // before ALL captures, so the full-page image and the
        // webarchive benefit too — build() does not scroll again.
        let raw = try await webView.evaluateJavaScript(freezeJS)
        guard let json = raw as? String else { throw BuildError.freezeFailed }
        let resources = parseResources(json)

        // Pull the base64 body in chunks (multiple of 4 keeps quartets whole).
        let lenRaw = try await webView.evaluateJavaScript("window.__snapB64 ? window.__snapB64.length : 0")
        let total = (lenRaw as? NSNumber)?.intValue ?? 0
        guard total > 0 else { throw BuildError.emptyHTML }
        var b64 = ""
        b64.reserveCapacity(total)
        var pos = 0
        let chunk = 100_004
        while pos < total {
            let end = min(pos + chunk, total)
            let piece = try await webView.evaluateJavaScript(
                "window.__snapB64.substring(\(pos), \(end))") as? String ?? ""
            b64 += piece
            pos = end
        }
        guard let htmlData = Data(base64Encoded: b64),
              var html = String(data: htmlData, encoding: .utf8) else {
            throw BuildError.emptyHTML
        }

        let cookies = await allCookies(from: webView)
        let fetcher = ResourceFetcher(cookies: cookies)
        let replacements = await fetcher.fetchAll(resources)
        var inlined = 0
        for resource in resources {
            if let value = replacements[resource.token] {
                html = html.replacingOccurrences(of: resource.token, with: value)
                inlined += 1
            } else {
                // Fallback: live URL for media, nothing for stylesheets.
                let fallback = resource.kind == "css" ? "" : resource.url
                html = html.replacingOccurrences(of: resource.token, with: fallback)
            }
        }
        return Result(data: Data(html.utf8), inlined: inlined, total: resources.count)
    }

    private static func parseResources(_ json: String) -> [Resource] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { entry in
            guard let token = entry["token"] as? String,
                  let url = entry["url"] as? String,
                  let kind = entry["kind"] as? String else { return nil }
            return Resource(token: token, url: url, kind: kind)
        }
    }

    private static func allCookies(from webView: WKWebView) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
    }
}

// MARK: - Resource fetching

/// Fetches tokenised resources in bounded parallel batches (6 at a
/// time, v0.4.13) under a shared byte budget. CSS resources are
/// returned as processed stylesheet text; everything else as a
/// data URI. The references inside a stylesheet (@import sheets,
/// url() images/fonts) are fetched in bounded parallel too — they
/// used to be awaited one by one and dominated the build time on
/// CSS-heavy pages.
private final class ResourceFetcher {
    private let cookies: [HTTPCookie]
    private let session: URLSession
    private var usedBytes = 0

    private static let totalLimit = 40_000_000
    private static let perItemLimit = 5_000_000
    private static let perCSSLimit = 3_000_000

    init(cookies: [HTTPCookie]) {
        self.cookies = cookies
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    func fetchAll(_ resources: [SelfContainedHTML.Resource]) async -> [String: String] {
        var replacements: [String: String] = [:]
        var index = 0
        let batchSize = 6
        while index < resources.count {
            if usedBytes >= Self.totalLimit { break }
            let batch = Array(resources[index..<min(index + batchSize, resources.count)])
            index += batch.count
            let results: [(String, String, Int)] = await withTaskGroup(
                of: (String, String, Int)?.self
            ) { group in
                for resource in batch {
                    group.addTask { [self] in
                        guard let url = URL(string: resource.url) else { return nil }
                        if resource.kind == "css" {
                            if let css = await fetchCSS(url: url, depth: 0) {
                                return (resource.token, css.text, css.bytes)
                            }
                            return nil
                        }
                        guard let (data, mime) = await fetchData(url: url,
                                                                 limit: Self.perItemLimit)
                        else { return nil }
                        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
                        return (resource.token, uri, data.count)
                    }
                }
                var collected: [(String, String, Int)] = []
                for await result in group {
                    if let result { collected.append(result) }
                }
                return collected
            }
            for (token, value, bytes) in results {
                replacements[token] = value
                usedBytes += bytes
            }
        }
        return replacements
    }

    // MARK: Fetch primitives

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let matching = cookies.filter { cookie in
            guard let host = url.host else { return false }
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        if !matching.isEmpty,
           let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func fetchData(url: URL, limit: Int) async -> (Data, String)? {
        do {
            let (data, response) = try await session.data(for: makeRequest(url: url))
            guard !data.isEmpty, data.count <= limit else { return nil }
            let mime = response.mimeType ?? Self.mimeType(forExtension: url.pathExtension)
            return (data, mime)
        } catch {
            return nil
        }
    }

    /// Bounded-parallel map: runs `work` over the items in chunks
    /// of at most 6 concurrent tasks and collects the non-nil
    /// results by key. Used for the references inside a stylesheet
    /// (v0.4.13), which used to be awaited strictly one by one.
    private func fetchInParallel<Key: Hashable, Value>(
        _ items: [(Key, URL)],
        work: @escaping (URL) async -> Value?
    ) async -> [Key: Value] {
        var results: [Key: Value] = [:]
        var index = 0
        let chunkSize = 6
        while index < items.count {
            let chunk = Array(items[index..<min(index + chunkSize, items.count)])
            index += chunk.count
            let chunkResults: [(Key, Value)] = await withTaskGroup(
                of: (Key, Value)?.self
            ) { group in
                for (key, itemURL) in chunk {
                    group.addTask {
                        guard let value = await work(itemURL) else { return nil }
                        return (key, value)
                    }
                }
                var collected: [(Key, Value)] = []
                for await result in group {
                    if let result { collected.append(result) }
                }
                return collected
            }
            for (key, value) in chunkResults { results[key] = value }
        }
        return results
    }

    /// Downloads a stylesheet and resolves its url() / @import references.
    /// Returns the processed CSS plus its approximate byte cost.
    private func fetchCSS(url: URL, depth: Int) async -> (text: String, bytes: Int)? {
        guard let (data, _) = await fetchData(url: url, limit: Self.perCSSLimit),
              var css = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .shiftJIS)
        else { return nil }
        var bytes = data.count

        // @import first (recursive, depth-capped), then url() in
        // the merged text. The nested sheets are fetched in
        // bounded parallel, then inlined in match order.
        let imports = Self.matches(of: Self.importPattern, in: css)
        if depth < 2 {
            var targets: [(String, URL)] = []
            var seenTargets = Set<String>()
            for match in imports {
                guard let ref = match.group,
                      let target = URL(string: ref, relativeTo: url)?.absoluteURL,
                      seenTargets.insert(match.full).inserted
                else { continue }
                targets.append((match.full, target))
            }
            let fetched = await fetchInParallel(targets) { target in
                await self.fetchCSS(url: target, depth: depth + 1)
            }
            for match in imports {
                if let nested = fetched[match.full] {
                    css = css.replacingOccurrences(of: match.full, with: nested.text)
                    bytes += nested.bytes
                } else {
                    css = css.replacingOccurrences(of: match.full, with: "")
                }
            }
        } else {
            for match in imports {
                css = css.replacingOccurrences(of: match.full, with: "")
            }
        }

        // url() references (background images, @font-face fonts):
        // unique refs fetched in bounded parallel, then swapped
        // for data URIs.
        let urlRefs = Self.matches(of: Self.cssURLPattern, in: css)
        var targets: [(String, URL)] = []
        var seenRefs = Set<String>()
        for match in urlRefs {
            guard let ref = match.group, !ref.hasPrefix("data:"),
                  seenRefs.insert(ref).inserted,
                  let target = URL(string: ref, relativeTo: url)?.absoluteURL
            else { continue }
            targets.append((ref, target))
        }
        let fetchedData = await fetchInParallel(targets) { target in
            await self.fetchData(url: target, limit: Self.perItemLimit)
        }
        for match in urlRefs {
            guard let ref = match.group, let got = fetchedData[ref] else { continue }
            let uri = "data:\(got.1);base64,\(got.0.base64EncodedString())"
            css = css.replacingOccurrences(of: match.full, with: "url(\(uri))")
            bytes += got.0.count
        }
        return (css, bytes)
    }

    // MARK: Regex helpers

    private struct Match {
        var full: String
        var group: String?
    }

    private static let importPattern = #"@import\s+(?:url\(\s*)?["']?([^"')\s;]+)["']?\s*\)?\s*;"#
    private static let cssURLPattern = #"url\(\s*["']?([^"')]+)["']?\s*\)"#

    private static func matches(of pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { result in
            let full = Range(result.range, in: text).map { String(text[$0]) } ?? ""
            var group: String?
            if result.numberOfRanges > 1, let r = Range(result.range(at: 1), in: text) {
                group = String(text[r])
            }
            return Match(full: full, group: group)
        }
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }
}
