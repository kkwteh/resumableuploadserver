# Resumable Upload Server (Go)

A resumable upload server implementing `draft-ietf-httpbis-resumable-upload` with support for local disk and S3 storage backends.

## Build

```bash
go build -o resumable-upload-server .
```

## Usage

```bash
./resumable-upload-server [port] [origin]
```

### Local disk mode (default)

No configuration needed. Uploads are written to the `uploads/` directory.

```bash
./resumable-upload-server 8080
```

### S3 mode

Set `S3_BUCKET` to enable S3 multipart uploads. The server buffers incoming bytes in memory and flushes them as S3 parts (default 8MB each).

```bash
export S3_BUCKET=my-bucket
export AWS_REGION=us-east-1
./resumable-upload-server 8080
```

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `S3_BUCKET` | For S3 mode | — | S3 bucket name. If unset, uses local disk. |
| `S3_KEY_PREFIX` | No | `""` | Prefix prepended to S3 object keys. |
| `S3_PART_SIZE` | No | `8388608` (8MB) | Multipart part size in bytes. Minimum 5MB. |
| `S3_ENDPOINT` | No | — | Custom S3 endpoint URL (for MinIO/LocalStack). |
| `AWS_REGION` | No | `us-east-1` | AWS region. |
| `AWS_ACCESS_KEY_ID` | For S3 mode | — | AWS credentials (or use other SDK credential methods). |
| `AWS_SECRET_ACCESS_KEY` | For S3 mode | — | AWS credentials. |

## Local testing with MinIO

[MinIO](https://min.io/) is an S3-compatible object store you can run locally via Docker.

### 1. Start MinIO

```bash
docker run -d --name minio -p 9000:9000 -p 9001:9001 \
  minio/minio server /data --console-address ":9001"
```

Default credentials: `minioadmin` / `minioadmin`
Web console: http://localhost:9001

### 2. Create a test bucket

Using the AWS CLI:

```bash
aws --endpoint-url http://localhost:9000 s3 mb s3://test-uploads
```

Or create it through the MinIO web console at http://localhost:9001.

### 3. Run the server against MinIO

```bash
export S3_BUCKET=test-uploads
export S3_ENDPOINT=http://localhost:9000
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin
export AWS_REGION=us-east-1
./resumable-upload-server 8080
```

You should see:

```
Storage: S3 (bucket=test-uploads, prefix="", partSize=8388608)
S3 Endpoint: http://localhost:9000
```

### 4. Run the benchmark

```bash
cd ..
python3 benchmark.py --port 8080 --sizes 10 --iterations 1
```

The response JSON will include `"file": "s3://test-uploads/..."`. You can verify the uploaded object in the MinIO console.

### 5. Clean up

```bash
docker stop minio && docker rm minio
```
