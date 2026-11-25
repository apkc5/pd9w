import SwiftUI
import WebKit

/// 3-mode viewer: 画像 / アーカイブ / テキスト.
/// In archive mode, links are tappable and navigate live inside the viewer
/// (same behaviour the user asked for on Android v0.3.1): the first page is
/// the saved .webarchive; following a link loads the real page.
struct SnapshotViewerView: View {
    let store: SnapshotStore
    let item: SnapshotItem
    var onOpenURL: (String) -> Void

    @State private var mode: Mode = .image

    enum Mode: String, CaseIterable, Identifiable {
        case image = "画像"
        case archive = "アーカイブ"
        case text = "テキスト"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("表示", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .image: imagePane
            case .archive: ArchiveWebView(fileURL: store.fileURL(for: item, name: "archive.webarchive"))
            case .text: textPane
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("元ページを開く") { onOpenURL(item.url) }
            }
        }
    }

    // MARK: - Panes

    @ViewBuilder
    private var imagePane: some View {
        let url = store.fileURL(for: item, name: "image.png")
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            ScrollView([.vertical, .horizontal]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            }
        } else {
            ContentUnavailableView("画像がありません", systemImage: "photo.slash")
        }
    }

    @ViewBuilder
    private var textPane: some View {
        let url = store.fileURL(for: item, name: "text.txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            ScrollView {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            ContentUnavailableView("テキストがありません", systemImage: "doc.text.slash")
        }
    }
}

/// WKWebView that loads a .webarchive file. Navigation inside it is left
/// enabled on purpose (tappable links, live navigation) — no delegate
/// interception is installed.
private struct ArchiveWebView: UIViewRepresentable {
    let fileURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.allowsBackForwardNavigationGestures = true
        if FileManager.default.fileExists(atPath: fileURL.path) {
            webView.loadFileURL(fileURL,
                                allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
