import http from "node:http";
import { createWriteStream, WriteStream } from "node:fs";
import type { Upload } from "./resumable-upload.js";

const LOG_INTERVAL_MS = 2000;
const INTEROP_VERSION = "3";

function formatBytes(bytes: number): string {
  if (bytes >= 1_073_741_824) {
    return `${(bytes / 1_073_741_824).toFixed(2)} GB`;
  } else if (bytes >= 1_048_576) {
    return `${(bytes / 1_048_576).toFixed(1)} MB`;
  } else if (bytes >= 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${bytes} B`;
}

/**
 * Stream the request body to the upload's file, appending at the current position.
 * Calls `onDone` with the total bytes written from this request.
 */
export function handleUploadBody(
  req: http.IncomingMessage,
  upload: Upload,
  onDone: (bytesWritten: number) => void
): void {
  const stream: WriteStream = createWriteStream(upload.filePath, {
    flags: upload.offset === 0 ? "w" : "a",
  });

  let bytesReceived = 0;
  const startTime = Date.now();
  let lastLogTime = startTime;

  req.on("data", (chunk: Buffer) => {
    bytesReceived += chunk.length;
    stream.write(chunk);

    const now = Date.now();
    if (now - lastLogTime >= LOG_INTERVAL_MS) {
      const elapsed = (now - startTime) / 1000;
      const speedMBps =
        elapsed > 0 ? bytesReceived / elapsed / 1_048_576 : 0;
      console.log(
        `[Upload] Progress: ${formatBytes(upload.offset + bytesReceived)} received, ${speedMBps.toFixed(1)} MB/s`
      );
      lastLogTime = now;
    }
  });

  req.on("end", () => {
    stream.end(() => {
      const elapsed = (Date.now() - startTime) / 1000;
      const totalBytes = upload.offset + bytesReceived;
      const speedMBps =
        elapsed > 0 ? bytesReceived / elapsed / 1_048_576 : 0;
      console.log(
        `[Upload] Chunk complete: ${formatBytes(totalBytes)} total (${formatBytes(bytesReceived)} this chunk) in ${elapsed.toFixed(2)}s (${speedMBps.toFixed(1)} MB/s) -> ${upload.filePath}`
      );
      onDone(bytesReceived);
    });
  });

  req.on("error", (err) => {
    console.log(`[Upload] Error: ${err.message}`);
    stream.end();
  });
}

/**
 * Send the final response after an upload completes (all bytes received).
 */
export function sendUploadComplete(
  res: http.ServerResponse,
  upload: Upload
): void {
  const elapsed = (Date.now() - upload.startTime) / 1000;
  const speedMBps =
    elapsed > 0 ? upload.offset / elapsed / 1_048_576 : 0;

  console.log(
    `[Upload] Complete: ${formatBytes(upload.offset)} in ${elapsed.toFixed(2)}s (${speedMBps.toFixed(1)} MB/s) -> ${upload.filePath}`
  );

  const json = JSON.stringify({
    bytes_received: upload.offset,
    elapsed_seconds: parseFloat(elapsed.toFixed(2)),
    speed_mbps: parseFloat(speedMBps.toFixed(1)),
    file: upload.filePath,
  });

  res.setHeader("Upload-Draft-Interop-Version", INTEROP_VERSION);
  res.setHeader("Connection", "close");
  res.setHeader("Upload-Incomplete", "?0");
  res.setHeader("Upload-Offset", upload.offset.toString());
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Content-Length", Buffer.byteLength(json).toString());
  res.writeHead(200);
  res.end(json);
}
