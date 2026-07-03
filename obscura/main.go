package main

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const (
	port       = "8191"
	obscuraBin = "/obscura"
)

// --- FlareSolverr-compatible API types ---

type v1Request struct {
	Cmd        string `json:"cmd"`
	URL        string `json:"url"`
	MaxTimeout int    `json:"maxTimeout"`
}

type v1Response struct {
	Status         string      `json:"status"`
	Message        string      `json:"message"`
	StartTimestamp int64       `json:"startTimestamp,omitempty"`
	EndTimestamp   int64       `json:"endTimestamp,omitempty"`
	Version        string      `json:"version,omitempty"`
	Solution       *v1Solution `json:"solution,omitempty"`
}

type v1Solution struct {
	URL       string            `json:"url"`
	Status    int               `json:"status"`
	Headers   map[string]string `json:"headers"`
	Response  string            `json:"response"`
	Cookies   map[string]string `json:"cookies"`
	UserAgent string            `json:"userAgent"`
}

// --- handlers ---

func handleRoot(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func handleV1(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	if r.Method != http.MethodPost {
		slog.Warn("method not allowed", "method", r.Method, "remote", r.RemoteAddr)
		writeJSON(w, v1Response{
			Status:  "error",
			Message: fmt.Sprintf("Method %s not allowed, use POST", r.Method),
		})
		return
	}

	var req v1Request
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		slog.Warn("invalid json", "remote", r.RemoteAddr, "error", err)
		writeJSON(w, v1Response{
			Status:  "error",
			Message: fmt.Sprintf("Invalid JSON: %v", err),
		})
		return
	}

	if req.URL == "" {
		slog.Warn("missing url", "remote", r.RemoteAddr, "cmd", req.Cmd)
		writeJSON(w, v1Response{
			Status:  "error",
			Message: "Missing 'url' field",
		})
		return
	}

	logger := slog.With("cmd", req.Cmd, "url", req.URL, "timeout", req.MaxTimeout)

	switch req.Cmd {
	case "request.get":
		handleRequestGet(w, &req, logger)
	case "sessions.create":
		logger.Info("session create ignored")
		writeJSON(w, v1Response{
			Status:  "ok",
			Message: "session create ignored",
		})
	default:
		logger.Warn("unknown command")
		writeJSON(w, v1Response{
			Status:  "error",
			Message: fmt.Sprintf("Unsupported command: %s", req.Cmd),
		})
	}
}

func handleRequestGet(w http.ResponseWriter, req *v1Request, logger *slog.Logger) {
	start := time.Now()

	timeout := req.MaxTimeout
	if timeout <= 0 {
		timeout = 60000
	}

	// obscura --timeout is in seconds
	timeoutSec := timeout / 1000
	if timeoutSec < 1 {
		timeoutSec = 5
	}
	if timeoutSec > 120 {
		timeoutSec = 120
	}

	args := []string{
		"fetch", req.URL,
		"--dump", "html",
		"--timeout", strconv.Itoa(timeoutSec),
		"--quiet",
	}

	cmd := exec.Command(obscuraBin, args...)
	logger.Info("fetching", "args", strings.Join(args, " "))
	output, err := cmd.Output()
	elapsed := time.Since(start)

	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			errMsg := strings.TrimSpace(string(exitErr.Stderr))
			if errMsg == "" {
				errMsg = err.Error()
			}
			logger.Error("obscura failed", "error", errMsg, "elapsed", elapsed.String())
			writeJSON(w, v1Response{
				Status:  "error",
				Message: fmt.Sprintf("Obscura error: %s", errMsg),
			})
		} else {
			logger.Error("obscura exec error", "error", err, "elapsed", elapsed.String())
			writeJSON(w, v1Response{
				Status:  "error",
				Message: fmt.Sprintf("Obscura exec error: %v", err),
			})
		}
		return
	}

	logger.Info("fetched ok", "bytes", len(output), "elapsed", elapsed.String())

	writeJSON(w, v1Response{
		Status:         "ok",
		Message:        "",
		StartTimestamp: start.UnixMilli(),
		EndTimestamp:   time.Now().UnixMilli(),
		Version:        "1.0",
		Solution: &v1Solution{
			URL:       req.URL,
			Status:    200,
			Headers:   map[string]string{"Content-Type": "text/html"},
			Cookies:   make(map[string]string),
			Response:  string(output),
			UserAgent: "Obscura/1.0",
		},
	})
}

func writeJSON(w http.ResponseWriter, resp v1Response) {
	data, _ := json.Marshal(resp)
	w.Write(data)
}

// --- main ---

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRoot)
	mux.HandleFunc("/v1", handleV1)

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 120 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	slog.Info("listening", "port", port)
	if err := server.ListenAndServe(); err != nil {
		slog.Error("server error", "error", err)
		os.Exit(1)
	}
}
