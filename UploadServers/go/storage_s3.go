package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

type S3Storage struct {
	client   *s3.Client
	bucket   string
	prefix   string
	partSize int
}

func NewS3Storage(cfg Config) (*S3Storage, error) {
	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background(),
		awsconfig.WithRegion(cfg.AWSRegion))
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}

	client := s3.NewFromConfig(awsCfg, func(o *s3.Options) {
		if cfg.S3Endpoint != "" {
			o.BaseEndpoint = aws.String(cfg.S3Endpoint)
			o.UsePathStyle = true // Required for MinIO
		}
	})

	return &S3Storage{
		client:   client,
		bucket:   cfg.S3Bucket,
		prefix:   cfg.S3KeyPrefix,
		partSize: cfg.S3PartSize,
	}, nil
}

func (s *S3Storage) Init(ctx context.Context, u *upload) error {
	var b [16]byte
	rand.Read(b[:])
	key := s.prefix + hex.EncodeToString(b[:])

	out, err := s.client.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{
		Bucket: aws.String(s.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return fmt.Errorf("create multipart upload: %w", err)
	}

	u.backendState = &s3State{
		key:         key,
		uploadID:    *out.UploadId,
		nextPartNum: 1,
	}
	return nil
}

func (s *S3Storage) Write(ctx context.Context, r io.Reader, u *upload) (int64, error) {
	st := u.backendState.(*s3State)

	var bytesReceived int64
	start := time.Now()
	lastLog := start
	buf := make([]byte, 1_048_576) // 1MB read buffer

	for {
		n, err := r.Read(buf)
		if n > 0 {
			st.pendingBuf = append(st.pendingBuf, buf[:n]...)
			bytesReceived += int64(n)

			// Flush when buffer reaches part size
			for len(st.pendingBuf) >= s.partSize {
				if fErr := s.flushPart(ctx, st, s.partSize); fErr != nil {
					return bytesReceived, fErr
				}
			}

			now := time.Now()
			if now.Sub(lastLog).Seconds() >= logIntervalSecs {
				elapsed := now.Sub(start).Seconds()
				speed := float64(bytesReceived) / elapsed / 1_048_576
				fmt.Printf("[Upload] Progress: %s received, %.1f MB/s\n",
					formatBytes(u.offset+bytesReceived), speed)
				lastLog = now
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return bytesReceived, fmt.Errorf("read body: %w", err)
		}
	}

	elapsed := time.Since(start).Seconds()
	speed := 0.0
	if elapsed > 0 {
		speed = float64(bytesReceived) / elapsed / 1_048_576
	}
	fmt.Printf("[Upload] Request complete: %s total (%s this request) in %.2fs (%.1f MB/s) -> s3://%s/%s\n",
		formatBytes(u.offset+bytesReceived), formatBytes(bytesReceived), elapsed, speed, s.bucket, st.key)

	return bytesReceived, nil
}

func (s *S3Storage) flushPart(ctx context.Context, st *s3State, size int) error {
	data := st.pendingBuf[:size]
	partNum := st.nextPartNum

	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		out, err := s.client.UploadPart(ctx, &s3.UploadPartInput{
			Bucket:     aws.String(s.bucket),
			Key:        aws.String(st.key),
			UploadId:   aws.String(st.uploadID),
			PartNumber: aws.Int32(partNum),
			Body:       bytes.NewReader(data),
		})
		if err != nil {
			lastErr = err
			fmt.Printf("[Upload] UploadPart %d attempt %d failed: %s\n", partNum, attempt+1, err)
			continue
		}

		st.completedParts = append(st.completedParts, types.CompletedPart{
			ETag:       out.ETag,
			PartNumber: aws.Int32(partNum),
		})
		st.nextPartNum++
		// Remove flushed bytes from buffer
		st.pendingBuf = st.pendingBuf[size:]
		return nil
	}
	return fmt.Errorf("upload part %d failed after 3 attempts: %w", partNum, lastErr)
}

func (s *S3Storage) Complete(ctx context.Context, u *upload) error {
	st := u.backendState.(*s3State)

	// Flush remaining bytes as the final part
	if len(st.pendingBuf) > 0 {
		if err := s.flushPart(ctx, st, len(st.pendingBuf)); err != nil {
			return err
		}
	}

	_, err := s.client.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{
		Bucket:   aws.String(s.bucket),
		Key:      aws.String(st.key),
		UploadId: aws.String(st.uploadID),
		MultipartUpload: &types.CompletedMultipartUpload{
			Parts: st.completedParts,
		},
	})
	if err != nil {
		return fmt.Errorf("complete multipart upload: %w", err)
	}
	return nil
}

func (s *S3Storage) Abort(ctx context.Context, u *upload) error {
	st := u.backendState.(*s3State)
	_, err := s.client.AbortMultipartUpload(ctx, &s3.AbortMultipartUploadInput{
		Bucket:   aws.String(s.bucket),
		Key:      aws.String(st.key),
		UploadId: aws.String(st.uploadID),
	})
	if err != nil {
		return fmt.Errorf("abort multipart upload: %w", err)
	}
	return nil
}

func (s *S3Storage) Location(u *upload) string {
	st := u.backendState.(*s3State)
	return fmt.Sprintf("s3://%s/%s", s.bucket, st.key)
}
