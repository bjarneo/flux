package config

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
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
	// Disabled lists the plugins that the user turned off for this device.
	Disabled []string `json:"disabledPlugins,omitempty"`
}

// TrustStore is the list of paired devices in devices.json.
type TrustStore struct {
	mu      sync.Mutex
	path    string
	devices map[string]TrustedDevice
}

// LoadTrust reads devices.json from the data directory.
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
		return nil, err
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
