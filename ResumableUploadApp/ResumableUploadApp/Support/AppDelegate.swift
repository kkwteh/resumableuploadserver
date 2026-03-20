import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == UploadStore.backgroundSessionIdentifier else {
            completionHandler()
            return
        }

        UploadStore.shared.captureBackgroundSessionCompletionHandler(completionHandler)
    }
}
