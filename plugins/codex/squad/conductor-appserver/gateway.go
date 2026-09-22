package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// arbiter is the single turn authority shared by scheduler and native TUI
// clients. Codex currently treats a second turn/start as same-turn steering,
// so scheduler starts must be rejected before reaching the private server.
type arbiter struct {
	mu sync.Mutex
	// policyForward makes registering a policy verification and forwarding
	// governed mutations one ordering boundary. It is held only for the
	// websocket write, never while waiting for an App Server response.
	policyForward chan struct{}
	threads       map[string]*threadAuthority
	stateDir      string
}

type threadAuthority struct {
	mu             sync.Mutex
	Active         string            `json:"active,omitempty"`
	Generation     uint64            `json:"generation"`
	Retired        bool              `json:"retired,omitempty"`
	Terminal       map[string]string `json:"terminal,omitempty"`
	PolicyInFlight uint64            `json:"-"`
	PolicyTainted  bool              `json:"-"`
	PolicyVerified bool              `json:"-"`
}

// policyVerification gives one forwarded resume a unique settlement identity.
// Response handling, disconnect cleanup and a failed writer can race, so the
// token is settled under arbiter.mu and may affect its thread-wide group once.
type policyVerification struct {
	thread  string
	settled bool
}

type authorityFile struct {
	Version int                         `json:"version"`
	Threads map[string]*threadAuthority `json:"threads"`
}

func newArbiter(stateDir string) *arbiter {
	a := &arbiter{policyForward: make(chan struct{}, 1), threads: map[string]*threadAuthority{}, stateDir: stateDir}
	a.policyForward <- struct{}{}
	if stateDir != "" {
		if b, err := os.ReadFile(filepath.Join(stateDir, "gateway-authority.json")); err == nil {
			var saved authorityFile
			if json.Unmarshal(b, &saved) == nil && saved.Threads != nil {
				for id, state := range saved.Threads {
					if state != nil {
						state.Terminal = terminalMap(state.Terminal)
						a.threads[id] = state
					}
				}
			} else {
				// Preserve authority written by the pre-generation implementation.
				var legacy map[string]string
				if json.Unmarshal(b, &legacy) == nil {
					for id, turn := range legacy {
						a.threads[id] = &threadAuthority{Active: turn, Generation: 1, Terminal: map[string]string{}}
					}
				}
			}
		}
	}
	return a
}

func (a *arbiter) acquirePolicyForward() bool {
	select {
	case <-a.policyForward:
		return true
	case <-time.After(5 * time.Second):
		return false
	}
}

func (a *arbiter) releasePolicyForward() {
	a.policyForward <- struct{}{}
}

func terminalMap(in map[string]string) map[string]string {
	if in == nil {
		return map[string]string{}
	}
	return in
}

func (a *arbiter) persistLocked() {
	if a.stateDir == "" {
		return
	}
	_ = atomicJSON(filepath.Join(a.stateDir, "gateway-authority.json"), authorityFile{Version: 2, Threads: a.threads})
}

func (a *arbiter) thread(id string) *threadAuthority {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.threads[id] == nil {
		a.threads[id] = &threadAuthority{Terminal: map[string]string{}}
	}
	a.threads[id].Terminal = terminalMap(a.threads[id].Terminal)
	return a.threads[id]
}

func (a *arbiter) observe(m message) {
	if m.Method != "turn/started" && m.Method != "turn/completed" {
		return
	}
	var p turnEnvelope
	if json.Unmarshal(m.Params, &p) != nil || p.ThreadID == "" {
		return
	}
	a.mu.Lock()
	t := a.threads[p.ThreadID]
	if t == nil {
		t = &threadAuthority{Terminal: map[string]string{}}
		a.threads[p.ThreadID] = t
	}
	t.Terminal = terminalMap(t.Terminal)
	if t.Retired || p.Turn.ID == "" {
		a.mu.Unlock()
		return
	}
	changed, updateHuman := false, false
	if m.Method == "turn/completed" || isTerminal(p.Turn.Status) {
		if _, known := t.Terminal[p.Turn.ID]; !known {
			t.Terminal[p.Turn.ID] = p.Turn.Status
			changed = true
		}
		// Only the current exact turn may release authority. Old and duplicate
		// completion notifications remain terminal facts but cannot clear a
		// newer turn or overwrite its human control record.
		if t.Active == p.Turn.ID {
			t.Active = ""
			changed, updateHuman = true, true
		}
	} else if _, terminal := t.Terminal[p.Turn.ID]; !terminal {
		// A started event can resolve this thread's pending reservation. It can
		// never displace a different, already named turn.
		if t.Active == "" || strings.HasPrefix(t.Active, "pending:") || t.Active == p.Turn.ID {
			if t.Active != p.Turn.ID {
				t.Active = p.Turn.ID
				changed = true
			}
			updateHuman = true
		}
	}
	if changed {
		t.Generation++
		a.persistLocked()
	}
	if updateHuman {
		a.persistThreadStateLocked(p.ThreadID, p.Turn.ID, p.Turn.Status)
	}
	a.mu.Unlock()
}

func isTerminal(status string) bool {
	switch status {
	case "completed", "failed", "interrupted", "cancelled", "canceled", "stopped":
		return true
	}
	return false
}

func (a *arbiter) activeTurn(thread string) string {
	a.mu.Lock()
	defer a.mu.Unlock()
	if t := a.threads[thread]; t != nil {
		return t.Active
	}
	return ""
}
func (a *arbiter) setActive(thread, turn string) {
	a.mu.Lock()
	t := a.threads[thread]
	if t == nil {
		t = &threadAuthority{Terminal: map[string]string{}}
		a.threads[thread] = t
	}
	if !t.Retired && t.Active != turn {
		t.Active = turn
		t.Generation++
		a.persistLocked()
	}
	a.mu.Unlock()
}

func (a *arbiter) reserveStart(thread string) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	t := a.threads[thread]
	if t == nil {
		t = &threadAuthority{Terminal: map[string]string{}}
		a.threads[thread] = t
	}
	if t.Retired {
		return "", fmt.Errorf("thread %s is retired; start refused", thread)
	}
	if t.Active != "" {
		return "", fmt.Errorf("thread %s already has active turn %s", thread, t.Active)
	}
	t.Generation++
	t.Active = fmt.Sprintf("pending:%d", t.Generation)
	a.persistLocked()
	return t.Active, nil
}

func (a *arbiter) failStart(thread, pending string) {
	a.mu.Lock()
	if t := a.threads[thread]; t != nil && !t.Retired && t.Active == pending {
		t.Active = ""
		t.Generation++
		a.persistLocked()
	}
	a.mu.Unlock()
}

func (a *arbiter) rollover(thread string) (string, error) {
	t := a.thread(thread)
	t.mu.Lock()
	defer t.mu.Unlock()
	a.mu.Lock()
	if t.Retired {
		a.mu.Unlock()
		return "", fmt.Errorf("thread %s is already retired", thread)
	}
	if active := t.Active; active != "" {
		a.mu.Unlock()
		return "", fmt.Errorf("thread %s still has active turn %s; rollover refused", thread, active)
	}
	path := filepath.Join(a.stateDir, "chief-of-staff-thread.json")
	var saved map[string]any
	b, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(b, &saved) != nil || fmt.Sprint(saved["thread_id"]) != thread {
		a.mu.Unlock()
		return "", fmt.Errorf("persisted state for thread %s is unavailable", thread)
	}
	dir := filepath.Join(a.stateDir, "rollovers")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		a.mu.Unlock()
		return "", err
	}
	archived := filepath.Join(dir, time.Now().UTC().Format("20060102T150405.000000000Z")+"-thread.json")
	if err := os.Rename(path, archived); err != nil {
		a.mu.Unlock()
		return "", err
	}
	t.Retired = true
	t.Generation++
	a.persistLocked()
	a.mu.Unlock()
	return archived, nil
}

func (a *arbiter) persistThreadState(thread, turn, status string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.persistThreadStateLocked(thread, turn, status)
}

func (a *arbiter) persistThreadStateLocked(thread, turn, status string) {
	if a.stateDir == "" {
		return
	}
	path := filepath.Join(a.stateDir, "chief-of-staff-thread.json")
	var saved map[string]any
	b, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(b, &saved) != nil || fmt.Sprint(saved["thread_id"]) != thread {
		return
	}
	saved["turn_id"], saved["turn_status"], saved["attachable"] = turn, status, true
	_ = atomicJSON(path, saved)
}

// establishThread records the first owned thread from the gateway-observed
// App Server result. The controller never writes the human control record, so
// a late scheduler response cannot replace newer native turn state.
func (a *arbiter) establishThread(raw json.RawMessage) (string, error) {
	var result map[string]any
	if json.Unmarshal(raw, &result) != nil {
		return "", errors.New("thread/start returned no verifiable result")
	}
	threadResult, ok := result["thread"].(map[string]any)
	if !ok || fmt.Sprint(threadResult["id"]) == "" {
		return "", errors.New("thread/start returned no thread id")
	}
	thread := fmt.Sprint(threadResult["id"])
	delete(result, "thread")

	a.mu.Lock()
	defer a.mu.Unlock()
	path := filepath.Join(a.stateDir, "chief-of-staff-thread.json")
	if b, err := os.ReadFile(path); err == nil {
		var saved map[string]any
		if json.Unmarshal(b, &saved) != nil || fmt.Sprint(saved["thread_id"]) != thread {
			return "", errors.New("thread/start refused: another owned thread is already persisted")
		}
		return thread, nil
	} else if !os.IsNotExist(err) {
		return "", err
	}
	if a.stateDir != "" {
		if err := atomicJSON(path, map[string]any{
			"thread_id": thread, "resolved": result, "attachable": false,
			"updated_at": time.Now().UTC().Format(time.RFC3339),
		}); err != nil {
			return "", err
		}
	}
	t := a.threads[thread]
	if t == nil {
		t = &threadAuthority{Terminal: map[string]string{}}
		a.threads[thread] = t
	}
	// The policy persisted above is the effective policy returned for this new
	// thread, so it establishes the first verified policy group.
	t.PolicyInFlight = 0
	t.PolicyTainted = false
	t.PolicyVerified = true
	return thread, nil
}

func (a *arbiter) beginPolicyVerification(thread string) *policyVerification {
	a.mu.Lock()
	defer a.mu.Unlock()
	t := a.threads[thread]
	if t == nil {
		t = &threadAuthority{Terminal: map[string]string{}}
		a.threads[thread] = t
	}
	// A new group begins only after every operation in the previous group has
	// settled. Overlapping resumes share one outcome: any failure or uncertainty
	// fences the entire group until a later, non-overlapping reconciliation.
	if t.PolicyInFlight == 0 {
		t.PolicyTainted = false
	}
	t.PolicyInFlight++
	t.PolicyVerified = false
	return &policyVerification{thread: thread}
}

func (a *arbiter) finishPolicyVerification(check *policyVerification, verified bool) {
	if check == nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if check.settled {
		return
	}
	check.settled = true
	t := a.threads[check.thread]
	if t == nil || t.PolicyInFlight == 0 {
		return
	}
	if !verified {
		t.PolicyTainted = true
	}
	t.PolicyInFlight--
	if t.PolicyInFlight == 0 {
		t.PolicyVerified = verified && !t.PolicyTainted
	}
}

func (a *arbiter) policyVerified(thread string) bool {
	if a.stateDir == "" {
		return true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	t := a.threads[thread]
	return t != nil && t.PolicyVerified
}

func (a *arbiter) reconcileResult(raw json.RawMessage) {
	var identity struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	if json.Unmarshal(raw, &identity) != nil || identity.Thread.ID == "" {
		return
	}
	a.mu.Lock()
	t := a.threads[identity.Thread.ID]
	if t == nil {
		t = &threadAuthority{Terminal: map[string]string{}}
		a.threads[identity.Thread.ID] = t
	}
	generation := t.Generation
	a.mu.Unlock()
	a.reconcileSnapshot(identity.Thread.ID, generation, raw)
}

func (a *arbiter) reconcileSnapshot(thread string, generation uint64, raw json.RawMessage) {
	var out struct {
		Thread struct {
			ID     string `json:"id"`
			Status struct {
				Type string `json:"type"`
			} `json:"status"`
			Turns []json.RawMessage `json:"turns"`
		} `json:"thread"`
	}
	if json.Unmarshal(raw, &out) != nil || out.Thread.ID == "" || out.Thread.ID != thread {
		return
	}
	active := ""
	terminal := map[string]string{}
	for i := len(out.Thread.Turns) - 1; i >= 0; i-- {
		var t struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		}
		if json.Unmarshal(out.Thread.Turns[i], &t) == nil {
			if isTerminal(t.Status) {
				terminal[t.ID] = t.Status
			}
			if active == "" && t.Status == "inProgress" {
				active = t.ID
			}
		}
	}
	a.mu.Lock()
	t := a.threads[thread]
	if t == nil || t.Retired || t.Generation != generation || strings.HasPrefix(t.Active, "pending:") {
		a.mu.Unlock()
		return
	}
	changed := false
	previous := t.Active
	for id, status := range terminal {
		if _, known := t.Terminal[id]; !known {
			t.Terminal[id] = status
			changed = true
		}
	}
	// A history-bearing or explicitly idle snapshot is authoritative only if
	// no lifecycle mutation happened after its request began.
	if out.Thread.Turns != nil || out.Thread.Status.Type == "idle" {
		if t.Active != active {
			t.Active = active
			changed = true
		}
	}
	if changed {
		t.Generation++
		a.persistLocked()
		if active != "" {
			a.persistThreadStateLocked(thread, active, "inProgress")
		} else if status, completed := terminal[previous]; completed && previous != "" {
			a.persistThreadStateLocked(thread, previous, status)
		}
	}
	a.mu.Unlock()
}

type startReply struct {
	method      string
	thread      string
	pending     string
	generation  uint64
	native      bool
	reserved    bool
	policyCheck *policyVerification
	done        chan struct{}
}

func (a *arbiter) generation(thread string) uint64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	t := a.threads[thread]
	if t == nil {
		t = &threadAuthority{Terminal: map[string]string{}}
		a.threads[thread] = t
	}
	return t.Generation
}

func (a *arbiter) isRetired(thread string) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.threads[thread] != nil && a.threads[thread].Retired
}

func (a *arbiter) completeStart(thread, pending string, raw json.RawMessage) {
	var out struct {
		Turn struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		} `json:"turn"`
	}
	if json.Unmarshal(raw, &out) != nil || out.Turn.ID == "" {
		return
	}
	a.mu.Lock()
	t := a.threads[thread]
	if t == nil || t.Retired {
		a.mu.Unlock()
		return
	}
	status := out.Turn.Status
	if status == "" {
		status = "inProgress"
	}
	terminalStatus, alreadyTerminal := t.Terminal[out.Turn.ID]
	if isTerminal(status) && !alreadyTerminal {
		t.Terminal[out.Turn.ID] = status
		terminalStatus, alreadyTerminal = status, true
	}
	if alreadyTerminal {
		// A terminal outcome learned before this reply is monotonic. The late
		// reply can identify the completed reservation but cannot resurrect it.
		if t.Active == pending || t.Active == out.Turn.ID {
			t.Active = ""
			t.Generation++
			a.persistLocked()
			a.persistThreadStateLocked(thread, out.Turn.ID, terminalStatus)
		}
		a.mu.Unlock()
		return
	}
	if t.Active == pending || t.Active == out.Turn.ID {
		if t.Active != out.Turn.ID {
			t.Active = out.Turn.ID
			t.Generation++
			a.persistLocked()
		}
		a.persistThreadStateLocked(thread, out.Turn.ID, status)
	}
	a.mu.Unlock()
}

func websocketDialer(upstream string) (*websocket.Conn, error) {
	u, err := url.Parse(upstream)
	if err != nil {
		return nil, err
	}
	d := *websocket.DefaultDialer
	if u.Scheme == "unix" {
		path := u.Path
		u.Scheme, u.Host, u.Path = "ws", "localhost", "/"
		d.NetDialContext = func(_ context.Context, _, _ string) (net.Conn, error) { return net.Dial("unix", path) }
	}
	c, _, err := d.Dial(u.String(), nil)
	return c, err
}

func (a *arbiter) proxy(upstream string, down *websocket.Conn) {
	up, err := websocketDialer(upstream)
	if err != nil {
		_ = down.WriteJSON(map[string]any{"error": map[string]any{"code": -32051, "message": err.Error()}})
		return
	}
	defer up.Close()
	var writeDown sync.Mutex
	var pendingMu sync.Mutex
	pending := map[string]startReply{}
	closed := make(chan struct{})
	go func() {
		defer func() {
			pendingMu.Lock()
			unresolved := make([]startReply, 0, len(pending))
			for id, p := range pending {
				unresolved = append(unresolved, p)
				delete(pending, id)
			}
			pendingMu.Unlock()
			for _, p := range unresolved {
				if p.policyCheck != nil {
					a.finishPolicyVerification(p.policyCheck, false)
				}
				if p.method == "turn/start" && p.reserved {
					a.failStart(p.thread, p.pending)
				}
				if p.done != nil {
					close(p.done)
				}
			}
			close(closed)
			_ = down.Close()
		}()
		for {
			_, raw, err := up.ReadMessage()
			if err != nil {
				return
			}
			var m message
			_ = json.Unmarshal(raw, &m)
			if m.Method == "turn/started" || m.Method == "turn/completed" {
				a.observe(m)
			}
			if len(m.ID) > 0 {
				pendingMu.Lock()
				p, ok := pending[string(m.ID)]
				if ok {
					delete(pending, string(m.ID))
				}
				pendingMu.Unlock()
				if ok {
					success := len(m.Error) == 0 || string(m.Error) == "null"
					policyAccepted := true
					if success {
						if p.method == "thread/resume" && p.policyCheck != nil {
							if mismatch := effectivePolicyMismatch(a.stateDir, p.thread, m.Result); mismatch != "" {
								m.Result = nil
								m.Error, _ = json.Marshal(map[string]any{"code": -32052, "message": mismatch})
								policyAccepted = false
							}
						}
						if p.method == "thread/start" {
							if _, establishErr := a.establishThread(m.Result); establishErr != nil {
								m.Result = nil
								m.Error, _ = json.Marshal(map[string]any{"code": -32052, "message": establishErr.Error()})
								success = false
							}
						}
						switch p.method {
						case "turn/start":
							a.completeStart(p.thread, p.pending, m.Result)
						case "thread/read", "thread/resume":
							if policyAccepted {
								a.reconcileSnapshot(p.thread, p.generation, m.Result)
							}
						}
					}
					if p.method == "thread/resume" && p.policyCheck != nil {
						a.finishPolicyVerification(p.policyCheck, success && policyAccepted)
					}
					if !success && p.method == "turn/start" && p.reserved {
						a.failStart(p.thread, p.pending)
					}
					if p.done != nil {
						close(p.done)
					}
					raw, _ = json.Marshal(m)
				}
			}
			writeDown.Lock()
			_ = down.WriteMessage(websocket.TextMessage, raw)
			writeDown.Unlock()
		}
	}()

	scheduler := false
	for {
		_, raw, err := down.ReadMessage()
		if err != nil {
			return
		}
		var m message
		if json.Unmarshal(raw, &m) != nil {
			continue
		}
		if m.Method == "initialize" {
			var p struct {
				ClientInfo struct {
					Name string `json:"name"`
				} `json:"clientInfo"`
			}
			_ = json.Unmarshal(m.Params, &p)
			scheduler = p.ClientInfo.Name == "squad_conductor"
		}
		if m.Method == "squad/thread/rollover" {
			var p struct {
				ThreadID string `json:"threadId"`
			}
			_ = json.Unmarshal(m.Params, &p)
			archived, rollErr := a.rollover(p.ThreadID)
			writeDown.Lock()
			if rollErr != nil {
				_ = down.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(m.ID), "error": map[string]any{"code": -32053, "message": rollErr.Error()}})
			} else {
				_ = down.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(m.ID), "result": map[string]any{"archived": archived}})
			}
			writeDown.Unlock()
			continue
		}
		var identity struct {
			ThreadID string `json:"threadId"`
		}
		_ = json.Unmarshal(m.Params, &identity)
		threadID := identity.ThreadID
		if a.isRetired(threadID) && (m.Method == "thread/resume" || m.Method == "thread/settings/update" || m.Method == "turn/start") {
			writeProxyError(&writeDown, down, m.ID, fmt.Sprintf("thread %s is retired; mutation refused", threadID))
			continue
		}
		verifyResumePolicy := false
		if m.Method == "thread/resume" {
			_, persistedErr := loadPersistedPolicy(a.stateDir)
			verifyResumePolicy = !scheduler || persistedErr == nil
		}
		if verifyResumePolicy {
			var p map[string]any
			if json.Unmarshal(m.Params, &p) == nil {
				mismatch := policyMismatch(a.stateDir, p)
				if mismatch != "" {
					writeProxyError(&writeDown, down, m.ID, mismatch)
					continue
				}
				if mismatch = applyPersistedPolicy(a.stateDir, threadID, p); mismatch != "" {
					writeProxyError(&writeDown, down, m.ID, mismatch)
					continue
				}
				m.Params, _ = json.Marshal(p)
				raw, _ = json.Marshal(m)
			}
		}
		if (m.Method == "thread/settings/update" || m.Method == "turn/start") && !scheduler {
			var p map[string]any
			_ = json.Unmarshal(m.Params, &p)
			mismatch := policyMismatch(a.stateDir, p)
			if mismatch != "" {
				writeProxyError(&writeDown, down, m.ID, mismatch)
				continue
			}
		}
		governedMutation := m.Method == "thread/settings/update" || m.Method == "turn/start"
		var t *threadAuthority
		if m.Method == "turn/start" {
			// Starts for one thread remain serial through their response, but that
			// wait must happen before the global policy ordering gate is acquired.
			t = a.thread(threadID)
			t.mu.Lock()
		}
		if governedMutation || verifyResumePolicy {
			if !a.acquirePolicyForward() {
				if t != nil {
					t.mu.Unlock()
				}
				writeProxyError(&writeDown, down, m.ID, "owned-thread mutation refused: policy ordering guard timed out")
				continue
			}
		}
		if governedMutation {
			requirePolicy := !scheduler
			if scheduler {
				_, policyErr := loadPersistedPolicy(a.stateDir)
				requirePolicy = policyErr == nil
			}
			if requirePolicy && (threadID == "" || !a.policyVerified(threadID)) {
				a.releasePolicyForward()
				if t != nil {
					t.mu.Unlock()
				}
				writeProxyError(&writeDown, down, m.ID, "owned-thread mutation refused: the current policy verification group has not completed successfully")
				continue
			}
		}
		request := startReply{method: m.Method, thread: threadID, native: !scheduler}
		if m.Method == "thread/read" || m.Method == "thread/resume" {
			request.generation = a.generation(threadID)
		}
		if verifyResumePolicy {
			request.policyCheck = a.beginPolicyVerification(threadID)
		}
		if m.Method == "turn/start" {
			active := a.activeTurn(threadID)
			if active != "" && scheduler {
				a.releasePolicyForward()
				t.mu.Unlock()
				writeProxyError(&writeDown, down, m.ID, fmt.Sprintf("thread %s already has active turn %s; scheduler start refused", threadID, active))
				continue
			}
			if active == "" {
				request.pending, err = a.reserveStart(threadID)
				if err != nil {
					a.releasePolicyForward()
					t.mu.Unlock()
					writeProxyError(&writeDown, down, m.ID, err.Error())
					continue
				}
				request.reserved = true
			} else {
				// Native input during a current turn is App Server's implicit
				// steer and must retain the existing lifecycle identity.
				request.pending = active
			}
			request.done = make(chan struct{})
		}
		if len(m.ID) > 0 {
			pendingMu.Lock()
			pending[string(m.ID)] = request
			pendingMu.Unlock()
		}
		guardedForward := governedMutation || verifyResumePolicy
		if guardedForward {
			_ = up.SetWriteDeadline(time.Now().Add(5 * time.Second))
		}
		if err := up.WriteMessage(websocket.TextMessage, raw); err != nil {
			if len(m.ID) > 0 {
				pendingMu.Lock()
				delete(pending, string(m.ID))
				pendingMu.Unlock()
			}
			if request.policyCheck != nil {
				a.finishPolicyVerification(request.policyCheck, false)
			}
			if m.Method == "turn/start" {
				if request.reserved {
					a.failStart(threadID, request.pending)
				}
				t.mu.Unlock()
			}
			if guardedForward {
				a.releasePolicyForward()
			}
			return
		}
		if guardedForward {
			_ = up.SetWriteDeadline(time.Time{})
			a.releasePolicyForward()
		}
		if m.Method == "turn/start" {
			select {
			case <-request.done:
			case <-closed:
			}
			t.mu.Unlock()
		}
	}
}

func writeProxyError(mu *sync.Mutex, down *websocket.Conn, id json.RawMessage, message string) {
	mu.Lock()
	_ = down.WriteJSON(map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(id), "error": map[string]any{"code": -32052, "message": message}})
	mu.Unlock()
}

func serveGateway(listen, upstream, stateDir string) error {
	a := newArbiter(stateDir)
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	h := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer c.Close()
		a.proxy(upstream, c)
	})
	if strings.HasPrefix(listen, "unix://") {
		path := strings.TrimPrefix(listen, "unix://")
		if info, statErr := os.Lstat(path); statErr == nil {
			if info.Mode()&os.ModeSocket == 0 {
				return fmt.Errorf("gateway path exists and is not a socket: %s", path)
			}
			if existing, dialErr := net.DialTimeout("unix", path, 250*time.Millisecond); dialErr == nil {
				existing.Close()
				return fmt.Errorf("gateway socket is already active: %s", path)
			}
			if err := os.Remove(path); err != nil {
				return err
			}
		} else if !os.IsNotExist(statErr) {
			return statErr
		}
		ln, err := net.Listen("unix", path)
		if err != nil {
			return err
		}
		if err := os.Chmod(path, 0o600); err != nil {
			ln.Close()
			return err
		}
		defer os.Remove(path)
		return http.Serve(ln, h)
	}
	addr := strings.TrimPrefix(listen, "ws://")
	if strings.Contains(addr, "/") {
		addr = strings.SplitN(addr, "/", 2)[0]
	}
	return http.ListenAndServe(addr, h)
}

type persistedPolicy struct {
	ThreadID string         `json:"thread_id"`
	Resolved map[string]any `json:"resolved"`
}

func loadPersistedPolicy(stateDir string) (persistedPolicy, error) {
	var saved persistedPolicy
	if stateDir == "" {
		return saved, fmt.Errorf("native resume refused: persisted policy state is unavailable")
	}
	b, err := os.ReadFile(filepath.Join(stateDir, "chief-of-staff-thread.json"))
	if err != nil || json.Unmarshal(b, &saved) != nil || saved.Resolved == nil {
		return saved, fmt.Errorf("native resume refused: persisted policy state is unavailable")
	}
	return saved, nil
}

func applyPersistedPolicy(stateDir, thread string, requested map[string]any) string {
	saved, err := loadPersistedPolicy(stateDir)
	if err != nil {
		return err.Error()
	}
	if saved.ThreadID == "" || thread != saved.ThreadID {
		return fmt.Sprintf("native resume refused: thread %s is not the persisted owned thread", thread)
	}
	for key, savedKey := range map[string]string{
		"model": "model", "cwd": "cwd", "approvalPolicy": "approvalPolicy",
		"approvalsReviewer": "approvalsReviewer", "runtimeWorkspaceRoots": "runtimeWorkspaceRoots",
	} {
		if value, present := requested[key]; (!present || value == nil) && saved.Resolved[savedKey] != nil {
			requested[key] = saved.Resolved[savedKey]
		}
	}
	if value, present := requested["sandbox"]; !present || value == nil {
		var sandboxValue any
		if sandbox, ok := saved.Resolved["sandbox"].(map[string]any); ok {
			sandboxValue = sandbox["type"]
		} else if saved.Resolved["sandbox"] != nil {
			sandboxValue = saved.Resolved["sandbox"]
		}
		switch normalEnum(sandboxValue) {
		case "readonly":
			sandboxValue = "read-only"
		case "workspacewrite":
			sandboxValue = "workspace-write"
		case "dangerfullaccess":
			sandboxValue = "danger-full-access"
		}
		if sandboxValue != nil {
			requested["sandbox"] = sandboxValue
		}
	}
	config, _ := requested["config"].(map[string]any)
	if config == nil {
		config = map[string]any{}
	}
	if _, present := config["model_reasoning_effort"]; !present && saved.Resolved["reasoningEffort"] != nil {
		config["model_reasoning_effort"] = saved.Resolved["reasoningEffort"]
	}
	requested["config"] = config
	return ""
}

func normalEnum(v any) string {
	s := strings.ToLower(strings.ReplaceAll(fmt.Sprint(v), "-", ""))
	return strings.ReplaceAll(s, "_", "")
}

func policyMismatch(stateDir string, requested map[string]any) string {
	hasOverride := false
	for _, key := range []string{"model", "effort", "reasoningEffort", "approvalPolicy", "approvalsReviewer", "cwd", "runtimeWorkspaceRoots", "sandbox", "sandboxPolicy", "permissions", "activePermissionProfile", "config"} {
		if v, ok := requested[key]; ok && v != nil {
			hasOverride = true
			break
		}
	}
	if !hasOverride {
		return ""
	}
	if stateDir == "" {
		return "native resume refused: persisted policy state is unavailable"
	}
	saved, err := loadPersistedPolicy(stateDir)
	if err != nil {
		return err.Error()
	}
	if v, present := requested["config"]; present && v != nil {
		config, ok := v.(map[string]any)
		if !ok {
			return "native mutation refused: config override is malformed; use conductor-session.sh attach"
		}
		for key, got := range config {
			var want any
			switch key {
			case "model_reasoning_effort":
				want = saved.Resolved["reasoningEffort"]
			case "model":
				want = saved.Resolved["model"]
			case "cwd":
				want = saved.Resolved["cwd"]
			case "approval_policy":
				want = saved.Resolved["approvalPolicy"]
			case "sandbox_mode":
				if policy, ok := saved.Resolved["sandbox"].(map[string]any); ok {
					want = policy["type"]
				}
			default:
				continue
			}
			equal := normalEnum(got) == normalEnum(want)
			if key == "cwd" || key == "model" {
				equal = fmt.Sprint(got) == fmt.Sprint(want)
			}
			if !equal {
				return fmt.Sprintf("native mutation refused: config.%s=%v is outside the persisted policy; use conductor-session.sh attach", key, got)
			}
		}
	}
	for _, key := range []string{"permissions", "activePermissionProfile"} {
		if v, present := requested[key]; present && v != nil {
			return fmt.Sprintf("native mutation refused: %s overrides are not allowed; use conductor-session.sh attach", key)
		}
	}
	if roots, present := requested["runtimeWorkspaceRoots"]; present && roots != nil && !reflect.DeepEqual(roots, saved.Resolved["runtimeWorkspaceRoots"]) {
		return "native mutation refused: runtimeWorkspaceRoots differ from persisted policy; start the attach wrapper from the recorded project"
	}
	if v, present := requested["sandboxPolicy"]; present && v != nil {
		requestedPolicy, requestedOK := v.(map[string]any)
		savedPolicy, savedOK := saved.Resolved["sandbox"].(map[string]any)
		mismatch := !requestedOK || !savedOK || normalEnum(requestedPolicy["type"]) != normalEnum(savedPolicy["type"])
		if !mismatch && len(savedPolicy) > 1 {
			mismatch = !reflect.DeepEqual(requestedPolicy, savedPolicy)
		}
		if mismatch {
			return "native mutation refused: sandboxPolicy differs from persisted policy; use conductor-session.sh attach"
		}
	}
	governed := map[string]any{"model": saved.Resolved["model"], "cwd": saved.Resolved["cwd"]}
	enums := map[string]any{"effort": saved.Resolved["reasoningEffort"], "reasoningEffort": saved.Resolved["reasoningEffort"], "approvalPolicy": saved.Resolved["approvalPolicy"], "approvalsReviewer": saved.Resolved["approvalsReviewer"]}
	if sandbox, ok := saved.Resolved["sandbox"].(map[string]any); ok {
		enums["sandbox"] = sandbox["type"]
	}
	for key, want := range governed {
		if got, present := requested[key]; present && got != nil && fmt.Sprint(got) != fmt.Sprint(want) {
			return fmt.Sprintf("native resume refused: %s=%v differs from persisted %v; use conductor-session.sh attach", key, got, want)
		}
	}
	for key, want := range enums {
		if got, present := requested[key]; present && got != nil && normalEnum(got) != normalEnum(want) {
			return fmt.Sprintf("native resume refused: %s=%v differs from persisted %v; use conductor-session.sh attach", key, got, want)
		}
	}
	return ""
}

func effectivePolicyMismatch(stateDir, thread string, raw json.RawMessage) string {
	saved, err := loadPersistedPolicy(stateDir)
	if err != nil {
		return err.Error()
	}
	if thread != saved.ThreadID {
		return fmt.Sprintf("native resume refused: thread %s is not the persisted owned thread", thread)
	}
	var got map[string]any
	if json.Unmarshal(raw, &got) != nil {
		return "native resume refused: App Server returned no verifiable effective policy"
	}
	threadResult, ok := got["thread"].(map[string]any)
	if !ok || fmt.Sprint(threadResult["id"]) != thread {
		return "native resume refused: App Server response did not name the persisted owned thread"
	}
	for key, savedKey := range map[string]string{
		"model": "model", "reasoningEffort": "reasoningEffort", "cwd": "cwd",
		"approvalPolicy": "approvalPolicy", "approvalsReviewer": "approvalsReviewer",
	} {
		want := saved.Resolved[savedKey]
		if want == nil {
			continue
		}
		value, present := got[key]
		equal := present && normalEnum(value) == normalEnum(want)
		if key == "cwd" || key == "model" {
			equal = present && fmt.Sprint(value) == fmt.Sprint(want)
		}
		if !equal {
			return fmt.Sprintf("native resume refused: App Server effective %s=%v differs from persisted %v", key, value, want)
		}
	}
	if !reflect.DeepEqual(got["runtimeWorkspaceRoots"], saved.Resolved["runtimeWorkspaceRoots"]) {
		return "native resume refused: App Server effective runtimeWorkspaceRoots differ from persisted policy"
	}
	wantSandbox := saved.Resolved["sandbox"]
	if savedMap, ok := wantSandbox.(map[string]any); ok {
		gotMap, ok := got["sandbox"].(map[string]any)
		if !ok || normalEnum(gotMap["type"]) != normalEnum(savedMap["type"]) || (len(savedMap) > 1 && !reflect.DeepEqual(gotMap, savedMap)) {
			return "native resume refused: App Server effective sandbox differs from persisted policy"
		}
	} else if normalEnum(got["sandbox"]) != normalEnum(wantSandbox) {
		return "native resume refused: App Server effective sandbox differs from persisted policy"
	}
	return ""
}
