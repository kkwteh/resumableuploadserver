import crypto from "node:crypto";
import path from "node:path";

const UPLOADS_DIR = "uploads";
const RESUME_PATH_PREFIX = "/resumable_upload/";

export type Upload = {
  token: string;
  resumePath: string;
  filePath: string;
  offset: number;
  complete: boolean;
  startTime: number;
  cancel: () => void;
};

export class ResumableUploadManager {
  private origin: string;
  private uploads = new Map<string, Upload>();
  private timeoutMs: number;

  constructor(origin: string, timeoutMs = 3600_000) {
    this.origin = origin;
    this.timeoutMs = timeoutMs;
  }

  create(): Upload {
    const token = `${crypto.randomInt(2 ** 48 - 1)}-${crypto.randomInt(2 ** 48 - 1)}`;
    const resumePath = `${RESUME_PATH_PREFIX}${token}`;
    const filePath = path.join(UPLOADS_DIR, `${crypto.randomUUID()}`);

    let timeout: ReturnType<typeof setTimeout> | null = null;

    const upload: Upload = {
      token,
      resumePath,
      filePath,
      offset: 0,
      complete: false,
      startTime: Date.now(),
      cancel: () => {
        if (timeout) clearTimeout(timeout);
      },
    };

    // Start idle timeout — remove upload if no activity for the timeout period
    const resetTimeout = () => {
      if (timeout) clearTimeout(timeout);
      timeout = setTimeout(() => {
        console.log(
          `[Upload] Timeout: removing upload ${token} after ${this.timeoutMs}ms idle`
        );
        this.uploads.delete(token);
      }, this.timeoutMs);
    };
    resetTimeout();

    this.uploads.set(token, upload);
    return upload;
  }

  find(urlPath: string): Upload | undefined {
    if (!urlPath.startsWith(RESUME_PATH_PREFIX)) return undefined;
    const token = urlPath.slice(RESUME_PATH_PREFIX.length);
    return this.uploads.get(token);
  }

  remove(urlPath: string): void {
    if (!urlPath.startsWith(RESUME_PATH_PREFIX)) return;
    const token = urlPath.slice(RESUME_PATH_PREFIX.length);
    const upload = this.uploads.get(token);
    if (upload) {
      upload.cancel();
      this.uploads.delete(token);
    }
  }
}
