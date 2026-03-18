package main

import (
	"context"
	"io"

	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// Storage abstracts the destination for upload bytes.
type Storage interface {
	Init(ctx context.Context, u *upload) error
	Write(ctx context.Context, r io.Reader, u *upload) (int64, error)
	Complete(ctx context.Context, u *upload) error
	Abort(ctx context.Context, u *upload) error
	Location(u *upload) string
}

// localState holds per-upload state for local disk storage.
type localState struct {
	filePath string
}

// s3State holds per-upload state for S3 multipart upload.
type s3State struct {
	key            string
	uploadID       string
	completedParts []types.CompletedPart
	pendingBuf     []byte
	nextPartNum    int32
}
