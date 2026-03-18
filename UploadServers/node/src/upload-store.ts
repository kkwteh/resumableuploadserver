import { createClient } from "redis";
import type { Storage } from "./storage.js";
import {
  type S3CompletedPart,
  type Upload,
  computeFlushedOffset,
  isLocalState,
  isS3State,
} from "./upload.js";

const REDIS_KEY_PREFIX = "upload:";

type UploadStore = {
  create(upload: Upload): Promise<void>;
  find(token: string): Promise<Upload | undefined>;
  save(upload: Upload): Promise<void>;
  delete(token: string): Promise<void>;
};

type RedisUploadRecord = {
  backend?: string;
  complete?: string;
  start_time?: string;
  flushed_offset?: string;
  file_path?: string;
  key?: string;
  upload_id?: string;
  next_part_num?: string;
  completed_parts?: string;
};

function redisKey(token: string): string {
  return `${REDIS_KEY_PREFIX}${token}`;
}

function serializeUpload(upload: Upload): Record<string, string> {
  const serialized: Record<string, string> = {
    complete: upload.complete ? "1" : "0",
    start_time: upload.startTime.toString(),
    flushed_offset: computeFlushedOffset(upload).toString(),
  };

  if (isS3State(upload.backendState)) {
    serialized.backend = "s3";
    serialized.key = upload.backendState.key;
    serialized.upload_id = upload.backendState.uploadId;
    serialized.next_part_num = upload.backendState.nextPartNumber.toString();
    serialized.completed_parts = JSON.stringify(upload.backendState.completedParts);
    return serialized;
  }

  if (isLocalState(upload.backendState)) {
    serialized.backend = "local";
    serialized.file_path = upload.backendState.filePath;
    return serialized;
  }

  throw new Error("Unsupported backend state");
}

function parseCompletedParts(rawValue: string | undefined): S3CompletedPart[] {
  if (rawValue === undefined || rawValue === "") {
    return [];
  }

  const parsedValue: unknown = JSON.parse(rawValue);
  if (!Array.isArray(parsedValue)) {
    throw new Error("completed_parts must be an array");
  }

  return parsedValue.map((part) => {
    if (
      typeof part !== "object" ||
      part === null ||
      typeof part.eTag !== "string" ||
      typeof part.partNumber !== "number"
    ) {
      throw new Error("completed_parts contains an invalid part");
    }

    return {
      eTag: part.eTag,
      partNumber: part.partNumber,
    };
  });
}

function deserializeUpload(
  token: string,
  record: RedisUploadRecord
): Upload | undefined {
  if (record.backend === undefined) {
    return undefined;
  }

  const startTime = Number.parseInt(record.start_time ?? "0", 10);
  const flushedOffset = Number.parseInt(record.flushed_offset ?? "0", 10);

  if (Number.isNaN(startTime) || Number.isNaN(flushedOffset)) {
    throw new Error("Stored upload state has invalid numeric fields");
  }

  if (record.backend === "s3") {
    const nextPartNumber = Number.parseInt(record.next_part_num ?? "1", 10);
    if (Number.isNaN(nextPartNumber) || record.key === undefined || record.upload_id === undefined) {
      throw new Error("Stored S3 upload state is incomplete");
    }

    return {
      token,
      offset: flushedOffset,
      complete: record.complete === "1",
      startTime,
      backendState: {
        backend: "s3",
        key: record.key,
        uploadId: record.upload_id,
        nextPartNumber,
        completedParts: parseCompletedParts(record.completed_parts),
        pendingBuffer: Buffer.alloc(0),
      },
    };
  }

  if (record.backend === "local") {
    if (record.file_path === undefined) {
      throw new Error("Stored local upload state is incomplete");
    }

    return {
      token,
      offset: flushedOffset,
      complete: record.complete === "1",
      startTime,
      backendState: {
        backend: "local",
        filePath: record.file_path,
      },
    };
  }

  throw new Error(`Unknown backend: ${record.backend}`);
}

export class MemoryStore implements UploadStore {
  private readonly uploads = new Map<string, Upload>();

  constructor(
    private readonly storage: Storage,
    private readonly timeoutMs: number
  ) {}

  async create(upload: Upload): Promise<void> {
    upload.timer = setTimeout(() => {
      console.log(
        `[Upload] Timeout: removing upload ${upload.token} after idle`
      );
      void this.storage.abort(upload);
      this.uploads.delete(upload.token);
    }, this.timeoutMs);
    this.uploads.set(upload.token, upload);
  }

  async find(token: string): Promise<Upload | undefined> {
    return this.uploads.get(token);
  }

  async save(_upload: Upload): Promise<void> {}

  async delete(token: string): Promise<void> {
    const upload = this.uploads.get(token);
    if (upload?.timer !== undefined) {
      clearTimeout(upload.timer);
    }
    this.uploads.delete(token);
  }
}

export class RedisStore implements UploadStore {
  private readonly cache = new Map<string, Upload>();

  constructor(
    private readonly client: ReturnType<typeof createClient>,
    private readonly ttlSeconds: number
  ) {}

  static async create(
    redisUrl: string,
    ttlSeconds: number
  ): Promise<RedisStore> {
    const client = createClient({ url: redisUrl });
    await client.connect();
    await client.ping();
    return new RedisStore(client, ttlSeconds);
  }

  async create(upload: Upload): Promise<void> {
    await this.writeUpload(upload);
    this.cache.set(upload.token, upload);
  }

  async find(token: string): Promise<Upload | undefined> {
    const cachedUpload = this.cache.get(token);
    if (cachedUpload !== undefined) {
      return cachedUpload;
    }

    const record = (await this.client.hGetAll(
      redisKey(token)
    )) as RedisUploadRecord;
    if (Object.keys(record).length === 0) {
      return undefined;
    }

    const upload = deserializeUpload(token, record);
    if (upload !== undefined) {
      this.cache.set(token, upload);
    }
    return upload;
  }

  async save(upload: Upload): Promise<void> {
    await this.writeUpload(upload);
  }

  async delete(token: string): Promise<void> {
    await this.client.del(redisKey(token));
    this.cache.delete(token);
  }

  private async writeUpload(upload: Upload): Promise<void> {
    const key = redisKey(upload.token);
    const serialized = serializeUpload(upload);

    const pipeline = this.client.multi();
    pipeline.hSet(key, serialized);
    pipeline.expire(key, this.ttlSeconds);
    await pipeline.exec();
  }
}

export async function createUploadStore(
  {
    redisUrl,
    storage,
    timeoutMs,
  }: {
    redisUrl: string;
    storage: Storage;
    timeoutMs: number;
  }
): Promise<UploadStore> {
  if (redisUrl !== "") {
    return RedisStore.create(redisUrl, Math.ceil(timeoutMs / 1000));
  }

  return new MemoryStore(storage, timeoutMs);
}

export type { UploadStore };
