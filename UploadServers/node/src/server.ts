import http from "node:http";
import { loadConfig } from "./config.js";
import { ResumableUploadManager } from "./resumable-upload.js";
import { createStorage } from "./storage.js";
import { sendUploadComplete } from "./throughput-handler.js";
import { createUploadStore } from "./upload-store.js";

const INTEROP_VERSION = "3";
const IDLE_TIMEOUT_MS = 3600_000;

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

function parseUploadOffset(
  value: string | undefined
): number | undefined {
  if (value === undefined) {
    return undefined;
  }

  const parsedValue = Number.parseInt(value, 10);
  if (Number.isNaN(parsedValue)) {
    return undefined;
  }

  return parsedValue;
}

async function main(): Promise<void> {
  const config = loadConfig(process.argv);
  const storage = createStorage(config);
  const store = await createUploadStore({
    redisUrl: config.redisUrl,
    storage,
    timeoutMs: IDLE_TIMEOUT_MS,
  });
  const uploads = new ResumableUploadManager(storage, store, IDLE_TIMEOUT_MS);

  if (config.s3Bucket !== "") {
    console.log(
      `Storage: S3 (bucket=${config.s3Bucket}, prefix="${config.s3KeyPrefix}", partSize=${config.s3PartSize})`
    );
    if (config.s3Endpoint !== "") {
      console.log(`S3 Endpoint: ${config.s3Endpoint}`);
    }
  } else {
    console.log("Storage: local disk");
  }

  if (config.redisUrl !== "") {
    console.log(`State: Redis (${config.redisUrl})`);
  } else {
    console.log("State: in-memory");
  }

  const server = http.createServer((req, res) => {
    void handleRequest({
      config,
      req,
      res,
      uploads,
      storage,
    }).catch((error: unknown) => {
      console.error("[Upload] Request failed:", error);
      if (!res.headersSent) {
        setCommonHeaders(res);
        res.writeHead(500, { "Content-Length": "0" });
      }
      res.end();
    });
  });

  server.listen(config.port, "0.0.0.0", () => {
    console.log(
      `Starting resumable upload server on port ${config.port.toString()}`
    );
    console.log(`Origin: ${config.origin}`);
    console.log(`Usage: node dist/server.js [port] [origin]`);
    console.log(`  Example: node dist/server.js 8080 https://abc123.ngrok.io`);
    console.log();
    console.log(`Server listening on 0.0.0.0:${config.port.toString()}`);
    console.log(`Ready for uploads. POST to ${config.origin}/upload`);
    console.log();
  });
}

type HandleRequestArgs = {
  config: ReturnType<typeof loadConfig>;
  req: http.IncomingMessage;
  res: http.ServerResponse;
  uploads: ResumableUploadManager;
  storage: ReturnType<typeof createStorage>;
};

async function handleRequest({
  config,
  req,
  res,
  uploads,
  storage,
}: HandleRequestArgs): Promise<void> {
  const method = req.method ?? "GET";
  const url = new URL(req.url ?? "/", config.origin);
  const interopVersion = req.headers["upload-draft-interop-version"] as
    | string
    | undefined;

  if (interopVersion !== INTEROP_VERSION) {
    res.writeHead(400, { "Content-Length": "0" });
    res.end();
    return;
  }

  const incomplete = parseUploadIncomplete(
    req.headers["upload-incomplete"] as string | undefined
  );
  const offset = parseUploadOffset(
    req.headers["upload-offset"] as string | undefined
  );

  if (url.pathname.startsWith("/resumable_upload/")) {
    const upload = await uploads.find(url.pathname);
    if (upload === undefined) {
      setCommonHeaders(res);
      res.writeHead(404, { "Content-Length": "0" });
      res.end();
      return;
    }

    if (method === "HEAD") {
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
      if (offset === undefined) {
        setCommonHeaders(res);
        res.writeHead(400, { "Content-Length": "0" });
        res.end();
        return;
      }

      if (offset !== upload.offset) {
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
      const bytesWritten = await storage.write(req, upload);
      upload.offset += bytesWritten;
      if (isComplete) {
        upload.complete = true;
      }

      if (upload.complete) {
        await storage.complete(upload);
        await uploads.delete(upload);
        sendUploadComplete(res, upload, storage);
        return;
      }

      await uploads.save(upload);
      setCommonHeaders(res);
      res.setHeader("Upload-Incomplete", formatUploadIncomplete(true));
      res.setHeader("Upload-Offset", upload.offset.toString());
      res.writeHead(201);
      res.end();
      return;
    }

    if (method === "DELETE") {
      if (incomplete !== undefined || offset !== undefined) {
        setCommonHeaders(res);
        res.writeHead(400, { "Content-Length": "0" });
        res.end();
        return;
      }

      await uploads.remove(url.pathname);
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

  if (incomplete !== undefined) {
    if (offset !== undefined && offset !== 0) {
      setCommonHeaders(res);
      res.writeHead(400, { "Content-Length": "0" });
      res.end();
      return;
    }

    const isComplete = !incomplete;
    const upload = await uploads.create();

    console.log(
      `[Upload] ${method} ${url.pathname} started -> ${storage.location(upload)} (token: ${upload.token})`
    );

    const bytesWritten = await storage.write(req, upload);
    upload.offset += bytesWritten;
    if (isComplete) {
      upload.complete = true;
    }

    if (upload.complete) {
      await storage.complete(upload);
      await uploads.delete(upload);
      sendUploadComplete(res, upload, storage);
      return;
    }

    await uploads.save(upload);
    setCommonHeaders(res);
    res.setHeader(
      "Location",
      `${config.origin}${uploads.getResumePath(upload)}`
    );
    res.setHeader("Upload-Incomplete", formatUploadIncomplete(true));
    res.setHeader("Upload-Offset", upload.offset.toString());
    res.writeHead(201);
    res.end();
    return;
  }

  res.writeHead(400, { "Content-Length": "0" });
  res.end();
}

void main().catch((error: unknown) => {
  console.error("Server error:", error);
  process.exit(1);
});
