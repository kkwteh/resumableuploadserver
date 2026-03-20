import Foundation

enum UploadState: String, Codable, CaseIterable, Sendable {
    case queued
    case uploading
    case paused
    case completed
    case failed
    case canceled
}

struct UploadRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var createdAt: Date
    var fileName: String
    var endpoint: String
    var authToken: String?
    var localFilePath: String?
    var fileSize: Int64
    var state: UploadState
    var taskIdentifier: Int?
    var bytesSent: Int64
    var expectedBytes: Int64
    var responseStatusCode: Int?
    var errorDescription: String?
    var resumeDataFileName: String?
    var resumableUploadURL: String?
    var lastKnownServerOffset: Int64?
    var lastUpdatedAt: Date

    var progressFraction: Double? {
        let total = expectedBytes > 0 ? expectedBytes : fileSize
        guard total > 0 else { return nil }
        return min(max(Double(bytesSent) / Double(total), 0), 1)
    }

    var isTerminal: Bool {
        state == .completed || state == .failed || state == .canceled
    }

    var canResume: Bool {
        switch state {
        case .queued, .paused:
            return localFilePath != nil
        case .failed:
            return localFilePath != nil || resumeDataFileName != nil
        case .uploading, .completed, .canceled:
            return false
        }
    }
}
