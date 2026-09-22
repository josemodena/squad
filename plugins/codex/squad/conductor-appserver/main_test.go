package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func fakeAppServer(t *testing.T) *httptest.Server {
	t.Helper()
	u := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			switch m.Method {
			case "initialize":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			case "thread/resume":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"thread": map[string]any{"id": "shared"}, "model": "gpt-test", "cwd": "/work", "approvalPolicy": "never", "reasoningEffort": "medium", "sandbox": map[string]any{"type": "workspaceWrite"}}})
			case "initialized":
			case "thread/start":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"thread": map[string]any{"id": "owned-thread"}}})
			case "turn/start":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"turn": map[string]any{"id": "owned-turn"}}})
				// An unrelated completion must not acknowledge the owned launch.
				_ = c.WriteJSON(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "auto-title-thread", "turn": map[string]any{"id": "other-turn", "status": "completed"}}})
				_ = c.WriteJSON(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "owned-thread", "turn": map[string]any{"id": "owned-turn", "status": "completed"}}})
			}
		}
	}))
}

func TestNotificationBeforeStartResponseDoesNotDeadlock(t *testing.T) {
	u := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			if m.Method == "initialize" {
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			} else if m.Method == "turn/start" {
				_ = c.WriteJSON(map[string]any{"method": "turn/started", "params": map[string]any{"threadId": "owned", "turn": map[string]any{"id": "one"}}})
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"turn": map[string]any{"id": "one"}}})
			}
		}
	}))
	defer upstream.Close()
	a := newArbiter("")
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := u.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(upstream.URL, "http"), c)
	}))
	defer gateway.Close()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(gateway.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.WriteJSON(map[string]any{"id": 0, "method": "initialize", "params": map[string]any{"clientInfo": map[string]any{"name": "squad_conductor"}}})
	var initialised message
	if err := c.ReadJSON(&initialised); err != nil {
		t.Fatal(err)
	}
	_ = c.WriteJSON(map[string]any{"id": 1, "method": "turn/start", "params": map[string]any{"threadId": "owned"}})
	_ = c.SetReadDeadline(time.Now().Add(time.Second))
	for {
		var m message
		if err := c.ReadJSON(&m); err != nil {
			t.Fatalf("response blocked behind notification: %v", err)
		}
		if len(m.ID) > 0 {
			return
		}
	}
}

func TestLostStartResponseDoesNotResubmit(t *testing.T) {
	var starts atomic.Int32
	u := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		for {
			var m message
			if c.ReadJSON(&m) != nil {
				return
			}
			switch m.Method {
			case "initialize":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			case "thread/start", "thread/resume":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"thread": map[string]any{"id": "owned", "turns": []any{}}}})
			case "turn/start":
				starts.Add(1)
				return
			}
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	_ = atomicJSON(filepath.Join(dir, "current.json"), currentState{ID: "launch", Phase: "claimed"})
	endpoint := "ws" + strings.TrimPrefix(srv.URL, "http")
	if err := runTurn(endpoint, dir, "launch", "one piece", dir); err == nil {
		t.Fatal("expected lost reply")
	}
	if err := runTurn(endpoint, dir, "launch", "one piece", dir); !errors.Is(err, errAmbiguousStart) {
		t.Fatalf("expected visible ambiguity, got %v", err)
	}
	if starts.Load() != 1 {
		t.Fatalf("upstream accepted %d starts for one launch", starts.Load())
	}
}

func TestArbiterRestoresActiveAuthority(t *testing.T) {
	dir := t.TempDir()
	if err := atomicJSON(filepath.Join(dir, "gateway-authority.json"), map[string]string{"thread": "turn"}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(dir)
	if got := a.activeTurn("thread"); got != "turn" {
		t.Fatalf("active authority not restored: %q", got)
	}
}

func TestPolicyMismatchIsVisible(t *testing.T) {
	dir := t.TempDir()
	state := map[string]any{"resolved": map[string]any{"model": "gpt-test", "cwd": "/work", "approvalPolicy": "never", "reasoningEffort": "medium", "sandbox": map[string]any{"type": "workspaceWrite"}}}
	if err := atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), state); err != nil {
		t.Fatal(err)
	}
	if got := policyMismatch(dir, map[string]any{"model": "other"}); !strings.Contains(got, "differs from persisted") {
		t.Fatalf("mismatch was not actionable: %q", got)
	}
	if got := policyMismatch(dir, map[string]any{"model": "gpt-test", "cwd": "/work", "sandbox": "workspace-write"}); got != "" {
		t.Fatalf("matching policy refused: %q", got)
	}
}

func TestPolicyAcceptsObserverAndRejectsNativeMutation(t *testing.T) {
	dir := t.TempDir()
	state := map[string]any{"resolved": map[string]any{"model": "gpt-test", "cwd": "/work", "approvalPolicy": "never", "sandbox": map[string]any{"type": "workspaceWrite"}}}
	if err := atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), state); err != nil {
		t.Fatal(err)
	}
	if got := policyMismatch(dir, map[string]any{"threadId": "owned"}); got != "" {
		t.Fatalf("read-only observer was refused: %q", got)
	}
	if got := policyMismatch(dir, map[string]any{"threadId": "owned", "sandboxPolicy": map[string]any{"type": "readOnly"}}); !strings.Contains(got, "differs") {
		t.Fatalf("native permission mutation was not rejected: %q", got)
	}
}

func TestRolloverUsesSameAuthorityAsStarts(t *testing.T) {
	dir := t.TempDir()
	if err := atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), map[string]any{"thread_id": "owned"}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(dir)
	a.setActive("owned", "native-turn")
	if _, err := a.rollover("owned"); err == nil {
		t.Fatal("rollover accepted while a native turn was active")
	}
	a.setActive("owned", "")
	archived, err := a.rollover("owned")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(archived); err != nil {
		t.Fatalf("archived state missing: %v", err)
	}
}

func TestRunAcknowledgesOnlyMatchingCompletedTurn(t *testing.T) {
	srv := fakeAppServer(t)
	defer srv.Close()
	dir := t.TempDir()
	if err := atomicJSON(filepath.Join(dir, "current.json"), currentState{ID: "launch-1", Events: []string{"e1"}, Phase: "claimed"}); err != nil {
		t.Fatal(err)
	}
	url := "ws" + strings.TrimPrefix(srv.URL, "http")
	if err := runTurn(url, dir, "launch-1", "do work", dir); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "acks", "launch-1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var ack map[string]any
	if json.Unmarshal(b, &ack) != nil || ack["turn_id"] != "owned-turn" || ack["status"] != float64(0) {
		t.Fatalf("unexpected ack: %s", b)
	}
}

func TestArbiterTracksOnlyNamedThreadAndTurn(t *testing.T) {
	stateDir := t.TempDir()
	if err := atomicJSON(filepath.Join(stateDir, "chief-of-staff-thread.json"), map[string]any{"thread_id": "shared", "resolved": map[string]any{"model": "gpt-test", "cwd": "/work", "approvalPolicy": "never", "reasoningEffort": "medium", "sandbox": map[string]any{"type": "workspaceWrite"}}}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(stateDir)
	a.observe(message{Method: "turn/started", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"one"}}`)})
	a.observe(message{Method: "turn/completed", Params: json.RawMessage(`{"threadId":"other","turn":{"id":"noise"}}`)})
	if got := a.activeTurn("owned"); got != "one" {
		t.Fatalf("unrelated completion cleared owned turn: %q", got)
	}
	a.observe(message{Method: "turn/completed", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"one"}}`)})
	if got := a.activeTurn("owned"); got != "" {
		t.Fatalf("matching completion did not clear turn: %q", got)
	}
}

func TestGatewayRefusesSchedulerStartDuringNativeTurn(t *testing.T) {
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			var m message
			if c.ReadJSON(&m) != nil {
				return
			}
			switch m.Method {
			case "initialize":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			case "thread/resume":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"thread": map[string]any{"id": "shared"}, "model": "gpt-test", "cwd": "/work", "approvalPolicy": "never", "reasoningEffort": "medium", "sandbox": map[string]any{"type": "workspaceWrite"}}})
			case "turn/start":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"turn": map[string]any{"id": "native-turn"}}})
			}
		}
	}))
	defer upstream.Close()
	stateDir := t.TempDir()
	if err := atomicJSON(filepath.Join(stateDir, "chief-of-staff-thread.json"), map[string]any{"thread_id": "shared", "resolved": map[string]any{"model": "gpt-test", "cwd": "/work", "approvalPolicy": "never", "reasoningEffort": "medium", "sandbox": map[string]any{"type": "workspaceWrite"}}}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(stateDir)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(upstream.URL, "http"), c)
	}))
	defer gateway.Close()
	connect := func(name string) *websocket.Conn {
		c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(gateway.URL, "http"), nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := c.WriteJSON(map[string]any{"id": 1, "method": "initialize", "params": map[string]any{"clientInfo": map[string]any{"name": name}}}); err != nil {
			t.Fatal(err)
		}
		var response message
		if err := c.ReadJSON(&response); err != nil {
			t.Fatal(err)
		}
		return c
	}
	native := connect("codex_cli")
	defer native.Close()
	if err := native.WriteJSON(map[string]any{"id": 2, "method": "thread/resume", "params": map[string]any{"threadId": "shared", "model": "gpt-test", "cwd": "/work", "approvalPolicy": "never", "sandbox": "workspace-write"}}); err != nil {
		t.Fatal(err)
	}
	var resumed message
	if err := native.ReadJSON(&resumed); err != nil || len(resumed.Error) != 0 {
		t.Fatalf("native resume not accepted: %v %s", err, resumed.Error)
	}
	scheduler := connect("squad_conductor")
	defer scheduler.Close()
	start := map[string]any{"id": 3, "method": "turn/start", "params": map[string]any{"threadId": "shared", "input": []map[string]string{{"type": "text", "text": "hello"}}}}
	if err := native.WriteJSON(start); err != nil {
		t.Fatal(err)
	}
	var accepted message
	if err := native.ReadJSON(&accepted); err != nil || len(accepted.Error) != 0 {
		t.Fatalf("native start not accepted: %v %s", err, accepted.Error)
	}
	if err := scheduler.WriteJSON(start); err != nil {
		t.Fatal(err)
	}
	var refused message
	if err := scheduler.ReadJSON(&refused); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(refused.Error), "scheduler start refused") {
		t.Fatalf("scheduler race was not refused: %+v", refused)
	}
}

func TestGatewayRejectsNativeSettingsMutation(t *testing.T) {
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	var updates atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			var m message
			if c.ReadJSON(&m) != nil {
				return
			}
			switch m.Method {
			case "initialize":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			case "initialized":
			case "thread/resume":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"thread": map[string]any{"id": "shared"}, "model": "gpt-test", "cwd": "/work", "runtimeWorkspaceRoots": []any{"/work"}, "approvalPolicy": "never", "reasoningEffort": "medium", "sandbox": map[string]any{"type": "workspaceWrite"}}})
			case "thread/settings/update":
				updates.Add(1)
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			}
		}
	}))
	defer upstream.Close()
	stateDir := t.TempDir()
	if err := atomicJSON(filepath.Join(stateDir, "chief-of-staff-thread.json"), map[string]any{"thread_id": "shared", "resolved": map[string]any{"model": "gpt-test", "cwd": "/work", "runtimeWorkspaceRoots": []any{"/work"}, "approvalPolicy": "never", "reasoningEffort": "medium", "sandbox": map[string]any{"type": "workspaceWrite"}}}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(stateDir)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(upstream.URL, "http"), c)
	}))
	defer gateway.Close()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(gateway.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	request := func(id int, method string, params any) message {
		if err := c.WriteJSON(map[string]any{"id": id, "method": method, "params": params}); err != nil {
			t.Fatal(err)
		}
		var response message
		if err := c.ReadJSON(&response); err != nil {
			t.Fatal(err)
		}
		return response
	}
	_ = request(1, "initialize", map[string]any{"clientInfo": map[string]any{"name": "codex_cli"}})
	_ = c.WriteJSON(map[string]any{"method": "initialized"})
	if response := request(2, "thread/resume", map[string]any{"threadId": "shared"}); len(response.Error) != 0 {
		t.Fatalf("observer resume refused: %s", response.Error)
	}
	response := request(3, "thread/settings/update", map[string]any{"threadId": "shared", "sandboxPolicy": map[string]any{"type": "dangerFullAccess"}})
	if !strings.Contains(string(response.Error), "differs from persisted") {
		t.Fatalf("unsafe settings update was not visibly rejected: %s", response.Error)
	}
	if updates.Load() != 0 {
		t.Fatal("unsafe settings update reached the private App Server")
	}
}
