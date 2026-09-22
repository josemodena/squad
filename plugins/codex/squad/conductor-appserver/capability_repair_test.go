package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gorilla/websocket"
)

func TestSchedulerNegotiatesExperimentalPolicyFields(t *testing.T) {
	var rejected atomic.Int32
	u := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := u.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		experimental := false
		for {
			var m message
			if c.ReadJSON(&m) != nil {
				return
			}
			switch m.Method {
			case "initialize":
				var p struct {
					Capabilities struct {
						ExperimentalAPI bool `json:"experimentalApi"`
					} `json:"capabilities"`
				}
				_ = json.Unmarshal(m.Params, &p)
				experimental = p.Capabilities.ExperimentalAPI
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			case "initialized":
			case "thread/resume":
				var p map[string]any
				_ = json.Unmarshal(m.Params, &p)
				if p["runtimeWorkspaceRoots"] != nil && !experimental {
					rejected.Add(1)
					_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "error": map[string]any{"code": -32600, "message": "runtimeWorkspaceRoots requires capabilities.experimentalApi"}})
					continue
				}
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": effectiveTestPolicy("owned")})
			case "thread/read":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"thread": map[string]any{"id": "owned", "turns": []any{}}}})
			case "turn/start":
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"turn": map[string]any{"id": "turn-1"}}})
				_ = c.WriteJSON(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "owned", "turn": map[string]any{"id": "turn-1", "status": "completed"}}})
			}
		}
	}))
	defer upstream.Close()

	// Reproduce the App Server contract failure with a client which omits the
	// capability while sending the experimental field.
	raw, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(upstream.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	legacy := &rpcClient{c: raw, nextID: 1}
	if _, err = legacy.call("initialize", map[string]any{"clientInfo": map[string]any{"name": "legacy"}}, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = legacy.call("thread/resume", map[string]any{"threadId": "owned", "runtimeWorkspaceRoots": []any{"/work"}}, nil); err == nil || !strings.Contains(err.Error(), "-32600") {
		t.Fatalf("missing experimentalApi did not reproduce rejection: %v", err)
	}
	_ = raw.Close()

	state := t.TempDir()
	writeTestPolicy(t, state)
	if err := atomicJSON(filepath.Join(state, "current.json"), currentState{ID: "launch", Phase: "controller-starting"}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(state)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, upgradeErr := u.Upgrade(w, r, nil)
		if upgradeErr == nil {
			defer c.Close()
			a.proxy("ws"+strings.TrimPrefix(upstream.URL, "http"), c)
		}
	}))
	defer gateway.Close()

	if err := runTurn("ws"+strings.TrimPrefix(gateway.URL, "http"), state, "launch", "continue", "/work"); err != nil {
		t.Fatalf("capability-aware scheduler resume failed: %v", err)
	}
	if rejected.Load() != 1 {
		t.Fatalf("expected only the deliberate legacy rejection, got %d", rejected.Load())
	}
	ack, err := os.ReadFile(filepath.Join(state, "acks", "launch.json"))
	if err != nil || !strings.Contains(string(ack), `"status":0`) {
		t.Fatalf("successful checked resume did not permit the turn: %v %s", err, ack)
	}
}

func TestNativeCapabilityNegotiationIsForwarded(t *testing.T) {
	var sawExperimental atomic.Bool
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
				sawExperimental.Store(strings.Contains(string(m.Params), `"experimentalApi":true`))
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			} else if m.Method == "initialized" {
			} else if m.Method == "thread/resume" {
				_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": effectiveTestPolicy("owned")})
			}
		}
	}))
	defer upstream.Close()
	state := t.TempDir()
	writeTestPolicy(t, state)
	a := newArbiter(state)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := u.Upgrade(w, r, nil)
		if err == nil {
			defer c.Close()
			a.proxy("ws"+strings.TrimPrefix(upstream.URL, "http"), c)
		}
	}))
	defer gateway.Close()
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(gateway.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	native := &rpcClient{c: c, nextID: 1}
	if _, err = native.call("initialize", map[string]any{"clientInfo": map[string]any{"name": "codex_cli"}, "capabilities": map[string]any{"experimentalApi": true}}, nil); err != nil {
		t.Fatal(err)
	}
	if err = c.WriteJSON(map[string]any{"jsonrpc": "2.0", "method": "initialized"}); err != nil {
		t.Fatal(err)
	}
	if _, err = native.call("thread/resume", map[string]any{"threadId": "owned"}, nil); err != nil {
		t.Fatalf("native checked resume failed: %v", err)
	}
	if !sawExperimental.Load() {
		t.Fatal("gateway did not preserve native experimentalApi negotiation")
	}
}

func TestReadCurrentFencesStaleController(t *testing.T) {
	path := filepath.Join(t.TempDir(), "current.json")
	if _, err := readCurrent(path, "old"); !errors.Is(err, errStaleLaunch) {
		t.Fatalf("missing launch record was not stale: %v", err)
	}
	if err := atomicJSON(path, currentState{ID: "new", Phase: "controller-starting"}); err != nil {
		t.Fatal(err)
	}
	if _, err := readCurrent(path, "old"); !errors.Is(err, errStaleLaunch) {
		t.Fatalf("replaced launch record was not stale: %v", err)
	}
	state := t.TempDir()
	if err := recordRunResult(state, "old", fmt.Errorf("restart: %w", errStaleLaunch)); err != nil {
		t.Fatalf("stale restarted controller did not terminate successfully: %v", err)
	}
	if _, err := os.Stat(filepath.Join(state, "acks", "old.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale controller wrote an acknowledgement for a launch it did not own: %v", err)
	}
}

func writeTestPolicy(t *testing.T, state string) {
	t.Helper()
	if err := atomicJSON(filepath.Join(state, "chief-of-staff-thread.json"), map[string]any{
		"thread_id": "owned",
		"resolved":  effectiveTestPolicy("owned"),
	}); err != nil {
		t.Fatal(err)
	}
}

func effectiveTestPolicy(thread string) map[string]any {
	return map[string]any{
		"thread": map[string]any{"id": thread}, "model": "gpt-test", "reasoningEffort": "medium",
		"cwd": "/work", "runtimeWorkspaceRoots": []any{"/work"}, "approvalPolicy": "never",
		"sandbox": map[string]any{"type": "workspaceWrite"},
	}
}
