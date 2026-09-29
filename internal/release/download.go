package release

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Download writes the file at url to path. It writes path.part first, so
// that path holds only a complete download.
func Download(ctx context.Context, url, path, version string) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "flux/"+version)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: %s", url, resp.Status)
	}
	f, err := os.Create(path + ".part")
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		os.Remove(path + ".part")
		return fmt.Errorf("download %s: %w", url, err)
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(path+".part", path)
}

// Verify compares the SHA-256 checksum of path with its line in the
// SHA256SUMS file sums.
func Verify(path, sums string) error {
	f, err := os.Open(sums)
	if err != nil {
		return err
	}
	defer f.Close()
	name := filepath.Base(path)
	want := ""
	s := bufio.NewScanner(f)
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == name {
			want = fields[0]
		}
	}
	if want == "" {
		return fmt.Errorf("SHA256SUMS has no line for %s", name)
	}
	in, err := os.Open(path)
	if err != nil {
		return err
	}
	defer in.Close()
	h := sha256.New()
	if _, err := io.Copy(h, in); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return fmt.Errorf("the SHA-256 checksum of %s is %s, and SHA256SUMS gives %s", name, got, want)
	}
	return nil
}

// Fetch downloads the file at url into dir and checks it against the
// SHA256SUMS file at sumsURL. It returns the path of the file. A file that
// fails the check is removed.
func Fetch(ctx context.Context, url, sumsURL, dir, version string) (string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	path := filepath.Join(dir, filepath.Base(url))
	sums := filepath.Join(dir, "SHA256SUMS")
	if err := Download(ctx, sumsURL, sums, version); err != nil {
		return "", err
	}
	defer os.Remove(sums)
	// A file from an earlier download that passes the check is complete.
	if Verify(path, sums) == nil {
		return path, nil
	}
	if err := Download(ctx, url, path, version); err != nil {
		return "", err
	}
	if err := Verify(path, sums); err != nil {
		os.Remove(path)
		return "", fmt.Errorf("%w. Flux removed the file", err)
	}
	return path, nil
}
