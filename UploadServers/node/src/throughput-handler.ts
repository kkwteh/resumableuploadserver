import http from "node:http";
import type { Storage } from "./storage.js";
import { formatBytes } from "./storage.js";
import type { Upload } from "./upload.js";

const INTEROP_VERSION = "3";

export function sendUploadComplete(
  res: http.ServerResponse,
  upload: Upload,
  storage: Storage
): void {
  const elapsedSeconds = (Date.now() - upload.startTime) / 1000;
  const speedMbps =
    elapsedSeconds > 0 ? upload.offset / elapsedSeconds / 1_048_576 : 0;
  const location = storage.location(upload);

  console.log(
    `[Upload] Complete: ${formatBytes(upload.offset)} in ${elapsedSeconds.toFixed(2)}s (${speedMbps.toFixed(1)} MB/s) -> ${location}`
  );

  const json = JSON.stringify({
    bytes_received: upload.offset,
    elapsed_seconds: Number.parseFloat(elapsedSeconds.toFixed(2)),
    speed_mbps: Number.parseFloat(speedMbps.toFixed(1)),
    file: location,
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
