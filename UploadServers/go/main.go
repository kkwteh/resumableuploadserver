package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"math/big"
	"net/http"
	"os"
	"path/filepath"
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
	token     string
	filePath  string
	offset    int64
	complete  bool
	startTime time.Time
	timer     *time.Timer
}

// uploadManager holds all active uploads.
type uploadManager struct {
	mu      sync.Mutex
	origin  string
	uploads map[string]*upload
}

func newUploadManager(origin string) *uploadManager {
	return &uploadManager{
		origin:  origin,
		uploads: make(map[string]*upload),
	}
}

func randomToken() string {
	max := new(big.Int).SetUint64(1<<48 - 1)
	a, _ := rand.Int(rand.Reader, max)
	b, _ := rand.Int(rand.Reader, max)
	return fmt.Sprintf("%d-%d", a, b)
}

func (m *uploadManager) create() *upload {
	token := randomToken()
	var b [16]byte
	rand.Read(b[:])
	filePath := filepath.Join(uploadsDir, hex.EncodeToString(b[:]))

	u := &upload{
		token:     token,
		filePath:  filePath,
		offset:    0,
		complete:  false,
		startTime: time.Now(),
	}

	m.mu.Lock()
	m.uploads[token] = u
	m.mu.Unlock()

	// Idle timeout
	u.timer = time.AfterFunc(idleTimeout, func() {
		fmt.Printf("[Upload] Timeout: removing upload %s after idle\n", token)
		m.mu.Lock()
		delete(m.uploads, token)
		m.mu.Unlock()
	})

	return u
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

// formatBytes formats a byte count for display.
func formatBytes(bytes int64) string {
	switch {
	case bytes >= 1_073_741_824:
		return fmt.Sprintf("%.2f GB", float64(bytes)/1_073_741_824)
	case bytes >= 1_048_576:
		return fmt.Sprintf("%.1f MB", float64(bytes)/1_048_576)
	case bytes >= 1024:
		return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}

// parseUploadIncomplete parses the Upload-Incomplete structured field boolean.
// Returns (value, present).
func parseUploadIncomplete(v string) (bool, bool) {
	switch v {
	case "?1":
		return true, true
	case "?0":
		return false, true
	default:
		return false, false
	}
}

func formatUploadIncomplete(incomplete bool) string {
	if incomplete {
		return "?1"
	}
	return "?0"
}

func setCommonHeaders(w http.ResponseWriter) {
	w.Header().Set("Upload-Draft-Interop-Version", interopVersion)
	w.Header().Set("Connection", "close")
}

// streamBodyToFile reads the request body and appends it to the upload's file.
// Returns the number of bytes written.
func streamBodyToFile(r *http.Request, u *upload) (int64, error) {
	flags := os.O_WRONLY | os.O_CREATE
	if u.offset == 0 {
		flags |= os.O_TRUNC
	} else {
		flags |= os.O_APPEND
	}

	f, err := os.OpenFile(u.filePath, flags, 0644)
	if err != nil {
		return 0, fmt.Errorf("open file: %w", err)
	}
	defer f.Close()

	var bytesReceived int64
	start := time.Now()
	lastLog := start
	buf := make([]byte, 1_048_576) // 1MB buffer

	for {
		n, err := r.Body.Read(buf)
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
		formatBytes(u.offset+bytesReceived), formatBytes(bytesReceived), elapsed, speed, u.filePath)

	return bytesReceived, nil
}

type completionResponse struct {
	BytesReceived  int64   `json:"bytes_received"`
	ElapsedSeconds float64 `json:"elapsed_seconds"`
	SpeedMbps      float64 `json:"speed_mbps"`
	File           string  `json:"file"`
}

func sendUploadComplete(w http.ResponseWriter, u *upload) {
	elapsed := time.Since(u.startTime).Seconds()
	speed := 0.0
	if elapsed > 0 {
		speed = float64(u.offset) / elapsed / 1_048_576
	}

	fmt.Printf("[Upload] Complete: %s in %.2fs (%.1f MB/s) -> %s\n",
		formatBytes(u.offset), elapsed, speed, u.filePath)

	resp := completionResponse{
		BytesReceived:  u.offset,
		ElapsedSeconds: math.Round(elapsed*100) / 100,
		SpeedMbps:      math.Round(speed*10) / 10,
		File:           u.filePath,
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
	port := "8080"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	origin := fmt.Sprintf("http://localhost:%s", port)
	if len(os.Args) > 2 {
		origin = os.Args[2]
	}

	if _, err := os.Stat(uploadsDir); os.IsNotExist(err) {
		os.MkdirAll(uploadsDir, 0755)
		fmt.Printf("Created %s/ directory\n", uploadsDir)
	}

	mgr := newUploadManager(origin)

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

				bytesWritten, err := streamBodyToFile(r, u)
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
					sendUploadComplete(w, u)
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
			u := mgr.create()

			fmt.Printf("[Upload] %s %s started -> %s (token: %s)\n",
				r.Method, urlPath, u.filePath, u.token)

			bytesWritten, err := streamBodyToFile(r, u)
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
				sendUploadComplete(w, u)
			} else {
				setCommonHeaders(w)
				w.Header().Set("Location", origin+u.resumePath())
				w.Header().Set("Upload-Incomplete", "?1")
				w.Header().Set("Upload-Offset", strconv.FormatInt(u.offset, 10))
				w.WriteHeader(201)
			}
			return
		}

		w.Header().Set("Content-Length", "0")
		w.WriteHeader(400)
	})

	addr := "0.0.0.0:" + port
	fmt.Printf("Starting resumable upload server on port %s\n", port)
	fmt.Printf("Origin: %s\n", origin)
	fmt.Printf("Usage: resumable-upload-server [port] [origin]\n")
	fmt.Printf("  Example: resumable-upload-server 8080 https://abc123.ngrok.io\n")
	fmt.Println()
	fmt.Printf("Server listening on %s\n", addr)
	fmt.Printf("Ready for uploads. POST to %s/upload\n", origin)
	fmt.Println()

	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintf(os.Stderr, "Server error: %s\n", err)
		os.Exit(1)
	}
}
