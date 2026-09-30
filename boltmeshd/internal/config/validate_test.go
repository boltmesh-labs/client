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
	directives := []string{"PreUp", "PostUp", "PreDown", "PostDown", "SaveConfig"}
	for _, directive := range directives {
		value := "id"
		if directive == "SaveConfig" {
			value = "true"
		}
		// wg-quick strips comments before matching the key, while executable
		// hook values are taken from the original line. Cover both comment-
		// obfuscation forms.
		lines := []string{
			directive + " = " + value,
			directive + "#=" + value,
			directive + " #ignored = " + value,
		}
		for _, line := range lines {
			t.Run(line, func(t *testing.T) {
				text := strings.Replace(validConfig, "Address = 10.8.0.5/32",
					"Address = 10.8.0.5/32\n"+line, 1)
				if err := Validate(text); err == nil {
					t.Fatalf("Validate with %q = nil, want error", line)
				}
			})
		}
	}
}

func TestValidateRejectsUnknownDirective(t *testing.T) {
	text := strings.Replace(validConfig, "Address = 10.8.0.5/32",
		"Address = 10.8.0.5/32\nUnknown = value", 1)
	if err := Validate(text); err == nil {
		t.Fatal("Validate with unknown directive = nil, want error")
	}
}

func TestValidateRejectsCommentBeforeEquals(t *testing.T) {
	text := strings.Replace(validConfig, "Address = 10.8.0.5/32",
		"Address# = 10.8.0.5/32", 1)
	if err := Validate(text); err == nil {
		t.Fatal("Validate with comment before '=' = nil, want error")
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

// obfuscatedConfig is the canonical client config carrying a complete
// AmneziaWG obfuscation set. Both tunnel ends must run identical parameters,
// so the set is all-or-none.
const obfuscatedConfig = `[Interface]
PrivateKey = ` + keyA + `
Address = 10.8.0.5/32
DNS = 10.8.0.1
Jc = 3
Jmin = 40
Jmax = 70
S1 = 15
S2 = 17
S3 = 10
S4 = 5
H1 = 115-120
H2 = 130
H3 = 150-160
H4 = 171

[Peer]
PublicKey = ` + keyB + `
Endpoint = 203.0.113.10:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
`

func TestValidateAcceptsObfuscatedConfig(t *testing.T) {
	if err := Validate(obfuscatedConfig); err != nil {
		t.Fatalf("Validate(obfuscatedConfig) = %v, want nil", err)
	}
}

func TestValidateRejectsPartialObfuscation(t *testing.T) {
	for _, directive := range []string{"Jc", "Jmin", "Jmax", "S1", "S4", "H1", "H4"} {
		t.Run(directive, func(t *testing.T) {
			text := strings.Replace(obfuscatedConfig, directive+" = ", "#"+directive+" = ", 1)
			if err := Validate(text); err == nil {
				t.Fatalf("Validate without %s = nil, want all-or-none error", directive)
			}
		})
	}
}

func TestValidateRejectsBadObfuscationValues(t *testing.T) {
	cases := []struct {
		name     string
		replacer *strings.Replacer
	}{
		{"junk count not a number", strings.NewReplacer("Jc = 3", "Jc = many")},
		{"junk count over the cap", strings.NewReplacer("Jc = 3", "Jc = 200")},
		{"junk min above junk max", strings.NewReplacer("Jmin = 40", "Jmin = 90")},
		{"padding over the cap", strings.NewReplacer("S1 = 15", "S1 = 9999")},
		{"padding not a number", strings.NewReplacer("S2 = 17", "S2 = 0x11")},
		{"header with a list", strings.NewReplacer("H2 = 130", "H2 = 130,131")},
		{"header range reversed", strings.NewReplacer("H1 = 115-120", "H1 = 120-115")},
		{"header not a number", strings.NewReplacer("H3 = 150-160", "H3 = 150-abc")},
		{"header ranges overlapping", strings.NewReplacer("H2 = 130", "H2 = 118")},
		{"header empty", strings.NewReplacer("H4 = 171", "H4 = ")},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if err := Validate(tc.replacer.Replace(obfuscatedConfig)); err == nil {
				t.Fatal("Validate with a bad obfuscation value = nil, want error")
			}
		})
	}
}

func TestValidateRejectsObfuscationInPeerSection(t *testing.T) {
	text := strings.Replace(obfuscatedConfig, "PersistentKeepalive = 25",
		"PersistentKeepalive = 25\nJc = 3", 1)
	if err := Validate(text); err == nil {
		t.Fatal("Validate with Jc in [Peer] = nil, want error")
	}
}
