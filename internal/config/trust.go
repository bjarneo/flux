package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// TrustedDevice is a paired device. Flux pins the certificate of the device
// and refuses a link that presents a different certificate.
type TrustedDevice struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"`
	CertPEM  string `json:"certificate"`
	PairedAt string `json:"pairedAt"`
	// LastIP is the last address of the device. fluxd connects to it at
	// start, so a phone that does not broadcast still reconnects.
	LastIP string `json:"lastIp,omitempty"`
	// LastPort is the TCP port of the device. With LastIP, fluxd connects
	// out to the device, so no incoming connection is necessary.
	LastPort int `json:"lastPort,omitempty"`
	// Addresses are host names or IP addresses that the user added, for
	// example the Tailscale name of the phone. fluxd tries them after
	// LastIP while the device is offline.
	Addresses []string `json:"addresses,omitempty"`
}

// TrustStore is the list of paired devices in devices.json.
type TrustStore struct {
	mu      sync.Mutex
	path    string
	devices map[string]TrustedDevice

	// Broken is the new path of a devices.json that did not parse, or "".
	// BrokenErr is the parse error.
	Broken    string
	BrokenErr error
}

// LoadTrust reads devices.json from the data directory. A file that does
// not parse moves to devices.json.broken-<Unix time>, and LoadTrust returns
// an empty store with Broken set. fluxd then starts, and the user pairs
// the devices again. LoadTrust returns an error when it cannot move the
// file, so that a new pairing does not write over it.
func LoadTrust() (*TrustStore, error) {
	ts := &TrustStore{path: filepath.Join(DataDir(), "devices.json"), devices: map[string]TrustedDevice{}}
	data, err := os.ReadFile(ts.path)
	if errors.Is(err, os.ErrNotExist) {
		return ts, nil
	}
	if err != nil {
		return nil, err
	}
	var list []TrustedDevice
	if err := json.Unmarshal(data, &list); err != nil {
		// The path tells the user which file to repair.
		err = fmt.Errorf("%s: %w", ts.path, err)
		broken := fmt.Sprintf("%s.broken-%d", ts.path, time.Now().Unix())
		if rerr := os.Rename(ts.path, broken); rerr != nil {
			return nil, fmt.Errorf("%w. It cannot move: %v", err, rerr)
		}
		ts.Broken, ts.BrokenErr = broken, err
		return ts, nil
	}
	for _, d := range list {
		ts.devices[d.ID] = d
	}
	return ts, nil
}

// Get returns the trusted device with the ID.
func (ts *TrustStore) Get(id string) (TrustedDevice, bool) {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	d, ok := ts.devices[id]
	return d, ok
}

// All returns every trusted device.
func (ts *TrustStore) All() []TrustedDevice {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	out := make([]TrustedDevice, 0, len(ts.devices))
	for _, d := range ts.devices {
		out = append(out, d)
	}
	return out
}

// Put adds or replaces a trusted device and saves the file.
func (ts *TrustStore) Put(d TrustedDevice) error {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	ts.devices[d.ID] = d
	return ts.save()
}

// Update changes a trusted device in place and saves the file. It does
// nothing when the device is not trusted.
func (ts *TrustStore) Update(id string, fn func(*TrustedDevice)) error {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	d, ok := ts.devices[id]
	if !ok {
		return nil
	}
	fn(&d)
	ts.devices[id] = d
	return ts.save()
}

// Remove deletes a trusted device and saves the file.
func (ts *TrustStore) Remove(id string) error {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	delete(ts.devices, id)
	return ts.save()
}

func (ts *TrustStore) save() error {
	list := make([]TrustedDevice, 0, len(ts.devices))
	for _, d := range ts.devices {
		list = append(list, d)
	}
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(ts.path), 0o700); err != nil {
		return err
	}
	return writeAtomic(ts.path, data, 0o600)
}
