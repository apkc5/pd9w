import Foundation
import SwiftUI
import WebKit

/// Shields (v0.4.14): ad / tracker blocking — the feature the
/// Android version has had since its v0.3 and iOS lacked entirely.
///
/// Engine: WKContentRuleList. One compiled list carries
///   1. a block-cookies rule and 2. a block rule, both scoped to
///      third-party loads whose resource domain is on the bundled
///      blocklist (if-domain matches the domain and its subdomains),
///   3. one ignore-previous-rules rule per site the user exempted
///      — if-domain there matches the PAGE's domain, so on an
///      exempted site every rule above is skipped for that page.
/// Toggling anything recompiles the list (the identifier embeds a
/// hash of the exemption set) and swaps it into every live tab.
///
/// Counting blocked requests is impossible by design:
/// WKContentRuleList reports no hits back to the app, and this app
/// never fakes a counter — the panel shows state only.
enum ShieldBlocklist {
    /// Bump when the bundled domains or the rule shape change, so
    /// stale compiled lists in the store are never reused.
    static let listVersion = 1

    // Domains: the Android version's bundled curated list (278),
    // plus 14 additions verified present in Disconnect's tracking
    // protection entities list (fetched 2026-11-28 from
    // github.com/disconnectme/disconnect-tracking-protection).
    static let ads: [String] = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "ads.google.com", "googletagservices.com", "amazon-adsystem.com", "ads.yahoo.com",
        "advertising.com", "adsrvr.org", "adnxs.com", "appnexus.com",
        "adsafeprotected.com", "adform.net", "adroll.com", "pubmatic.com",
        "openx.net", "rubiconproject.com", "casalemedia.com", "contextweb.com",
        "criteo.com", "criteo.net", "outbrain.com", "taboola.com",
        "zergnet.com", "mgid.com", "revcontent.com", "media.net",
        "buysellads.com", "carbonads.com", "applovin.com", "unityads.unity3d.com",
        "vungle.com", "chartboost.com", "ironsrc.com", "mopub.com",
        "smaato.net", "inmobi.com", "adcolony.com", "tapjoy.com",
        "smartadserver.com", "spotxchange.com", "teads.tv", "sharethrough.com",
        "gumgum.com", "triplelift.com", "indexww.com", "sovrn.com",
        "lijit.com", "districtm.ca", "yieldmo.com", "kargo.com",
        "nativo.com", "plista.com", "ligatus.com", "adzerk.net",
        "springserve.com", "tremorhub.com", "adsymptotic.com", "onclickads.net",
        "popads.net", "popcash.net", "propellerads.com", "adcash.com",
        "hilltopads.net", "exoclick.com", "juicyads.com", "trafficjunky.com",
        "adsterra.com", "clickadu.com", "a-ads.com", "coinzilla.com",
        "adskeeper.com", "evadav.com", "ad-maven.com", "galaksion.com",
        "monetag.com", "rollerads.com", "kadam.net", "bidvertiser.com",
        "infolinks.com", "servebom.com", "adbutler.com", "richpush.co",
        "push.house", "vimmy.com", "mybid.io", "bitmedia.io",
        "cointraffic.io", "onclickmax.com", "ads.stroeer.com", "seedtag.com",
        "playwire.com", "snack-media.com", "mediavine.com", "adthrive.com",
        "raptive.com", "shemedia.com", "freestar.com", "playbuzz.com",
        "adsbynimbus.com", "bidmatic.io", "adtelligent.com", "between.digital",
        "buzoola.com", "hybrid.ai", "otm-r.com", "relap.io",
        "yandexadexchange.net", "an.yandex.ru", "adsdk.yandex.ru", "marketgid.com",
        "trafficstars.com", "twinred.com", "exosrv.com", "exdynsrv.com",
        "syndication.exdynsrv.com", "a.magsrv.com", "magsrv.com", "tsyndicate.com",
        "adspyglass.com", "hilltopads.com", "clickaine.com", "adoperator.com",
        "adsblox.com", "popin.cc", "adxxx.com", "33across.com",
        "flashtalking.com", "serving-sys.com", "i-mobile.co.jp", "geniee.co.jp",
        "microad.co.jp", "fluct.jp",
    ]

    static let analytics: [String] = [
        "google-analytics.com", "analytics.google.com", "googletagmanager.com", "hotjar.com",
        "hotjar.io", "static.hotjar.com", "fullstory.com", "mouseflow.com",
        "clarity.ms", "mixpanel.com", "api.mixpanel.com", "segment.com",
        "segment.io", "api.segment.io", "cdn.segment.com", "amplitude.com",
        "api.amplitude.com", "api2.amplitude.com", "heap.io", "heapanalytics.com",
        "kissmetrics.com", "woopra.com", "statcounter.com", "c.statcounter.com",
        "scorecardresearch.com", "sb.scorecardresearch.com", "comscore.com", "quantserve.com",
        "quantcast.com", "chartbeat.com", "ping.chartbeat.net", "parsely.com",
        "api.parsely.com", "bam.nr-data.net", "js-agent.newrelic.com", "piwik.pro",
        "mc.yandex.ru", "mc.yandex.com", "bat.bing.com", "claritycdn.com",
        "crazyegg.com", "script.crazyegg.com", "luckyorange.com", "cdn.luckyorange.com",
        "smartlook.com", "rec.smartlook.com", "vwo.com", "dev.visualwebsiteoptimizer.com",
        "optimizely.com", "cdn.optimizely.com", "abtasty.com", "try.abtasty.com",
        "dynatrace.com", "fls-na.amazon.com", "device-metrics-us.amazon.com", "device-metrics-us-2.amazon.com",
        "unagi-na.amazon.com", "smetrics.aol.com", "analytics.aol.com", "logx.optimizely.com",
        "rum-http-intake.logs.datadoghq.com", "browser-intake-datadoghq.com", "sessions.bugsnag.com", "notify.bugsnag.com",
        "events.hotjar.io", "careers.hotjar.com", "api.hotjar.com", "surveystats.hotjar.com",
        "api.fullstory.com", "edge.fullstory.com", "rs.fullstory.com", "m.heapanalytics.com",
        "cdn.heapanalytics.com", "trk.kissmetrics.io", "api.woopra.com", "www.woopra.com",
        "counter.yadro.ru", "top-fwz1.mail.ru", "ad.mail.ru", "r.mradx.net",
        "top100.rambler.ru", "counter.rambler.ru", "s.rambler.ru", "metrika.yandex.ru",
        "webvisor.com", "api.mouseflow.com", "cdn.mouseflow.com", "tools.mouseflow.com",
        "o2.mouseflow.com", "api.segment.com", "tracking.segment.com", "o427607.ingest.sentry.io",
        "ingest.sentry.io", "plausible.io", "clicky.com", "static.getclicky.com",
        "in.getclicky.com", "pi.pardot.com", "go.pardot.com", "analytics.twitter.com",
        "ad.doubleclick.net", "ssl.google-analytics.com", "www.google-analytics.com", "stats.g.doubleclick.net",
        "cm.g.doubleclick.net", "bid.g.doubleclick.net", "securepubads.g.doubleclick.net", "pagead2.googlesyndication.com",
        "tpc.googlesyndication.com", "partner.googleadservices.com", "moatads.com", "demdex.net",
        "bluekai.com", "contentsquare.net", "krxd.net",
    ]

    static let social: [String] = [
        "connect.facebook.net", "ads.facebook.com", "an.facebook.com", "pixel.facebook.com",
        "platform.twitter.com", "ads-twitter.com", "ads-api.twitter.com", "syndication.twitter.com",
        "snap.licdn.com", "px.ads.linkedin.com", "ads.linkedin.com", "analytics.pinterest.com",
        "widgets.pinterest.com", "trk.pinterest.com", "tr.snapchat.com", "tr6.snapchat.com",
        "events.reddit.com", "alb.reddit.com", "pixel.reddit.com", "w3-reporting.reddit.com",
        "analytics.tiktok.com", "ads.tiktok.com", "business-api.tiktok.com", "log.byteoversea.com",
        "mon-va.byteoversea.com", "mssdk.bytedance.com", "mssdk.tiktokw.eu", "mon.tiktokv.com",
        "ads.vk.com", "stats.vk.com", "r.vk.com", "px.vk.com",
        "top.vk.com", "ads.line.me", "gw-ads.line.me", "ad.line-scdn.net",
        "analytics.line.me", "trk.teads.tv", "beacons.clicmanager.fr", "ws.clicmanager.fr",
        "s.clicmanager.fr", "addthis.com", "sharethis.com",
    ]

    static var domains: [String] { ads + analytics + social }
}

/// Owns the compiled rule list and its distribution to tabs.
/// BrowserModel holds the single instance; compilation is async,
/// so tabs created before the first compile finishes are covered
/// when refresh() applies the result to every tab it was given,
/// and tabs created afterwards pick the list up via apply(to:).
@MainActor
final class ShieldsController: ObservableObject {
    /// Last compile failure, shown in the Shields panel instead of
    /// failing silently. Nil while the current list compiled fine.
    @Published private(set) var compileError: String?

    private(set) var currentList: WKContentRuleList?
    private(set) var currentIdentifier: String?
    private var generation = 0

    /// The store caches compiled lists by identifier on disk, so
    /// the identifier must change exactly when the content does:
    /// list version + a deterministic (FNV-1a) hash of the sorted
    /// exemption set. (String.hashValue is per-process randomised
    /// and must not be used for this.)
    static func identifier(for settings: AppSettings) -> String {
        let key = settings.shieldsDisabledSites.sorted().joined(separator: ",")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "shields.v\(ShieldBlocklist.listVersion).\(String(hash, radix: 16))"
    }

    static func ruleListJSON(disabledSites: Set<String>) -> String {
        let ifDomains = ShieldBlocklist.domains.map { "*" + $0 }
        let trigger: [String: Any] = [
            "url-filter": ".*",
            "load-type": ["third-party"],
            "if-domain": ifDomains,
        ]
        var rules: [[String: Any]] = [
            ["trigger": trigger, "action": ["type": "block-cookies"]],
            ["trigger": trigger, "action": ["type": "block"]],
        ]
        for site in disabledSites.sorted() {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": ["*" + site]],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(data: data, encoding: .utf8)!
    }

    /// Recompiles (when the configuration changed) and swaps the
    /// list into every given tab. With the master switch off the
    /// list is simply detached everywhere. onApplied runs on the
    /// main actor once the tabs reflect the new configuration.
    func refresh(settings: AppSettings, tabs: [BrowserTab], onApplied: (() -> Void)? = nil) {
        generation += 1
        let gen = generation
        guard settings.shieldsEnabled else {
            currentList = nil
            currentIdentifier = nil
            for tab in tabs { tab.applyShields(list: nil, identifier: nil) }
            onApplied?()
            return
        }
        let identifier = Self.identifier(for: settings)
        if identifier == currentIdentifier, let currentList {
            for tab in tabs { tab.applyShields(list: currentList, identifier: identifier) }
            onApplied?()
            return
        }
        let json = Self.ruleListJSON(disabledSites: settings.shieldsDisabledSites)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: json
        ) { [weak self] list, error in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if let list {
                    self.compileError = nil
                    self.currentList = list
                    self.currentIdentifier = identifier
                    for tab in tabs { tab.applyShields(list: list, identifier: identifier) }
                } else {
                    self.compileError = error?.localizedDescription ?? "不明なエラー"
                }
                onApplied?()
            }
        }
    }

    /// Gives a freshly created tab the current list, if one is
    /// already compiled. Tabs created earlier are covered by the
    /// refresh() that completes the compile.
    func apply(to tab: BrowserTab, settings: AppSettings) {
        guard settings.shieldsEnabled,
              let list = currentList, let identifier = currentIdentifier else { return }
        tab.applyShields(list: list, identifier: identifier)
    }
}

/// Per-site Shields panel (v0.4.14), opened from the ⋯ menu.
/// Shows state only — global on/off, this site's on/off, and the
/// bundled domain count. There is deliberately no blocked-request
/// counter: WKContentRuleList gives the app no hit callbacks.
struct ShieldsPanelView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject var manager: BrowserModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var shields: ShieldsController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let host = tab.currentHost {
                    Section {
                        Toggle("このサイトでブロック", isOn: siteBinding(host: host))
                            .disabled(!settings.shieldsEnabled)
                    } header: {
                        Text(host)
                    } footer: {
                        Text(settings.shieldsEnabled
                             ? "オフにすると、このサイトでは広告・トラッカーのブロックと対象ドメインの Cookie 遮断が止まります。切り替えは再読み込みで反映されます。"
                             : "Shields 全体がオフのため、このサイトでもブロックしていません。")
                    }
                } else {
                    Section {
                        Text("サイトを開いていないため、サイト別の設定はありません。")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("広告・トラッカーをブロック（全体）", isOn: $settings.shieldsEnabled)
                    LabeledContent("ブロック対象", value: "\(ShieldBlocklist.domains.count) ドメイン")
                } header: {
                    Text("Shields")
                } footer: {
                    Text("広告・トラッキングのドメインへのサードパーティ読み込みと、そのドメインの Cookie をブロックします。ブロック件数は WebKit の仕様上アプリ側で数えられないため、表示していません。")
                }

                if let error = shields.compileError {
                    Section {
                        Text("ルールの読み込みに失敗しました：\(error)")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Shields")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onChange(of: settings.shieldsEnabled) { _ in
                manager.refreshShields(reloadActiveTab: true)
            }
        }
    }

    private func siteBinding(host: String) -> Binding<Bool> {
        Binding(
            get: { !settings.shieldsDisabledSites.contains(AppSettings.shieldsSiteKey(host: host)) },
            set: { newValue in
                settings.setShieldsActive(newValue, forHost: host)
                manager.refreshShields(reloadActiveTab: true)
            })
    }
}
