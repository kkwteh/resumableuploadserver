import SwiftUI

@main
struct ResumableUploadAppApp: App {
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
