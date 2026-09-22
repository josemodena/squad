package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gorilla/websocket"
)

func TestFinalGatewayEarlyCompletionDoesNotRestoreActive(t *testing.T) {
	u := websocket.Upgrader{}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			if m.Method == "turn/start" {
				c.WriteJSON(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "owned", "turn": map[string]any{"id": "one", "status": "completed"}}})
				result = map[string]any{"turn": map[string]any{"id": "one", "status": "completed"}}
			}
			c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	}))
	defer up.Close()
	a := newArbiter("")
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(up.URL, "http"), c)
	}))
	defer gateway.Close()
	c, e := dial("ws" + strings.TrimPrefix(gateway.URL, "http"))
	if e != nil {
		t.Fatal(e)
	}
	defer c.c.Close()
	if _, e = c.call("turn/start", map[string]any{"threadId": "owned"}, nil); e != nil {
		t.Fatal(e)
	}
	if got := a.activeTurn("owned"); got != "" {
		t.Fatalf("completed turn resurrected as active: %q", got)
	}
}

func TestFinalDelayedCompletionMustNotClearNewTurn(t *testing.T) {
	a := newArbiter("")
	a.setActive("owned", "new-turn")
	a.observe(message{Method: "turn/completed", Params: json.RawMessage(`{"threadId":"owned","turn":{"id":"old-turn","status":"completed"}}`)})
	if got := a.activeTurn("owned"); got != "new-turn" {
		t.Fatalf("delayed old completion cleared current authority: %q", got)
	}
}

func TestFinalStaleHistoryMustNotClearPendingStart(t *testing.T) {
	a := newArbiter("")
	a.setActive("owned", "pending:3")
	a.reconcileResult(json.RawMessage(`{"thread":{"id":"owned","status":{"type":"idle"},"turns":[]}}`))
	if got := a.activeTurn("owned"); got != "pending:3" {
		t.Fatalf("concurrent stale observer history cleared reserved start: %q", got)
	}
}

func TestFinalNativeResumeMustValidateEffectivePolicy(t *testing.T) {
	u := websocket.Upgrader{}
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			if m.Method == "thread/resume" {
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "approvalPolicy": "never", "sandbox": map[string]any{"type": "dangerFullAccess"}}
			}
			c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	}))
	defer up.Close()
	dir := t.TempDir()
	atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), map[string]any{"thread_id": "owned", "resolved": map[string]any{"approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}})
	a := newArbiter(dir)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(up.URL, "http"), c)
	}))
	defer gateway.Close()
	conn, e := websocketDialer("ws" + strings.TrimPrefix(gateway.URL, "http"))
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	c := &rpcClient{c: conn, nextID: 1}
	if _, e = c.call("initialize", map[string]any{"clientInfo": map[string]any{"name": "codex_cli"}}, nil); e != nil {
		t.Fatal(e)
	}
	if _, e = c.call("thread/resume", map[string]any{"threadId": "owned"}, nil); e == nil {
		t.Fatal("accepted native resume with effective dangerFullAccess/never despite persisted readOnly/on-request")
	}
}

func TestFinalTwoClientsStaleReadAllowsSecondSchedulerStart(t *testing.T) {
	u := websocket.Upgrader{}
	readCaptured := make(chan struct{})
	releaseRead := make(chan struct{})
	var starts atomic.Int32
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			switch m.Method {
			case "thread/read":
				close(readCaptured)
				<-releaseRead
				result = map[string]any{"thread": map[string]any{"id": "owned", "status": map[string]any{"type": "idle"}, "turns": []any{}}}
			case "turn/start":
				starts.Add(1)
				result = map[string]any{"turn": map[string]any{"id": "running", "status": "inProgress"}}
			}
			c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	}))
	defer up.Close()
	a := newArbiter("")
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(up.URL, "http"), c)
	}))
	defer gateway.Close()
	endpoint := "ws" + strings.TrimPrefix(gateway.URL, "http")
	observer, e := dial(endpoint)
	if e != nil {
		t.Fatal(e)
	}
	defer observer.c.Close()
	scheduler, e := dial(endpoint)
	if e != nil {
		t.Fatal(e)
	}
	defer scheduler.c.Close()
	observed := make(chan error, 1)
	go func() { _, e := observer.call("thread/read", map[string]any{"threadId": "owned"}, nil); observed <- e }()
	<-readCaptured
	if _, e = scheduler.call("turn/start", map[string]any{"threadId": "owned"}, nil); e != nil {
		t.Fatal(e)
	}
	close(releaseRead)
	if e = <-observed; e != nil {
		t.Fatal(e)
	}
	_, e = scheduler.call("turn/start", map[string]any{"threadId": "owned"}, nil)
	if e == nil || starts.Load() != 1 {
		t.Fatalf("stale other-client snapshot allowed second upstream start: starts=%d error=%v", starts.Load(), e)
	}
}

func TestNativeResumeFillsAndVerifiesPersistedRestrictivePolicy(t *testing.T) {
	u := websocket.Upgrader{}
	seen := make(chan map[string]any, 1)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			if m.Method == "thread/resume" {
				var p map[string]any
				_ = json.Unmarshal(m.Params, &p)
				seen <- p
				result = map[string]any{"thread": map[string]any{"id": "owned"}, "model": "gpt-test", "reasoningEffort": "high", "cwd": "/work", "runtimeWorkspaceRoots": []any{"/work"}, "approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}
			}
			_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	}))
	defer up.Close()
	dir := t.TempDir()
	resolved := map[string]any{"model": "gpt-test", "reasoningEffort": "high", "cwd": "/work", "runtimeWorkspaceRoots": []any{"/work"}, "approvalPolicy": "on-request", "sandbox": map[string]any{"type": "readOnly"}}
	if err := atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), map[string]any{"thread_id": "owned", "resolved": resolved}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(dir)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(up.URL, "http"), c)
	}))
	defer gateway.Close()
	conn, e := websocketDialer("ws" + strings.TrimPrefix(gateway.URL, "http"))
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	c := &rpcClient{c: conn, nextID: 1}
	if _, e = c.call("initialize", map[string]any{"clientInfo": map[string]any{"name": "codex_cli"}}, nil); e != nil {
		t.Fatal(e)
	}
	if _, e = c.call("thread/resume", map[string]any{"threadId": "owned", "model": nil, "cwd": nil, "runtimeWorkspaceRoots": nil, "approvalPolicy": nil, "sandbox": nil}, nil); e != nil {
		t.Fatal(e)
	}
	p := <-seen
	if p["approvalPolicy"] != "on-request" || p["sandbox"] != "read-only" || p["cwd"] != "/work" || !reflect.DeepEqual(p["runtimeWorkspaceRoots"], []any{"/work"}) {
		t.Fatalf("persisted policy was not supplied to App Server: %#v", p)
	}
	config, _ := p["config"].(map[string]any)
	if p["model"] != "gpt-test" || config["model_reasoning_effort"] != "high" {
		t.Fatalf("persisted model/effort were not supplied: %#v", p)
	}
}

func TestRetiredThreadRejectsAlreadyAttachedClient(t *testing.T) {
	u := websocket.Upgrader{}
	var starts atomic.Int32
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			if m.Method == "initialized" {
				continue
			}
			result := map[string]any{}
			switch m.Method {
			case "thread/resume":
				result = map[string]any{"thread": map[string]any{"id": "old"}, "model": "gpt-test", "reasoningEffort": "medium", "cwd": "/work", "runtimeWorkspaceRoots": []any{"/work"}, "approvalPolicy": "never", "sandbox": map[string]any{"type": "readOnly"}}
			case "turn/start":
				starts.Add(1)
				result = map[string]any{"turn": map[string]any{"id": "revived"}}
			}
			_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	}))
	defer up.Close()
	dir := t.TempDir()
	resolved := map[string]any{"model": "gpt-test", "reasoningEffort": "medium", "cwd": "/work", "runtimeWorkspaceRoots": []any{"/work"}, "approvalPolicy": "never", "sandbox": map[string]any{"type": "readOnly"}}
	if err := atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), map[string]any{"thread_id": "old", "resolved": resolved}); err != nil {
		t.Fatal(err)
	}
	a := newArbiter(dir)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(up.URL, "http"), c)
	}))
	defer gateway.Close()
	conn, e := websocketDialer("ws" + strings.TrimPrefix(gateway.URL, "http"))
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	c := &rpcClient{c: conn, nextID: 1}
	if _, e = c.call("initialize", map[string]any{"clientInfo": map[string]any{"name": "codex_cli"}}, nil); e != nil {
		t.Fatal(e)
	}
	if _, e = c.call("thread/resume", map[string]any{"threadId": "old"}, nil); e != nil {
		t.Fatal(e)
	}
	if _, e = a.rollover("old"); e != nil {
		t.Fatal(e)
	}
	if _, e = c.call("turn/start", map[string]any{"threadId": "old"}, nil); e == nil || !strings.Contains(e.Error(), "retired") {
		t.Fatalf("attached client revived retired thread: %v", e)
	}
	a.observe(message{Method: "turn/started", Params: json.RawMessage(`{"threadId":"old","turn":{"id":"revived","status":"inProgress"}}`)})
	if got := a.activeTurn("old"); got != "" {
		t.Fatalf("late old-client notification revived retired thread: %q", got)
	}
	if starts.Load() != 0 {
		t.Fatalf("retired start reached upstream %d times", starts.Load())
	}
}
