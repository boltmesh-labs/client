package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestValidID(t *testing.T) {
	tests := []struct {
		name string
		id   string
		want bool
	}{
		{"empty", "", false},
		{"simple", "1", true},
		{"seq", "42", true},
		{"uuid-ish", "3f9a-1b2c_4.5:6", true},
		{"max length", strings.Repeat("a", MaxIDLength), true},
		{"over max length", strings.Repeat("a", MaxIDLength+1), false},
		{"space", "a b", false},
		{"control byte", "a\nb", false},
		{"nul", "a\x00b", false},
		{"quote", `a"b`, false},
		{"brace", "a{b", false},
		{"unicode", "idå", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ValidID(tt.id); got != tt.want {
				t.Fatalf("ValidID(%q) = %v, want %v", tt.id, got, tt.want)
			}
		})
	}
}

func TestRequestValidate(t *testing.T) {
	base := func() *Request {
		return &Request{V: Version, ID: "1", Op: OpPing}
	}

	tests := []struct {
		name    string
		mutate  func(*Request)
		wantErr bool
	}{
		{"ping ok", func(*Request) {}, false},
		{"status ok", func(r *Request) { r.Op = OpStatus }, false},
		{"down ok", func(r *Request) { r.Op = OpDown }, false},
		{"up with config", func(r *Request) { r.Op = OpUp; r.Config = stringPointer("x") }, false},
		{"empty id", func(r *Request) { r.ID = "" }, true},
		{"bad id", func(r *Request) { r.ID = "a b" }, true},
		{"overlong id", func(r *Request) { r.ID = strings.Repeat("a", MaxIDLength+1) }, true},
		{"unknown op", func(r *Request) { r.Op = "bogus" }, true},
		{"config on ping", func(r *Request) { r.Config = stringPointer("x") }, true},
		{"config on status", func(r *Request) { r.Op = OpStatus; r.Config = stringPointer("x") }, true},
		{"config on down", func(r *Request) { r.Op = OpDown; r.Config = stringPointer("x") }, true},
		{"empty config on ping", func(r *Request) { r.Config = stringPointer("") }, true},
		{"empty config on status", func(r *Request) { r.Op = OpStatus; r.Config = stringPointer("") }, true},
		{"empty config on down", func(r *Request) { r.Op = OpDown; r.Config = stringPointer("") }, true},
		{"up without config", func(r *Request) { r.Op = OpUp }, true},
		{"up with empty config", func(r *Request) { r.Op = OpUp; r.Config = stringPointer("") }, true},
		{"caps ok", func(r *Request) { r.Caps = []string{CapStrictValidation} }, false},
		{"empty cap", func(r *Request) { r.Caps = []string{""} }, true},
		{"overlong cap", func(r *Request) { r.Caps = []string{strings.Repeat("a", MaxCapLength+1)} }, true},
		{"uppercase cap", func(r *Request) { r.Caps = []string{"Nope"} }, true},
		{"too many caps", func(r *Request) {
			r.Caps = make([]string, MaxCaps+1)
			for i := range r.Caps {
				r.Caps[i] = "x"
			}
		}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := base()
			tt.mutate(req)
			err := req.Validate()
			if (err != nil) != tt.wantErr {
				t.Fatalf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestRequestConfigPresenceSurvivesJSONDecoding(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		wantPresent bool
		wantValue   string
	}{
		{"omitted", `{"v":1,"id":"1","op":"up"}`, false, ""},
		{"explicit empty", `{"v":1,"id":"1","op":"up","config":""}`, true, ""},
		{"non-empty", `{"v":1,"id":"1","op":"up","config":"x"}`, true, "x"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var req Request
			if err := json.Unmarshal([]byte(tt.input), &req); err != nil {
				t.Fatalf("Unmarshal(%s): %v", tt.input, err)
			}
			if got := req.Config != nil; got != tt.wantPresent {
				t.Fatalf("Config presence = %v, want %v", got, tt.wantPresent)
			}
			if req.Config != nil && *req.Config != tt.wantValue {
				t.Fatalf("Config = %q, want %q", *req.Config, tt.wantValue)
			}
		})
	}
}

func TestCapabilityMatching(t *testing.T) {
	caps := []string{CapStrictValidation, CapCapabilities}
	if !hasCap(caps, CapStrictValidation) {
		t.Fatal("expected strict-validation")
	}
	if hasCap(caps, "missing") {
		t.Fatal("unexpected capability")
	}
	if hasCap(nil, CapCapabilities) {
		t.Fatal("nil caps should not match")
	}
}

func TestSupportedCapabilitiesIncludeNegotiation(t *testing.T) {
	caps := SupportedCapabilities()
	if !hasCap(caps, CapStrictValidation) || !hasCap(caps, CapCapabilities) {
		t.Fatalf("SupportedCapabilities() = %v", caps)
	}
}

func TestOKCapabilitiesAdvertisesCaps(t *testing.T) {
	resp := OKCapabilities("7", &Status{Interface: "boltmesh0"})
	if !resp.OK || resp.ID != "7" || resp.V != Version {
		t.Fatalf("response = %+v", resp)
	}
	if !hasCap(resp.Caps, CapCapabilities) {
		t.Fatalf("caps = %v", resp.Caps)
	}
}

func hasCap(caps []string, token string) bool {
	for _, cap := range caps {
		if cap == token {
			return true
		}
	}
	return false
}

func TestFailHasNoStatus(t *testing.T) {
	resp := Fail("7", CodeBadRequest, "nope")
	if resp.OK || resp.Status != nil || resp.Error == nil || resp.Error.Code != CodeBadRequest {
		t.Fatalf("response = %+v", resp)
	}
}

func stringPointer(value string) *string { return &value }
