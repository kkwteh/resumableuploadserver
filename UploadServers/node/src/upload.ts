import crypto from "node:crypto";

export const RESUME_PATH_PREFIX = "/resumable_upload/";

export type S3CompletedPart = {
  eTag: string;
  partNumber: number;
};

export type LocalState = {
  backend: "local";
  filePath: string;
};

export type S3State = {
  backend: "s3";
  key: string;
  uploadId: string;
  completedParts: S3CompletedPart[];
  pendingBuffer: Buffer;
  nextPartNumber: number;
};

export type Upload = {
  token: string;
  offset: number;
  complete: boolean;
  startTime: number;
  backendState?: LocalState | S3State;
  timer?: NodeJS.Timeout;
};

export function createUpload(): Upload {
  return {
    token: `${crypto.randomInt(2 ** 48 - 1)}-${crypto.randomInt(2 ** 48 - 1)}`,
    offset: 0,
    complete: false,
    startTime: Date.now(),
  };
}

export function getResumePath(token: string): string {
  return `${RESUME_PATH_PREFIX}${token}`;
}

export function getTokenFromPath(urlPath: string): string | undefined {
  if (!urlPath.startsWith(RESUME_PATH_PREFIX)) {
    return undefined;
  }
  return urlPath.slice(RESUME_PATH_PREFIX.length);
}

export function computeFlushedOffset(upload: Upload): number {
  if (isS3State(upload.backendState)) {
    return upload.offset - upload.backendState.pendingBuffer.length;
  }
  return upload.offset;
}

export function isLocalState(
  backendState: Upload["backendState"]
): backendState is LocalState {
  return backendState?.backend === "local";
}

export function isS3State(
  backendState: Upload["backendState"]
): backendState is S3State {
  return backendState?.backend === "s3";
}
