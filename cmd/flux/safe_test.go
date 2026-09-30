package main

import (
	"encoding/json"
	"strings"
	"testing"

	"flux/internal/proto"
)

func TestSafe(t *testing.T) {
	for in, want := range map[string]string{
		"Pixel 8":                   "Pixel 8",
		"Pixel 8 é 日本":              "Pixel 8 é 日本",
		"Pixel\x1b]52;c;aGk=\x07 8": "Pixel�]52;c;aGk=� 8",
		"a\tb\nc\rd":                "a b c d",
		"Pixel \u202egnp.exe\u2066": "Pixel �gnp.exe�",
		"\u009b31m\u0085":           "�31m�",
	} {
		if got := safe(in); got != want {
			t.Errorf("safe(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestCleanAll checks that every string in a result from fluxd loses its
// control characters, also inside slices, maps, pointers, and interfaces.
func TestCleanAll(t *testing.T) {
	type device struct {
		Name  string
		Tags  []string
		Extra map[string]any
		Raw   json.RawMessage
	}
	esc := "x\x1b[2Jy"
	v := struct {
		Devices []*device
		Any     any
	}{
		Devices: []*device{{Name: esc, Tags: []string{esc}, Extra: map[string]any{esc: esc, "list": []any{esc}}, Raw: json.RawMessage(`"\u001b"`)}},
		Any:     map[string]any{"title": esc},
	}
	cleanAll(&v)
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var back any
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	var walk func(any)
	walk = func(x any) {
		switch x := x.(type) {
		case string:
			if strings.ContainsFunc(x, proto.IsControl) {
				t.Errorf("%q keeps a control character", x)
			}
		case []any:
			for _, e := range x {
				walk(e)
			}
		case map[string]any:
			for k, e := range x {
				walk(k)
				walk(e)
			}
		}
	}
	back.(map[string]any)["Devices"].([]any)[0].(map[string]any)["Raw"] = nil
	walk(back)
	if string(v.Devices[0].Raw) != `"\u001b"` {
		t.Errorf("cleanAll changed raw JSON to %s", v.Devices[0].Raw)
	}
}

// TestSafeJSON checks that JSON output shows control characters as
// escapes and keeps its meaning.
func TestSafeJSON(t *testing.T) {
	in := []byte("{\"name\":\"a\u202eb\u009bc\",\"n\":1}\n")
	out := safeJSON(in)
	if strings.ContainsFunc(strings.TrimSuffix(string(out), "\n"), proto.IsControl) {
		t.Fatalf("safeJSON kept a control character: %q", out)
	}
	var a, b any
	if json.Unmarshal(in, &a) != nil || json.Unmarshal(out, &b) != nil {
		t.Fatalf("safeJSON made invalid JSON: %s", out)
	}
	if a.(map[string]any)["name"] != b.(map[string]any)["name"] {
		t.Fatalf("safeJSON changed the value: %q", b)
	}
}
