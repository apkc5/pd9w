import SwiftUI

/// Settings screen (v0.4): search engine, display defaults, browsing-data
/// clearing, and app info. Bookmarks and snapshots are NOT browsing data
/// and are never touched here.
struct SettingsView: View {
    @ObservedObject var manager: BrowserModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var confirmClear: ClearKind?
    @State private var clearedNotice = false

    private enum ClearKind: String, Identifiable {
        case history, websiteData, all
        var id: String { rawValue }
        var message: String {
            switch self {
            case .history: return "閲覧履歴をすべて削除します。"
            case .websiteData: return "Cookieとサイトデータ（ログイン状態など）をすべて削除します。"
            case .all: return "履歴・Cookie・サイトデータをすべて削除します。"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("既定の検索エンジン", selection: $settings.searchEngine) {
                        ForEach(SearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    Toggle("検索候補を表示", isOn: $settings.searchSuggestionsEnabled)
                    Button("候補から隠した項目をリセット") {
                        settings.resetHiddenSuggestions()
                    }
                    .disabled(settings.hiddenSuggestionURLs.isEmpty)
                } header: {
                    Text("検索")
                } footer: {
                    Text("検索候補を有効にすると、アドレスバーに入力中の文字が選択中の検索エンジンに送信され、候補が表示されます。「お使いのデバイス」の候補で×を押した項目は、履歴・ブックマークからは消えず、候補に出なくなるだけです。上のリセットで元に戻せます。")
                }

                Section("表示") {
                    Toggle("PC版サイトを既定にする", isOn: $settings.desktopByDefault)
                    Picker("テキストサイズ", selection: $settings.textSizePercent) {
                        Text("80%").tag(80)
                        Text("100%").tag(100)
                        Text("120%").tag(120)
                        Text("150%").tag(150)
                    }
                }

                Section {
                    Picker("ホーム画面のペット", selection: $settings.homePet) {
                        ForEach(HomePet.allCases) { pet in
                            Text(pet.title).tag(pet)
                        }
                    }
                } header: {
                    Text("ホーム画面")
                } footer: {
                    Text("スタートページの下端を歩く小さな装飾です。素材クレジット — 猫: cez02（OpenGameArt、CC-BY 4.0）／犬: kirard（OpenGameArt、CC0）／あひる: Drummyfish（Wikimedia Commons、CC0）／ペンギン: segel（OpenGameArt、CC0）。")
                }

                Section {
                    Button("履歴を削除") { confirmClear = .history }
                    Button("Cookieとサイトデータを削除") { confirmClear = .websiteData }
                    Button("すべての閲覧データを削除", role: .destructive) { confirmClear = .all }
                } header: {
                    Text("データ")
                } footer: {
                    Text("ブックマーク・スナップ（ライブラリ）・Playlistのダウンロードは削除されません。")
                }

                Section("情報") {
                    LabeledContent("バージョン", value: versionText)
                    LabeledContent("バンドルID", value: "jp.anko.snapbrowser")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onChange(of: settings.textSizePercent) { _ in
                manager.applyTextSizeToAllTabs()
            }
            .confirmationDialog("削除しますか？",
                                isPresented: confirmBinding,
                                titleVisibility: .visible) {
                Button("削除", role: .destructive) { performClear() }
                Button("キャンセル", role: .cancel) { confirmClear = nil }
            } message: {
                Text(confirmClear?.message ?? "")
            }
            .alert("削除しました", isPresented: $clearedNotice) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { confirmClear != nil },
                set: { if !$0 { confirmClear = nil } })
    }

    private func performClear() {
        guard let kind = confirmClear else { return }
        confirmClear = nil
        switch kind {
        case .history:
            manager.history.clearAll()
            clearedNotice = true
        case .websiteData:
            Task {
                await manager.clearWebsiteData()
                clearedNotice = true
            }
        case .all:
            manager.history.clearAll()
            Task {
                await manager.clearWebsiteData()
                clearedNotice = true
            }
        }
    }
}
