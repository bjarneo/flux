package main

import (
	"errors"
	"fmt"
	"reflect"
	"strings"

	"flux/internal/ipc"
	"flux/internal/proto"
)

// Text from fluxd comes from the network: device names, notification text
// from any app on the phone, and error messages. flux-cli replaces the
// control characters and the bidi controls in it before it prints it. The
// text then cannot move the cursor, write to the clipboard through an
// escape sequence, or change the order of the text on the terminal.

// safe replaces the control characters and the bidi controls in s with
// U+FFFD. A tab and a line break become a space, so that 1 value stays on
// 1 line.
func safe(s string) string {
	if strings.IndexFunc(s, proto.IsControl) < 0 {
		return s
	}
	return strings.Map(func(r rune) rune {
		switch {
		case r == '\t' || r == '\n' || r == '\r':
			return ' '
		case proto.IsControl(r):
			return '�'
		}
		return r
	}, s)
}

// cleanAll applies safe to every string in v, the pointer that received
// the result of a call.
func cleanAll(v any) {
	if v != nil {
		cleanValue(reflect.ValueOf(v))
	}
}

func cleanValue(v reflect.Value) {
	switch v.Kind() {
	case reflect.String:
		if s := safe(v.String()); s != v.String() && v.CanSet() {
			v.SetString(s)
		}
	case reflect.Pointer:
		if !v.IsNil() {
			cleanValue(v.Elem())
		}
	case reflect.Interface:
		if v.IsNil() || !v.CanSet() {
			return
		}
		c := reflect.New(v.Elem().Type()).Elem()
		c.Set(v.Elem())
		cleanValue(c)
		v.Set(c)
	case reflect.Struct:
		for i := range v.NumField() {
			cleanValue(v.Field(i))
		}
	case reflect.Slice, reflect.Array:
		// Bytes are raw JSON or data, not text.
		if v.Type().Elem().Kind() == reflect.Uint8 {
			return
		}
		for i := range v.Len() {
			cleanValue(v.Index(i))
		}
	case reflect.Map:
		if v.IsNil() {
			return
		}
		for _, k := range v.MapKeys() {
			e := reflect.New(v.Type().Elem()).Elem()
			e.Set(v.MapIndex(k))
			cleanValue(e)
			key := k
			if k.Kind() == reflect.String {
				if s := safe(k.String()); s != k.String() {
					v.SetMapIndex(k, reflect.Value{})
					key = reflect.ValueOf(s).Convert(k.Type())
				}
			}
			v.SetMapIndex(key, e)
		}
	}
}

// safeJSON writes the control characters and the bidi controls in JSON
// text as \u escapes. The JSON keeps its meaning, because such characters
// can only be inside strings, and the terminal shows them as text.
func safeJSON(b []byte) []byte {
	s := string(b)
	if strings.IndexFunc(s, proto.IsControl) < 0 {
		return b
	}
	var out strings.Builder
	for _, r := range s {
		if proto.IsControl(r) && r != '\t' && r != '\n' && r != '\r' {
			fmt.Fprintf(&out, `\u%04x`, r)
			continue
		}
		out.WriteRune(r)
	}
	return []byte(out.String())
}

// cleanErr applies safe to the message of an error from fluxd.
func cleanErr(err error) error {
	var e *ipc.Error
	if errors.As(err, &e) {
		return &ipc.Error{Code: e.Code, Message: safe(e.Message)}
	}
	return err
}
