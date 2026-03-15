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
/// Upload flow:
/// 1. POST to server with Upload-Incomplete: ?1 to create upload session and get resumption URL
/// 2. PATCH chunks to resumption URL via background URLSession
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
    private var resumptionURL: String?
    private var serverURL: String = ""
    private var chunkSize: Int = 1_048_576
    private var isPaused = false
    private var speedTimer: Timer?
    private var lastSpeedCheckTime: Date?
    private var lastSpeedCheckBytes: Int64 = 0
    private var uploadStartTime: Date?

    private static let backgroundSessionID = "com.resumableupload.background"
    private static let stateKey = "ResumableUploadState"

    private lazy var foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var _backgroundSession: URLSession?
    private var backgroundSession: URLSession {
        if let session = _backgroundSession { return session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.shouldUseExtendedBackgroundIdleMode = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _backgroundSession = session
        return session
    }

    private var backgroundCompletionHandler: (() -> Void)?

    // MARK: - File Loading

    func loadVideo(from item: PhotosPickerItem) async {
        state = .preparing
        connectionInfo = "Loading video..."

        do {
            // Use loadTransferable to get file without loading into memory
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
            connectionInfo = "File ready"
            errorMessage = nil
        } catch {
            state = .idle
            errorMessage = "Failed to load video: \(error.localizedDescription)"
            connectionInfo = "Idle"
        }
    }

    // MARK: - Upload Control

    func startUpload(serverURL: String, chunkSizeMB: Int) {
        guard let fileURL, state == .idle else { return }

        self.serverURL = serverURL.trimmingCharacters(in: .whitespaces)
        self.chunkSize = chunkSizeMB * 1_048_576
        self.bytesUploaded = 0
        self.currentOffset = 0
        self.progress = 0
        self.errorMessage = nil
        self.isPaused = false
        self.resumptionURL = nil

        state = .creatingUpload
        connectionInfo = "Connecting..."
        uploadStartTime = Date()
        startSpeedTracking()

        Task {
            await createUploadSession(fileURL: fileURL)
        }
    }

    func pause() {
        guard state == .uploading else { return }
        isPaused = true
        state = .paused
        connectionInfo = "Paused"
        stopSpeedTracking()

        // Cancel current background tasks - we'll resume from server offset
        backgroundSession.getTasksWithCompletionHandler { _, uploadTasks, _ in
            for task in uploadTasks { task.cancel() }
        }
    }

    func resume() {
        guard state == .paused || state == .failed else { return }
        guard resumptionURL != nil else {
            // No resumption URL - need to restart
            if fileURL != nil {
                state = .idle
                startUpload(serverURL: serverURL, chunkSizeMB: chunkSize / 1_048_576)
            }
            return
        }

        isPaused = false
        state = .resuming
        connectionInfo = "Checking server offset..."
        startSpeedTracking()

        Task {
            await queryOffsetAndResume()
        }
    }

    func cancel() {
        guard state == .uploading || state == .paused || state == .resuming else { return }

        // Send DELETE to cancel server-side
        if let resumptionURL, let url = URL(string: resumptionURL) {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
            foregroundSession.dataTask(with: request).resume()
        }

        backgroundSession.getTasksWithCompletionHandler { _, uploadTasks, _ in
            for task in uploadTasks { task.cancel() }
        }

        state = .cancelled
        connectionInfo = "Cancelled"
        stopSpeedTracking()
        clearPersistedState()
    }

    // MARK: - Background Session Reconnection

    func reconnectBackgroundSession() {
        // Reconnecting to the background session triggers delivery of completed tasks
        _ = backgroundSession

        // Check for persisted state from a previous app launch
        if let saved = loadPersistedState() {
            resumptionURL = saved.resumptionURL
            serverURL = saved.serverURL
            chunkSize = saved.chunkSize
            totalBytes = saved.totalBytes
            currentOffset = saved.currentOffset
            bytesUploaded = saved.currentOffset

            if let path = saved.filePath, FileManager.default.fileExists(atPath: path) {
                fileURL = URL(fileURLWithPath: path)
                selectedFileName = URL(fileURLWithPath: path).lastPathComponent
                updateProgress()

                // Auto-resume if we have a resumption URL
                state = .paused
                connectionInfo = "Restored from previous session"
            } else {
                clearPersistedState()
            }
        }
    }

    /// Called by the app delegate when background session events arrive
    func handleBackgroundSessionEvents(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
    }

    // MARK: - Upload Protocol Implementation

    /// Step 1: POST to create upload session and get resumption URL
    private func createUploadSession(fileURL: URL) async {
        let uploadURL: URL
        // Use /upload as the default endpoint path
        if let url = URL(string: serverURL) {
            if url.path.isEmpty || url.path == "/" {
                uploadURL = url.appendingPathComponent("upload")
            } else {
                uploadURL = url
            }
        } else {
            await handleError("Invalid server URL")
            return
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
        // ?1 = incomplete (structured field boolean true)
        request.setValue("?1", forHTTPHeaderField: "Upload-Incomplete")
        request.setValue("0", forHTTPHeaderField: "Upload-Offset")
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        do {
            let (_, response) = try await foregroundSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                await handleError("Invalid response")
                return
            }

            // Server responds with 201 Created and Location header containing resumption URL
            guard httpResponse.statusCode == 201 else {
                await handleError("Server returned \(httpResponse.statusCode)")
                return
            }

            guard let location = httpResponse.value(forHTTPHeaderField: "Location") else {
                await handleError("No Location header in response")
                return
            }

            // Parse Upload-Offset from response
            if let offsetStr = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
               let offset = Int64(offsetStr) {
                currentOffset = offset
            }

            resumptionURL = location
            persistState()

            await MainActor.run {
                state = .uploading
                connectionInfo = "Upload session created"
            }

            await uploadNextChunk()
        } catch {
            await handleError("Connection failed: \(error.localizedDescription)")
        }
    }

    /// Step 2: PATCH chunks to resumption URL
    private func uploadNextChunk() async {
        guard let fileURL, let resumptionURL, let total = totalBytes else { return }
        guard !isPaused else { return }
        guard currentOffset < total else {
            await completeUpload()
            return
        }

        let remaining = total - currentOffset
        let thisChunkSize = min(Int64(chunkSize), remaining)
        let isLastChunk = (currentOffset + thisChunkSize) >= total

        // Create a temporary file containing just this chunk
        guard let chunkFileURL = createChunkFile(
            from: fileURL,
            offset: currentOffset,
            length: thisChunkSize
        ) else {
            await handleError("Failed to read file chunk")
            return
        }

        guard let url = URL(string: resumptionURL) else {
            await handleError("Invalid resumption URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
        request.setValue("\(currentOffset)", forHTTPHeaderField: "Upload-Offset")
        // ?0 = false (complete), ?1 = true (incomplete)
        request.setValue(isLastChunk ? "?0" : "?1", forHTTPHeaderField: "Upload-Incomplete")
        request.setValue("\(thisChunkSize)", forHTTPHeaderField: "Content-Length")
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")

        await MainActor.run {
            connectionInfo = "Uploading chunk at offset \(currentOffset)..."
        }

        // Use background session for actual data upload
        let task = backgroundSession.uploadTask(with: request, fromFile: chunkFileURL)
        task.taskDescription = "\(currentOffset):\(thisChunkSize):\(isLastChunk ? "1" : "0"):\(chunkFileURL.path)"
        task.resume()
    }

    /// Step 3: HEAD to check server offset for resumption
    private func queryOffsetAndResume() async {
        guard let resumptionURL, let url = URL(string: resumptionURL) else {
            await handleError("No resumption URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")

        do {
            let (_, response) = try await foregroundSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                await handleError("Invalid response")
                return
            }

            if httpResponse.statusCode == 204 {
                if let offsetStr = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
                   let offset = Int64(offsetStr) {
                    await MainActor.run {
                        currentOffset = offset
                        bytesUploaded = offset
                        updateProgress()
                        state = .uploading
                        connectionInfo = "Resumed from offset \(offset)"
                    }
                    persistState()
                    await uploadNextChunk()
                } else {
                    await handleError("No offset in HEAD response")
                }
            } else if httpResponse.statusCode == 404 {
                // Upload expired on server - restart
                await MainActor.run {
                    self.resumptionURL = nil
                    self.currentOffset = 0
                    self.bytesUploaded = 0
                    self.progress = 0
                }
                clearPersistedState()
                await handleError("Upload expired on server. Please restart.")
            } else {
                await handleError("HEAD returned \(httpResponse.statusCode)")
            }
        } catch {
            await handleError("Resume failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Chunk File Management

    private func createChunkFile(from sourceURL: URL, offset: Int64, length: Int64) -> URL? {
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { handle.closeFile() }

            handle.seek(toFileOffset: UInt64(offset))
            let data = handle.readData(ofLength: Int(length))

            let chunkDir = FileManager.default.temporaryDirectory.appendingPathComponent("upload_chunks")
            try FileManager.default.createDirectory(at: chunkDir, withIntermediateDirectories: true)

            let chunkURL = chunkDir.appendingPathComponent("chunk_\(offset).bin")
            try data.write(to: chunkURL)
            return chunkURL
        } catch {
            print("Failed to create chunk file: \(error)")
            return nil
        }
    }

    private func cleanupChunkFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - State Persistence

    private struct PersistedUploadState: Codable {
        var resumptionURL: String
        var serverURL: String
        var filePath: String?
        var totalBytes: Int64
        var currentOffset: Int64
        var chunkSize: Int
    }

    private func persistState() {
        guard let resumptionURL else { return }
        let state = PersistedUploadState(
            resumptionURL: resumptionURL,
            serverURL: serverURL,
            filePath: fileURL?.path,
            totalBytes: totalBytes ?? 0,
            currentOffset: currentOffset,
            chunkSize: chunkSize
        )
        if let data = try? JSONEncoder().encode(state) {
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

    // MARK: - Completion

    private func completeUpload() async {
        await MainActor.run {
            state = .completed
            progress = 1.0
            connectionInfo = "Upload complete"
            stopSpeedTracking()
            clearPersistedState()

            if let start = uploadStartTime {
                let elapsed = Date().timeIntervalSince(start)
                let totalMB = Double(totalBytes ?? 0) / 1_048_576
                speedDisplay = String(format: "Avg: %.1f MB/s (%.1fs)", totalMB / elapsed, elapsed)
            }
        }

        // Clean up chunk files
        let chunkDir = FileManager.default.temporaryDirectory.appendingPathComponent("upload_chunks")
        try? FileManager.default.removeItem(at: chunkDir)
    }

    private func handleError(_ message: String) async {
        await MainActor.run {
            state = .failed
            errorMessage = message
            connectionInfo = "Error"
            stopSpeedTracking()
        }
    }
}

// MARK: - URLSession Delegate

extension UploadManager: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            // Parse task description for chunk metadata
            guard let desc = task.taskDescription else { return }
            let parts = desc.split(separator: ":")
            guard parts.count >= 4 else { return }

            let chunkOffset = Int64(parts[0]) ?? 0
            let chunkSize = Int64(parts[1]) ?? 0
            let isLastChunk = parts[2] == "1"
            let chunkFilePath = String(parts[3...].joined(separator: ":"))

            // Clean up chunk file
            cleanupChunkFile(at: chunkFilePath)

            if let error {
                if (error as NSError).code == NSURLErrorCancelled {
                    // Intentional cancellation (pause or cancel) - don't treat as error
                    return
                }
                errorMessage = "Upload error: \(error.localizedDescription)"
                state = .failed
                connectionInfo = "Connection lost"
                stopSpeedTracking()
                return
            }

            // Check HTTP response
            guard let httpResponse = task.response as? HTTPURLResponse else {
                await handleError("Invalid server response")
                return
            }

            let statusCode = httpResponse.statusCode

            if statusCode == 409 {
                // Conflict - offset mismatch, query server and retry
                connectionInfo = "Offset conflict, re-syncing..."
                await queryOffsetAndResume()
                return
            }

            guard (200...299).contains(statusCode) else {
                await handleError("Server returned \(statusCode)")
                return
            }

            // Update offset from response or from our calculation
            if let serverOffsetStr = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
               let serverOffset = Int64(serverOffsetStr) {
                currentOffset = serverOffset
            } else {
                currentOffset = chunkOffset + chunkSize
            }

            bytesUploaded = currentOffset
            updateProgress()
            persistState()

            if isLastChunk || (totalBytes != nil && currentOffset >= totalBytes!) {
                await completeUpload()
            } else if !isPaused {
                await uploadNextChunk()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { @MainActor in
            // Update bytes uploaded with partial progress within current chunk
            guard let desc = task.taskDescription else { return }
            let parts = desc.split(separator: ":")
            guard parts.count >= 1, let chunkOffset = Int64(parts[0]) else { return }

            bytesUploaded = chunkOffset + totalBytesSent
            updateProgress()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
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
