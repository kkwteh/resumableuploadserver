import { randomBytes, randomUUID } from "node:crypto";
import { createWriteStream, existsSync, mkdirSync, rm } from "node:fs";
import { once } from "node:events";
import path from "node:path";
import type { Readable } from "node:stream";
import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  S3Client,
  UploadPartCommand,
} from "@aws-sdk/client-s3";
import type { Config } from "./config.js";
import { type S3State, type Upload, isLocalState, isS3State } from "./upload.js";

const LOG_INTERVAL_MS = 2000;

export function formatBytes(bytes: number): string {
  if (bytes >= 1_073_741_824) {
    return `${(bytes / 1_073_741_824).toFixed(2)} GB`;
  }
  if (bytes >= 1_048_576) {
    return `${(bytes / 1_048_576).toFixed(1)} MB`;
  }
  if (bytes >= 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${bytes} B`;
}

async function logRequestProgress(
  {
    req,
    upload,
    writeChunk,
    location,
  }: {
    req: Readable;
    upload: Upload;
    writeChunk: (chunk: Buffer) => Promise<void>;
    location: string;
  }
): Promise<number> {
  let bytesReceived = 0;
  const startTime = Date.now();
  let lastLogTime = startTime;

  for await (const chunk of req) {
    const bufferChunk = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytesReceived += bufferChunk.length;
    await writeChunk(bufferChunk);

    const now = Date.now();
    if (now - lastLogTime >= LOG_INTERVAL_MS) {
      const elapsedSeconds = (now - startTime) / 1000;
      const speedMbps =
        elapsedSeconds > 0 ? bytesReceived / elapsedSeconds / 1_048_576 : 0;
      console.log(
        `[Upload] Progress: ${formatBytes(upload.offset + bytesReceived)} received, ${speedMbps.toFixed(1)} MB/s`
      );
      lastLogTime = now;
    }
  }

  const elapsedSeconds = (Date.now() - startTime) / 1000;
  const speedMbps =
    elapsedSeconds > 0 ? bytesReceived / elapsedSeconds / 1_048_576 : 0;
  console.log(
    `[Upload] Request complete: ${formatBytes(upload.offset + bytesReceived)} total (${formatBytes(bytesReceived)} this request) in ${elapsedSeconds.toFixed(2)}s (${speedMbps.toFixed(1)} MB/s) -> ${location}`
  );

  return bytesReceived;
}

export type Storage = {
  init(upload: Upload): Promise<void>;
  write(req: Readable, upload: Upload): Promise<number>;
  complete(upload: Upload): Promise<void>;
  abort(upload: Upload): Promise<void>;
  location(upload: Upload): string;
};

export class LocalStorage implements Storage {
  constructor(private readonly uploadsDir: string) {
    if (!existsSync(this.uploadsDir)) {
      mkdirSync(this.uploadsDir, { recursive: true });
      console.log(`Created ${this.uploadsDir}/ directory`);
    }
  }

  async init(upload: Upload): Promise<void> {
    upload.backendState = {
      backend: "local",
      filePath: path.join(this.uploadsDir, randomUUID()),
    };
  }

  async write(req: Readable, upload: Upload): Promise<number> {
    if (!isLocalState(upload.backendState)) {
      throw new Error("Local storage requires local backend state");
    }
    const state = upload.backendState;

    const flags = upload.offset === 0 ? "w" : "a";
    const stream = createWriteStream(state.filePath, { flags });
    let streamError: Error | undefined;
    stream.on("error", (error: Error) => {
      streamError = error;
    });

    const bytesReceived = await logRequestProgress({
      req,
      upload,
      location: state.filePath,
      writeChunk: async (chunk) => {
        const canContinue = stream.write(chunk);
        if (!canContinue) {
          await once(stream, "drain");
        }
        if (streamError !== undefined) {
          throw streamError;
        }
      },
    });

    stream.end();
    await once(stream, "finish");

    if (streamError !== undefined) {
      throw streamError;
    }

    return bytesReceived;
  }

  async complete(_upload: Upload): Promise<void> {}

  async abort(upload: Upload): Promise<void> {
    if (!isLocalState(upload.backendState)) {
      return;
    }
    const state = upload.backendState;

    await new Promise<void>((resolve, reject) => {
      rm(state.filePath, { force: true }, (error) => {
        if (error !== null) {
          reject(error);
          return;
        }
        resolve();
      });
    });
  }

  location(upload: Upload): string {
    if (!isLocalState(upload.backendState)) {
      throw new Error("Local storage requires local backend state");
    }
    return upload.backendState.filePath;
  }
}

export class S3Storage implements Storage {
  private readonly client: S3Client;

  constructor(
    private readonly bucket: string,
    private readonly keyPrefix: string,
    private readonly partSize: number,
    config: Config
  ) {
    this.client = new S3Client({
      region: config.awsRegion,
      endpoint: config.s3Endpoint === "" ? undefined : config.s3Endpoint,
      forcePathStyle: config.s3Endpoint !== "",
    });
  }

  async init(upload: Upload): Promise<void> {
    const key = `${this.keyPrefix}${randomBytes(16).toString("hex")}`;
    const response = await this.client.send(
      new CreateMultipartUploadCommand({
        Bucket: this.bucket,
        Key: key,
      })
    );

    if (response.UploadId === undefined) {
      throw new Error("S3 did not return a multipart upload ID");
    }

    upload.backendState = {
      backend: "s3",
      key,
      uploadId: response.UploadId,
      completedParts: [],
      pendingBuffer: Buffer.alloc(0),
      nextPartNumber: 1,
    };
  }

  async write(req: Readable, upload: Upload): Promise<number> {
    if (!isS3State(upload.backendState)) {
      throw new Error("S3 storage requires S3 backend state");
    }
    const state = upload.backendState;

    return logRequestProgress({
      req,
      upload,
      location: this.location(upload),
      writeChunk: async (chunk) => {
        state.pendingBuffer = Buffer.concat([
          state.pendingBuffer,
          chunk,
        ]);

        while (state.pendingBuffer.length >= this.partSize) {
          await this.flushPart(state, this.partSize);
        }
      },
    });
  }

  async complete(upload: Upload): Promise<void> {
    if (!isS3State(upload.backendState)) {
      throw new Error("S3 storage requires S3 backend state");
    }
    const state = upload.backendState;

    if (state.pendingBuffer.length > 0) {
      await this.flushPart(state, state.pendingBuffer.length);
    }

    await this.client.send(
      new CompleteMultipartUploadCommand({
        Bucket: this.bucket,
        Key: state.key,
        UploadId: state.uploadId,
        MultipartUpload: {
          Parts: state.completedParts.map((part) => ({
            ETag: part.eTag,
            PartNumber: part.partNumber,
          })),
        },
      })
    );
  }

  async abort(upload: Upload): Promise<void> {
    if (!isS3State(upload.backendState)) {
      return;
    }

    await this.client.send(
      new AbortMultipartUploadCommand({
        Bucket: this.bucket,
        Key: upload.backendState.key,
        UploadId: upload.backendState.uploadId,
      })
    );
  }

  location(upload: Upload): string {
    if (!isS3State(upload.backendState)) {
      throw new Error("S3 storage requires S3 backend state");
    }
    return `s3://${this.bucket}/${upload.backendState.key}`;
  }

  private async flushPart(state: S3State, size: number): Promise<void> {
    const body = state.pendingBuffer.subarray(0, size);
    const partNumber = state.nextPartNumber;

    let lastError: unknown;
    for (let attempt = 1; attempt <= 3; attempt += 1) {
      try {
        const response = await this.client.send(
          new UploadPartCommand({
            Bucket: this.bucket,
            Key: state.key,
            UploadId: state.uploadId,
            PartNumber: partNumber,
            Body: body,
          })
        );

        if (response.ETag === undefined) {
          throw new Error(`S3 did not return an ETag for part ${partNumber}`);
        }

        state.completedParts.push({
          eTag: response.ETag,
          partNumber,
        });
        state.nextPartNumber += 1;
        state.pendingBuffer = state.pendingBuffer.subarray(size);
        return;
      } catch (error) {
        lastError = error;
        console.log(
          `[Upload] UploadPart ${partNumber} attempt ${attempt} failed: ${String(error)}`
        );
      }
    }

    throw new Error(
      `Upload part ${partNumber} failed after 3 attempts: ${String(lastError)}`
    );
  }
}

export function createStorage(config: Config): Storage {
  if (config.s3Bucket !== "") {
    return new S3Storage(
      config.s3Bucket,
      config.s3KeyPrefix,
      config.s3PartSize,
      config
    );
  }

  return new LocalStorage(config.uploadsDir);
}
