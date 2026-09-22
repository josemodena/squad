package main

import (
	"encoding/json"
	"github.com/gorilla/websocket"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestAdministratorModelIsExplicitAndMismatchCannotStartTurn(t *testing.T) {
	for _, mismatch := range []bool{false, true} {
		t.Run(map[bool]string{false: "configured-model", true: "wrong-effective-model"}[mismatch], func(t *testing.T) {
			var starts atomic.Int32
			var requested atomic.Bool
			u := websocket.Upgrader{}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
					case "initialized":
						continue
					case "thread/start":
						var p map[string]any
						_ = json.Unmarshal(m.Params, &p)
						requested.Store(p["model"] == "gpt-5.6-luna")
						model := "gpt-5.6-luna"
						if mismatch {
							model = "gpt-6-astra"
						}
						result = map[string]any{"thread": map[string]any{"id": "admin"}, "model": model}
					case "turn/start":
						starts.Add(1)
						result = map[string]any{"turn": map[string]any{"id": "turn"}}
					}
					_ = c.WriteJSON(map[string]any{"id": json.RawMessage(m.ID), "result": result})
					if m.Method == "turn/start" {
						_ = c.WriteJSON(map[string]any{"method": "turn/completed", "params": map[string]any{"threadId": "admin", "turn": map[string]any{"id": "turn", "status": "completed"}}})
					}
				}
			}))
			defer server.Close()
			dir := t.TempDir()
			if err := atomicJSON(filepath.Join(dir, "current.json"), currentState{ID: "launch", Phase: "claimed"}); err != nil {
				t.Fatal(err)
			}
			err := runTurnWithModel("ws"+strings.TrimPrefix(server.URL, "http"), dir, "launch", "coordinate", dir, "gpt-5.6-luna")
			if !requested.Load() {
				t.Fatal("model was not explicit on thread/start")
			}
			if mismatch {
				if err == nil || starts.Load() != 0 {
					t.Fatalf("mismatch launched: %v, starts=%d", err, starts.Load())
				}
			} else if err != nil || starts.Load() != 1 {
				t.Fatalf("configured launch failed: %v", err)
			}
		})
	}
}
