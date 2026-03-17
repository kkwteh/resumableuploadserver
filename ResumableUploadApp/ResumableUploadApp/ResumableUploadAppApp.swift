import SwiftUI
import UIKit
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        print("[AppDelegate] System woke us for background session: \(identifier)")
        UploadManager.backgroundSessionCompletionHandler = completionHandler
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        print("[AppDelegate] App launched, options: \(launchOptions ?? [:])")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            print("[AppDelegate] Notification permission: \(granted), error: \(error?.localizedDescription ?? "none")")
        }
        return true
    }
}

@main
struct ResumableUploadAppApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var uploadManager = UploadManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(uploadManager)
                .onAppear {
                    uploadManager.reconnectBackgroundSession()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                print("[Lifecycle] App became active (foreground)")
            case .inactive:
                print("[Lifecycle] App became inactive")
            case .background:
                print("[Lifecycle] App entered background")
            @unknown default:
                print("[Lifecycle] Unknown scene phase: \(newPhase)")
            }
        }
    }
}
