import SwiftUI
import WebKit

/// Reader mode (v0.4): the article body is extracted from the live page
/// with a heuristic JS pass (see BrowserTab.extractReaderContent) and
/// re-rendered in a clean, styled page — system font, generous line
/// height, images kept, scripts/handlers stripped during extraction.
/// Heuristic by nature: some pages yield little or nothing, and the view
/// says so honestly instead of showing a broken page.
struct ReaderView: View {
    let tab: BrowserTab
    @Environment(\.dismiss) private var dismiss
    @StateObject private var holder = ReaderWebHolder()
    @State private var pageTitle = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if failed {
                    ContentUnavailableView("読み取れませんでした",
                                           systemImage: "doc.plaintext",
                                           description: Text("このページではリーダーモードを使えませんでした。"))
                } else {
                    WebView(webView: holder.webView)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .background(Theme.paper)
            .navigationTitle(pageTitle.isEmpty ? "リーダーモード" : pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .task {
            guard let extracted = await tab.extractReaderContent(),
                  !extracted.bodyHTML.isEmpty else {
                failed = true
                return
            }
            pageTitle = extracted.title
            holder.webView.loadHTMLString(
                Self.pageHTML(title: extracted.title, body: extracted.bodyHTML),
                baseURL: tab.webView.url)
        }
    }

    /// Clean reading page: paper background, ink text, cobalt links,
    /// images capped at column width. Title is HTML-escaped; the body
    /// comes from the extractor, which strips scripts and attributes.
    static func pageHTML(title: String, body: String) -> String {
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { font-family: -apple-system, sans-serif; margin: 0;
                 padding: 20px 18px 48px; line-height: 1.85;
                 color: #1A1C20; background: #F7F5F0;
                 word-wrap: break-word; }
          @media (prefers-color-scheme: dark) {
            body { color: #E8EAF0; background: #121417; }
            a { color: #8FA2FF; }
          }
          h1 { font-size: 1.45em; line-height: 1.4; margin: 0 0 0.8em; }
          a { color: #2F4BFF; }
          img { max-width: 100%; height: auto; }
          pre, code { white-space: pre-wrap; }
          table { display: block; overflow-x: auto; }
        </style></head>
        <body><h1>\(escapedTitle)</h1>\(body)</body></html>
        """
    }
}

private final class ReaderWebHolder: ObservableObject {
    let webView = WKWebView()
}
