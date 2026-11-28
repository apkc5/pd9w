import SwiftUI

@main
struct SnapBrowserApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        // Tear-off / split-view windows (v0.4.13): a value-carrying
        // group opened through SwiftUI's openWindow action, with
        // the moved tab's payload (URL / archive folder / privacy)
        // as the value. This replaces the pre-v0.4.13 route —
        // UIApplication.requestSceneSessionActivation with an
        // NSUserActivity whose type was never declared in the
        // app's Info.plist NSUserActivityTypes (the key is absent
        // from the shipped v0.4.12 IPA, verified): the system
        // rejected every activation request, the API's error
        // handler swallowed the error, and on device the split /
        // tear-off buttons did literally nothing (BUILD_LOG
        // 第22次）. openWindow needs no plist declaration, and
        // TabWindows verifies each request actually produced a
        // scene session, so a failure can no longer pass silently.
        WindowGroup(id: TabWindows.windowGroupID, for: TabWindowPayload.self) { payload in
            ContentView(windowPayload: payload.wrappedValue)
        }
    }
}
