package main

import (
	"encoding/json"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestOverlappingResumeFencesMutationsUntilGroupSettles(t *testing.T) {
	for _, outcome := range []string{"pending", "mismatch", "disconnect"} {
		t.Run(outcome, func(t *testing.T) {
			u := websocket.Upgrader{}
			seen, release := make(chan struct{}), make(chan struct{})
			var resumes, starts atomic.Int32
			handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				c, err := u.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				defer c.Close()
				for {
					var m message
					if c.ReadJSON(&m) != nil {
						return
					}
					result := map[string]any{}
					switch m.Method {
					case "thread/resume":
						approval, sandbox := "on-request", "readOnly"
						if resumes.Add(1) == 1 {
							close(seen)
							<-release
							if outcome == "disconnect" {
								return
							}
							if outcome == "mismatch" {
								approval, sandbox = "never", "dangerFullAccess"
							}
						}
						result = map[string]any{
							"thread":         map[string]any{"id": "owned"},
							"approvalPolicy": approval,
							"sandbox":        map[string]any{"type": sandbox},
						}
					case "turn/start":
						starts.Add(1)
						result = map[string]any{"turn": map[string]any{"id": "safe", "status": "inProgress"}}
					}
					if len(m.ID) > 0 {
						_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
					}
				}
			})

			dir := t.TempDir()
			persistRestrictivePolicy(t, dir)
			endpoint, _, cleanup := policyTestGateway(t, dir, handler)
			defer cleanup()
			first := policyTestClient(t, endpoint)
			defer first.c.Close()
			second := policyTestClient(t, endpoint)
			defer second.c.Close()

			completed := make(chan error, 1)
			go func() {
				_, err := first.call("thread/resume", map[string]any{"threadId": "owned"}, nil)
				completed <- err
			}()
			<-seen
			if _, err := second.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
				t.Fatal(err)
			}
			if _, err := second.call("turn/start", map[string]any{"threadId": "owned"}, nil); err == nil || starts.Load() != 0 {
				t.Fatalf("pending overlapping resume did not fence governed work: starts=%d error=%v", starts.Load(), err)
			}

			close(release)
			firstErr := <-completed
			if outcome == "pending" {
				if firstErr != nil {
					t.Fatalf("matching outstanding resume failed: %v", firstErr)
				}
			} else if firstErr == nil {
				t.Fatalf("%s fixture did not fail", outcome)
			}

			if outcome != "pending" {
				if _, err := second.call("turn/start", map[string]any{"threadId": "owned"}, nil); err == nil || starts.Load() != 0 {
					t.Fatalf("%s outcome did not keep policy fenced: starts=%d error=%v", outcome, starts.Load(), err)
				}
				if _, err := second.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
					t.Fatalf("fresh reconciliation after %s failed: %v", outcome, err)
				}
			}
			if _, err := second.call("turn/start", map[string]any{"threadId": "owned"}, nil); err != nil {
				t.Fatalf("settled %s group did not recover safely: %v", outcome, err)
			}
			if starts.Load() != 1 {
				t.Fatalf("expected exactly one forwarded start after recovery, got %d", starts.Load())
			}
		})
	}
}

func TestPolicyVerificationSettlementIsRequestOwned(t *testing.T) {
	for _, tc := range []struct {
		name     string
		verified bool
	}{
		{name: "duplicate-success", verified: true},
		{name: "duplicate-error", verified: false},
		{name: "duplicate-disconnect", verified: false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := newArbiter(t.TempDir())
			first := a.beginPolicyVerification("owned")
			second := a.beginPolicyVerification("owned")
			a.finishPolicyVerification(second, tc.verified)
			a.finishPolicyVerification(second, tc.verified)

			a.mu.Lock()
			inFlight := a.threads["owned"].PolicyInFlight
			a.mu.Unlock()
			if inFlight != 1 {
				t.Fatalf("duplicate settlement consumed another request: in_flight=%d", inFlight)
			}

			a.finishPolicyVerification(first, true)
			if got := a.policyVerified("owned"); got != tc.verified {
				t.Fatalf("settled group verification=%v, want %v", got, tc.verified)
			}
			if !tc.verified {
				fresh := a.beginPolicyVerification("owned")
				a.finishPolicyVerification(fresh, true)
				if !a.policyVerified("owned") {
					t.Fatal("fresh reconciliation did not restore verification")
				}
			}
		})
	}
}

func TestStartSerialisationDoesNotHoldPolicyOrderingGate(t *testing.T) {
	u := websocket.Upgrader{}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := u.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			var m message
			if c.ReadJSON(&m) != nil {
				return
			}
			result := map[string]any{}
			if m.Method == "thread/resume" {
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}
			}
			if m.Method == "turn/start" {
				result = map[string]any{"turn": map[string]any{"id": "one", "status": "inProgress"}}
			}
			if len(m.ID) > 0 {
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
			}
		}
	})
	dir := t.TempDir()
	persistRestrictivePolicy(t, dir)
	endpoint, a, cleanup := policyTestGateway(t, dir, handler)
	defer cleanup()
	seed := policyTestClient(t, endpoint)
	defer seed.c.Close()
	if _, err := seed.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}

	thread := a.thread("owned")
	thread.mu.Lock()
	blocked := policyTestClient(t, endpoint)
	defer blocked.c.Close()
	startDone := make(chan error, 1)
	go func() {
		_, err := blocked.call("turn/start", map[string]any{"threadId": "owned"}, nil)
		startDone <- err
	}()
	time.Sleep(30 * time.Millisecond)

	resume := policyTestClient(t, endpoint)
	defer resume.c.Close()
	resumeDone := make(chan error, 1)
	go func() {
		_, err := resume.call("thread/resume", map[string]any{"threadId": "owned"}, nil)
		resumeDone <- err
	}()
	select {
	case err := <-resumeDone:
		if err != nil {
			thread.mu.Unlock()
			t.Fatal(err)
		}
	case <-time.After(750 * time.Millisecond):
		thread.mu.Unlock()
		t.Fatal("start waiting for per-thread serialisation held the policy ordering gate")
	}
	thread.mu.Unlock()
	if err := <-startDone; err != nil {
		t.Fatal(err)
	}
}
