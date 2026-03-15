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
/// 2. PATCH chunks to resumption URL
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
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    private static let stateKey = "ResumableUploadState"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

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

        state = .creatingUpload
        connectionInfo = "Connecting..."
        uploadStartTime = Date()
        startSpeedTracking()
        beginBackgroundTask()

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
        endBackgroundTask()
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
        beginBackgroundTask()

        Task {
            await queryOffsetAndResume()
        }
    }

    func cancel() {
        guard state == .uploading || state == .paused || state == .resuming else { return }
        isCancelled = true
        isPaused = false

        // Send DELETE to cancel server-side
        if let url = buildResumptionURL() {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("3", forHTTPHeaderField: "Upload-Draft-Interop-Version")
            session.dataTask(with: request).resume()
        }

        state = .cancelled
        connectionInfo = "Cancelled"
        stopSpeedTracking()
        endBackgroundTask()
        clearPersistedState()
        print("[UploadManager] Cancelled")
    }

    // MARK: - Background Session Reconnection

    func reconnectBackgroundSession() {
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
                state = .paused
                connectionInfo = "Restored from previous session (offset \(currentOffset))"
                print("[UploadManager] Restored state: offset=\(currentOffset), path=\(saved.resumptionPath)")
            } else {
                clearPersistedState()
            }
        }
    }

    // MARK: - URL Building

    /// Build the full resumption URL from the server URL + resumption path.
    /// This avoids origin mismatch when server is behind ngrok/proxy.
    private func buildResumptionURL() -> URL? {
        guard let resumptionPath else { return nil }
        guard var components = URLComponents(string: serverURL) else { return nil }
        components.path = resumptionPath
        return components.url
    }

    // MARK: - Upload Protocol Implementation

    /// Step 1: POST to create upload session and get resumption URL
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
            let (_, response) = try await session.data(for: request)

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

            // Extract just the path from the Location URL to avoid origin mismatch
            // Server returns e.g. http://localhost:8080/resumable_upload/token
            // We only need /resumable_upload/token and will combine with our serverURL
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

            await uploadNextChunk()
        } catch {
            await setError("Connection failed: \(error.localizedDescription)")
        }
    }

    /// Step 2: PATCH chunks to resumption URL
    private func uploadNextChunk() async {
        guard let fileURL else {
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
            await completeUpload()
            return
        }

        guard let patchURL = buildResumptionURL() else {
            await setError("Cannot build resumption URL")
            return
        }

        let remaining = total - currentOffset
        let thisChunkSize = min(Int64(chunkSize), remaining)
        let isLastChunk = (currentOffset + thisChunkSize) >= total

        print("[UploadManager] Uploading chunk: offset=\(currentOffset), size=\(thisChunkSize), isLast=\(isLastChunk)")
        connectionInfo = "Uploading \(formatBytes(currentOffset))/\(formatBytes(total))..."

        // Read chunk data from file
        guard let chunkData = readChunk(from: fileURL, offset: currentOffset, length: thisChunkSize) else {
            await setError("Failed to read file chunk at offset \(currentOffset)")
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
        request.httpBody = chunkData

        do {
            let (_, response) = try await session.data(for: request)

            guard !isPaused, !isCancelled else { return }

            guard let httpResponse = response as? HTTPURLResponse else {
                await setError("Invalid server response for PATCH")
                return
            }

            let statusCode = httpResponse.statusCode
            print("[UploadManager] PATCH response: \(statusCode)")

            if statusCode == 409 {
                connectionInfo = "Offset conflict, re-syncing..."
                print("[UploadManager] 409 Conflict, querying offset")
                await queryOffsetAndResume()
                return
            }

            guard (200...299).contains(statusCode) else {
                await setError("PATCH returned \(statusCode)")
                return
            }

            // Update offset from server response or our calculation
            if let serverOffsetStr = httpResponse.value(forHTTPHeaderField: "Upload-Offset"),
               let serverOffset = Int64(serverOffsetStr) {
                currentOffset = serverOffset
            } else {
                currentOffset += thisChunkSize
            }

            bytesUploaded = currentOffset
            updateProgress()
            persistState()

            print("[UploadManager] Chunk done, offset now: \(currentOffset)")

            if isLastChunk || currentOffset >= total {
                await completeUpload()
            } else {
                await uploadNextChunk()
            }
        } catch {
            if isPaused || isCancelled { return }
            await setError("PATCH failed: \(error.localizedDescription)")
        }
    }

    /// Step 3: HEAD to check server offset for resumption
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
            let (_, response) = try await session.data(for: request)
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
                    await uploadNextChunk()
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

    // MARK: - Background Task

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in
                self?.handleBackgroundExpiry()
            }
        }
        print("[UploadManager] Background task started: \(backgroundTaskID)")
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        print("[UploadManager] Background task ended: \(backgroundTaskID)")
        backgroundTaskID = .invalid
    }

    private func handleBackgroundExpiry() {
        print("[UploadManager] Background time expiring, pausing upload")
        if state == .uploading {
            pause()
        }
        endBackgroundTask()
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

    private func completeUpload() async {
        state = .completed
        progress = 1.0
        connectionInfo = "Upload complete"
        stopSpeedTracking()
        endBackgroundTask()
        clearPersistedState()

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
        endBackgroundTask()
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
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        Task { @MainActor in
            // Only update for PATCH tasks (not the initial POST)
            guard task.originalRequest?.httpMethod == "PATCH" else { return }
            bytesUploaded = currentOffset + totalBytesSent
            updateProgress()
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
