const DEFAULT_PART_SIZE = 8 * 1024 * 1024;
const MIN_PART_SIZE = 5 * 1024 * 1024;

export type Config = {
  port: number;
  origin: string;
  uploadsDir: string;
  s3Bucket: string;
  s3KeyPrefix: string;
  s3Endpoint: string;
  s3PartSize: number;
  awsRegion: string;
  redisUrl: string;
};

function parsePartSize(rawValue: string | undefined): number {
  if (rawValue === undefined || rawValue === "") {
    return DEFAULT_PART_SIZE;
  }

  const parsedValue = Number.parseInt(rawValue, 10);
  if (Number.isNaN(parsedValue)) {
    return DEFAULT_PART_SIZE;
  }

  if (parsedValue < MIN_PART_SIZE) {
    console.warn(
      `Warning: S3_PART_SIZE ${parsedValue} is below minimum ${MIN_PART_SIZE}, using minimum`
    );
    return MIN_PART_SIZE;
  }

  return parsedValue;
}

export function loadConfig(argv: readonly string[]): Config {
  const port = Number.parseInt(argv[2] ?? "8080", 10);
  const origin = argv[3] ?? `http://localhost:${port}`;

  return {
    port,
    origin,
    uploadsDir: process.env.UPLOADS_DIR ?? "uploads",
    s3Bucket: process.env.S3_BUCKET ?? "",
    s3KeyPrefix: process.env.S3_KEY_PREFIX ?? "",
    s3Endpoint: process.env.S3_ENDPOINT ?? "",
    s3PartSize: parsePartSize(process.env.S3_PART_SIZE),
    awsRegion: process.env.AWS_REGION ?? "us-east-1",
    redisUrl: process.env.REDIS_URL ?? "",
  };
}
