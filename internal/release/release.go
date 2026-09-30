// Package release reads the latest Flux release from GitHub and compares
// versions. fluxd checks once a day, and `flux-cli update` checks when the
// user runs it. Without a network, a check returns an error and Flux works
// as before. Fetch downloads a release file and checks it against the
// SHA256SUMS file of the release and the signature of that file.
package release

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// DefaultURL is the GitHub API address of the latest release.
const DefaultURL = "https://api.github.com/repos/bjarneo/flux/releases/latest"

// downloadURL is the start of the address of each file of a release on
// GitHub.
const downloadURL = "https://github.com/bjarneo/flux/releases/download/"

// URL returns FLUX_RELEASES_URL, or DefaultURL. Tests set the variable to
// a local server. Flux uses the variable only with an https address, or
// with an http address on the loopback interface. For another value, URL
// returns DefaultURL.
func URL() string {
	if u := os.Getenv("FLUX_RELEASES_URL"); u != "" && allowedURL(u) {
		return u
	}
	return DefaultURL
}

// allowedURL reports whether u is an https address, or an http address on
// the loopback interface.
func allowedURL(u string) bool {
	p, err := url.Parse(u)
	if err != nil || p.Host == "" {
		return false
	}
	switch p.Scheme {
	case "https":
		return true
	case "http":
		host := p.Hostname()
		ip := net.ParseIP(host)
		return host == "localhost" || ip != nil && ip.IsLoopback()
	}
	return false
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

	// Dropped has the names of the files that Latest removed from Assets,
	// because GitHub gives them at an address outside the release of the
	// tag in the Flux repository. A caller that does not find a file
	// uses Dropped to tell a removed file from a file that the release
	// does not have.
	Dropped []string `json:"-"`
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
	if url == DefaultURL {
		r.Assets, r.Dropped = official(r)
	}
	return r, nil
}

// official returns the files of r that GitHub serves over https from the
// release of the tag in the Flux repository, and the names of the other
// files. Flux downloads no other file from a release that DefaultURL
// gives.
func official(r Release) (kept []Asset, dropped []string) {
	for _, a := range r.Assets {
		if a.URL == downloadURL+r.Tag+"/"+a.Name {
			kept = append(kept, a)
		} else {
			dropped = append(dropped, a.Name)
		}
	}
	return kept, dropped
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
