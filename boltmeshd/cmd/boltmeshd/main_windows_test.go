//go:build windows

package main

import (
	"testing"
	"time"

	"golang.org/x/sys/windows/svc/mgr"
)

func TestServiceRecoveryActions(t *testing.T) {
	actions := serviceRecoveryActions()
	if len(actions) != 3 {
		t.Fatalf("got %d recovery actions, want 3", len(actions))
	}
	want := []struct {
		typ   int
		delay time.Duration
	}{
		{mgr.ServiceRestart, 5 * time.Second},
		{mgr.ServiceRestart, 15 * time.Second},
		{mgr.ServiceRestart, 60 * time.Second},
	}
	for i, got := range actions {
		if got.Type != want[i].typ || got.Delay != want[i].delay {
			t.Errorf("action %d = (%d, %s), want (%d, %s)", i, got.Type, got.Delay, want[i].typ, want[i].delay)
		}
	}
	if serviceRecoveryResetPeriod != 24*60*60 {
		t.Fatalf("reset period = %d seconds, want 86400", serviceRecoveryResetPeriod)
	}
}
