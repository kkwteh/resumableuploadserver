package main

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"net/http"
)

func randomToken() string {
	max := new(big.Int).SetUint64(1<<48 - 1)
	a, _ := rand.Int(rand.Reader, max)
	b, _ := rand.Int(rand.Reader, max)
	return fmt.Sprintf("%d-%d", a, b)
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
