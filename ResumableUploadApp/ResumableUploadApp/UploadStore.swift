import Foundation

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

    private var backgroundCompletionHandler: (() -> Void)?

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
                lastKnownServerOffset: nil,
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
                try removeLocalFile(for: id)
            } catch {
                messageBanner = error.localizedDescription
            }

            updateUpload(id: id) { upload in
                upload.state = .canceled
                upload.taskIdentifier = nil
                upload.resumeDataFileName = nil
                upload.resumableUploadURL = nil
                upload.lastKnownServerOffset = nil
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

        uploadTask.taskDescription = id.uuidString
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
                upload.lastKnownServerOffset = nil
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

            updateUpload(id: id) { upload in
                upload.taskIdentifier = task.taskIdentifier
                upload.bytesSent = max(upload.bytesSent, max(task.countOfBytesSent, upload.lastKnownServerOffset ?? 0))
                upload.expectedBytes = task.countOfBytesExpectedToSend > 0 ? task.countOfBytesExpectedToSend : upload.expectedBytes
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

    private func parseUploadIncomplete(from response: HTTPURLResponse) -> Bool? {
        guard let value = response.value(forHTTPHeaderField: "Upload-Incomplete")?
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
        case failure(message: String)
    }

    private func verifyCompletion(for id: UUID, response: HTTPURLResponse) async -> CompletionVerificationResult {
        let responseOffset = response.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
        let responseIsIncomplete = parseUploadIncomplete(from: response)
        let expectedBytes = upload(with: id)?.expectedBytes ?? 0

        print(
            "[UploadStore] Verifying completion",
            "uploadID=\(id.uuidString)",
            "status=\(response.statusCode)",
            "responseOffset=\(String(describing: responseOffset))",
            "responseIncomplete=\(String(describing: responseIsIncomplete))",
            "expectedBytes=\(expectedBytes)",
            "headers=\(response.allHeaderFields)"
        )

        if responseIsIncomplete == true {
            return .failure(message: "Server reported the upload is incomplete.")
        }

        if expectedBytes > 0, let responseOffset {
            if responseOffset == expectedBytes {
                return .success(verifiedOffset: responseOffset)
            }

            return .failure(message: "Server acknowledged only \(responseOffset) of \(expectedBytes) bytes.")
        }

        guard let record = upload(with: id),
              let resumableUploadURLString = record.resumableUploadURL,
              let resumableUploadURL = URL(string: resumableUploadURLString)
        else {
            return .failure(message: "Server completion could not be verified because the resumable upload URL is unavailable.")
        }

        var request = URLRequest(url: resumableUploadURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 60
        if let authToken = record.authToken, authToken.isEmpty == false {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, headResponse) = try await URLSession.shared.data(for: request)
            guard let httpHeadResponse = headResponse as? HTTPURLResponse else {
                return .failure(message: "Server returned an invalid HEAD response during completion verification.")
            }

            let headOffset = httpHeadResponse.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
            let headIsIncomplete = parseUploadIncomplete(from: httpHeadResponse)

            print(
                "[UploadStore] HEAD verification response",
                "uploadID=\(id.uuidString)",
                "status=\(httpHeadResponse.statusCode)",
                "offset=\(String(describing: headOffset))",
                "incomplete=\(String(describing: headIsIncomplete))",
                "headers=\(httpHeadResponse.allHeaderFields)"
            )

            guard (200 ..< 300).contains(httpHeadResponse.statusCode) else {
                return .failure(message: "Completion verification HEAD returned HTTP \(httpHeadResponse.statusCode).")
            }

            if headIsIncomplete == true {
                return .failure(message: "Server still reports the upload as incomplete.")
            }

            if expectedBytes > 0, let headOffset {
                if headOffset == expectedBytes {
                    return .success(verifiedOffset: headOffset)
                }

                return .failure(message: "Server acknowledged only \(headOffset) of \(expectedBytes) bytes.")
            }

            return .failure(message: "Server did not provide an Upload-Offset during completion verification.")
        } catch {
            print("[UploadStore] HEAD verification failed uploadID=\(id.uuidString) error=\(error.localizedDescription)")
            return .failure(message: "Completion verification failed: \(error.localizedDescription)")
        }
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
        return UUID(uuidString: taskDescription)
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
        let completionHandler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        completionHandler?()
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

        Task { @MainActor in
            self.updateUpload(id: id) { upload in
                upload.bytesSent = max(upload.bytesSent, totalBytesSent)
                if totalBytesExpectedToSend > 0 {
                    upload.expectedBytes = totalBytesExpectedToSend
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

        Task { @MainActor in
            self.updateUpload(id: id) { upload in
                if let offset {
                    upload.bytesSent = max(upload.bytesSent, offset)
                    upload.lastKnownServerOffset = max(upload.lastKnownServerOffset ?? 0, offset)
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
            if (200 ..< 300).contains(statusCode) == false {
                self.updateUpload(id: id) { upload in
                    upload.state = .failed
                    upload.taskIdentifier = nil
                    upload.responseStatusCode = statusCode
                    upload.errorDescription = "Server responded with HTTP \(statusCode)."
                    upload.lastUpdatedAt = .now
                }
                return
            }

            let verificationResult = await self.verifyCompletion(for: id, response: response)

            switch verificationResult {
            case .success(let verifiedOffset):
                do {
                    try self.removeResumeData(for: id)
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
                    upload.lastKnownServerOffset = nil
                    upload.localFilePath = nil
                    upload.lastUpdatedAt = .now
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
