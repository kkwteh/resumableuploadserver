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

print("Starting resumable upload server on port \(port)")
print("Origin: \(origin)")
print("Usage: UploadServer [port] [origin]")
print("  Example: UploadServer 8080 https://abc123.ngrok.io")
print("")

let uploadContext = HTTPResumableUploadContext(origin: origin)

let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
defer { try! group.syncShutdownGracefully() }

let bootstrap = ServerBootstrap(group: group)
    .serverChannelOption(.backlog, value: 256)
    .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
    .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
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
