package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

type LocalStorage struct{}

func NewLocalStorage() *LocalStorage {
	if _, err := os.Stat(uploadsDir); os.IsNotExist(err) {
		os.MkdirAll(uploadsDir, 0755)
		fmt.Printf("Created %s/ directory\n", uploadsDir)
	}
	return &LocalStorage{}
}

func (s *LocalStorage) Init(_ context.Context, u *upload) error {
	var b [16]byte
	rand.Read(b[:])
	filePath := filepath.Join(uploadsDir, hex.EncodeToString(b[:]))
	u.backendState = &localState{filePath: filePath}
	return nil
}

func (s *LocalStorage) Write(_ context.Context, r io.Reader, u *upload) (int64, error) {
	st := u.backendState.(*localState)

	flags := os.O_WRONLY | os.O_CREATE
	if u.offset == 0 {
		flags |= os.O_TRUNC
	} else {
		flags |= os.O_APPEND
	}

	f, err := os.OpenFile(st.filePath, flags, 0644)
	if err != nil {
		return 0, fmt.Errorf("open file: %w", err)
	}
	defer f.Close()

	var bytesReceived int64
	start := time.Now()
	lastLog := start
	buf := make([]byte, 1_048_576) // 1MB buffer

	for {
		n, err := r.Read(buf)
		if n > 0 {
			if _, wErr := f.Write(buf[:n]); wErr != nil {
				return bytesReceived, fmt.Errorf("write: %w", wErr)
			}
			bytesReceived += int64(n)

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
	fmt.Printf("[Upload] Request complete: %s total (%s this request) in %.2fs (%.1f MB/s) -> %s\n",
		formatBytes(u.offset+bytesReceived), formatBytes(bytesReceived), elapsed, speed, st.filePath)

	return bytesReceived, nil
}

func (s *LocalStorage) Complete(_ context.Context, _ *upload) error {
	return nil
}

func (s *LocalStorage) Abort(_ context.Context, u *upload) error {
	st := u.backendState.(*localState)
	return os.Remove(st.filePath)
}

func (s *LocalStorage) Location(u *upload) string {
	st := u.backendState.(*localState)
	return st.filePath
}
