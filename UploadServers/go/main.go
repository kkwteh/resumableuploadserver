package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	interopVersion  = "3"
	uploadsDir      = "uploads"
	resumePrefix    = "/resumable_upload/"
	idleTimeout     = 1 * time.Hour
	logIntervalSecs = 2.0
)

// upload tracks a single resumable upload session.
type upload struct {
	token        string
	backendState interface{}
	offset       int64
	complete     bool
	startTime    time.Time
	timer        *time.Timer
}

// uploadManager holds all active uploads.
type uploadManager struct {
	mu      sync.Mutex
	origin  string
	storage Storage
	uploads map[string]*upload
}

func newUploadManager(origin string, storage Storage) *uploadManager {
	return &uploadManager{
		origin:  origin,
		storage: storage,
		uploads: make(map[string]*upload),
	}
}

func (m *uploadManager) create(ctx context.Context) (*upload, error) {
	token := randomToken()

	u := &upload{
		token:     token,
		offset:    0,
		complete:  false,
		startTime: time.Now(),
	}

	if err := m.storage.Init(ctx, u); err != nil {
		return nil, err
	}

	m.mu.Lock()
	m.uploads[token] = u
	m.mu.Unlock()

	// Idle timeout
	u.timer = time.AfterFunc(idleTimeout, func() {
		fmt.Printf("[Upload] Timeout: removing upload %s after idle\n", token)
		m.storage.Abort(context.Background(), u)
		m.mu.Lock()
		delete(m.uploads, token)
		m.mu.Unlock()
	})

	return u, nil
}

func (m *uploadManager) find(path string) *upload {
	if !strings.HasPrefix(path, resumePrefix) {
		return nil
	}
	token := path[len(resumePrefix):]
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.uploads[token]
}

func (m *uploadManager) remove(path string) {
	if !strings.HasPrefix(path, resumePrefix) {
		return
	}
	token := path[len(resumePrefix):]
	m.mu.Lock()
	u := m.uploads[token]
	if u != nil {
		if u.timer != nil {
			u.timer.Stop()
		}
		m.storage.Abort(context.Background(), u)
		delete(m.uploads, token)
	}
	m.mu.Unlock()
}

func (u *upload) resumePath() string {
	return resumePrefix + u.token
}

func (u *upload) resetTimer() {
	if u.timer != nil {
		u.timer.Reset(idleTimeout)
	}
}

type completionResponse struct {
	BytesReceived  int64   `json:"bytes_received"`
	ElapsedSeconds float64 `json:"elapsed_seconds"`
	SpeedMbps      float64 `json:"speed_mbps"`
	File           string  `json:"file"`
}

func sendUploadComplete(w http.ResponseWriter, u *upload, storage Storage) {
	elapsed := time.Since(u.startTime).Seconds()
	speed := 0.0
	if elapsed > 0 {
		speed = float64(u.offset) / elapsed / 1_048_576
	}

	location := storage.Location(u)
	fmt.Printf("[Upload] Complete: %s in %.2fs (%.1f MB/s) -> %s\n",
		formatBytes(u.offset), elapsed, speed, location)

	resp := completionResponse{
		BytesReceived:  u.offset,
		ElapsedSeconds: math.Round(elapsed*100) / 100,
		SpeedMbps:      math.Round(speed*10) / 10,
		File:           location,
	}
	body, _ := json.Marshal(resp)

	setCommonHeaders(w)
	w.Header().Set("Upload-Incomplete", "?0")
	w.Header().Set("Upload-Offset", strconv.FormatInt(u.offset, 10))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(200)
	w.Write(body)
}

func main() {
	cfg := LoadConfig()

	var storage Storage
	if cfg.UseS3() {
		s3s, err := NewS3Storage(cfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to initialize S3 storage: %s\n", err)
			os.Exit(1)
		}
		storage = s3s
		fmt.Printf("Storage: S3 (bucket=%s, prefix=%q, partSize=%d)\n", cfg.S3Bucket, cfg.S3KeyPrefix, cfg.S3PartSize)
		if cfg.S3Endpoint != "" {
			fmt.Printf("S3 Endpoint: %s\n", cfg.S3Endpoint)
		}
	} else {
		storage = NewLocalStorage()
		fmt.Println("Storage: local disk")
	}

	mgr := newUploadManager(cfg.Origin, storage)

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		interop := r.Header.Get("Upload-Draft-Interop-Version")
		if interop != interopVersion {
			w.Header().Set("Content-Length", "0")
			w.WriteHeader(400)
			return
		}

		urlPath := r.URL.Path
		incompleteStr := r.Header.Get("Upload-Incomplete")
		offsetStr := r.Header.Get("Upload-Offset")

		incomplete, hasIncomplete := parseUploadIncomplete(incompleteStr)
		var offset int64
		hasOffset := false
		if offsetStr != "" {
			var err error
			offset, err = strconv.ParseInt(offsetStr, 10, 64)
			if err == nil {
				hasOffset = true
			}
		}

		ctx := r.Context()

		// Resumption path requests
		if strings.HasPrefix(urlPath, resumePrefix) {
			u := mgr.find(urlPath)
			if u == nil {
				setCommonHeaders(w)
				w.Header().Set("Content-Length", "0")
				w.WriteHeader(404)
				return
			}
			u.resetTimer()

			switch r.Method {
			case http.MethodHead:
				if hasIncomplete || hasOffset {
					setCommonHeaders(w)
					w.Header().Set("Content-Length", "0")
					w.WriteHeader(400)
					return
				}
				setCommonHeaders(w)
				w.Header().Set("Upload-Incomplete", formatUploadIncomplete(!u.complete))
				w.Header().Set("Upload-Offset", strconv.FormatInt(u.offset, 10))
				w.Header().Set("Cache-Control", "no-store")
				w.WriteHeader(204)

			case http.MethodPatch:
				if !hasOffset {
					setCommonHeaders(w)
					w.Header().Set("Content-Length", "0")
					w.WriteHeader(400)
					return
				}
				if offset != u.offset {
					setCommonHeaders(w)
					w.Header().Set("Upload-Incomplete", formatUploadIncomplete(!u.complete))
					w.Header().Set("Upload-Offset", strconv.FormatInt(u.offset, 10))
					w.Header().Set("Content-Length", "0")
					w.WriteHeader(409)
					return
				}

				isComplete := true
				if hasIncomplete {
					isComplete = !incomplete
				}

				bytesWritten, err := mgr.storage.Write(ctx, r.Body, u)
				if err != nil {
					fmt.Printf("[Upload] Error: %s\n", err)
					w.WriteHeader(500)
					return
				}

				u.offset += bytesWritten
				if isComplete {
					u.complete = true
				}

				if u.complete {
					if err := mgr.storage.Complete(ctx, u); err != nil {
						fmt.Printf("[Upload] Complete error: %s\n", err)
						w.WriteHeader(500)
						return
					}
					sendUploadComplete(w, u, mgr.storage)
				} else {
					setCommonHeaders(w)
					w.Header().Set("Upload-Incomplete", "?1")
					w.Header().Set("Upload-Offset", strconv.FormatInt(u.offset, 10))
					w.WriteHeader(201)
				}

			case http.MethodDelete:
				if hasIncomplete || hasOffset {
					setCommonHeaders(w)
					w.Header().Set("Content-Length", "0")
					w.WriteHeader(400)
					return
				}
				mgr.remove(urlPath)
				setCommonHeaders(w)
				w.WriteHeader(204)

			default:
				setCommonHeaders(w)
				w.Header().Set("Content-Length", "0")
				w.WriteHeader(400)
			}
			return
		}

		// Upload creation
		if hasIncomplete {
			if hasOffset && offset != 0 {
				setCommonHeaders(w)
				w.Header().Set("Content-Length", "0")
				w.WriteHeader(400)
				return
			}

			isComplete := !incomplete
			u, err := mgr.create(ctx)
			if err != nil {
				fmt.Printf("[Upload] Init error: %s\n", err)
				w.WriteHeader(500)
				return
			}

			fmt.Printf("[Upload] %s %s started -> %s (token: %s)\n",
				r.Method, urlPath, mgr.storage.Location(u), u.token)

			bytesWritten, err := mgr.storage.Write(ctx, r.Body, u)
			if err != nil {
				fmt.Printf("[Upload] Error: %s\n", err)
				w.WriteHeader(500)
				return
			}

			u.offset += bytesWritten
			if isComplete {
				u.complete = true
			}

			if u.complete {
				if err := mgr.storage.Complete(ctx, u); err != nil {
					fmt.Printf("[Upload] Complete error: %s\n", err)
					w.WriteHeader(500)
					return
				}
				sendUploadComplete(w, u, mgr.storage)
			} else {
				setCommonHeaders(w)
				w.Header().Set("Location", cfg.Origin+u.resumePath())
				w.Header().Set("Upload-Incomplete", "?1")
				w.Header().Set("Upload-Offset", strconv.FormatInt(u.offset, 10))
				w.WriteHeader(201)
			}
			return
		}

		w.Header().Set("Content-Length", "0")
		w.WriteHeader(400)
	})

	addr := "0.0.0.0:" + cfg.Port
	fmt.Printf("Starting resumable upload server on port %s\n", cfg.Port)
	fmt.Printf("Origin: %s\n", cfg.Origin)
	fmt.Printf("Usage: resumable-upload-server [port] [origin]\n")
	fmt.Printf("  Example: resumable-upload-server 8080 https://abc123.ngrok.io\n")
	fmt.Println()
	fmt.Printf("Server listening on %s\n", addr)
	fmt.Printf("Ready for uploads. POST to %s/upload\n", cfg.Origin)
	fmt.Println()

	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %s\n", err)
		os.Exit(1)
	}
}
