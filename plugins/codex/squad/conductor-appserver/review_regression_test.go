package main

import (
	"encoding/json"
	"github.com/gorilla/websocket"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReviewControllerUnixEndpoint(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.sock")
	ln, e := net.Listen("unix", path)
	if e != nil {
		t.Fatal(e)
	}
	u := websocket.Upgrader{}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			if m.Method != "initialized" {
				c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			}
		}
	})}
	defer srv.Close()
	go srv.Serve(ln)
	c, e := dial("unix://" + path)
	if e != nil {
		t.Fatalf("production endpoint unsupported: %v", e)
	}
	c.c.Close()
}

func TestReviewCompletionBeforeStartResponse(t *testing.T) {
	stop := make(chan struct{})
	defer close(stop)
	u := websocket.Upgrader{}
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
				c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			case "thread/start":
				c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"thread": map[string]any{"id": "owned"}}})
			case "turn/start":
				c.WriteJSON(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "owned", "turn": map[string]any{"id": "one", "status": "completed"}}})
				c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{"turn": map[string]any{"id": "one"}}})
				<-stop
				return
			}
		}
	}))
	defer srv.Close()
	dir := t.TempDir()
	atomicJSON(filepath.Join(dir, "current.json"), currentState{ID: "launch", Phase: "claimed"})
	done := make(chan error, 1)
	go func() { done <- runTurn("ws"+strings.TrimPrefix(srv.URL, "http"), dir, "launch", "test", dir) }()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(300 * time.Millisecond):
		t.Fatal("matching completion discarded before start reply; controller remains blocked")
	}
}

func TestReviewGatewayReconcilesCompletedHistoryAfterRestart(t *testing.T) {
	dir := t.TempDir()
	atomicJSON(filepath.Join(dir, "gateway-authority.json"), map[string]string{"owned": "old-turn"})
	u := websocket.Upgrader{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			var result any = map[string]any{}
			switch m.Method {
			case "initialized":
				continue
			case "thread/resume", "thread/read":
				result = map[string]any{"thread": map[string]any{"id": "owned", "turns": []any{map[string]any{"id": "old-turn", "status": "completed"}}}}
			case "turn/start":
				result = map[string]any{"turn": map[string]any{"id": "new-turn"}}
			}
			c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
		}
	}))
	defer upstream.Close()
	a := newArbiter(dir)
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(upstream.URL, "http"), c)
	}))
	defer gateway.Close()
	c, e := dial("ws" + strings.TrimPrefix(gateway.URL, "http"))
	if e != nil {
		t.Fatal(e)
	}
	defer c.c.Close()
	if _, e = c.call("thread/resume", map[string]any{"threadId": "owned"}, nil); e != nil {
		t.Fatal(e)
	}
	if _, e = c.call("thread/read", map[string]any{"threadId": "owned", "includeTurns": true}, nil); e != nil {
		t.Fatal(e)
	}
	if _, e = c.call("turn/start", map[string]any{"threadId": "owned"}, nil); e != nil {
		t.Fatalf("completed history did not release stale authority: %v", e)
	}
}

func TestReviewDistinctCwdMustBeRejected(t *testing.T) {
	dir := t.TempDir()
	atomicJSON(filepath.Join(dir, "chief-of-staff-thread.json"), map[string]any{"resolved": map[string]any{"cwd": "/work/foo-bar"}})
	if got := policyMismatch(dir, map[string]any{"cwd": "/work/foobar"}); got == "" {
		t.Fatal("different working directory accepted as persisted policy")
	}
}

func TestReviewUpstreamDisconnectPropagates(t *testing.T) {
	closeUp := make(chan struct{})
	u := websocket.Upgrader{}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
			c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": map[string]any{}})
			if m.Method == "thread/read" {
				<-closeUp
				return
			}
		}
	}))
	defer upstream.Close()
	a := newArbiter("")
	gateway := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, e := u.Upgrade(w, r, nil)
		if e != nil {
			return
		}
		defer c.Close()
		a.proxy("ws"+strings.TrimPrefix(upstream.URL, "http"), c)
	}))
	defer gateway.Close()
	c, e := dial("ws" + strings.TrimPrefix(gateway.URL, "http"))
	if e != nil {
		t.Fatal(e)
	}
	defer c.c.Close()
	if _, e = c.call("thread/read", map[string]any{"threadId": "owned"}, nil); e != nil {
		t.Fatal(e)
	}
	close(closeUp)
	c.c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	var m message
	e = c.c.ReadJSON(&m)
	if n, ok := e.(net.Error); ok && n.Timeout() {
		t.Fatal("upstream closed but downstream remained open; controller cannot reconnect")
	}
	if e == nil {
		t.Fatal("expected connection close")
	}
}
