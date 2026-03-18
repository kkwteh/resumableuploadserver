import Dispatch
import Foundation
import HTTPTypes
import HTTPTypesNIO
import NIOCore

/// Handler that receives the stripped (non-resumable) HTTP request on the child channel,
/// counts bytes received, writes them to disk, and responds with throughput stats.
final class ThroughputHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPTypeServerRequestPart
    typealias OutboundOut = HTTPTypeServerResponsePart

    static let uploadsDirectory = "uploads"

    private var bytesReceived: Int64 = 0
    private var startTime: UInt64 = 0
    private var method: HTTPRequest.Method = .get
    private var lastLogTime: UInt64 = 0
    private static let logIntervalNanos: UInt64 = 2_000_000_000 // 2 seconds

    private var fileHandle: FileHandle?
    private var filePath: String?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let request):
            method = request.method
            bytesReceived = 0
            startTime = DispatchTime.now().uptimeNanoseconds
            lastLogTime = startTime

            let filename = UUID().uuidString
            let path = "\(Self.uploadsDirectory)/\(filename)"
            FileManager.default.createFile(atPath: path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: path)
            filePath = path

            print("[Upload] \(request.method) \(request.path ?? "/") started -> \(path)")

        case .body(let buffer):
            bytesReceived += Int64(buffer.readableBytes)

            let data = Data(buffer.readableBytesView)
            fileHandle?.write(data)

            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastLogTime >= Self.logIntervalNanos {
                let elapsed = Double(now - startTime) / 1_000_000_000
                let speedMBps = elapsed > 0 ? Double(bytesReceived) / elapsed / 1_048_576 : 0
                print("[Upload] Progress: \(formatBytes(bytesReceived)) received, \(String(format: "%.1f", speedMBps)) MB/s")
                lastLogTime = now
            }

        case .end:
            fileHandle?.closeFile()
            fileHandle = nil

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000_000
            let speedMBps = elapsed > 0 ? Double(bytesReceived) / elapsed / 1_048_576 : 0
            let savedPath = filePath ?? "unknown"
            filePath = nil
            print("[Upload] Complete: \(formatBytes(bytesReceived)) in \(String(format: "%.2f", elapsed))s (\(String(format: "%.1f", speedMBps)) MB/s) -> \(savedPath)")

            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            let json = """
            {"bytes_received":\(bytesReceived),"elapsed_seconds":\(String(format: "%.2f", elapsed)),"speed_mbps":\(String(format: "%.1f", speedMBps)),"file":"\(savedPath)"}
            """
            var buffer = context.channel.allocator.buffer(capacity: json.utf8.count)
            buffer.writeString(json)

            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[Upload] Error: \(error)")
        context.close(promise: nil)
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
