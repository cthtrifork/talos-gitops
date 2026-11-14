package main

import (
	"crypto/subtle"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"
)

var errUnauthorized = errors.New("missing or invalid token")

// TokenAuth reads the token from the mounted Secret: the files current and rotated-at. A rotation restarts the pod (Reloader).
type TokenAuth struct{ dir string }

func NewTokenAuth(dir string) *TokenAuth { return &TokenAuth{dir: dir} }

func (a *TokenAuth) read(name string) string {
	b, err := os.ReadFile(filepath.Join(a.dir, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func (a *TokenAuth) rotatedAt() time.Time {
	t, _ := time.Parse(time.RFC3339, a.read("rotated-at"))
	return t
}

// Check accepts "Bearer <token>" when it is the current token.
func (a *TokenAuth) Check(header string) error {
	tok, ok := strings.CutPrefix(header, "Bearer ")
	cur := a.read("current")
	if !ok || tok == "" || cur == "" || subtle.ConstantTimeCompare([]byte(tok), []byte(cur)) != 1 {
		return errUnauthorized
	}
	return nil
}

// TokenInfo is what the admin page shows.
type TokenInfo struct {
	Current   string     `json:"current"`
	RotatedAt *time.Time `json:"rotatedAt,omitempty"`
}

func (a *TokenAuth) Info() TokenInfo {
	info := TokenInfo{Current: a.read("current")}
	if r := a.rotatedAt(); !r.IsZero() {
		info.RotatedAt = &r
	}
	return info
}
