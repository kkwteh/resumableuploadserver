import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

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

/// Manages resumable file uploads using the HTTP Resumable Upload protocol
/// (draft-ietf-httpbis-resumable-upload-01).
///
/// Uses a dual-session architecture:
/// - **Foreground session**: lightweight protocol requests (POST, HEAD, DELETE)
/// - **Background session**: PATCH chunk uploads that continue even when the app is suspended/killed
///
/// Upload flow:
/// 1. POST to server with Upload-Incomplete: ?1 to create upload session and get resumption URL
/// 2. PATCH chunks to resumption URL via background upload tasks (one at a time, delegate-driven)
/// 3. On interruption: HEAD to get server offset, resume with PATCH
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

    // MARK: - Computed

    var canStart: Bool { state == .idle && fileURL != nil }
    var canPause: Bool { state == .uploading }
    var canResume: Bool { state == .paused || state == .failed }
    var canCancel: Bool { state == .uploading || state == .paused || state == .resuming }

    // MARK: - Internal State

    private var fileURL: URL?
    /// The path portion of the resumption URL (e.g. /resumable_upload/12345-67890)
    private var resumptionPath: String?
    private var serverURL: String = ""
    private var chunkSize: Int = 1_048_576
    private var isPaused = false
    private var isCancelled = false
    private var speedTimer: Timer?
    private var lastSpeedCheckTime: Date?
    private var lastSpeedCheckBytes: Int64 = 0
    private var uploadStartTime: Date?

    /// Tracks the current background upload task so we can cancel it on pause
    private var currentBackgroundTask: URLSessionUploadTask?

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
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Background session for PATCH chunk uploads — transfers continue even when app is suspended/killed
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.isDiscretionary = false
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    // MARK: - Temp File Management

    private var chunkTempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("upload_chunks")
    }

    private func writeChunkToTempFile(offset: Int64, length: Int64) -> URL? {
        guard let fileURL else { return nil }
        guard let chunkData = readChunk(from: fileURL, offset: offset, length: length) else { return nil }

        let dir = chunkTempDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let tempFile = dir.appendingPathComponent("chunk_\(offset).bin")
        do {
            try chunkData.write(to: tempFile)
            return tempFile
        } catch {
            print("[UploadManager] Failed to write temp chunk file: \(error)")
            return nil
        }
    }

    private func cleanupTempFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func cleanupAllTempChunks() {
        let dir = chunkTempDirectory
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - File Loading

    func loadVideo(from item: PhotosPickerItem) async {
        state = .preparing
        connectionInfo = "Loading video..."

        do {
            guard let videoData = try await item.loadTransferable(type: VideoFileTransferable.self) else {
                state = .idle
                errorMessage = "Failed to load video"
                connectionInfo = "Idle"
                return
            }

            fileURL = videoData.url
            let attrs = try FileManager.default.attributesOfItem(atPath: videoData.url.path)
            let fileSize = attrs[.size] as? Int64 ?? 0
            totalBytes = fileSize
            selectedFileName = videoData.url.lastPathComponent
            state = .idle
            connectionInfo = "File ready (\(formatBytes(fileSize)))"
            errorMessage = nil
            print("[UploadManager] File loaded: \(videoData.url.lastPathComponent), size: \(fileSize)")
        } catch {
            state = .idle
            errorMessage = "Failed to load video: \(error.localizedDescription)"
            connectionInfo = "Idle"
            print("[UploadManager] File load error: \(error)")
        }
    }

    // MARK: - Upload Control

    func startUpload(serverURL: String, chunkSizeMB: Int) {
        guard fileURL != nil, state == .idle else { return }

        self.serverURL = serverURL.trimmingCharacters(in: .whitespaces)
        self.chunkSize = chunkSizeMB * 1_048_576
        self.bytesUploaded = 0
        self.currentOffset = 0
        self.progress = 0
        self.errorMessage = nil
        self.isPaused = false
        self.isCancelled = false
        self.resumptionPath = nil

        cleanupAllTempChunks()

        state = .creatingUpload
        connectionInfo = "Connecting..."
        uploadStartTime = Date()
        startSpeedTracking()

        Task {
            await createUploadSession()
        }
    }

    func pause() {
        guard state == .uploading else { return }
        isPaused = true
        state = .paused
        connectionInfo = "Paused at offset \(currentOffset)"
        stopSpeedTracking()

        // Cancel the current background upload task; didCompleteWithError will detect cancellation
        currentBackgroundTask?.cancel()
        currentBackgroundTask = nil

        print("[UploadManager] Paused at offset \(currentOffset)")
    }

    func resume() {
        guard state == .paused || state == .failed else { return }
        guard resumptionPath != nil else {
            if fileURL != nil {
                state = .idle
                startUpload(serverURL: serverURL, chunkSizeMB: chunkSize / 1_048_576)
            }
            return
        }

        isPaused = false
        isCancelled = false
        state = .resuming
        connectionInfo = "Checking server offset..."
        startSpeedTracking()

        Task {
            await queryOffsetAndResume()
        }
    }

    func cancel() {
        guard state == .uploading || state == .paused || state == .resuming else { return }
        isCancelled = true
        isPaused = false

        // Cancel any in-flight background tasks
        currentBackgroundTask?.cancel()
        currentBackgroundTask = nil

        // Send DELETE to cancel server-side via foreground session
        if let url = buildResumptionURL() {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
            foregroundSession.dataTask(with: request).resume()
        }

        state = .cancelled
        connectionInfo = "Cancelled"
        stopSpeedTracking()
        clearPersistedState()
        cleanupAllTempChunks()
        print("[UploadManager] Cancelled")
    }

    // MARK: - Background Session Reconnection

    func reconnectBackgroundSession() {
        cleanupAllTempChunks()

        // Touch the background session so it reconnects with the system daemon
        _ = backgroundSession

        if let saved = loadPersistedState() {
            resumptionPath = saved.resumptionPath
            serverURL = saved.serverURL
            chunkSize = saved.chunkSize
            totalBytes = saved.totalBytes
            currentOffset = saved.currentOffset
            bytesUploaded = saved.currentOffset

            if let path = saved.filePath, FileManager.default.fileExists(atPath: path) {
                fileURL = URL(fileURLWithPath: path)
                selectedFileName = URL(fileURLWithPath: path).lastPathComponent
                updateProgress()

                // Check if there are pending background tasks
                backgroundSession.getAllTasks { [weak self] tasks in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let activeTasks = tasks.filter { $0.state == .running || $0.state == .suspended }
                        if activeTasks.isEmpty {
                            // No pending tasks — last chunk may have completed while app was dead
                            // Restore as paused so user can resume (HEAD will sync offset)
                            self.state = .paused
                            self.connectionInfo = "Restored from previous session (offset \(self.currentOffset))"
                            print("[UploadManager] Restored state, no active tasks. offset=\(self.currentOffset)")
                        } else {
                            // Active tasks exist — delegate callbacks will drive them
                            self.state = .uploading
                            self.connectionInfo = "Background upload in progress..."
                            self.startSpeedTracking()
                            print("[UploadManager] Restored state, \(activeTasks.count) active background task(s)")
                        }
                    }
                }
            } else {
                clearPersistedState()
            }
        }
    }

    // MARK: - URL Building

    /// Build the full resumption URL from the server URL + resumption path.
    private func buildResumptionURL() -> URL? {
        guard let resumptionPath else { return nil }
        guard var components = URLComponents(string: serverURL) else { return nil }
        components.path = resumptionPath
        return components.url
    }

    // MARK: - Upload Protocol Implementation

    /// Step 1: POST to create upload session and get resumption URL (foreground session)
    private func createUploadSession() async {
        guard let uploadBaseURL = URL(string: serverURL) else {
            await setError("Invalid server URL")
            return
        }

        let uploadURL: URL
        if uploadBaseURL.path.isEmpty || uploadBaseURL.path == "/" {
            uploadURL = uploadBaseURL.appendingPathComponent("upload")
        } else {
            uploadURL = uploadBaseURL
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
        request.setValue("?1", forHTTPHeaderField: "Upload-Incomplete")
        request.setValue("0", forHTTPHeaderField: "Upload-Offset")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("close", forHTTPHeaderField: "Connection")

        print("[UploadManager] POST \(uploadURL) to create upload session")

        do {
            let (_, response) = try await foregroundSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                await setError("Invalid response from server")
                return
            }

            print("[UploadManager] POST response: \(httpResponse.statusCode)")
            print("[UploadManager] Headers: \(httpResponse.allHeaderFields)")

            guard httpResponse.statusCode == 201 else {
                await setError("Server returned \(httpResponse.statusCode) (expected 201)")
                return
            }

            guard let location = httpResponse.value(forHTTPHeaderField: "Location") else {
                await setError("No Location header in 201 response")
                return
            }

            if let locationURL = URL(string: location) {
                resumptionPath = locationURL.path
            } else {
                resumptionPath = location
            }

            print("[UploadManager] Resumption path: \(resumptionPath ?? "nil")")

            if let offsetStr = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
               let offset = Int64(offsetStr) {
                currentOffset = offset
            }

            persistState()
            state = .uploading
            connectionInfo = "Upload session created"

            enqueueNextChunk()
        } catch {
            await setError("Connection failed: \(error.localizedDescription)")
        }
    }

    /// Enqueue the next chunk as a background upload task.
    /// This is synchronous (MainActor) — the delegate callback drives the loop.
    private func enqueueNextChunk() {
        guard fileURL != nil else {
            print("[UploadManager] No file URL")
            return
        }
        guard resumptionPath != nil else {
            print("[UploadManager] No resumption path")
            return
        }
        guard let total = totalBytes else {
            print("[UploadManager] No total bytes")
            return
        }
        guard !isPaused, !isCancelled else {
            print("[UploadManager] Upload paused or cancelled, stopping chunk loop")
            return
        }
        guard currentOffset < total else {
            completeUpload()
            return
        }

        guard let patchURL = buildResumptionURL() else {
            state = .failed
            errorMessage = "Cannot build resumption URL"
            connectionInfo = "Error"
            return
        }

        let remaining = total - currentOffset
        let thisChunkSize = min(Int64(chunkSize), remaining)
        let isLastChunk = (currentOffset + thisChunkSize) >= total

        print("[UploadManager] Enqueuing chunk: offset=\(currentOffset), size=\(thisChunkSize), isLast=\(isLastChunk)")
        connectionInfo = "Uploading \(formatBytes(currentOffset))/\(formatBytes(total))..."

        // Write chunk data to a temp file (background sessions require fromFile: uploads)
        guard let tempFileURL = writeChunkToTempFile(offset: currentOffset, length: thisChunkSize) else {
            state = .failed
            errorMessage = "Failed to write chunk temp file at offset \(currentOffset)"
            connectionInfo = "Error"
            return
        }

        var request = URLRequest(url: patchURL)
        request.httpMethod = "PATCH"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
        request.setValue("\(currentOffset)", forHTTPHeaderField: "Upload-Offset")
        request.setValue(isLastChunk ? "?0" : "?1", forHTTPHeaderField: "Upload-Incomplete")
        request.setValue("\(thisChunkSize)", forHTTPHeaderField: "Content-Length")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")

        let task = backgroundSession.uploadTask(with: request, fromFile: tempFileURL)
        task.taskDescription = "chunk_\(currentOffset)"
        currentBackgroundTask = task
        task.resume()
    }

    /// Step 3: HEAD to check server offset for resumption (foreground session)
    private func queryOffsetAndResume() async {
        guard let headURL = buildResumptionURL() else {
            await setError("No resumption URL for HEAD")
            return
        }

        var request = URLRequest(url: headURL)
        request.httpMethod = "HEAD"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")

        print("[UploadManager] HEAD \(headURL)")

        do {
            let (_, response) = try await foregroundSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await setError("Invalid HEAD response")
                return
            }

            print("[UploadManager] HEAD response: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 204 {
                if let offsetStr = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
                   let offset = Int64(offsetStr) {
                    currentOffset = offset
                    bytesUploaded = offset
                    updateProgress()
                    state = .uploading
                    connectionInfo = "Resumed from offset \(offset)"
                    persistState()
                    print("[UploadManager] Resumed at offset \(offset)")
                    enqueueNextChunk()
                } else {
                    await setError("No Upload-Offset in HEAD response")
                }
            } else if httpResponse.statusCode == 404 {
                resumptionPath = nil
                currentOffset = 0
                bytesUploaded = 0
                progress = 0
                clearPersistedState()
                await setError("Upload expired on server. Please restart.")
            } else {
                await setError("HEAD returned \(httpResponse.statusCode)")
            }
        } catch {
            await setError("Resume failed: \(error.localizedDescription)")
        }
    }

    // MARK: - File Reading

    private func readChunk(from sourceURL: URL, offset: Int64, length: Int64) -> Data? {
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { handle.closeFile() }
            handle.seek(toFileOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(length))
            return data
        } catch {
            print("[UploadManager] Failed to read chunk: \(error)")
            return nil
        }
    }

    // MARK: - State Persistence

    private struct PersistedUploadState: Codable {
        var resumptionPath: String
        var serverURL: String
        var filePath: String?
        var totalBytes: Int64
        var currentOffset: Int64
        var chunkSize: Int
    }

    private func persistState() {
        guard let resumptionPath else { return }
        let persisted = PersistedUploadState(
            resumptionPath: resumptionPath,
            serverURL: serverURL,
            filePath: fileURL?.path,
            totalBytes: totalBytes ?? 0,
            currentOffset: currentOffset,
            chunkSize: chunkSize
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
    }

    private func updateProgress() {
        guard let total = totalBytes, total > 0 else { return }
        progress = Double(bytesUploaded) / Double(total)
    }

    // MARK: - Completion / Error

    private func completeUpload() {
        state = .completed
        progress = 1.0
        connectionInfo = "Upload complete"
        stopSpeedTracking()
        clearPersistedState()
        cleanupAllTempChunks()
        currentBackgroundTask = nil

        if let start = uploadStartTime {
            let elapsed = Date().timeIntervalSince(start)
            let totalMB = Double(totalBytes ?? 0) / 1_048_576
            speedDisplay = String(format: "Avg: %.1f MB/s (%.1fs)", totalMB / elapsed, elapsed)
        }
        print("[UploadManager] Upload complete! Total: \(formatBytes(totalBytes ?? 0))")
    }

    private func setError(_ message: String) async {
        state = .failed
        errorMessage = message
        connectionInfo = "Error"
        stopSpeedTracking()
        currentBackgroundTask = nil
        print("[UploadManager] ERROR: \(message)")
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
}

// MARK: - URLSession Delegate

extension UploadManager: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    /// Intra-chunk progress — works for both foreground and background sessions
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { @MainActor in
            guard task.originalRequest?.httpMethod == "PATCH" else { return }
            bytesUploaded = currentOffset + totalBytesSent
            updateProgress()
        }
    }

    /// Main driver for background upload chain: called when each upload task completes.
    /// Reads response headers, updates offset, and enqueues the next chunk (or completes).
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        MainActor.assumeIsolated {
            // Clean up the temp file for this chunk
            if let taskDesc = task.taskDescription,
               taskDesc.hasPrefix("chunk_") {
                let tempFile = chunkTempDirectory.appendingPathComponent("\(taskDesc).bin")
                cleanupTempFile(tempFile)
            }

            // If this was a cancellation (from pause or cancel), don't continue
            if let error = error as? NSError, error.code == NSURLErrorCancelled {
                print("[UploadManager] Background task cancelled")
                return
            }

            // Handle network errors
            if let error {
                print("[UploadManager] Background task error: \(error)")
                if !isPaused, !isCancelled {
                    state = .failed
                    errorMessage = "Upload failed: \(error.localizedDescription)"
                    connectionInfo = "Error"
                    stopSpeedTracking()
                    currentBackgroundTask = nil
                    print("[UploadManager] ERROR: Upload failed: \(error.localizedDescription)")
                }
                return
            }

            // Only process PATCH responses
            guard task.originalRequest?.httpMethod == "PATCH" else { return }

            guard let httpResponse = task.response as? HTTPURLResponse else {
                state = .failed
                errorMessage = "Invalid server response for background PATCH"
                connectionInfo = "Error"
                stopSpeedTracking()
                currentBackgroundTask = nil
                print("[UploadManager] ERROR: Invalid server response for background PATCH")
                return
            }

            let statusCode = httpResponse.statusCode
            print("[UploadManager] Background PATCH response: \(statusCode)")

            if statusCode == 409 {
                // Offset conflict — re-sync via HEAD
                connectionInfo = "Offset conflict, re-syncing..."
                print("[UploadManager] 409 Conflict, querying offset")
                Task {
                    await queryOffsetAndResume()
                }
                return
            }

            guard (200...299).contains(statusCode) else {
                state = .failed
                errorMessage = "PATCH returned \(statusCode)"
                connectionInfo = "Error"
                stopSpeedTracking()
                currentBackgroundTask = nil
                print("[UploadManager] ERROR: PATCH returned \(statusCode)")
                return
            }

            // Update offset from server response
            if let serverOffsetStr = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
               let serverOffset = Int64(serverOffsetStr) {
                currentOffset = serverOffset
            } else {
                // Fallback: calculate from what we sent
                if let requestOffsetStr = task.originalRequest?.value(forHTTPHeaderField: "Upload-Offset"),
                   let requestOffset = Int64(requestOffsetStr),
                   let contentLenStr = task.originalRequest?.value(forHTTPHeaderField: "Content-Length"),
                   let contentLen = Int64(contentLenStr) {
                    currentOffset = requestOffset + contentLen
                }
            }

            bytesUploaded = currentOffset
            updateProgress()
            persistState()
            currentBackgroundTask = nil

            print("[UploadManager] Chunk done, offset now: \(currentOffset)")

            guard let total = totalBytes else { return }

            if currentOffset >= total {
                completeUpload()
            } else if !isPaused, !isCancelled {
                enqueueNextChunk()
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

// MARK: - Video File Transferable

struct VideoFileTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let uploadsDir = docs.appendingPathComponent("pending_uploads")
            try FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)

            let destination = uploadsDir.appendingPathComponent(
                UUID().uuidString + "_" + received.file.lastPathComponent
            )
            try FileManager.default.copyItem(at: received.file, to: destination)
            return VideoFileTransferable(url: destination)
        }
    }
}
