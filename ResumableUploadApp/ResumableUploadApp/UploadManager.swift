import Foundation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

enum UploadState: String {
    case idle
    case preparing
    case creatingUpload
    case uploading
    case paused
    case resuming
    case completed
    case failed
    case cancelled

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Preparing..."
        case .creatingUpload: return "Creating upload session..."
        case .uploading: return "Uploading"
        case .paused: return "Paused"
        case .resuming: return "Resuming..."
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Manages resumable file uploads using URLSession's native resumable upload support.
///
/// Upload flow:
/// 1. Start a single background upload task from the exported video file
/// 2. Pause with cancelByProducingResumeData
/// 3. Resume with uploadTask(withResumeData:)
/// 4. On interruption, retry automatically from URLError.uploadTaskResumeData when available
@MainActor
class UploadManager: NSObject, ObservableObject {
    // MARK: - Published State

    @Published var state: UploadState = .idle
    @Published var progress: Double = 0
    @Published var bytesUploaded: Int64 = 0
    @Published var totalBytes: Int64? = nil
    @Published var currentOffset: Int64 = 0
    @Published var speedDisplay: String = "—"
    @Published var connectionInfo: String = "Idle"
    @Published var errorMessage: String? = nil
    @Published var selectedFileName: String? = nil
    @Published var preparationProgress: Double = 0

    // MARK: - Computed

    var canPause: Bool { state == .uploading }
    var canResume: Bool { state == .paused || state == .failed }
    var canCancel: Bool { state == .uploading || state == .paused || state == .resuming }

    // MARK: - Internal State

    private var fileURL: URL?
    /// PHAsset.localIdentifier for re-exporting from Photos library on failure/relaunch
    private var assetIdentifier: String?
    private var serverURL: String = ""
    private var authToken: String?
    private var isPaused = false
    private var isCancelled = false
    private var speedTimer: Timer?
    private var lastSpeedCheckTime: Date?
    private var lastSpeedCheckBytes: Int64 = 0
    private var uploadStartTime: Date?

    /// Tracks the current background upload task so we can cancel it on pause
    private var currentBackgroundTask: URLSessionUploadTask?
    /// Native resume blob produced by URLSession when the upload is paused or interrupted
    private var resumeData: Data?
    /// Resume URL advertised by the server in the 104 informational response
    private var resumeURL: URL?
    /// Estimated uploaded bytes before the current task started sending body data
    private var progressBaseBytes: Int64 = 0

    private static let stateKey = "ResumableUploadState"
    private static let backgroundSessionID = "com.resumableupload.background"

    /// System completion handler provided by AppDelegate when the app is woken for background events
    static var backgroundSessionCompletionHandler: (() -> Void)?

    // MARK: - Sessions

    /// Foreground session for lightweight protocol requests (POST, HEAD, DELETE)
    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// Background session for PATCH uploads — transfers continue even when app is suspended/killed
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.isDiscretionary = false
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    // MARK: - File Management

    /// Remove the exported file from Documents/pending_uploads/ if it exists there.
    private func cleanupExportedFile() {
        guard let url = fileURL else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let uploadsDir = docs.appendingPathComponent("pending_uploads")
        if url.path.hasPrefix(uploadsDir.path) {
            try? FileManager.default.removeItem(at: url)
            print("[UploadManager] Cleaned up exported file: \(url.lastPathComponent)")
        }
    }

    /// Remove all files in Documents/pending_uploads/ (for stale cleanup on fresh start).
    private func cleanupAllPendingUploads() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let uploadsDir = docs.appendingPathComponent("pending_uploads")
        if let files = try? FileManager.default.contentsOfDirectory(at: uploadsDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
                print("[UploadManager] Cleaned up stale file: \(file.lastPathComponent)")
            }
        }
    }

    // MARK: - File Loading

    /// Load a video from the PhotosPicker and immediately begin uploading.
    /// Uses PHAssetResourceManager to export the video with progress tracking,
    /// instead of loadTransferable which provides no progress for large files.
    func loadVideoAndUpload(from item: PhotosPickerItem, serverURL: String, authToken: String? = nil) async {
        self.authToken = authToken
        state = .preparing
        preparationProgress = 0
        connectionInfo = "Loading video..."

        // Request Photos library access so we can use PHAsset APIs for progress tracking.
        // PhotosPicker alone doesn't grant PHAsset-level access.
        let authStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else {
            state = .idle
            errorMessage = "Photos library access is required to upload videos"
            connectionInfo = "Idle"
            print("[UploadManager] Photos authorization denied: \(authStatus.rawValue)")
            return
        }

        // Persist the asset identifier for re-export on failure/relaunch
        assetIdentifier = item.itemIdentifier
        print("[UploadManager] Starting export for item: \(item.itemIdentifier ?? "unknown")")

        guard let identifier = item.itemIdentifier else {
            state = .idle
            errorMessage = "No asset identifier — please grant full Photos access in Settings"
            connectionInfo = "Idle"
            return
        }

        let results = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = results.firstObject else {
            state = .idle
            errorMessage = "Could not find video in Photos library"
            connectionInfo = "Idle"
            print("[UploadManager] PHAsset not found for identifier: \(identifier)")
            return
        }

        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video })
                ?? PHAssetResource.assetResources(for: asset).first else {
            state = .idle
            errorMessage = "No video resource found"
            connectionInfo = "Idle"
            print("[UploadManager] No video resource for asset")
            return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let uploadsDir = docs.appendingPathComponent("pending_uploads")
        try? FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
        let destination = uploadsDir.appendingPathComponent(UUID().uuidString + "_" + resource.originalFilename)
        try? FileManager.default.removeItem(at: destination)

        print("[UploadManager] Exporting asset to: \(destination.lastPathComponent)")

        let exportedURL: URL? = await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            options.progressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.preparationProgress = progress
                    self?.connectionInfo = "Loading video... \(Int(progress * 100))%"
                }
            }
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    print("[UploadManager] Asset export failed: \(error)")
                    continuation.resume(returning: nil)
                } else {
                    print("[UploadManager] Asset export succeeded: \(destination.lastPathComponent)")
                    continuation.resume(returning: destination)
                }
            }
        }

        guard let exportedURL else {
            state = .idle
            errorMessage = "Failed to export video from Photos"
            connectionInfo = "Idle"
            return
        }

        do {
            fileURL = exportedURL
            let attrs = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
            let fileSize = attrs[.size] as? Int64 ?? 0
            totalBytes = fileSize
            selectedFileName = resource.originalFilename
            errorMessage = nil
            preparationProgress = 1.0
            print("[UploadManager] File exported: \(resource.originalFilename), size: \(fileSize)")

            // Auto-start the upload
            startUpload(serverURL: serverURL)
        } catch {
            state = .idle
            errorMessage = "Failed to read exported file: \(error.localizedDescription)"
            connectionInfo = "Idle"
            print("[UploadManager] File read error: \(error)")
        }
    }

    // MARK: - Upload Control

    private func startUpload(serverURL: String) {
        guard fileURL != nil else { return }

        currentBackgroundTask?.cancel()
        currentBackgroundTask = nil
        resumeData = nil
        resumeURL = nil
        progressBaseBytes = 0
        stopSpeedTracking()

        self.serverURL = serverURL.trimmingCharacters(in: .whitespaces)
        self.bytesUploaded = 0
        self.currentOffset = 0
        self.progress = 0
        self.errorMessage = nil
        self.isPaused = false
        self.isCancelled = false
        self.connectionInfo = "Connecting..."

        state = .creatingUpload
        uploadStartTime = Date()
        startSpeedTracking()

        enqueueInitialUpload()
    }

    func pause() {
        guard state == .uploading else { return }
        guard let task = currentBackgroundTask else { return }

        isPaused = true
        state = .paused
        connectionInfo = "Pausing..."
        stopSpeedTracking()
        currentBackgroundTask = nil
        progressBaseBytes = bytesUploaded

        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resumeData = data
                self.currentOffset = self.bytesUploaded
                self.persistState()

                if data == nil {
                    self.state = .failed
                    self.errorMessage = "Pause failed because the server did not return resume data"
                    self.connectionInfo = "Pause failed"
                    print("[UploadManager] Pause failed: no resume data")
                    return
                }

                self.connectionInfo = "Paused at offset \(self.currentOffset)"
                print("[UploadManager] Paused at offset \(self.currentOffset)")
            }
        })
    }

    func resume() {
        guard state == .paused || state == .failed else { return }

        isPaused = false
        isCancelled = false
        state = .resuming
        connectionInfo = "Resuming..."
        startSpeedTracking()

        Task {
            await resumeUpload()
        }
    }

    func cancel() {
        guard state == .uploading || state == .paused || state == .resuming else { return }
        isCancelled = true
        isPaused = false

        currentBackgroundTask?.cancel()
        currentBackgroundTask = nil
        resumeData = nil
        deleteServerUploadIfPossible()

        state = .cancelled
        connectionInfo = "Cancelled"
        stopSpeedTracking()
        clearPersistedState()
        cleanupExportedFile()
        assetIdentifier = nil
        resumeURL = nil
        progressBaseBytes = 0
        print("[UploadManager] Cancelled")
    }

    // MARK: - Background Session Reconnection

    func reconnectBackgroundSession() {
        // Touch the background session so it reconnects with the system daemon
        _ = backgroundSession

        backgroundSession.getAllTasks { tasks in
            print("[Debug] Background tasks on reconnect: \(tasks.count)")
            for t in tasks {
                print("[Debug] Task: \(t.taskIdentifier) state=\(t.state.rawValue) request=\(t.originalRequest?.httpMethod ?? "?") \(t.originalRequest?.url?.path ?? "?")")
            }
        }

        if let saved = loadPersistedState() {
            serverURL = saved.serverURL
            totalBytes = saved.totalBytes
            currentOffset = saved.currentOffset
            bytesUploaded = saved.currentOffset
            assetIdentifier = saved.assetIdentifier
            authToken = saved.authToken
            resumeData = saved.resumeData
            progressBaseBytes = saved.currentOffset
            if let resumeURLString = saved.resumeURL,
               let parsedResumeURL = URL(string: resumeURLString) {
                resumeURL = parsedResumeURL
            }

            let fileExists = saved.filePath.map { FileManager.default.fileExists(atPath: $0) } ?? false

            if fileExists, let path = saved.filePath {
                fileURL = URL(fileURLWithPath: path)
                selectedFileName = URL(fileURLWithPath: path).lastPathComponent
            } else if saved.assetIdentifier != nil {
                // Temp file is gone (app relaunched), but we have the asset identifier.
                // We'll re-export from Photos when the upload needs to retry.
                print("[UploadManager] Temp file gone, will re-export from Photos on retry")
            } else {
                // No file and no asset identifier — can't recover
                print("[UploadManager] No file and no asset identifier, clearing state")
                clearPersistedState()
                return
            }

            updateProgress(uploadedBytes: saved.currentOffset)

            // Check if there are pending background tasks
            backgroundSession.getAllTasks { [weak self] tasks in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let activeTasks = tasks.compactMap { $0 as? URLSessionUploadTask }
                        .filter { $0.state == .running || $0.state == .suspended }
                    if activeTasks.isEmpty {
                        self.currentBackgroundTask = nil
                        if self.resumeData != nil {
                            self.state = .paused
                            self.connectionInfo = "Restored paused upload"
                            print("[UploadManager] Restored paused upload at offset=\(self.currentOffset)")
                        } else {
                            self.state = .failed
                            self.connectionInfo = "Upload interrupted, restart required"
                            self.errorMessage = "No active background task or native resume data was available"
                            print("[UploadManager] Restored state without an active task or resume data")
                        }
                    } else {
                        let activeTask = activeTasks[0]
                        self.currentBackgroundTask = activeTask
                        self.progressBaseBytes = self.parseTaskBaseOffset(from: activeTask.taskDescription) ?? saved.currentOffset
                        self.state = .uploading
                        self.connectionInfo = "Background upload in progress..."
                        self.startSpeedTracking()
                        print("[UploadManager] Restored state, \(activeTasks.count) active background task(s)")
                    }
                }
            }
        } else {
            // No persisted state — clean up any stale files from a previous session
            cleanupAllPendingUploads()
        }
    }

    /// Re-export the video from the Photos library using the persisted PHAsset.localIdentifier.
    /// Used when the exported file is gone (e.g. app relaunched) but the upload needs to restart.
    private func exportAssetToFile() async -> URL? {
        guard let identifier = assetIdentifier else {
            print("[UploadManager] No asset identifier for re-export")
            return nil
        }

        let results = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = results.firstObject else {
            print("[UploadManager] PHAsset not found for identifier: \(identifier)")
            return nil
        }

        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .video }) else {
            print("[UploadManager] No video resource found for asset")
            return nil
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let uploadsDir = docs.appendingPathComponent("pending_uploads")
        try? FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
        let destination = uploadsDir.appendingPathComponent(UUID().uuidString + "_" + resource.originalFilename)

        // Remove any existing file at destination
        try? FileManager.default.removeItem(at: destination)

        print("[UploadManager] Re-exporting asset to: \(destination.lastPathComponent)")

        return await withCheckedContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    print("[UploadManager] Asset export failed: \(error)")
                    continuation.resume(returning: nil)
                } else {
                    print("[UploadManager] Asset export succeeded: \(destination.lastPathComponent)")
                    continuation.resume(returning: destination)
                }
            }
        }
    }

    private func enqueueInitialUpload() {
        guard let fileURL else { return }
        guard let uploadURL = buildUploadURL() else {
            Task {
                await setError("Invalid server URL")
            }
            return
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
        request.setValue("?0", forHTTPHeaderField: "Upload-Incomplete")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = makeTaskDescription(baseOffset: 0)
        currentBackgroundTask = task
        persistState()
        state = .uploading
        connectionInfo = "Upload started"
        print("[UploadManager] Starting upload task to \(uploadURL)")
        task.resume()
    }

    private func resumeUpload() async {
        if let resumeData {
            progressBaseBytes = bytesUploaded
            let task = backgroundSession.uploadTask(withResumeData: resumeData)
            task.taskDescription = makeTaskDescription(baseOffset: progressBaseBytes)
            currentBackgroundTask = task
            self.resumeData = nil
            persistState()
            state = .uploading
            connectionInfo = "Upload resumed"
            print("[UploadManager] Resuming upload from native resume data")
            task.resume()
            return
        }

        if fileURL == nil, assetIdentifier != nil {
            connectionInfo = "Re-exporting from Photos..."
            if let exportedURL = await exportAssetToFile() {
                fileURL = exportedURL
                selectedFileName = exportedURL.lastPathComponent
                persistState()
            } else {
                await setError("Could not re-export video from Photos library")
                return
            }
        }

        if fileURL != nil {
            state = .idle
            startUpload(serverURL: serverURL)
            return
        }

        await setError("No file available to resume")
    }

    private func buildUploadURL() -> URL? {
        guard let uploadBaseURL = URL(string: serverURL) else { return nil }
        if uploadBaseURL.path.isEmpty || uploadBaseURL.path == "/" {
            return uploadBaseURL.appendingPathComponent("upload")
        }
        return uploadBaseURL
    }

    // MARK: - State Persistence

    private struct PersistedUploadState: Codable {
        var serverURL: String
        var filePath: String?
        var assetIdentifier: String?
        var totalBytes: Int64
        var currentOffset: Int64
        var authToken: String?
        var resumeData: Data?
        var resumeURL: String?
    }

    private func persistState() {
        let persisted = PersistedUploadState(
            serverURL: serverURL,
            filePath: fileURL?.path,
            assetIdentifier: assetIdentifier,
            totalBytes: totalBytes ?? 0,
            currentOffset: currentOffset,
            authToken: authToken,
            resumeData: resumeData,
            resumeURL: resumeURL?.absoluteString
        )
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }

    private func loadPersistedState() -> PersistedUploadState? {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey) else { return nil }
        return try? JSONDecoder().decode(PersistedUploadState.self, from: data)
    }

    private func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: Self.stateKey)
    }

    // MARK: - Speed Tracking

    private func startSpeedTracking() {
        lastSpeedCheckTime = Date()
        lastSpeedCheckBytes = bytesUploaded
        speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSpeed()
            }
        }
    }

    private func stopSpeedTracking() {
        speedTimer?.invalidate()
        speedTimer = nil
    }

    private func updateSpeed() {
        let now = Date()
        guard let lastTime = lastSpeedCheckTime else {
            lastSpeedCheckTime = now
            lastSpeedCheckBytes = bytesUploaded
            return
        }

        let elapsed = now.timeIntervalSince(lastTime)
        guard elapsed > 0 else { return }

        let bytesDelta = bytesUploaded - lastSpeedCheckBytes
        let speedBps = Double(bytesDelta) / elapsed

        if speedBps >= 1_048_576 {
            speedDisplay = String(format: "%.1f MB/s", speedBps / 1_048_576)
        } else if speedBps >= 1024 {
            speedDisplay = String(format: "%.0f KB/s", speedBps / 1024)
        } else if speedBps > 0 {
            speedDisplay = String(format: "%.0f B/s", speedBps)
        } else {
            speedDisplay = "—"
        }

        lastSpeedCheckTime = now
        lastSpeedCheckBytes = bytesUploaded

        if state == .uploading || state == .paused || state == .resuming {
            currentOffset = bytesUploaded
            persistState()
        }
    }

    private func updateProgress(uploadedBytes: Int64? = nil) {
        if let uploadedBytes {
            bytesUploaded = uploadedBytes
        }
        currentOffset = bytesUploaded
        guard let total = totalBytes, total > 0 else { return }
        progress = Double(bytesUploaded) / Double(total)
    }

    // MARK: - Completion / Error

    private func completeUpload(finalUploadedBytes: Int64? = nil) {
        state = .completed
        progress = 1.0
        if let finalUploadedBytes {
            bytesUploaded = finalUploadedBytes
        } else {
            bytesUploaded = totalBytes ?? bytesUploaded
        }
        currentOffset = bytesUploaded
        connectionInfo = "Upload complete"
        stopSpeedTracking()
        clearPersistedState()
        cleanupExportedFile()
        assetIdentifier = nil
        fileURL = nil
        currentBackgroundTask = nil
        resumeData = nil
        resumeURL = nil
        progressBaseBytes = 0

        if let start = uploadStartTime, bytesUploaded > 0 {
            let elapsed = Date().timeIntervalSince(start)
            let uploadedMB = Double(bytesUploaded) / 1_048_576
            speedDisplay = String(format: "Avg: %.1f MB/s (%.1fs)", uploadedMB / elapsed, elapsed)
        }
        sendLocalNotification(title: "Upload Complete", body: "\(formatBytes(bytesUploaded)) uploaded successfully.")
        print("[UploadManager] Upload complete! Total: \(formatBytes(bytesUploaded))")
    }

    private func setError(_ message: String) async {
        state = .failed
        errorMessage = message
        connectionInfo = "Error"
        stopSpeedTracking()
        currentBackgroundTask = nil
        currentOffset = bytesUploaded
        persistState()
        print("[UploadManager] ERROR: \(message)")
    }

    private func sendLocalNotification(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }

    private func deleteServerUploadIfPossible() {
        guard let resumeURL else { return }
        var request = URLRequest(url: resumeURL)
        request.httpMethod = "DELETE"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        foregroundSession.dataTask(with: request).resume()
    }

    private func makeTaskDescription(baseOffset: Int64) -> String {
        "upload_base_\(baseOffset)"
    }

    private func parseTaskBaseOffset(from taskDescription: String?) -> Int64? {
        guard let taskDescription,
              let baseOffset = Int64(taskDescription.replacingOccurrences(of: "upload_base_", with: "")) else {
            return nil
        }
        return baseOffset
    }

    private func parseUploadIncomplete(from response: HTTPURLResponse) -> Bool? {
        guard let value = response.value(forHTTPHeaderField: "Upload-Incomplete")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        switch value {
        case "?1", "true":
            return true
        case "?0", "false":
            return false
        default:
            return nil
        }
    }

    private enum CompletionVerificationResult {
        case success(Int64)
        case failure(String)
    }

    private func verifyCompletedUploadOffset(
        from response: HTTPURLResponse,
        responseOffset: Int64?,
        responseIsIncomplete: Bool?
    ) async -> CompletionVerificationResult {
        if responseIsIncomplete == true {
            return .failure("Server reported the upload is incomplete at offset \(responseOffset ?? bytesUploaded)")
        }

        if let totalBytes, let responseOffset, responseOffset == totalBytes {
            return .success(responseOffset)
        }

        guard let resumeURL else {
            if let responseOffset, let totalBytes {
                return .failure("Server acknowledged only \(formatBytes(responseOffset)) of \(formatBytes(totalBytes))")
            }

            return .failure("Server did not confirm the uploaded byte count")
        }

        var request = URLRequest(url: resumeURL)
        request.httpMethod = "HEAD"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, headResponse) = try await foregroundSession.data(for: request)
            guard let httpHeadResponse = headResponse as? HTTPURLResponse else {
                return .failure("Server returned an invalid HEAD response while verifying completion")
            }

            print("[UploadManager] Completion verification HEAD response: \(httpHeadResponse.statusCode)")
            print("[UploadManager] Completion verification headers: \(httpHeadResponse.allHeaderFields)")

            if httpHeadResponse.statusCode == 204 {
                let headOffset = httpHeadResponse.value(forHTTPHeaderField: "Upload-Offset")
                    .flatMap(Int64.init)
                let headIsIncomplete = parseUploadIncomplete(from: httpHeadResponse)

                if headIsIncomplete == true {
                    return .failure("Server reports the upload is still incomplete at offset \(headOffset ?? bytesUploaded)")
                }

                if let totalBytes, let headOffset, headOffset == totalBytes {
                    return .success(headOffset)
                }

                if let totalBytes, let headOffset {
                    return .failure("Server acknowledged only \(formatBytes(headOffset)) of \(formatBytes(totalBytes))")
                }

                return .failure("Server did not provide an Upload-Offset while verifying completion")
            }

            return .failure("Completion verification HEAD returned \(httpHeadResponse.statusCode)")
        } catch {
            return .failure("Completion verification failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - URLSession Delegate

extension UploadManager: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    /// progress — works for both foreground and background sessions
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { @MainActor in
            guard session.configuration.identifier == Self.backgroundSessionID else { return }
            let taskBaseOffset = parseTaskBaseOffset(from: task.taskDescription) ?? progressBaseBytes
            let uploadedBytes = max(bytesUploaded, taskBaseOffset + totalBytesSent)
            updateProgress(uploadedBytes: uploadedBytes)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceiveInformationalResponse response: HTTPURLResponse
    ) {
        MainActor.assumeIsolated {
            guard session.configuration.identifier == Self.backgroundSessionID else { return }
            if response.statusCode == 104,
               let location = response.value(forHTTPHeaderField: "Location"),
               let parsedResumeURL = URL(string: location) {
                resumeURL = parsedResumeURL
                connectionInfo = "Server confirmed resumable upload support"
                persistState()
                print("[UploadManager] Received resumable upload URL: \(parsedResumeURL)")
            }
        }
    }

    /// Called when the background upload task completes (success or failure).
    /// On failure, retries with native resume data when available.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        MainActor.assumeIsolated {
            guard session.configuration.identifier == Self.backgroundSessionID else { return }

            // If this was a cancellation (from pause or cancel), don't continue
            if let error = error as? NSError, error.code == NSURLErrorCancelled {
                print("[UploadManager] Background task cancelled")
                return
            }

            if let urlError = error as? URLError,
               let newResumeData = urlError.uploadTaskResumeData {
                print("[UploadManager] Background task interrupted: \(urlError)")
                resumeData = newResumeData
                currentBackgroundTask = nil
                currentOffset = bytesUploaded
                persistState()

                if isPaused || isCancelled {
                    return
                }

                sendLocalNotification(title: "Upload Interrupted", body: "Retrying automatically...")
                connectionInfo = "Transfer interrupted, resuming..."
                progressBaseBytes = bytesUploaded

                let resumedTask = backgroundSession.uploadTask(withResumeData: newResumeData)
                resumedTask.taskDescription = makeTaskDescription(baseOffset: progressBaseBytes)
                currentBackgroundTask = resumedTask
                resumeData = nil
                persistState()
                resumedTask.resume()
                print("[UploadManager] Retrying upload from native resume data")
                return
            }

            if let error {
                state = .failed
                errorMessage = "Upload failed: \(error.localizedDescription)"
                connectionInfo = "Error"
                stopSpeedTracking()
                currentBackgroundTask = nil
                persistState()
                sendLocalNotification(title: "Upload Failed", body: error.localizedDescription)
                print("[UploadManager] ERROR: \(error)")
                return
            }

            guard let httpResponse = task.response as? HTTPURLResponse else {
                state = .failed
                errorMessage = "Invalid server response for upload"
                connectionInfo = "Error"
                stopSpeedTracking()
                currentBackgroundTask = nil
                sendLocalNotification(title: "Upload Failed", body: "Invalid server response")
                persistState()
                print("[UploadManager] ERROR: Invalid server response for upload")
                return
            }

            let statusCode = httpResponse.statusCode
            print("[UploadManager] Background upload response: \(statusCode)")
            print("[UploadManager] Upload response headers: \(httpResponse.allHeaderFields)")

            let responseOffset = httpResponse.value(forHTTPHeaderField: "Upload-Offset")
                .flatMap(Int64.init)
            let responseIsIncomplete = parseUploadIncomplete(from: httpResponse)

            guard (200...299).contains(statusCode) else {
                state = .failed
                errorMessage = "Upload returned \(statusCode)"
                connectionInfo = "Error"
                stopSpeedTracking()
                currentBackgroundTask = nil
                sendLocalNotification(title: "Upload Failed", body: "Server returned \(statusCode). Open app to retry.")
                persistState()
                print("[UploadManager] ERROR: Upload returned \(statusCode)")
                return
            }

            currentBackgroundTask = nil
            Task { @MainActor in
                let verificationResult = await verifyCompletedUploadOffset(
                    from: httpResponse,
                    responseOffset: responseOffset,
                    responseIsIncomplete: responseIsIncomplete
                )

                switch verificationResult {
                case .success(let verifiedOffset):
                    updateProgress(uploadedBytes: verifiedOffset)
                    completeUpload(finalUploadedBytes: verifiedOffset)
                case .failure(let message):
                    state = .failed
                    errorMessage = message
                    connectionInfo = "Server completion could not be verified"
                    stopSpeedTracking()
                    persistState()
                    sendLocalNotification(title: "Upload Incomplete", body: message)
                    print("[UploadManager] ERROR: \(message)")
                }
            }
        }
    }

    /// Called when all background events for a session have been delivered.
    /// Must call the system completion handler to tell iOS we're done updating the UI.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            print("[UploadManager] Background session finished events")
            if let handler = UploadManager.backgroundSessionCompletionHandler {
                UploadManager.backgroundSessionCompletionHandler = nil
                handler()
            }
        }
    }
}
