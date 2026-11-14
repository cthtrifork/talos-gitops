package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Hand-written Prometheus text format (no dependencies), served on HEALTH_ADDR, which is not routed outside the pod.

type metrics struct {
	mu          sync.Mutex
	reqs        map[[3]string]uint64 // mode, method, code
	uploads     map[string]uint64    // result
	uploadBytes atomic.Uint64
	inflight    atomic.Int64
	collectors  []func(w io.Writer)
	started     time.Time
}

var m = &metrics{reqs: map[[3]string]uint64{}, uploads: map[string]uint64{}, started: time.Now()}

type statusWriter struct {
	http.ResponseWriter
	code int
}

func (w *statusWriter) WriteHeader(c int) {
	if w.code == 0 {
		w.code = c
	}
	w.ResponseWriter.WriteHeader(c)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.code == 0 {
		w.code = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

// ReadFrom keeps the sendfile path of io.Copy for downloads.
func (w *statusWriter) ReadFrom(r io.Reader) (int64, error) {
	if w.code == 0 {
		w.code = http.StatusOK
	}
	if rf, ok := w.ResponseWriter.(io.ReaderFrom); ok {
		return rf.ReadFrom(r)
	}
	return io.Copy(struct{ io.Writer }{w.ResponseWriter}, r)
}

func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

// instrument counts requests per mode, method and status, and the requests in flight.
func (m *metrics) instrument(mode string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		m.inflight.Add(1)
		defer m.inflight.Add(-1)
		sw := &statusWriter{ResponseWriter: w}
		h.ServeHTTP(sw, r)
		if sw.code == 0 {
			sw.code = http.StatusOK
		}
		m.mu.Lock()
		m.reqs[[3]string{mode, methodLabel(r.Method), fmt.Sprint(sw.code)}]++
		m.mu.Unlock()
	})
}

// methodLabel bounds the method label: a client can send any method.
func methodLabel(m string) string {
	switch m {
	case http.MethodGet, http.MethodHead, http.MethodPut, http.MethodPost, http.MethodDelete:
		return m
	}
	return "other"
}

// uploadResult is the label of fileserver_uploads_total.
func uploadResult(err error) string {
	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, ErrClash):
		return "clash"
	case errors.Is(err, ErrTooLarge):
		return "too_large"
	case errors.Is(err, ErrNoSpace):
		return "no_space"
	case errors.Is(err, ErrChecksum):
		return "checksum"
	case errors.Is(err, ErrBadName), errors.Is(err, ErrBadSum):
		return "bad_request"
	}
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		return "too_large"
	}
	return "error"
}

func (m *metrics) countUpload(err error, bytes int64) {
	m.mu.Lock()
	m.uploads[uploadResult(err)]++
	m.mu.Unlock()
	if err == nil && bytes > 0 {
		m.uploadBytes.Add(uint64(bytes))
	}
}

func (m *metrics) addCollector(f func(w io.Writer)) {
	m.mu.Lock()
	m.collectors = append(m.collectors, f)
	m.mu.Unlock()
}

func head(w io.Writer, name, typ, help string) {
	fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, typ)
}

func (m *metrics) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var b strings.Builder
	m.mu.Lock()
	keys := make([][3]string, 0, len(m.reqs))
	for k := range m.reqs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return fmt.Sprint(keys[i]) < fmt.Sprint(keys[j]) })
	head(&b, "fileserver_http_requests_total", "counter", "HTTP requests by mode, method and status code.")
	for _, k := range keys {
		fmt.Fprintf(&b, "fileserver_http_requests_total{mode=%q,method=%q,code=%q} %d\n", k[0], k[1], k[2], m.reqs[k])
	}
	results := make([]string, 0, len(m.uploads))
	for k := range m.uploads {
		results = append(results, k)
	}
	sort.Strings(results)
	head(&b, "fileserver_uploads_total", "counter", "Upload attempts by result (ok, clash, too_large, no_space, checksum, bad_request, error).")
	for _, k := range results {
		fmt.Fprintf(&b, "fileserver_uploads_total{result=%q} %d\n", k, m.uploads[k])
	}
	collectors := append([]func(io.Writer){}, m.collectors...)
	m.mu.Unlock()

	head(&b, "fileserver_upload_bytes_total", "counter", "Bytes stored by successful uploads.")
	fmt.Fprintf(&b, "fileserver_upload_bytes_total %d\n", m.uploadBytes.Load())
	head(&b, "fileserver_http_requests_in_flight", "gauge", "Requests being served now.")
	fmt.Fprintf(&b, "fileserver_http_requests_in_flight %d\n", m.inflight.Load())
	for _, c := range collectors {
		c(&b)
	}

	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	head(&b, "fileserver_go_goroutines", "gauge", "Goroutines.")
	fmt.Fprintf(&b, "fileserver_go_goroutines %d\n", runtime.NumGoroutine())
	head(&b, "fileserver_go_heap_alloc_bytes", "gauge", "Go heap in use.")
	fmt.Fprintf(&b, "fileserver_go_heap_alloc_bytes %d\n", ms.HeapAlloc)
	head(&b, "fileserver_start_time_seconds", "gauge", "Start time of the process.")
	fmt.Fprintf(&b, "fileserver_start_time_seconds %d\n", m.started.Unix())

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = io.WriteString(w, b.String())
}

// storeCollector reports files and free space at scrape time.
func storeCollector(s *Store) func(io.Writer) {
	return func(w io.Writer) {
		count := map[Visibility]int{}
		size := map[Visibility]int64{}
		if list, err := s.List(); err == nil {
			for _, e := range list {
				count[e.Visibility]++
				size[e.Visibility] += e.Size
			}
		}
		head(w, "fileserver_files", "gauge", "Stored files by visibility.")
		head(w, "fileserver_files_bytes", "gauge", "Bytes stored by visibility.")
		for _, v := range []Visibility{Public, Private} {
			fmt.Fprintf(w, "fileserver_files{visibility=%q} %d\n", v, count[v])
		}
		for _, v := range []Visibility{Public, Private} {
			fmt.Fprintf(w, "fileserver_files_bytes{visibility=%q} %d\n", v, size[v])
		}
		if free, err := s.freeBytes(); err == nil {
			head(w, "fileserver_disk_free_bytes", "gauge", "Free bytes on the volume.")
			fmt.Fprintf(w, "fileserver_disk_free_bytes %d\n", free)
		}
	}
}

// tokenCollector reports the last rotation, to alert when rotation stops.
func tokenCollector(a *TokenAuth) func(io.Writer) {
	return func(w io.Writer) {
		head(w, "fileserver_token_rotated_timestamp_seconds", "gauge", "Unix time of the last token rotation, 0 if there is no token.")
		var ts int64
		if r := a.rotatedAt(); !r.IsZero() {
			ts = r.Unix()
		}
		fmt.Fprintf(w, "fileserver_token_rotated_timestamp_seconds %d\n", ts)
	}
}
