import XCTest
@testable import ResumableUploadApp

final class UploadRecordTests: XCTestCase {
    func testProgressFractionUsesExpectedBytesWhenAvailable() {
        let record = UploadRecord(
            id: UUID(),
            createdAt: .now,
            fileName: "clip.mov",
            endpoint: "https://example.com/upload",
            authToken: "token-123",
            localFilePath: "/tmp/clip.mov",
            fileSize: 100,
            state: .uploading,
            taskIdentifier: 12,
            bytesSent: 25,
            expectedBytes: 50,
            responseStatusCode: nil,
            errorDescription: nil,
            resumeDataFileName: nil,
            lastUpdatedAt: .now
        )

        XCTAssertEqual(record.progressFraction, 0.5)
    }

    func testCodableRoundTripPreservesResumeDataFileName() throws {
        let source = UploadRecord(
            id: UUID(),
            createdAt: .now,
            fileName: "movie.mp4",
            endpoint: "https://example.com/upload",
            authToken: "token-456",
            localFilePath: "/tmp/movie.mp4",
            fileSize: 2_048,
            state: .paused,
            taskIdentifier: nil,
            bytesSent: 1_024,
            expectedBytes: 2_048,
            responseStatusCode: nil,
            errorDescription: nil,
            resumeDataFileName: "resume.bin",
            lastUpdatedAt: .now
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(source)
        let decoded = try decoder.decode(UploadRecord.self, from: data)

        XCTAssertEqual(decoded, source)
    }
}
