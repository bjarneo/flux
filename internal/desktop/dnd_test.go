package desktop

import "testing"

func TestOmarchyDND(t *testing.T) {
	cases := map[string][2]bool{
		"on\n":  {true, true},
		"off\n": {false, true},
		"":      {false, false},
		"error": {false, false},
	}
	for in, want := range cases {
		on, ok := omarchyDND(in)
		if on != want[0] || ok != want[1] {
			t.Errorf("%q: got %v, %v, want %v, %v", in, on, ok, want[0], want[1])
		}
	}
}

func TestMakoDND(t *testing.T) {
	if !makoDND("default\ndo-not-disturb\n") {
		t.Error("the do-not-disturb mode is on")
	}
	if makoDND("default\n") || makoDND("") {
		t.Error("no do-not-disturb mode is off")
	}
}
