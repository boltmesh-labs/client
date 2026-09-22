package config

import (
	"errors"
	"strings"
	"testing"
)

const (
	keyA = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	keyB = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
)

const validConfig = `[Interface]
PrivateKey = ` + keyA + `
Address = 10.8.0.5/32
DNS = 10.8.0.1

[Peer]
PublicKey = ` + keyB + `
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`

func TestValidateAcceptsClientConfig(t *testing.T) {
	if err := Validate(validConfig); err != nil {
		t.Fatalf("Validate(validConfig) = %v, want nil", err)
	}
}

func TestValidateRejectsEmpty(t *testing.T) {
	if err := Validate("   \n"); err == nil {
		t.Fatal("Validate(blank) = nil, want error")
	}
}

func TestValidateRejectsPrivilegedHooks(t *testing.T) {
	text := strings.Replace(validConfig, "Address = 10.8.0.5/32",
		"Address = 10.8.0.5/32\nPostUp = touch /root/pwned", 1)
	if err := Validate(text); err == nil {
		t.Fatal("Validate with PostUp = nil, want error")
	}
}

func TestValidateRejectsMissingPeer(t *testing.T) {
	text := "[Interface]\nPrivateKey = " + keyA + "\nAddress = 10.8.0.5/32\n"
	if err := Validate(text); err == nil {
		t.Fatal("Validate without [Peer] = nil, want error")
	}
}

func TestValidateRejectsMissingPrivateKey(t *testing.T) {
	text := "[Interface]\nAddress = 10.8.0.5/32\n\n[Peer]\nPublicKey = " + keyB + "\n"
	if err := Validate(text); err == nil {
		t.Fatal("Validate without PrivateKey = nil, want error")
	}
}

func TestValidateRejectsBadKey(t *testing.T) {
	text := strings.Replace(validConfig, keyA, "not-a-key", 1)
	if err := Validate(text); err == nil {
		t.Fatal("Validate with invalid key = nil, want error")
	}
}

func TestValidateRejectsUnknownSection(t *testing.T) {
	text := validConfig + "\n[Script]\nFoo = bar\n"
	if err := Validate(text); err == nil {
		t.Fatal("Validate with unknown section = nil, want error")
	}
}

func TestValidateRejectsDirectiveBeforeSection(t *testing.T) {
	if err := Validate("PrivateKey = " + keyA + "\n"); err == nil {
		t.Fatal("Validate with leading directive = nil, want error")
	}
}

func TestValidateRejectsNUL(t *testing.T) {
	if err := Validate(validConfig + "\x00"); err == nil {
		t.Fatal("Validate with NUL = nil, want error")
	}
}

func TestValidateRejectsOversize(t *testing.T) {
	big := validConfig + "\n# " + strings.Repeat("x", MaxSize)
	err := Validate(big)
	if !errors.Is(err, ErrTooLarge) {
		t.Fatalf("Validate(oversize) = %v, want ErrTooLarge", err)
	}
}
