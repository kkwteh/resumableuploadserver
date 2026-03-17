import NIOCore
import NIOPosix
import NIOHTTP1
import HTTPTypes
import HTTPTypesNIO
import HTTPTypesNIOHTTP1
import NIOResumableUpload

let port: Int = {
    if CommandLine.arguments.count > 1, let p = Int(CommandLine.arguments[1]) {
        return p
    }
    return 8080
}()

let origin: String = {
    if CommandLine.arguments.count > 2 {
        return CommandLine.arguments[2]
    }
    return "http://localhost:\(port)"
}()

// Ensure uploads directory exists
import Foundation
let uploadsDir = ThroughputHandler.uploadsDirectory
if !FileManager.default.fileExists(atPath: uploadsDir) {
    try FileManager.default.createDirectory(atPath: uploadsDir, withIntermediateDirectories: true)
    print("Created \(uploadsDir)/ directory")
}

print("Starting resumable upload server on port \(port)")
print("Origin: \(origin)")
print("Usage: UploadServer [port] [origin]")
print("  Example: UploadServer 8080 https://abc123.ngrok.io")
print("")

let uploadContext = HTTPResumableUploadContext(origin: origin)

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
defer { try! group.syncShutdownGracefully() }

/// Adds "Connection: close" to every HTTP/1.1 response so the server closes the
/// TCP connection after each response. This is required because the resumable upload
/// handler detaches after sending intermediate 201 responses, and a subsequent request
/// on the same keep-alive connection would be silently dropped by the checkHandler guard.
/// When behind a reverse proxy (ngrok), the proxy reuses connections, so the server
/// must be the one to close them.
final class ConnectionCloseHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = unwrapOutboundIn(data)
        switch part {
        case .head(var head):
            head.headers.replaceOrAdd(name: "connection", value: "close")
            context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body, .end:
            context.write(data, promise: promise)
        }
    }
}

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(.backlog, value: 256)
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
            // ConnectionCloseHandler intercepts HTTP/1.1 responses before they hit the wire
            // and adds Connection: close to force per-request connections.
            channel.pipeline.addHandler(ConnectionCloseHandler())
        }.flatMap {
            channel.pipeline.addHandler(HTTP1ToHTTPServerCodec(secure: false))
        }.flatMap {
            channel.pipeline.addHandler(
                HTTPResumableUploadHandler(
                    context: uploadContext,
                    handlers: [ThroughputHandler()]
                )
            )
        }
    }
    .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelOption(.maxMessagesPerRead, value: 16)

let channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
print("Server listening on \(channel.localAddress!)")
print("Ready for uploads. POST to \(origin)/upload")
print("")

try channel.closeFuture.wait()
