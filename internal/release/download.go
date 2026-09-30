package release

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// The size limits of the downloads. They stop a wrong file before it fills
// the disk.
const (
	// maxAsset is the largest release file that Flux downloads. The APK
	// has about 75 MB.
	maxAsset = 512 << 20
	// maxSums is the largest SHA256SUMS file.
	maxSums = 64 << 10
	// maxSig is the largest SHA256SUMS.sig file.
	maxSig = 1 << 10
)

// open sends the GET request for url and checks the answer. size is the
// size that the release gives, or 0 when it is not known. limit is the
// largest size that Flux accepts.
func open(ctx context.Context, url, version string, size, limit int64) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "flux/"+version)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", url, err)
	}
	switch n := resp.ContentLength; {
	case resp.StatusCode != http.StatusOK:
		resp.Body.Close()
		return nil, fmt.Errorf("download %s: %s", url, resp.Status)
	case n > limit:
		resp.Body.Close()
		return nil, fmt.Errorf("download %s: the file has %d bytes, and the limit is %d", url, n, limit)
	case size > 0 && n >= 0 && n != size:
		resp.Body.Close()
		return nil, fmt.Errorf("download %s: the file has %d bytes, and the release gives %d", url, n, size)
	}
	return resp, nil
}

// get returns the file at url. The file has at most limit bytes.
func get(ctx context.Context, url, version string, limit int64) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	resp, err := open(ctx, url, version, 0, limit)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, fmt.Errorf("download %s: %w", url, err)
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("download %s: the file has more than %d bytes", url, limit)
	}
	return body, nil
}

// download writes the file at url to a new temporary file in dir. It
// returns the path of that file and its SHA-256 checksum. Each call has its
// own file, so 2 downloads at the same time do not change each other. size
// is the size that the release gives, or 0 when it is not known.
func download(ctx context.Context, url, dir, name string, size int64, version string) (string, string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	resp, err := open(ctx, url, version, size, maxAsset)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	f, err := os.CreateTemp(dir, name+".*.part")
	if err != nil {
		return "", "", err
	}
	fail := func(err error) (string, string, error) {
		f.Close()
		os.Remove(f.Name())
		return "", "", fmt.Errorf("download %s: %w", url, err)
	}
	limit := int64(maxAsset)
	if size > 0 {
		limit = size
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, limit+1))
	switch {
	case err != nil:
		return fail(err)
	case n > limit && size > 0:
		return fail(fmt.Errorf("the file has more bytes than the %d that the release gives", size))
	case n > limit:
		return fail(fmt.Errorf("the file has more than %d bytes", limit))
	case size > 0 && n != size:
		return fail(fmt.Errorf("the file has %d bytes, and the release gives %d", n, size))
	}
	if err := f.Close(); err != nil {
		os.Remove(f.Name())
		return "", "", err
	}
	return f.Name(), hex.EncodeToString(h.Sum(nil)), nil
}

// sumOf returns the SHA-256 checksum of name in the SHA256SUMS file sums.
func sumOf(sums []byte, name string) (string, error) {
	s := bufio.NewScanner(bytes.NewReader(sums))
	for s.Scan() {
		fields := strings.Fields(s.Text())
		if len(fields) != 2 || strings.TrimPrefix(fields[1], "*") != name {
			continue
		}
		if b, err := hex.DecodeString(fields[0]); err != nil || len(b) != sha256.Size {
			return "", fmt.Errorf("SHA256SUMS has no valid checksum for %s", name)
		}
		return strings.ToLower(fields[0]), nil
	}
	return "", fmt.Errorf("SHA256SUMS has no line for %s", name)
}

// fileSum returns the SHA-256 checksum of the file at path.
func fileSum(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// validName reports whether name can be the name of a file in the update
// folder. A release file has a name such as flux-android-0.7.0.apk.
func validName(name string) bool {
	if name == "" || len(name) > 200 || name[0] == '.' || name[0] == '-' {
		return false
	}
	for _, c := range name {
		ok := c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("._+-", c)
		if !ok {
			return false
		}
	}
	return true
}

// Fetch downloads the release file a into the private folder dir and
// checks it. It reads SHA256SUMS from sumsURL. When this build has a
// release key, it also reads SHA256SUMS.sig from sigURL and checks the
// signature before it trusts a line of SHA256SUMS. Fetch returns the path
// of the file, dir/a.Name, and its SHA-256 checksum from SHA256SUMS. A
// download that fails a check does not stay on disk. Only the rename of a
// checked file writes the path, so 2 calls at the same time do not change
// each other.
func Fetch(ctx context.Context, a Asset, sumsURL, sigURL, dir, version string) (string, string, error) {
	if !validName(a.Name) {
		return "", "", fmt.Errorf("%q is not a valid name for a release file", a.Name)
	}
	if a.Size > maxAsset {
		return "", "", fmt.Errorf("%s has %d bytes, and the limit is %d", a.Name, a.Size, int64(maxAsset))
	}
	if sumsURL == "" {
		return "", "", errors.New("the release has no SHA256SUMS, so Flux cannot check the download")
	}
	sums, err := get(ctx, sumsURL, version, maxSums)
	if err != nil {
		return "", "", err
	}
	if releaseKey != "" {
		if sigURL == "" {
			return "", "", errors.New("the release has no SHA256SUMS.sig, so Flux cannot check who made it")
		}
		sig, err := get(ctx, sigURL, version, maxSig)
		if err != nil {
			return "", "", err
		}
		if err := CheckSignature(sums, sig, releaseKey); err != nil {
			return "", "", err
		}
	}
	want, err := sumOf(sums, a.Name)
	if err != nil {
		return "", "", err
	}
	// The folder is private, so that other users cannot change a file
	// between the check and its use.
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", "", err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return "", "", err
	}
	path := filepath.Join(dir, a.Name)
	// A file from an earlier download that passes the check is complete.
	if got, err := fileSum(path); err == nil && got == want {
		return path, want, nil
	}
	tmp, got, err := download(ctx, a.URL, dir, a.Name, a.Size, version)
	if err != nil {
		return "", "", err
	}
	if got != want {
		os.Remove(tmp)
		return "", "", fmt.Errorf("the SHA-256 checksum of %s is %s, and SHA256SUMS gives %s. Flux removed the file", a.Name, got, want)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return "", "", err
	}
	return path, want, nil
}
