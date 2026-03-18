import http from "node:http";
import { mkdirSync, existsSync } from "node:fs";
import { ResumableUploadManager } from "./resumable-upload.js";
import { handleUploadBody, sendUploadComplete } from "./throughput-handler.js";

const INTEROP_VERSION = "3";
const UPLOADS_DIR = "uploads";

const port = parseInt(process.argv[2] ?? "8080", 10);
const origin = process.argv[3] ?? `http://localhost:${port}`;

if (!existsSync(UPLOADS_DIR)) {
  mkdirSync(UPLOADS_DIR, { recursive: true });
  console.log(`Created ${UPLOADS_DIR}/ directory`);
}

const uploads = new ResumableUploadManager(origin);

function parseUploadIncomplete(
  value: string | undefined
): boolean | undefined {
  if (value === "?1") return true;
  if (value === "?0") return false;
  return undefined;
}

function formatUploadIncomplete(incomplete: boolean): string {
  return incomplete ? "?1" : "?0";
}

function setCommonHeaders(res: http.ServerResponse): void {
  res.setHeader("Upload-Draft-Interop-Version", INTEROP_VERSION);
  res.setHeader("Connection", "close");
}

const server = http.createServer((req, res) => {
  const method = req.method ?? "GET";
  const url = req.url ?? "/";
  const interopVersion = req.headers["upload-draft-interop-version"] as
    | string
    | undefined;

  // Only handle resumable upload requests (must have correct interop version)
  if (interopVersion !== INTEROP_VERSION) {
    res.writeHead(400, { "Content-Length": "0" });
    res.end();
    return;
  }

  const incomplete = parseUploadIncomplete(
    req.headers["upload-incomplete"] as string | undefined
  );
  const offsetHeader = req.headers["upload-offset"] as string | undefined;
  const offset = offsetHeader !== undefined ? parseInt(offsetHeader, 10) : undefined;

  // Resumption path requests (HEAD/PATCH/DELETE on /resumable_upload/...)
  if (url.startsWith("/resumable_upload/")) {
    const upload = uploads.find(url);

    if (!upload) {
      setCommonHeaders(res);
      res.writeHead(404, { "Content-Length": "0" });
      res.end();
      return;
    }

    if (method === "HEAD") {
      // Offset retrieval
      if (incomplete !== undefined || offset !== undefined) {
        setCommonHeaders(res);
        res.writeHead(400, { "Content-Length": "0" });
        res.end();
        return;
      }
      setCommonHeaders(res);
      res.setHeader(
        "Upload-Incomplete",
        formatUploadIncomplete(!upload.complete)
      );
      res.setHeader("Upload-Offset", upload.offset.toString());
      res.setHeader("Cache-Control", "no-store");
      res.writeHead(204);
      res.end();
      return;
    }

    if (method === "PATCH") {
      // Upload appending
      if (offset === undefined) {
        setCommonHeaders(res);
        res.writeHead(400, { "Content-Length": "0" });
        res.end();
        return;
      }

      if (offset !== upload.offset) {
        // Offset conflict
        setCommonHeaders(res);
        res.setHeader(
          "Upload-Incomplete",
          formatUploadIncomplete(!upload.complete)
        );
        res.setHeader("Upload-Offset", upload.offset.toString());
        res.setHeader("Content-Length", "0");
        res.writeHead(409);
        res.end();
        return;
      }

      const isComplete = incomplete === undefined ? true : !incomplete;

      handleUploadBody(req, upload, (bytesWritten) => {
        upload.offset += bytesWritten;
        if (isComplete) {
          upload.complete = true;
        }

        if (upload.complete) {
          sendUploadComplete(res, upload);
        } else {
          // Incomplete — respond 201
          setCommonHeaders(res);
          res.setHeader("Upload-Incomplete", formatUploadIncomplete(true));
          res.setHeader("Upload-Offset", upload.offset.toString());
          res.writeHead(201);
          res.end();
        }
      });
      return;
    }

    if (method === "DELETE") {
      // Upload cancellation
      if (incomplete !== undefined || offset !== undefined) {
        setCommonHeaders(res);
        res.writeHead(400, { "Content-Length": "0" });
        res.end();
        return;
      }
      upload.cancel();
      uploads.remove(url);
      setCommonHeaders(res);
      res.writeHead(204);
      res.end();
      return;
    }

    setCommonHeaders(res);
    res.writeHead(400, { "Content-Length": "0" });
    res.end();
    return;
  }

  // Upload creation (POST to /upload or any non-resumption path)
  if (incomplete !== undefined) {
    if (offset !== undefined && offset !== 0) {
      setCommonHeaders(res);
      res.writeHead(400, { "Content-Length": "0" });
      res.end();
      return;
    }

    const isComplete = !incomplete;
    const upload = uploads.create();

    console.log(
      `[Upload] ${method} ${url} started -> ${upload.filePath} (token: ${upload.token})`
    );

    handleUploadBody(req, upload, (bytesWritten) => {
      upload.offset += bytesWritten;
      if (isComplete) {
        upload.complete = true;
      }

      if (upload.complete) {
        sendUploadComplete(res, upload);
      } else {
        // Incomplete upload creation — respond 201 with Location
        setCommonHeaders(res);
        res.setHeader("Location", `${origin}${upload.resumePath}`);
        res.setHeader("Upload-Incomplete", formatUploadIncomplete(true));
        res.setHeader("Upload-Offset", upload.offset.toString());
        res.writeHead(201);
        res.end();
      }
    });
    return;
  }

  // Not a resumable upload request
  res.writeHead(400, { "Content-Length": "0" });
  res.end();
});

server.listen(port, "0.0.0.0", () => {
  console.log(`Starting resumable upload server on port ${port}`);
  console.log(`Origin: ${origin}`);
  console.log(`Usage: node dist/server.js [port] [origin]`);
  console.log(`  Example: node dist/server.js 8080 https://abc123.ngrok.io`);
  console.log();
  console.log(`Server listening on 0.0.0.0:${port}`);
  console.log(`Ready for uploads. POST to ${origin}/upload`);
  console.log();
});
