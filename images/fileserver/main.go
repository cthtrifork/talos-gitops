// fileserver: a small file server in three modes, one container each in the same pod (see README.md).
//
//	--mode=public  GET /<name> from the public directory, read-only mount
//	--mode=admin   admin page and JSON API, reached through the Omni service exposer
//	--mode=upload  PUT /v1/files/<name> for CI, authenticated with a bearer token from a mounted Secret
//
// The token Secret is written by a CronJob (k8s/apps/fileserver); the app only reads it.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int64) int64 {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 0 {
		slog.Error("invalid number", "env", key, "value", v)
		os.Exit(2)
	}
	return n
}

// The token directory may not exist before the first rotation: uploads are refused until it does.
func tokenAuth() *TokenAuth { return NewTokenAuth(env("TOKEN_DIR", "/var/run/fileserver-token")) }

func main() {
	mode := flag.String("mode", "", "public, admin or upload")
	flag.Parse()

	dataDir := env("DATA_DIR", "/data")
	maxBytes := envInt("MAX_FILE_BYTES", 8<<30)
	minFree := envInt("MIN_FREE_BYTES", 256<<20)
	healthAddr := env("HEALTH_ADDR", ":9102")

	var handler http.Handler
	var addr string
	switch *mode {
	case "public":
		// the public container mounts only public/, read-only
		root, err := os.OpenRoot(env("PUBLIC_DIR", dataDir+"/public"))
		fatal(err)
		handler, addr = publicHandler(root), env("LISTEN_ADDR", ":8080")
	case "admin":
		s, err := NewStore(dataDir, uint64(minFree))
		fatal(err)
		a := tokenAuth()
		m.addCollector(storeCollector(s))
		m.addCollector(tokenCollector(a))
		cfg := adminConfig{PublicURL: strings.TrimRight(os.Getenv("PUBLIC_URL"), "/"), UploadURL: strings.TrimRight(os.Getenv("UPLOAD_URL"), "/")}
		handler, addr = adminHandler(s, a, maxBytes, cfg), env("LISTEN_ADDR", ":8081")
	case "upload":
		s, err := NewStore(dataDir, uint64(minFree))
		fatal(err)
		a := tokenAuth()
		m.addCollector(storeCollector(s))
		m.addCollector(tokenCollector(a))
		handler, addr = uploadHandler(s, a, maxBytes), env("LISTEN_ADDR", ":8082")
	default:
		fatal(fmt.Errorf("--mode must be public, admin or upload"))
	}
	// no read/write timeout: files are several GiB; header and idle timeouts still bound slow clients
	// No overall read/write timeout: images are several GiB. Header and idle timeouts still bound slow clients.
	srv := &http.Server{Addr: addr, Handler: m.instrument(*mode, handler), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 2 * time.Minute}
	health := &http.Server{Addr: healthAddr, ReadHeaderTimeout: 5 * time.Second, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/healthz":
			_, _ = w.Write([]byte("ok\n"))
		case "/metrics":
			m.ServeHTTP(w, r)
		default:
			http.NotFound(w, r)
		}
	})}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	errc := make(chan error, 2)
	go func() { errc <- srv.ListenAndServe() }()
	go func() { errc <- health.ListenAndServe() }()
	slog.Info("listening", "mode", *mode, "addr", addr)

	select {
	case err := <-errc:
		fatal(err)
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdown)
	_ = health.Shutdown(shutdown)
}

func fatal(err error) {
	if err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}
