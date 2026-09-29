// Package release reads the latest Flux release from GitHub and compares
// versions. fluxd checks once a day, and `flux-cli update` checks when the
// user runs it. Without a network, a check returns an error and Flux works
// as before.
package release

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// DefaultURL is the GitHub API address of the latest release.
const DefaultURL = "https://api.github.com/repos/bjarneo/flux/releases/latest"

// URL returns FLUX_RELEASES_URL, or DefaultURL. Tests set the variable.
func URL() string {
	if u := os.Getenv("FLUX_RELEASES_URL"); u != "" {
		return u
	}
	return DefaultURL
}

// Asset is 1 file of a release.
type Asset struct {
	Name string `json:"name"`
	URL  string `json:"browser_download_url"`
	Size int64  `json:"size"`
}

// Release is the part of the GitHub release that Flux uses.
type Release struct {
	Tag    string  `json:"tag_name"`
	Page   string  `json:"html_url"`
	Assets []Asset `json:"assets"`
}

// Version returns the tag without the v.
func (r Release) Version() string { return strings.TrimPrefix(r.Tag, "v") }

// Find returns the first asset whose name matches.
func (r Release) Find(match func(name string) bool) (Asset, bool) {
	for _, a := range r.Assets {
		if match(a.Name) {
			return a, true
		}
	}
	return Asset{}, false
}

// Latest asks GitHub for the latest release. It sends only a GET request
// with the Flux version in the User-Agent header.
func Latest(ctx context.Context, url, version string) (Release, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return Release{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "flux/"+version)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return Release{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Release{}, fmt.Errorf("%s answered %s", url, resp.Status)
	}
	var r Release
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&r); err != nil {
		return Release{}, fmt.Errorf("%s: %w", url, err)
	}
	if _, ok := parse(r.Tag); !ok {
		return Release{}, fmt.Errorf("%s: the tag %q is not a version", url, r.Tag)
	}
	return r, nil
}

// Newer reports whether version a is newer than version b. A version
// starts with MAJOR.MINOR.PATCH, with or without v, such as v0.7.0,
// 0.7.0.r3.g1a2b3c4, or v0.7.0-3-g1a2b3c4-dirty. The part after the patch
// number does not count. When a version has no such start, as a dev build,
// Newer returns false.
func Newer(a, b string) bool {
	x, okA := parse(a)
	y, okB := parse(b)
	if !okA || !okB {
		return false
	}
	for i := range x {
		if x[i] != y[i] {
			return x[i] > y[i]
		}
	}
	return false
}

// Valid reports whether v starts with MAJOR.MINOR.PATCH.
func Valid(v string) bool {
	_, ok := parse(v)
	return ok
}

func parse(v string) ([3]int, bool) {
	var out [3]int
	v = strings.TrimPrefix(v, "v")
	for i := range out {
		end := 0
		for end < len(v) && v[end] >= '0' && v[end] <= '9' {
			end++
		}
		// A number has no leading zero, as in the release tags.
		if end == 0 || (end > 1 && v[0] == '0') {
			return out, false
		}
		n, err := strconv.Atoi(v[:end])
		if err != nil {
			return out, false
		}
		out[i] = n
		v = v[end:]
		if i < 2 {
			if !strings.HasPrefix(v, ".") {
				return out, false
			}
			v = v[1:]
		}
	}
	// A version such as 0.7.0.r3 or 0.7.0-3 continues with a separator.
	return out, v == "" || v[0] == '.' || v[0] == '-' || v[0] == '+'
}
