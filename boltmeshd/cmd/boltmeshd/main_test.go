package main

import (
	"os"
	"testing"
)

func TestGetEnvDistinguishesUnsetValueAndEmpty(t *testing.T) {
	const key = "BOLTMESHD_TEST_ENV"

	t.Run("value", func(t *testing.T) {
		t.Setenv(key, "configured")
		if got := getEnv(key, "fallback"); got != "configured" {
			t.Fatalf("getEnv() = %q, want configured", got)
		}
	})

	t.Run("empty", func(t *testing.T) {
		t.Setenv(key, "")
		if got := getEnv(key, "fallback"); got != "" {
			t.Fatalf("getEnv() = %q, want empty", got)
		}
	})

	t.Run("unset", func(t *testing.T) {
		t.Setenv(key, "")
		if err := os.Unsetenv(key); err != nil {
			t.Fatalf("Unsetenv: %v", err)
		}
		if got := getEnv(key, "fallback"); got != "fallback" {
			t.Fatalf("getEnv() = %q, want fallback", got)
		}
	})
}

func TestDocumentedEmptyEnvironmentOverrides(t *testing.T) {
	tests := []struct {
		name     string
		key      string
		fallback string
	}{
		{"file logging", "BOLTMESHD_LOG_FILE", "/var/log/boltmesh/boltmeshd.log"},
		{"root-only socket", "BOLTMESHD_SOCKET_GROUP", "boltmesh"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv(tt.key, "")
			if got := getEnv(tt.key, tt.fallback); got != "" {
				t.Fatalf("getEnv(%q) = %q, want empty", tt.key, got)
			}
		})
	}
}
