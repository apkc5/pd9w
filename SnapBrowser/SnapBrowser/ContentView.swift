import SwiftUI

struct ContentView: View {
    @StateObject private var browser = BrowserModel()
    @StateObject private var store = SnapshotStore()
    @State private var showingLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            if browser.isLoading {
                ProgressView(value: browser.estimatedProgress)
                    .progressViewStyle(.linear)
            }
            WebView(webView: browser.webView)
                .ignoresSafeArea(edges: .bottom)
            toolbar
        }
        .sheet(isPresented: $showingLibrary) {
            NavigationStack {
                SnapshotLibraryView(store: store) { url in
                    if let url = URL(string: url) {
                        browser.load(url)
                    }
                    showingLibrary = false
                }
            }
        }
        .alert("スナップ結果", isPresented: snapAlertBinding) {
            Button("OK", role: .cancel) { browser.lastSnapResult = nil }
        } message: {
            if let result = browser.lastSnapResult {
                Text(snapMessage(result))
            }
        }
    }

    // MARK: - Pieces

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("URLまたは検索", text: $browser.addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { browser.loadAddressBar() }
            if browser.isLoading {
                Button {
                    browser.webView.stopLoading()
                } label: {
                    Image(systemName: "xmark")
                }
            } else {
                Button {
                    browser.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var toolbar: some View {
        HStack {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!browser.canGoBack)

            Spacer()

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!browser.canGoForward)

            Spacer()

            // SNAP — the headline action. Shutter-red accent, as on Android.
            Button {
                browser.snap(store: store)
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "camera.aperture")
                        .font(.title3)
                    Text("SNAP")
                        .font(.caption2.bold())
                }
                .foregroundStyle(Color(red: 1.0, green: 0.30, blue: 0.18))
            }
            .disabled(browser.isSnapping)

            Spacer()

            Button { showingLibrary = true } label: {
                Image(systemName: "books.vertical")
            }

            Spacer()

            Button { browser.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Snap result

    private var snapAlertBinding: Binding<Bool> {
        Binding(
            get: { browser.lastSnapResult != nil },
            set: { if !$0 { browser.lastSnapResult = nil } }
        )
    }

    private func snapMessage(_ result: BrowserModel.SnapResult) -> String {
        func fmt(_ bytes: Int?) -> String {
            guard let bytes else { return "失敗" }
            return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
        var lines = [
            "画像: \(fmt(result.imageBytes))",
            "アーカイブ(.webarchive): \(fmt(result.archiveBytes))",
            "HTML: \(fmt(result.htmlBytes))",
            "テキスト: \(result.textChars.map { "\($0)文字" } ?? "失敗")"
        ]
        if !result.failures.isEmpty {
            lines.append("—")
            lines.append(contentsOf: result.failures)
        }
        return lines.joined(separator: "\n")
    }
}
