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
	"strconv"
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
// non-hook WireGuard, wg-quick, and AmneziaWG obfuscation directives
// supported by the daemon. Rejecting unknown names keeps parser differences
// from becoming a way to smuggle a privileged directive through validation.
var allowedDirectives = map[string]map[string]bool{
	"interface": {
		"address":    true,
		"dns":        true,
		"fwmark":     true,
		"listenport": true,
		"mtu":        true,
		"privatekey": true,
		"table":      true,
		"jc":         true,
		"jmin":       true,
		"jmax":       true,
		"s1":         true,
		"s2":         true,
		"s3":         true,
		"s4":         true,
		"h1":         true,
		"h2":         true,
		"h3":         true,
		"h4":         true,
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

// awgDirectives are the AmneziaWG obfuscation parameters accepted in the
// [Interface] section. They are meaningful only as a complete set — both
// tunnel ends must run identical obfuscation parameters, and a partial set
// would silently negotiate an unobfuscated-looking handshake — so [Validate]
// enforces all-or-none plus the value invariants the device itself checks
// (see [validateObfuscation]). The control plane owns parameter generation;
// the bounds below are sanity fences, not a generation policy.
var awgDirectives = []string{
	"jc", "jmin", "jmax",
	"s1", "s2", "s3", "s4",
	"h1", "h2", "h3", "h4",
}

var awgDirectiveSet = func() map[string]bool {
	set := make(map[string]bool, len(awgDirectives))
	for _, name := range awgDirectives {
		set[name] = true
	}
	return set
}()

// obfuscationValueMax bounds the numeric obfuscation parameters the daemon
// accepts. Junk counts are capped by the AmneziaWG specification; junk and
// padding sizes are capped at one ordinary frame so the daemon cannot be
// talked into generating pathological packets.
const (
	awgJunkCountMax = 128
	awgPaddingMax   = 1500
	awgHeaderMax    = uint64(1<<32 - 1)
)

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
		awgValues    = map[string]string{}
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

		if section == "interface" && awgDirectiveSet[key] {
			awgValues[key] = value
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
	if len(awgValues) > 0 {
		if err := validateObfuscation(awgValues); err != nil {
			return err
		}
	}
	return nil
}

// validateObfuscation checks the collected AmneziaWG obfuscation directives as
// a set. The device applies the values late (a merge failure would surface
// only after privileged state had been written), so the invariants are checked
// here instead: a complete set, bounded numeric values, Jmin <= Jmax, and
// pairwise non-overlapping H ranges (the device rejects overlapping magic
// headers outright).
func validateObfuscation(values map[string]string) error {
	var missing []string
	for _, name := range awgDirectives {
		if _, ok := values[name]; !ok {
			missing = append(missing, strings.ToUpper(name[:1])+name[1:])
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf(
			"obfuscation directives are all-or-none; missing %s",
			strings.Join(missing, ", "),
		)
	}

	parseUint := func(name string, max uint64) (uint64, error) {
		v, err := strconv.ParseUint(values[strings.ToLower(name)], 10, 64)
		if err != nil || v > max {
			return 0, fmt.Errorf("invalid %s %q", name, values[strings.ToLower(name)])
		}
		return v, nil
	}

	if _, err := parseUint("Jc", awgJunkCountMax); err != nil {
		return err
	}
	jmin, err := parseUint("Jmin", awgPaddingMax)
	if err != nil {
		return err
	}
	jmax, err := parseUint("Jmax", awgPaddingMax)
	if err != nil {
		return err
	}
	if jmin > jmax {
		return fmt.Errorf("invalid Jmin/Jmax: Jmin (%d) is greater than Jmax (%d)", jmin, jmax)
	}
	for _, name := range []string{"S1", "S2", "S3", "S4"} {
		if _, err := parseUint(name, awgPaddingMax); err != nil {
			return err
		}
	}

	headers := make([][2]uint64, 4)
	for i, name := range []string{"H1", "H2", "H3", "H4"} {
		raw := values[strings.ToLower(name)]
		lo, hi, err := parseHeaderRange(raw)
		if err != nil {
			return fmt.Errorf("invalid %s %q: %w", name, raw, err)
		}
		headers[i] = [2]uint64{lo, hi}
	}
	for i := 0; i < len(headers); i++ {
		for j := i + 1; j < len(headers); j++ {
			a, b := headers[i], headers[j]
			if a[0] <= b[1] && b[0] <= a[1] {
				return fmt.Errorf(
					"invalid H1–H4: ranges %d–%d and %d–%d overlap (the device requires distinct magic headers)",
					a[0], a[1], b[0], b[1],
				)
			}
		}
	}
	return nil
}

// parseHeaderRange parses an AmneziaWG magic-header value: a fixed number
// ("115") or an inclusive range ("115-120"). The values must already be
// lower-case directive keys' values; the display name is the caller's.
func parseHeaderRange(raw string) (uint64, uint64, error) {
	lo, hi, found := strings.Cut(raw, "-")
	if strings.TrimSpace(lo) == "" || (found && strings.TrimSpace(hi) == "") {
		return 0, 0, errors.New("empty range bound")
	}
	lov, err := strconv.ParseUint(strings.TrimSpace(lo), 10, 64)
	if err != nil || lov > awgHeaderMax {
		return 0, 0, errors.New("lower bound is not a 32-bit number")
	}
	if !found {
		return lov, lov, nil
	}
	hiv, err := strconv.ParseUint(strings.TrimSpace(hi), 10, 64)
	if err != nil || hiv > awgHeaderMax {
		return 0, 0, errors.New("upper bound is not a 32-bit number")
	}
	if hiv < lov {
		return 0, 0, errors.New("upper bound is below the lower bound")
	}
	return lov, hiv, nil
}
