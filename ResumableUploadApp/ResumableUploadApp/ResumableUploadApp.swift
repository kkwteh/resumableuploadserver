import SwiftUI

@main
struct ResumableUploadApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UploadStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
    }
}
