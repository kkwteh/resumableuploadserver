import Foundation
import UIKit

@MainActor
final class UploadStore: NSObject, ObservableObject {
    static let shared = UploadStore()
    static let backgroundSessionIdentifier = "com.kevinteh.resumableuploadapp.background-uploads"

    @Published private(set) var uploads: [UploadRecord] = []
    @Published var messageBanner: String?
    @Published var isImporting = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private let manifestURL: URL
    private let stagedVideoDirectoryURL: URL
    private let resumeDataDirectoryURL: URL
    private let resumeChunkDirectoryURL: URL

    private static let draftInteropVersion = "6"

    private var backgroundCompletionHandler: (() -> Void)?
    private var didReceiveBackgroundSessionFinishEvents = false
    private var inFlightRecoveryOperations = 0
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60 * 60 * 24
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        let baseDirectory = Self.applicationSupportDirectory()
        manifestURL = baseDirectory.appendingPathComponent("uploads.json")
        stagedVideoDirectoryURL = baseDirectory.appendingPathComponent("staged-videos", isDirectory: true)
        resumeDataDirectoryURL = baseDirectory.appendingPathComponent("resume-data", isDirectory: true)
        resumeChunkDirectoryURL = baseDirectory.appendingPathComponent("resume-chunks", isDirectory: true)

        super.init()

        createDirectoriesIfNeeded()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        loadPersistedState()

        Task {
            await restoreTasksAndRestartQueuedUploads()
        }
    }

    func captureBackgroundSessionCompletionHandler(_ completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        print("[UploadStore] Captured background session completion handler")
        finishBackgroundEventsIfNeeded()
    }

    func importPickedVideo(
        from sourceURL: URL,
        suggestedFileName: String,
        endpointString: String,
        authToken: String
    ) async {
        guard let endpointURL = sanitizedEndpoint(from: endpointString) else {
            messageBanner = "Enter a valid upload URL before selecting a video."
            return
        }

        isImporting = true

        do {
            let stagedVideoDirectoryURL = self.stagedVideoDirectoryURL
            let stagedVideo = try await Task.detached(priority: .userInitiated) {
                try Self.stageVideo(
                    from: sourceURL,
                    suggestedFileName: suggestedFileName,
                    destinationDirectory: stagedVideoDirectoryURL
                )
            }.value

            let record = UploadRecord(
                id: UUID(),
                createdAt: .now,
                fileName: stagedVideo.fileName,
                endpoint: endpointURL.absoluteString,
                authToken: authToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                localFilePath: stagedVideo.url.path,
                fileSize: stagedVideo.fileSize,
                state: .queued,
                taskIdentifier: nil,
                bytesSent: 0,
                expectedBytes: stagedVideo.fileSize,
                responseStatusCode: nil,
                errorDescription: nil,
                resumeDataFileName: nil,
                resumableUploadURL: nil,
                lastUpdatedAt: .now
            )

            uploads.insert(record, at: 0)
            persistState()
            startUpload(for: record.id)
        } catch {
            messageBanner = error.localizedDescription
        }

        isImporting = false
    }

    func pauseUpload(id: UUID) {
        guard let record = upload(with: id) else { return }

        Task {
            guard let task = await task(for: record.id) as? URLSessionUploadTask else {
                updateUpload(id: record.id) { upload in
                    upload.state = .paused
                    upload.taskIdentifier = nil
                    upload.lastUpdatedAt = .now
                }
                return
            }

            task.cancel(byProducingResumeData: { resumeData in
                Task { @MainActor in
                    if let resumeData, resumeData.isEmpty == false {
                        do {
                            self.logResumeData(resumeData, context: "manual-pause")
                            let fileName = try self.writeResumeData(resumeData, for: record.id)
                            self.updateUpload(id: record.id) { upload in
                                upload.state = .paused
                                upload.taskIdentifier = nil
                                upload.resumeDataFileName = fileName
                                upload.errorDescription = nil
                                upload.lastUpdatedAt = .now
                            }
                        } catch {
                            self.updateUpload(id: record.id) { upload in
                                upload.state = .failed
                                upload.taskIdentifier = nil
                                upload.errorDescription = error.localizedDescription
                                upload.lastUpdatedAt = .now
                            }
                        }
                    } else {
                        self.updateUpload(id: record.id) { upload in
                            upload.state = .failed
                            upload.taskIdentifier = nil
                            upload.errorDescription = "Pause failed because the server did not provide resumable upload data."
                            upload.lastUpdatedAt = .now
                        }
                    }
                }
            })
        }
    }

    func resumeUpload(id: UUID) {
        startUpload(for: id)
    }

    func cancelUpload(id: UUID) {
        Task {
            let task = await task(for: id)
            task?.cancel()

            do {
                try removeResumeData(for: id)
                try removeResumeChunk(for: id)
                try removeLocalFile(for: id)
            } catch {
                messageBanner = error.localizedDescription
            }

            updateUpload(id: id) { upload in
                upload.state = .canceled
                upload.taskIdentifier = nil
                upload.resumeDataFileName = nil
                upload.resumableUploadURL = nil
                upload.localFilePath = nil
                upload.errorDescription = nil
                upload.lastUpdatedAt = .now
            }
        }
    }

    private func startUpload(for id: UUID) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }

        guard let endpointURL = URL(string: uploads[index].endpoint) else {
            updateUpload(id: id) { upload in
                upload.state = .failed
                upload.errorDescription = "The configured endpoint URL is invalid."
                upload.lastUpdatedAt = .now
            }
            return
        }

        let uploadTask: URLSessionUploadTask
        let isResumingFromNativeResumeData: Bool

        if let resumeData = try? readResumeData(for: id) {
            uploadTask = session.uploadTask(withResumeData: resumeData)
            isResumingFromNativeResumeData = true
        } else if let localFilePath = uploads[index].localFilePath {
            let fileURL = URL(fileURLWithPath: localFilePath)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                updateUpload(id: id) { upload in
                    upload.state = .failed
                    upload.errorDescription = "The staged video is no longer available."
                    upload.lastUpdatedAt = .now
                }
                return
            }

            var request = URLRequest(url: endpointURL)
            request.httpMethod = "POST"
            request.timeoutInterval = 60 * 60 * 24
            request.allowsCellularAccess = true
            request.allowsConstrainedNetworkAccess = true
            request.allowsExpensiveNetworkAccess = true
            request.networkServiceType = .responsiveData
            request.setValue(Self.draftInteropVersion, forHTTPHeaderField: "Upload-Draft-Interop-Version")
            request.setValue("?1", forHTTPHeaderField: "Upload-Complete")
            request.setValue(contentType(for: fileURL), forHTTPHeaderField: "Content-Type")
            request.setValue(uploads[index].fileName, forHTTPHeaderField: "X-Upload-Filename")
            if let authToken = uploads[index].authToken, authToken.isEmpty == false {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }

            uploadTask = session.uploadTask(with: request, fromFile: fileURL)
            isResumingFromNativeResumeData = false
        } else {
            updateUpload(id: id) { upload in
                upload.state = .failed
                upload.errorDescription = "The staged video is no longer available."
                upload.lastUpdatedAt = .now
            }
            return
        }

        let baseOffset: Int64
        if isResumingFromNativeResumeData {
            baseOffset = uploads[index].bytesSent
        } else {
            baseOffset = 0
        }

        uploadTask.taskDescription = Self.taskDescription(for: id, baseOffset: baseOffset)
        uploadTask.priority = URLSessionTask.highPriority
        uploadTask.resume()

        updateUpload(id: id) { upload in
            upload.state = .uploading
            upload.taskIdentifier = uploadTask.taskIdentifier
            upload.errorDescription = nil
            upload.responseStatusCode = nil
            if isResumingFromNativeResumeData == false {
                upload.bytesSent = 0
                upload.resumableUploadURL = nil
            }
            upload.lastUpdatedAt = .now
        }

        try? removeResumeData(for: id)
    }

    private func restoreTasksAndRestartQueuedUploads() async {
        let tasks = await allTasks()
        var liveUploadIDs = Set<UUID>()

        for task in tasks {
            guard let id = Self.uploadID(from: task.taskDescription) else { continue }
            liveUploadIDs.insert(id)
            let taskBaseOffset = Self.taskBaseOffset(from: task.taskDescription) ?? 0

            updateUpload(id: id) { upload in
                upload.taskIdentifier = task.taskIdentifier
                upload.bytesSent = max(upload.bytesSent, taskBaseOffset + task.countOfBytesSent)
                if task.countOfBytesExpectedToSend > 0 {
                    upload.expectedBytes = max(upload.expectedBytes, taskBaseOffset + task.countOfBytesExpectedToSend)
                }
                upload.lastUpdatedAt = .now

                switch task.state {
                case .running:
                    upload.state = .uploading
                case .suspended:
                    upload.state = .paused
                case .canceling:
                    break
                case .completed:
                    break
                @unknown default:
                    break
                }
            }
        }

        for upload in uploads where !liveUploadIDs.contains(upload.id) {
            let shouldAutoRestart = upload.state == .queued
                || ((upload.state == .uploading || upload.state == .failed) && upload.resumeDataFileName != nil)

            if shouldAutoRestart {
                startUpload(for: upload.id)
            }
        }
    }

    private func upload(with id: UUID) -> UploadRecord? {
        uploads.first(where: { $0.id == id })
    }

    private func updateUpload(id: UUID, mutation: (inout UploadRecord) -> Void) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        mutation(&uploads[index])
        persistState()
    }

    private func loadPersistedState() {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            uploads = []
            return
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            uploads = try decoder.decode([UploadRecord].self, from: data)
                .sorted(by: { $0.createdAt > $1.createdAt })
        } catch {
            uploads = []
            messageBanner = "Failed to restore previous uploads: \(error.localizedDescription)"
        }
    }

    private func persistState() {
        do {
            let data = try encoder.encode(uploads)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            messageBanner = "Failed to save upload state: \(error.localizedDescription)"
        }
    }

    private func createDirectoriesIfNeeded() {
        try? fileManager.createDirectory(at: stagedVideoDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resumeDataDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: resumeChunkDirectoryURL, withIntermediateDirectories: true)
    }

    private func writeResumeData(_ data: Data, for id: UUID) throws -> String {
        let fileName = "\(id.uuidString).resume"
        let destinationURL = resumeDataDirectoryURL.appendingPathComponent(fileName)
        try data.write(to: destinationURL, options: .atomic)
        return fileName
    }

    private func readResumeData(for id: UUID) throws -> Data? {
        guard let record = upload(with: id), let fileName = record.resumeDataFileName else {
            return nil
        }

        let fileURL = resumeDataDirectoryURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try Data(contentsOf: fileURL)
    }

    private func removeResumeData(for id: UUID) throws {
        guard let record = upload(with: id), let fileName = record.resumeDataFileName else { return }
        let fileURL = resumeDataDirectoryURL.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func removeLocalFile(for id: UUID) throws {
        guard let record = upload(with: id), let localFilePath = record.localFilePath else { return }
        let fileURL = URL(fileURLWithPath: localFilePath)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func removeResumeChunk(for id: UUID) throws {
        let fileURL = resumeChunkDirectoryURL.appendingPathComponent("\(id.uuidString).partial")
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func parseStructuredFieldBoolean(_ value: String?) -> Bool? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
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

    private func parseUploadComplete(from response: HTTPURLResponse) -> Bool? {
        if let isComplete = parseStructuredFieldBoolean(response.value(forHTTPHeaderField: "Upload-Complete")) {
            return isComplete
        }

        // Accept the pre-v6 header for compatibility with older servers.
        if let isIncomplete = parseStructuredFieldBoolean(response.value(forHTTPHeaderField: "Upload-Incomplete")) {
            return isIncomplete == false
        }

        return nil
    }

    private func logResumeData(_ data: Data, context: String) {
        print("[UploadStore] Resume data received context=\(context) bytes=\(data.count)")

        let hexPrefix = data.prefix(64).map { String(format: "%02x", $0) }.joined()
        print("[UploadStore] Resume data hex prefix context=\(context) hex=\(hexPrefix)")

        do {
            let propertyList = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            print("[UploadStore] Resume data plist context=\(context) value=\(Self.describePropertyList(propertyList))")
        } catch {
            print("[UploadStore] Resume data plist decode failed context=\(context) error=\(error.localizedDescription)")
        }
    }

    private static func describePropertyList(_ value: Any, indent: String = "") -> String {
        if let dictionary = value as? [String: Any] {
            let lines = dictionary.keys.sorted().map { key in
                let child = dictionary[key] ?? NSNull()
                return "\(indent)\(key): \(describePropertyList(child, indent: indent + "  "))"
            }
            return "{\n" + lines.joined(separator: "\n") + "\n\(indent)}"
        }

        if let array = value as? [Any] {
            let lines = array.enumerated().map { index, child in
                "\(indent)[\(index)]: \(describePropertyList(child, indent: indent + "  "))"
            }
            return "[\n" + lines.joined(separator: "\n") + "\n\(indent)]"
        }

        if let data = value as? Data {
            let hexPrefix = data.prefix(32).map { String(format: "%02x", $0) }.joined()
            return "Data(bytes=\(data.count), hexPrefix=\(hexPrefix))"
        }

        if let url = value as? URL {
            return url.absoluteString
        }

        return String(describing: value)
    }

    private enum CompletionVerificationResult {
        case success(verifiedOffset: Int64?)
        case resumeRequired(serverOffset: Int64, message: String)
        case failure(message: String)
    }

    private enum CompletionVerificationAttemptResult {
        case success(verifiedOffset: Int64?)
        case resumeRequired(serverOffset: Int64, message: String)
        case retryable(message: String)
        case failure(message: String)
    }

    private func classifyCompletionVerificationResponse(_ response: HTTPURLResponse, expectedBytes: Int64) -> CompletionVerificationAttemptResult {
        let offset = response.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
        let isComplete = parseUploadComplete(from: response)
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let ngrokErrorCode = response.value(forHTTPHeaderField: "ngrok-error-code")

        if let ngrokErrorCode {
            return .retryable(message: "Verification hit transient ngrok error \(ngrokErrorCode).")
        }

        if response.statusCode == 404, contentType?.contains("text/html") == true {
            return .retryable(message: "Verification hit a transient HTML 404 response.")
        }

        if [404, 408, 409, 425, 429, 502, 503, 504].contains(response.statusCode) {
            return .retryable(message: "Verification returned transient HTTP \(response.statusCode).")
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            return .failure(message: "Completion verification HEAD returned HTTP \(response.statusCode).")
        }

        if expectedBytes > 0, let offset {
            if offset == expectedBytes {
                return .success(verifiedOffset: offset)
            }

            if offset < expectedBytes {
                return .resumeRequired(
                    serverOffset: offset,
                    message: "Server currently acknowledges only \(offset) of \(expectedBytes) bytes."
                )
            }

            return .failure(message: "Server reported \(offset) bytes for an upload expected to be \(expectedBytes) bytes.")
        }

        if isComplete == false {
            return .retryable(message: "Server still reports the upload as incomplete.")
        }

        return .retryable(message: "Server did not provide an Upload-Offset during completion verification.")
    }

    private func shouldAttemptCompletionVerification(for response: HTTPURLResponse) -> Bool {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let ngrokErrorCode = response.value(forHTTPHeaderField: "ngrok-error-code")
        let hasResumableHeaders = response.value(forHTTPHeaderField: "Upload-Offset") != nil
            || response.value(forHTTPHeaderField: "Upload-Complete") != nil
            || response.value(forHTTPHeaderField: "Upload-Incomplete") != nil

        if (200 ..< 300).contains(response.statusCode) {
            return true
        }

        if ngrokErrorCode != nil {
            return true
        }

        if [404, 408, 409, 425, 429, 502, 503, 504].contains(response.statusCode) {
            return true
        }

        if contentType?.contains("text/html") == true {
            return true
        }

        return hasResumableHeaders
    }

    private func verifyCompletion(for id: UUID, response: HTTPURLResponse) async -> CompletionVerificationResult {
        let responseOffset = response.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
        let responseIsComplete = parseUploadComplete(from: response)
        let expectedBytes = upload(with: id)?.expectedBytes ?? 0

        print(
            "[UploadStore] Verifying completion",
            "uploadID=\(id.uuidString)",
            "status=\(response.statusCode)",
            "responseOffset=\(String(describing: responseOffset))",
            "responseComplete=\(String(describing: responseIsComplete))",
            "expectedBytes=\(expectedBytes)",
            "headers=\(response.allHeaderFields)"
        )

        if responseIsComplete == false {
            if let responseOffset, expectedBytes > 0, responseOffset < expectedBytes {
                return .resumeRequired(
                    serverOffset: responseOffset,
                    message: "Final response reported the upload incomplete at offset \(responseOffset)."
                )
            }

            return .failure(message: "Server reported the upload is incomplete.")
        }

        if expectedBytes > 0, let responseOffset {
            if responseOffset == expectedBytes {
                return .success(verifiedOffset: responseOffset)
            }

            if responseOffset < expectedBytes {
                return .resumeRequired(
                    serverOffset: responseOffset,
                    message: "Final response acknowledged only \(responseOffset) of \(expectedBytes) bytes."
                )
            }

            return .failure(message: "Server acknowledged an invalid offset of \(responseOffset) bytes.")
        }

        guard let record = upload(with: id),
              let resumableUploadURLString = record.resumableUploadURL,
              let resumableUploadURL = URL(string: resumableUploadURLString)
        else {
            return .failure(message: "Server completion could not be verified because the resumable upload URL is unavailable.")
        }

        print(
            "[UploadStore] Starting HEAD verification loop",
            "uploadID=\(id.uuidString)",
            "resumableUploadURL=\(resumableUploadURL.absoluteString)",
            "expectedBytes=\(expectedBytes)"
        )

        var request = URLRequest(url: resumableUploadURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 60
        request.setValue(Self.draftInteropVersion, forHTTPHeaderField: "Upload-Draft-Interop-Version")
        if let authToken = record.authToken, authToken.isEmpty == false {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let retryDelaysInSeconds: [UInt64] = [0, 1, 2, 4, 8, 16, 30]
        var lastRetryableMessage = "Server completion could not yet be verified."

        for (attemptIndex, delayInSeconds) in retryDelaysInSeconds.enumerated() {
            if delayInSeconds > 0 {
                print(
                    "[UploadStore] Waiting before HEAD verification retry",
                    "uploadID=\(id.uuidString)",
                    "attempt=\(attemptIndex + 1)",
                    "delaySeconds=\(delayInSeconds)"
                )
                try? await Task.sleep(nanoseconds: delayInSeconds * 1_000_000_000)
            }

            print(
                "[UploadStore] Sending HEAD verification request",
                "uploadID=\(id.uuidString)",
                "attempt=\(attemptIndex + 1)",
                "url=\(resumableUploadURL.absoluteString)",
                "headers=\(request.allHTTPHeaderFields ?? [:])"
            )

            do {
                let (_, headResponse) = try await URLSession.shared.data(for: request)
                guard let httpHeadResponse = headResponse as? HTTPURLResponse else {
                    lastRetryableMessage = "Server returned an invalid HEAD response during completion verification."
                    continue
                }

                let headOffset = httpHeadResponse.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
                let headIsComplete = parseUploadComplete(from: httpHeadResponse)

                print(
                    "[UploadStore] HEAD verification response",
                    "uploadID=\(id.uuidString)",
                    "attempt=\(attemptIndex + 1)",
                    "status=\(httpHeadResponse.statusCode)",
                    "offset=\(String(describing: headOffset))",
                    "complete=\(String(describing: headIsComplete))",
                    "headers=\(httpHeadResponse.allHeaderFields)"
                )

                switch classifyCompletionVerificationResponse(httpHeadResponse, expectedBytes: expectedBytes) {
                case .success(let verifiedOffset):
                    return .success(verifiedOffset: verifiedOffset)
                case .resumeRequired(let serverOffset, let message):
                    print(
                        "[UploadStore] Completion verification found incomplete upload",
                        "uploadID=\(id.uuidString)",
                        "attempt=\(attemptIndex + 1)",
                        "serverOffset=\(serverOffset)",
                        "message=\(message)"
                    )
                    return .resumeRequired(serverOffset: serverOffset, message: message)
                case .retryable(let message):
                    lastRetryableMessage = message
                    print("[UploadStore] Completion verification will retry uploadID=\(id.uuidString) reason=\(message)")
                case .failure(let message):
                    return .failure(message: message)
                }
            } catch {
                lastRetryableMessage = "Completion verification failed: \(error.localizedDescription)"
                print(
                    "[UploadStore] HEAD verification failed",
                    "uploadID=\(id.uuidString)",
                    "attempt=\(attemptIndex + 1)",
                    "error=\(error.localizedDescription)"
                )
            }
        }

        return .failure(message: lastRetryableMessage)
    }

    private enum ResumeLaunchResult {
        case started
        case failure(message: String)
    }

    private func resumeIncompleteUpload(for id: UUID, serverOffset: Int64) async -> ResumeLaunchResult {
        guard let record = upload(with: id) else {
            return .failure(message: "Upload record was unavailable while attempting to resume.")
        }

        guard let resumableUploadURLString = record.resumableUploadURL,
              let resumableUploadURL = URL(string: resumableUploadURLString)
        else {
            return .failure(message: "Cannot resume because the resumable upload URL is unavailable.")
        }

        guard let localFilePath = record.localFilePath else {
            return .failure(message: "Cannot resume because the staged video is unavailable.")
        }

        let localFileURL = URL(fileURLWithPath: localFilePath)
        guard fileManager.fileExists(atPath: localFileURL.path) else {
            return .failure(message: "Cannot resume because the staged video no longer exists.")
        }

        let expectedBytes = record.expectedBytes > 0 ? record.expectedBytes : record.fileSize
        guard serverOffset >= 0 else {
            return .failure(message: "Cannot resume because the server reported a negative upload offset.")
        }

        guard serverOffset < expectedBytes else {
            return .failure(message: "Resume was requested even though the server offset \(serverOffset) is not shorter than the expected upload size \(expectedBytes).")
        }

        let partialFileURL = resumeChunkDirectoryURL.appendingPathComponent("\(id.uuidString).partial")

        print(
            "[UploadStore] Starting draft resume upload",
            "uploadID=\(id.uuidString)",
            "resumableUploadURL=\(resumableUploadURL.absoluteString)",
            "serverOffset=\(serverOffset)",
            "expectedBytes=\(expectedBytes)",
            "sourceFile=\(localFileURL.path)",
            "partialFile=\(partialFileURL.path)"
        )

        do {
            try removeResumeChunk(for: id)
        } catch {
            print(
                "[UploadStore] Failed to remove stale resume chunk",
                "uploadID=\(id.uuidString)",
                "error=\(error.localizedDescription)"
            )
        }

        let remainingBytes: Int64
        do {
            let resumeChunkDirectoryURL = self.resumeChunkDirectoryURL
            remainingBytes = try await Task.detached(priority: .userInitiated) {
                try Self.createResumeChunk(
                    sourceFileURL: localFileURL,
                    startingAt: serverOffset,
                    destinationFileURL: partialFileURL,
                    parentDirectoryURL: resumeChunkDirectoryURL
                )
            }.value
        } catch {
            return .failure(message: "Failed to prepare the remaining upload chunk: \(error.localizedDescription)")
        }

        guard remainingBytes > 0 else {
            return .failure(message: "The server offset \(serverOffset) leaves no bytes available to resume.")
        }

        var request = URLRequest(url: resumableUploadURL)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 60 * 60 * 24
        request.allowsCellularAccess = true
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.networkServiceType = .responsiveData
        request.setValue(Self.draftInteropVersion, forHTTPHeaderField: "Upload-Draft-Interop-Version")
        request.setValue(String(serverOffset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("?1", forHTTPHeaderField: "Upload-Complete")
        if let authToken = record.authToken, authToken.isEmpty == false {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        print(
            "[UploadStore] Resume PATCH request prepared",
            "uploadID=\(id.uuidString)",
            "headers=\(request.allHTTPHeaderFields ?? [:])",
            "remainingBytes=\(remainingBytes)"
        )

        let uploadTask = session.uploadTask(with: request, fromFile: partialFileURL)
        uploadTask.taskDescription = Self.taskDescription(for: id, baseOffset: serverOffset)
        uploadTask.priority = URLSessionTask.highPriority
        uploadTask.resume()

        do {
            try removeResumeData(for: id)
        } catch {
            print(
                "[UploadStore] Failed to remove stale native resume data before manual resume",
                "uploadID=\(id.uuidString)",
                "error=\(error.localizedDescription)"
            )
        }

        updateUpload(id: id) { upload in
            upload.state = .uploading
            upload.taskIdentifier = uploadTask.taskIdentifier
            upload.bytesSent = max(upload.bytesSent, serverOffset)
            upload.expectedBytes = expectedBytes
            upload.responseStatusCode = nil
            upload.errorDescription = nil
            upload.resumeDataFileName = nil
            upload.lastUpdatedAt = .now
        }

        print(
            "[UploadStore] Draft resume upload started",
            "uploadID=\(id.uuidString)",
            "taskIdentifier=\(uploadTask.taskIdentifier)",
            "taskDescription=\(uploadTask.taskDescription ?? "")"
        )

        return .started
    }

    private func persistResumeDataAndRestart(_ data: Data, for id: UUID) {
        do {
            logResumeData(data, context: "automatic-restart")
            let fileName = try writeResumeData(data, for: id)
            updateUpload(id: id) { upload in
                upload.state = .queued
                upload.taskIdentifier = nil
                upload.resumeDataFileName = fileName
                upload.errorDescription = nil
                upload.responseStatusCode = nil
                upload.lastUpdatedAt = .now
            }
            startUpload(for: id)
        } catch {
            updateUpload(id: id) { upload in
                upload.state = .failed
                upload.taskIdentifier = nil
                upload.errorDescription = "Upload was interrupted and resume data could not be saved: \(error.localizedDescription)"
                upload.lastUpdatedAt = .now
            }
        }
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks)
            }
        }
    }

    private func task(for id: UUID) async -> URLSessionTask? {
        let tasks = await allTasks()
        return tasks.first(where: { Self.uploadID(from: $0.taskDescription) == id })
    }

    private nonisolated static func uploadID(from taskDescription: String?) -> UUID? {
        guard let taskDescription else { return nil }
        let components = taskDescription.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        return UUID(uuidString: String(components.first ?? ""))
    }

    private nonisolated static func taskBaseOffset(from taskDescription: String?) -> Int64? {
        guard let taskDescription else { return nil }
        let components = taskDescription.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        return Int64(components[1])
    }

    private nonisolated static func taskDescription(for id: UUID, baseOffset: Int64) -> String {
        "\(id.uuidString)|\(baseOffset)"
    }

    private nonisolated static func resolvedUploadURL(from locationHeader: String, relativeTo requestURL: URL?) -> URL? {
        if let absoluteURL = URL(string: locationHeader), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let requestURL else {
            return nil
        }

        return URL(string: locationHeader, relativeTo: requestURL)?.absoluteURL
    }

    private func finishBackgroundEventsIfNeeded() {
        guard didReceiveBackgroundSessionFinishEvents else {
            return
        }

        guard inFlightRecoveryOperations == 0 else {
            print(
                "[UploadStore] Deferring background session completion handler",
                "inFlightRecoveryOperations=\(inFlightRecoveryOperations)"
            )
            return
        }

        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        didReceiveBackgroundSessionFinishEvents = false
        print("[UploadStore] Invoking background session completion handler")
        completionHandler?()
    }

    private func beginRecoveryOperation(reason: String, uploadID: UUID) {
        inFlightRecoveryOperations += 1

        if backgroundTaskIdentifier == .invalid {
            backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "UploadRecovery") { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print(
                        "[UploadStore] Background task expired",
                        "inFlightRecoveryOperations=\(self.inFlightRecoveryOperations)"
                    )
                    self.endBackgroundTaskIfNeeded(force: true)
                }
            }

            print(
                "[UploadStore] Began UIApplication background task",
                "identifier=\(backgroundTaskIdentifier.rawValue)"
            )
        }

        print(
            "[UploadStore] Began recovery operation",
            "uploadID=\(uploadID.uuidString)",
            "reason=\(reason)",
            "inFlightRecoveryOperations=\(inFlightRecoveryOperations)"
        )
    }

    private func endRecoveryOperation(reason: String, uploadID: UUID) {
        inFlightRecoveryOperations = max(0, inFlightRecoveryOperations - 1)

        print(
            "[UploadStore] Ended recovery operation",
            "uploadID=\(uploadID.uuidString)",
            "reason=\(reason)",
            "inFlightRecoveryOperations=\(inFlightRecoveryOperations)"
        )

        if inFlightRecoveryOperations == 0 {
            endBackgroundTaskIfNeeded(force: false)
            finishBackgroundEventsIfNeeded()
        }
    }

    private func endBackgroundTaskIfNeeded(force: Bool) {
        guard backgroundTaskIdentifier != .invalid else {
            return
        }

        guard force || inFlightRecoveryOperations == 0 else {
            return
        }

        let identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)

        print(
            "[UploadStore] Ended UIApplication background task",
            "identifier=\(identifier.rawValue)",
            "force=\(force)"
        )
    }

    private func sanitizedEndpoint(from endpointString: String) -> URL? {
        guard let url = URL(string: endpointString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return nil
        }
        return url
    }

    private func contentType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return "application/octet-stream"
        }
    }

    private static func applicationSupportDirectory() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = baseURL.appendingPathComponent("ResumableUploadApp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func stageVideo(
        from sourceURL: URL,
        suggestedFileName: String,
        destinationDirectory: URL
    ) throws -> StagedVideo {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let sanitizedName = suggestedFileName.replacingOccurrences(of: "/", with: "-")
        let suggestedURL = URL(fileURLWithPath: sanitizedName)
        let extensionName = sourceURL.pathExtension.isEmpty ? suggestedURL.pathExtension : sourceURL.pathExtension
        let baseName = suggestedURL.deletingPathExtension().lastPathComponent
        let finalName = "\(UUID().uuidString)-\(baseName.isEmpty ? "video" : baseName).\(extensionName.isEmpty ? "mov" : extensionName)"
        let destinationURL = destinationDirectory.appendingPathComponent(finalName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        let size = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0

        return StagedVideo(url: destinationURL, fileName: sanitizedName.isEmpty ? destinationURL.lastPathComponent : sanitizedName, fileSize: size)
    }

    private nonisolated static func createResumeChunk(
        sourceFileURL: URL,
        startingAt offset: Int64,
        destinationFileURL: URL,
        parentDirectoryURL: URL
    ) throws -> Int64 {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: parentDirectoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destinationFileURL.path) {
            try fileManager.removeItem(at: destinationFileURL)
        }

        let fileSize = try sourceFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        guard offset >= 0, offset <= fileSize else {
            throw NSError(
                domain: "UploadStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create a resume chunk for offset \(offset) in a file of \(fileSize) bytes."]
            )
        }

        let remainingBytes = fileSize - offset
        guard remainingBytes > 0 else {
            let created = fileManager.createFile(atPath: destinationFileURL.path, contents: Data())
            if created == false {
                throw NSError(
                    domain: "UploadStore",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create an empty resume chunk file."]
                )
            }
            return 0
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceFileURL)
        let destinationCreated = fileManager.createFile(atPath: destinationFileURL.path, contents: nil)
        guard destinationCreated else {
            throw NSError(
                domain: "UploadStore",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create the resume chunk destination file."]
            )
        }
        let destinationHandle = try FileHandle(forWritingTo: destinationFileURL)

        defer {
            try? sourceHandle.close()
            try? destinationHandle.close()
        }

        try sourceHandle.seek(toOffset: UInt64(offset))

        let chunkSize = 1_048_576
        while true {
            let data = try sourceHandle.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty {
                break
            }
            try destinationHandle.write(contentsOf: data)
        }

        return remainingBytes
    }
}

private struct StagedVideo {
    let url: URL
    let fileName: String
    let fileSize: Int64
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension UploadStore: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.didReceiveBackgroundSessionFinishEvents = true
            print(
                "[UploadStore] Background URLSession finished delivering events",
                "inFlightRecoveryOperations=\(self.inFlightRecoveryOperations)"
            )
            self.finishBackgroundEventsIfNeeded()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let id = Self.uploadID(from: task.taskDescription) else { return }
        let taskBaseOffset = Self.taskBaseOffset(from: task.taskDescription) ?? 0

        Task { @MainActor in
            self.updateUpload(id: id) { upload in
                upload.bytesSent = max(upload.bytesSent, taskBaseOffset + totalBytesSent)
                if totalBytesExpectedToSend > 0 {
                    upload.expectedBytes = max(upload.expectedBytes, taskBaseOffset + totalBytesExpectedToSend)
                }
                upload.state = .uploading
                upload.lastUpdatedAt = .now
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceiveInformationalResponse response: HTTPURLResponse
    ) {
        guard response.statusCode == 104,
              let id = Self.uploadID(from: task.taskDescription)
        else {
            return
        }

        let offset = response.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
        let resumableUploadURL = response.value(forHTTPHeaderField: "Location").flatMap {
            Self.resolvedUploadURL(from: $0, relativeTo: task.currentRequest?.url ?? task.originalRequest?.url)
        }

        print(
            "[UploadStore] Received informational response",
            "uploadID=\(id.uuidString)",
            "status=\(response.statusCode)",
            "offset=\(String(describing: offset))",
            "location=\(String(describing: resumableUploadURL?.absoluteString))",
            "headers=\(response.allHeaderFields)"
        )

        Task { @MainActor in
            self.updateUpload(id: id) { upload in
                if let offset {
                    upload.bytesSent = max(upload.bytesSent, offset)
                }
                if let resumableUploadURL {
                    upload.resumableUploadURL = resumableUploadURL.absoluteString
                }
                upload.lastUpdatedAt = .now
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let id = Self.uploadID(from: task.taskDescription) else { return }

        Task { @MainActor in
            guard let existingUpload = self.upload(with: id) else { return }

            self.beginRecoveryOperation(reason: "didCompleteWithError", uploadID: id)
            defer {
                self.endRecoveryOperation(reason: "didCompleteWithError", uploadID: id)
            }

            if existingUpload.state == .paused || existingUpload.state == .canceled {
                return
            }

            if let error {
                if let urlError = error as? URLError,
                   let resumeData = urlError.uploadTaskResumeData,
                   resumeData.isEmpty == false {
                    self.persistResumeDataAndRestart(resumeData, for: id)
                    return
                }

                if let urlError = error as? URLError {
                    print("[UploadStore] Upload failed without resume data uploadID=\(id.uuidString) urlError=\(urlError)")
                } else {
                    print("[UploadStore] Upload failed without resume data uploadID=\(id.uuidString) error=\(error.localizedDescription)")
                }

                self.updateUpload(id: id) { upload in
                    upload.state = .failed
                    upload.taskIdentifier = nil
                    upload.errorDescription = error.localizedDescription
                    upload.lastUpdatedAt = .now
                }
                return
            }

            guard let response = task.response as? HTTPURLResponse else {
                print("[UploadStore] Upload finished without an HTTPURLResponse uploadID=\(id.uuidString)")
                self.updateUpload(id: id) { upload in
                    upload.state = .failed
                    upload.taskIdentifier = nil
                    upload.errorDescription = "Server completion could not be verified because the final HTTP response was unavailable."
                    upload.lastUpdatedAt = .now
                }
                return
            }

            let statusCode = response.statusCode
            let shouldAttemptVerification = self.shouldAttemptCompletionVerification(for: response)

            print(
                "[UploadStore] Final upload response",
                "uploadID=\(id.uuidString)",
                "status=\(statusCode)",
                "taskDescription=\(task.taskDescription ?? "")",
                "headers=\(response.allHeaderFields)",
                "willAttemptVerification=\(shouldAttemptVerification)"
            )

            if (200 ..< 300).contains(statusCode) == false && shouldAttemptVerification == false {
                self.updateUpload(id: id) { upload in
                    upload.state = .failed
                    upload.taskIdentifier = nil
                    upload.responseStatusCode = statusCode
                    upload.errorDescription = "Server responded with HTTP \(statusCode)."
                    upload.lastUpdatedAt = .now
                }
                return
            }

            if (200 ..< 300).contains(statusCode) == false {
                print(
                    "[UploadStore] Final response is non-success but retryable",
                    "uploadID=\(id.uuidString)",
                    "status=\(statusCode)"
                )
            }

            let verificationResult = await self.verifyCompletion(for: id, response: response)

            switch verificationResult {
            case .success(let verifiedOffset):
                do {
                    try self.removeResumeData(for: id)
                    try self.removeResumeChunk(for: id)
                    try self.removeLocalFile(for: id)
                } catch {
                    self.messageBanner = error.localizedDescription
                }

                self.updateUpload(id: id) { upload in
                    upload.state = .completed
                    upload.taskIdentifier = nil
                    upload.bytesSent = max(upload.bytesSent, verifiedOffset ?? upload.expectedBytes)
                    upload.responseStatusCode = statusCode
                    upload.errorDescription = nil
                    upload.resumeDataFileName = nil
                    upload.resumableUploadURL = nil
                    upload.localFilePath = nil
                    upload.lastUpdatedAt = .now
                }
            case .resumeRequired(let serverOffset, let message):
                print(
                    "[UploadStore] Completion verification will resume upload",
                    "uploadID=\(id.uuidString)",
                    "serverOffset=\(serverOffset)",
                    "message=\(message)"
                )

                let resumeResult = await self.resumeIncompleteUpload(for: id, serverOffset: serverOffset)
                if case .failure(let resumeMessage) = resumeResult {
                    print("[UploadStore] Resume launch failed uploadID=\(id.uuidString) message=\(resumeMessage)")
                    self.updateUpload(id: id) { upload in
                        upload.state = .failed
                        upload.taskIdentifier = nil
                        upload.responseStatusCode = statusCode
                        upload.errorDescription = resumeMessage
                        upload.lastUpdatedAt = .now
                    }
                }
            case .failure(let message):
                print("[UploadStore] Completion verification failed uploadID=\(id.uuidString) message=\(message)")
                self.updateUpload(id: id) { upload in
                    upload.state = .failed
                    upload.taskIdentifier = nil
                    upload.responseStatusCode = statusCode
                    upload.errorDescription = message
                    upload.lastUpdatedAt = .now
                }
            }
        }
    }
}
