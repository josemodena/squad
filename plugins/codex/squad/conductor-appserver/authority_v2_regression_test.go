package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/gorilla/websocket"
)

func policyTestNamedClient(t *testing.T, endpoint, name string) *rpcClient {
	t.Helper()
	conn, err := websocketDialer(endpoint)
	if err != nil {
		t.Fatal(err)
	}
	c := &rpcClient{c: conn, nextID: 1}
	if _, err = c.call("initialize", map[string]any{"clientInfo": map[string]any{"name": name}}, nil); err != nil {
		conn.Close()
		t.Fatal(err)
	}
	return c
}

func policyTestClient(t *testing.T, endpoint string) *rpcClient {
	return policyTestNamedClient(t, endpoint, "codex_cli")
}

func policyTestGateway(t *testing.T, dir string, handler http.Handler) (string, *arbiter, func()) {
	t.Helper()
	u := websocket.Upgrader{}
	up := httptest.NewServer(handler)
	a := newArbiter(dir)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := u.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(up.URL, "http"), c)
	}))
	return "ws" + strings.TrimPrefix(gateway.URL, "http"), a, func() {
		gateway.Close()
		up.Close()
	}
}

func persistRestrictivePolicy(t *testing.T, dir string) {
	t.Helper()
	if err := atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), map[string]any{
		"thread_id": "owned",
		"resolved": map[string]any{
			"approvalPolicy": "on-request",
			"sandbox":        map[string]any{"type": "readOnly"},
		},
	}); err != nil {
		t.Fatal(err)
	}
}

func TestV2LateControllerAckMustNotOverwriteNewNativeTurn(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "chief-of-staff-thread.json")
	if err := atomicJSON(path, map[string]any{"thread_id": "owned", "resolved": map[string]any{}}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(dir)
	a.observe(message{Method: "turn/started", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"old","status":"inProgress"}}`)})
	a.observe(message{Method: "turn/completed", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"old","status":"completed"}}`)})
	a.observe(message{Method: "turn/started", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"new-native","status":"inProgress"}}`)})
	done := turnEnvelope{ThreadID: "owned"}
	done.Turn.ID, done.Turn.Status = "old", "completed"
	if err := writeCompletionAck(dir, "previous-launch", done); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]any
	_ = json.Unmarshal(b, &saved)
	if saved["turn_id"] != "new-native" || saved["turn_status"] != "inProgress" {
		t.Fatalf("late controller completion overwrote live native controls: %s; authority=%s", b, a.activeTurn("owned"))
	}
}

func TestLateSchedulerStartReplyMustNotOverwriteNewNativeTurn(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "chief-of-staff-thread.json")
	if err := atomicJSON(path, map[string]any{"thread_id": "owned", "resolved": map[string]any{}}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(dir)
	pending, err := a.reserveStart("owned")
	if err != nil {
		t.Fatal(err)
	}
	a.observe(message{Method: "turn/started", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"old","status":"inProgress"}}`)})
	a.observe(message{Method: "turn/completed", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"old","status":"completed"}}`)})
	a.observe(message{Method: "turn/started", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"new-native","status":"inProgress"}}`)})
	a.completeStart("owned", pending, json.RawMessage(`{"turn":{"id":"old","status":"inProgress"}}`))
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]any
	_ = json.Unmarshal(b, &saved)
	if saved["turn_id"] != "new-native" || a.activeTurn("owned") != "new-native" {
		t.Fatalf("late scheduler start reply regressed current native control state: %s", b)
	}
}

func TestV2FailedRepeatResumeMustRevokeNativeVerification(t *testing.T) {
	u := websocket.Upgrader{}
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			switch m.Method {
			case "thread/resume":
				approval, sandbox := "on-request", "readOnly"
				if resumes.Add(1) > 1 {
					approval, sandbox = "never", "dangerFullAccess"
				}
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "approvalPolicy": approval, "sandbox": map[string]any{"type": sandbox}}
			case "turn/start":
				starts.Add(1)
				result = map[string]any{"turn": map[string]any{"id": "unsafe", "status": "inProgress"}}
			}
			_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	})
	dir := t.TempDir()
	persistRestrictivePolicy(t, dir)
	endpoint, _, closeGateway := policyTestGateway(t, dir, handler)
	defer closeGateway()
	c := policyTestClient(t, endpoint)
	defer c.c.Close()
	if _, err := c.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := c.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err == nil {
		t.Fatal("fixture did not reject changed effective policy")
	}
	_, err := c.call("turn/start", map[string]any{"threadId": "owned"}, nil)
	if err == nil || starts.Load() != 0 {
		t.Fatalf("failed repeat resume retained native verification: starts=%d error=%v", starts.Load(), err)
	}
}

func TestV2PolicyFailureMustFenceOtherAttachedClient(t *testing.T) {
	u := websocket.Upgrader{}
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			switch m.Method {
			case "thread/resume":
				approval, sandbox := "on-request", "readOnly"
				if resumes.Add(1) > 2 {
					approval, sandbox = "never", "dangerFullAccess"
				}
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "approvalPolicy": approval, "sandbox": map[string]any{"type": sandbox}}
			case "turn/start":
				starts.Add(1)
				result = map[string]any{"turn": map[string]any{"id": "unsafe", "status": "inProgress"}}
			}
			_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	})
	dir := t.TempDir()
	persistRestrictivePolicy(t, dir)
	endpoint, _, closeGateway := policyTestGateway(t, dir, handler)
	defer closeGateway()
	c1 := policyTestClient(t, endpoint)
	defer c1.c.Close()
	c2 := policyTestClient(t, endpoint)
	defer c2.c.Close()
	if _, err := c1.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := c2.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := c1.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err == nil {
		t.Fatal("fixture did not reject changed effective policy")
	}
	scheduler := policyTestNamedClient(t, endpoint, "squad_conductor")
	defer scheduler.c.Close()
	if _, err := scheduler.call("turn/start", map[string]any{"threadId": "owned"}, nil); err == nil {
		t.Fatal("failed native verification did not fence the scheduler path")
	}
	_, err := c2.call("turn/start", map[string]any{"threadId": "owned"}, nil)
	if err == nil || starts.Load() != 0 {
		t.Fatalf("failed repeat resume retained another client's verification: starts=%d error=%v", starts.Load(), err)
	}
}

func TestGatewayOwnsFirstThreadBootstrapAndDynamicState(t *testing.T) {
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			switch m.Method {
			case "thread/start":
				result = map[string]any{"thread": map[string]any{"id": "first"}, "approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}
			case "turn/start":
				result = map[string]any{"turn": map[string]any{"id": "scheduler-one", "status": "inProgress"}}
			}
			_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	})
	dir := t.TempDir()
	endpoint, a, closeGateway := policyTestGateway(t, dir, handler)
	defer closeGateway()
	scheduler := policyTestNamedClient(t, endpoint, "squad_conductor")
	defer scheduler.c.Close()
	if _, err := scheduler.call("thread/start", map[string]any{"cwd": "/work"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := scheduler.call("turn/start", map[string]any{"threadId": "first"}, nil); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "chief-of-staff-thread.json"))
	if err != nil {
		t.Fatal(err)
	}
	var saved map[string]any
	_ = json.Unmarshal(b, &saved)
	if saved["thread_id"] != "first" || saved["turn_id"] != "scheduler-one" || a.activeTurn("first") != "scheduler-one" {
		t.Fatalf("gateway did not own bootstrap and dynamic turn state: %s", b)
	}
}

func TestPolicyOverlapFailureRequiresFreshReconciliation(t *testing.T) {
	u := websocket.Upgrader{}
	firstSeen, releaseFirst := make(chan struct{}), make(chan struct{})
	var resumeNumber atomic.Int32
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			if m.Method == "thread/resume" {
				n := resumeNumber.Add(1)
				if n == 1 {
					close(firstSeen)
					<-releaseFirst
					_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "error": map[string]any{"code": -1, "message": "earlier failure"}})
					continue
				}
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}
			} else if m.Method == "turn/start" {
				result = map[string]any{"turn": map[string]any{"id": "safe", "status": "inProgress"}}
			}
			_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	})
	dir := t.TempDir()
	persistRestrictivePolicy(t, dir)
	endpoint, _, closeGateway := policyTestGateway(t, dir, handler)
	defer closeGateway()
	c1 := policyTestClient(t, endpoint)
	defer c1.c.Close()
	c2 := policyTestClient(t, endpoint)
	defer c2.c.Close()
	var firstErr error
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_, firstErr = c1.call("thread/resume", map[string]any{"threadId": "owned"}, nil)
	}()
	<-firstSeen
	if _, err := c2.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	close(releaseFirst)
	wg.Wait()
	if firstErr == nil {
		t.Fatal("fixture did not return the delayed earlier failure")
	}
	if _, err := c2.call("turn/start", map[string]any{"threadId": "owned"}, nil); err == nil {
		t.Fatal("earlier failure was ignored after a later successful response")
	}
	if _, err := c2.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatalf("fresh policy reconciliation failed: %v", err)
	}
	if _, err := c2.call("turn/start", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatalf("fresh policy reconciliation did not restore the grant: %v", err)
	}
}

func TestAttachedNativeClientSurvivesLaterSamePolicySchedulerTurn(t *testing.T) {
	u := websocket.Upgrader{}
	var starts atomic.Int32
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			switch m.Method {
			case "thread/resume":
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}
			case "turn/start":
				n := starts.Add(1)
				turn := "scheduler-turn"
				if n == 2 {
					turn = "native-after-scheduler"
				}
				_ = c.WriteJSON(map[string]any{"method": "turn/started", "params": map[string]any{"threadId": "owned", "turn": map[string]any{"id": turn, "status": "inProgress"}}})
				if n == 1 {
					_ = c.WriteJSON(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "owned", "turn": map[string]any{"id": turn, "status": "completed"}}})
				}
				result = map[string]any{"turn": map[string]any{"id": turn, "status": "inProgress"}}
			}
			_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	})
	dir := t.TempDir()
	persistRestrictivePolicy(t, dir)
	endpoint, _, closeGateway := policyTestGateway(t, dir, handler)
	defer closeGateway()
	native := policyTestClient(t, endpoint)
	defer native.c.Close()
	scheduler := policyTestNamedClient(t, endpoint, "squad_conductor")
	defer scheduler.c.Close()
	if _, err := native.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := scheduler.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := scheduler.call("turn/start", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := native.call("turn/start", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatalf("attached native client lost the later successful shared policy grant: %v", err)
	}
	if starts.Load() != 2 {
		t.Fatalf("expected scheduler work then native input, got %d starts", starts.Load())
	}
}
