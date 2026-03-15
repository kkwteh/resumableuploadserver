import SwiftUI
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        print("[AppDelegate] System woke us for background session: \(identifier)")
        UploadManager.backgroundSessionCompletionHandler = completionHandler
    }
}

@main
struct ResumableUploadAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var uploadManager = UploadManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadManager)
                .onAppear {
                    uploadManager.reconnectBackgroundSession()
                }
        }
    }
}
