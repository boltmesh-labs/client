// Package config validates the wg-quick config text the client sends before
// the daemon persists it to a root-only path and hands it to wg-quick.
//
// This is a security boundary: the client process holds no privilege, but a
// compromised client must not be able to turn `up` into arbitrary root code
// execution. wg-quick runs PreUp/PostUp/PreDown/PostDown as root shell
// commands and SaveConfig rewrites caller-chosen state, so those directives
// are rejected outright. Only the supported, non-hook directives understood
// by the daemon are accepted.
package config

import (
	"errors"
	"fmt"
	"strings"

	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

// MaxSize bounds a config line and therefore the per-connection buffer. The
// client's generated config is a few hundred bytes; 64 KiB is generous while
// still refusing memory-exhaustion payloads.
const MaxSize = 64 * 1024

// forbiddenDirectives are wg-quick hooks that execute as root or mutate
// caller-controlled state. Never allow them through.
var forbiddenDirectives = map[string]bool{
	"preup":      true,
	"postup":     true,
	"predown":    true,
	"postdown":   true,
	"saveconfig": true,
}

// allowedDirectives is intentionally section-specific. It contains the
// non-hook WireGuard and wg-quick directives supported by the daemon.
// Rejecting unknown names keeps parser differences from becoming a way to
// smuggle a privileged directive through validation.
var allowedDirectives = map[string]map[string]bool{
	"interface": {
		"address":    true,
		"dns":        true,
		"fwmark":     true,
		"listenport": true,
		"mtu":        true,
		"privatekey": true,
		"table":      true,
	},
	"peer": {
		"allowedips":          true,
		"endpoint":            true,
		"persistentkeepalive": true,
		"presharedkey":        true,
		"publickey":           true,
	},
}

// ErrTooLarge is returned when the config exceeds [MaxSize].
var ErrTooLarge = errors.New("config too large")

// Validate checks that text is a structurally sane wg-quick config with at
// least one interface and one peer, valid key material, only supported
// directives, and no privileged hook directives. It intentionally does not
// check addresses/routes/DNS: wg-quick rejects those with its own diagnostics.
func Validate(text string) error {
	if strings.TrimSpace(text) == "" {
		return errors.New("config is empty")
	}
	if len(text) > MaxSize {
		return ErrTooLarge
	}
	if strings.ContainsRune(text, 0) {
		return errors.New("config contains a NUL byte")
	}

	var (
		section      string
		sawInterface bool
		sawPeer      bool
		sawPrivate   bool
		sawPublic    bool
	)

	for i, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		if strings.HasPrefix(line, "[") {
			switch strings.ToLower(line) {
			case "[interface]":
				section = "interface"
				sawInterface = true
			case "[peer]":
				section = "peer"
				sawPeer = true
			default:
				return fmt.Errorf("line %d: unknown section %q", i+1, line)
			}
			continue
		}

		rawKey, value, found := strings.Cut(line, "=")
		if !found {
			return fmt.Errorf("line %d: expected key = value", i+1)
		}
		// wg-quick removes comments before matching a directive name, but
		// keeps the original value for hooks. Do not allow that parser detail
		// to turn an unknown key such as "postup#" into an allowed one.
		if strings.ContainsRune(rawKey, '#') {
			return fmt.Errorf("line %d: comments are not allowed before '='", i+1)
		}
		key := strings.ToLower(strings.TrimSpace(rawKey))
		value = strings.TrimSpace(value)

		if section == "" {
			return fmt.Errorf("line %d: directive %q before any section", i+1, key)
		}
		if forbiddenDirectives[key] {
			return fmt.Errorf("directive %q is not allowed", key)
		}
		if !allowedDirectives[section][key] {
			return fmt.Errorf("line %d: directive %q is not supported", i+1, key)
		}

		switch {
		case section == "interface" && key == "privatekey":
			if _, err := wgtypes.ParseKey(value); err != nil {
				return fmt.Errorf("invalid PrivateKey: %w", err)
			}
			sawPrivate = true
		case section == "peer" && key == "publickey":
			if _, err := wgtypes.ParseKey(value); err != nil {
				return fmt.Errorf("invalid PublicKey: %w", err)
			}
			sawPublic = true
		}
	}

	if !sawInterface || !sawPeer {
		return errors.New("config must contain [Interface] and [Peer]")
	}
	if !sawPrivate {
		return errors.New("[Interface] is missing PrivateKey")
	}
	if !sawPublic {
		return errors.New("[Peer] is missing PublicKey")
	}
	return nil
}
