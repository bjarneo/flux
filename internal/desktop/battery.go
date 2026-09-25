package desktop

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// powerSupplyRoot is the sysfs directory of power supplies. Tests change
// it to a fake directory.
var powerSupplyRoot = "/sys/class/power_supply"

// Battery is the charge state of the laptop battery.
type Battery struct {
	Present  bool
	Charge   int
	Charging bool
}

// ReadBattery returns the average charge of the system batteries. It
// ignores the batteries of devices such as a mouse. Charging is true when
// a battery charges, or when a battery is full and external power is on.
func ReadBattery() Battery {
	entries, err := os.ReadDir(powerSupplyRoot)
	if err != nil {
		return Battery{}
	}
	var b Battery
	var total, count int
	full, acOnline := false, false
	for _, e := range entries {
		dir := filepath.Join(powerSupplyRoot, e.Name())
		typ := readSys(dir, "type")
		switch {
		case typ == "Battery":
			if readSys(dir, "scope") == "Device" {
				continue
			}
			capacity, err := strconv.Atoi(readSys(dir, "capacity"))
			if err != nil {
				continue
			}
			total += capacity
			count++
			switch readSys(dir, "status") {
			case "Charging":
				b.Charging = true
			case "Full":
				full = true
			}
		case typ == "Mains" || strings.HasPrefix(typ, "USB"):
			if readSys(dir, "online") == "1" {
				acOnline = true
			}
		}
	}
	if count == 0 {
		return Battery{}
	}
	b.Present = true
	b.Charge = total / count
	if full && acOnline {
		b.Charging = true
	}
	return b
}

func readSys(dir, name string) string {
	data, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}
