package main

import (
	"encoding/json"
	"github.com/gorilla/websocket"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// A is held upstream. B's large resume is interrupted during its socket write.
// C must not obtain a grant while A remains unanswered.
func TestReviewWriteFailureSettlesOnlyItsOwnResume(t *testing.T) {
	var connections, starts atomic.Int32
	firstSeen, releaseFirst, closeSecond := make(chan struct{}), make(chan struct{}), make(chan struct{})
	defer close(releaseFirst)
	u := websocket.Upgrader{}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := u.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		n := connections.Add(1)
		for {
			var m message
			if c.ReadJSON(&m) != nil {
				return
			}
			result := map[string]any{}
			if m.Method == "thread/resume" {
				if n == 1 {
					close(firstSeen)
					<-releaseFirst
				}
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}
			}
			if m.Method == "turn/start" {
				starts.Add(1)
				result = map[string]any{"turn": map[string]any{"id": "unsafe", "status": "inProgress"}}
			}
			if len(m.ID) > 0 {
				if c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result}) != nil {
					return
				}
			}
			if n == 2 && m.Method == "initialize" {
				<-closeSecond
				return
			}
		}
	})
	dir := t.TempDir()
	persistRestrictivePolicy(t, dir)
	endpoint, a, cleanup := policyTestGateway(t, dir, handler)
	defer cleanup()
	first := policyTestClient(t, endpoint)
	defer first.c.Close()
	go first.call("thread/resume", map[string]any{"threadId": "owned"}, nil)
	<-firstSeen
	second := policyTestClient(t, endpoint)
	defer second.c.Close()
	failed := make(chan error, 1)
	go func() {
		_, err := second.call("thread/resume", map[string]any{"threadId": "owned", "reviewPadding": strings.Repeat("x", 4<<20)}, nil)
		failed <- err
	}()
	deadline := time.Now().Add(8 * time.Second)
	for {
		a.mu.Lock()
		count := a.threads["owned"].PolicyInFlight
		a.mu.Unlock()
		if count == 2 {
			break
		}
		if time.Now().After(deadline) {
			close(closeSecond)
			t.Fatal("second request never registered")
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(30 * time.Millisecond)
	close(closeSecond)
	if err := <-failed; err == nil {
		t.Fatal("interrupted resume unexpectedly succeeded")
	}
	// Both disconnect and failed-write cleanup must have had time to run.
	time.Sleep(100 * time.Millisecond)
	if !a.acquirePolicyForward() {
		t.Fatal("write guard remained held")
	}
	a.releasePolicyForward()
	a.mu.Lock()
	t.Logf("after failed write: in_flight=%d tainted=%v", a.threads["owned"].PolicyInFlight, a.threads["owned"].PolicyTainted)
	a.mu.Unlock()
	third := policyTestClient(t, endpoint)
	defer third.c.Close()
	if _, err := third.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	_, err := third.call("turn/start", map[string]any{"threadId": "owned"}, nil)
	a.mu.Lock()
	count := a.threads["owned"].PolicyInFlight
	a.mu.Unlock()
	if err == nil || starts.Load() != 0 {
		t.Fatalf("write failure consumed another unresolved resume: in_flight=%d starts=%d error=%v", count, starts.Load(), err)
	}
}
