import { createUpload, getResumePath, getTokenFromPath, type Upload } from "./upload.js";
import type { Storage } from "./storage.js";
import type { UploadStore } from "./upload-store.js";

export class ResumableUploadManager {
  constructor(
    private readonly storage: Storage,
    private readonly store: UploadStore,
    private readonly timeoutMs: number
  ) {}

  async create(): Promise<Upload> {
    const upload = createUpload();
    await this.storage.init(upload);
    await this.store.create(upload);
    return upload;
  }

  async find(urlPath: string): Promise<Upload | undefined> {
    const token = getTokenFromPath(urlPath);
    if (token === undefined) {
      return undefined;
    }

    const upload = await this.store.find(token);
    if (upload?.timer !== undefined) {
      clearTimeout(upload.timer);
      upload.timer = setTimeout(() => {
        console.log(
          `[Upload] Timeout: removing upload ${upload.token} after idle`
        );
        void this.storage.abort(upload);
        void this.store.delete(upload.token);
      }, this.timeoutMs);
    }

    return upload;
  }

  async save(upload: Upload): Promise<void> {
    await this.store.save(upload);
  }

  async delete(upload: Upload): Promise<void> {
    await this.store.delete(upload.token);
  }

  async remove(urlPath: string): Promise<void> {
    const token = getTokenFromPath(urlPath);
    if (token === undefined) {
      return;
    }

    const upload = await this.store.find(token);
    if (upload === undefined) {
      return;
    }

    await this.storage.abort(upload);
    await this.store.delete(token);
  }

  getResumePath(upload: Upload): string {
    return getResumePath(upload.token);
  }
}
