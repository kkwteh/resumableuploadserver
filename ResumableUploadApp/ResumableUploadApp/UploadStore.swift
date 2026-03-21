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

        print(
            "[UploadStore] Received informational response",
            "uploadID=\(id.uuidString)",
            "status=\(response.statusCode)",
            "offset=\(String(describing: offset))",
            "headers=\(response.allHeaderFields)"
        )

        Task { @MainActor in
            self.updateUpload(id: id) { upload in
                if let offset {
                    upload.bytesSent = max(upload.bytesSent, offset)
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
            print(
                "[UploadStore] Final upload response",
                "uploadID=\(id.uuidString)",
                "status=\(statusCode)",
                "taskDescription=\(task.taskDescription ?? "")",
                "headers=\(response.allHeaderFields)"
            )

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

            do {
                try self.removeResumeData(for: id)
                try self.removeLocalFile(for: id)
            } catch {
                self.messageBanner = error.localizedDescription
            }

            self.updateUpload(id: id) { upload in
                upload.state = .completed
                upload.taskIdentifier = nil
                upload.bytesSent = max(upload.bytesSent, upload.expectedBytes)
                upload.responseStatusCode = statusCode
                upload.errorDescription = nil
                upload.resumeDataFileName = nil
                upload.localFilePath = nil
                upload.lastUpdatedAt = .now
            }
        }
    }
}
