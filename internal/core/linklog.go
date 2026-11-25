package core

import "fmt"

// linkUpLine returns the journal line for a link that opens.
func linkUpLine(name, id, ip string, paired bool) string {
	return fmt.Sprintf("link up: %s (%s) %s paired=%v", name, id, ip, paired)
}

// linkDownLine returns the journal line for a link that closes. The error
// text is empty when the link closed with no error.
func linkDownLine(name, id string, err error) string {
	if err == nil {
		return fmt.Sprintf("link down: %s (%s)", name, id)
	}
	return fmt.Sprintf("link down: %s (%s): %v", name, id, err)
}
