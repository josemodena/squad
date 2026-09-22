package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

const clientVersion = "0.1.0"

var errAmbiguousStart = errors.New("turn start outcome is ambiguous")
var errStaleLaunch = errors.New("controller no longer owns the current launch")

type message struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  json.RawMessage `json:"error,omitempty"`
}

type rpcClient struct {
	c      *websocket.Conn
	nextID int
}

func dial(rawURL string) (*rpcClient, error) {
	c, err := websocketDialer(rawURL)
	if err != nil {
		return nil, err
	}
	r := &rpcClient{c: c, nextID: 1}
	if _, err := r.call("initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "squad_conductor", "title": "Squad conductor", "version": clientVersion},
		"capabilities": map[string]any{"experimentalApi": true},
	}, nil); err != nil {
		c.Close()
		return nil, err
	}
	if err := c.WriteJSON(map[string]any{"jsonrpc": "2.0", "method": "initialized"}); err != nil {
		c.Close()
		return nil, err
	}
	return r, nil
}

func (r *rpcClient) call(method string, params any, onEvent func(message)) (json.RawMessage, error) {
	id := r.nextID
	r.nextID++
	req := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		req["params"] = params
	}
	if err := r.c.WriteJSON(req); err != nil {
		return nil, err
	}
	for {
		var m message
		if err := r.c.ReadJSON(&m); err != nil {
			return nil, err
		}
		if m.Method != "" {
			if onEvent != nil {
				onEvent(m)
			}
			continue
		}
		var got int
		if err := json.Unmarshal(m.ID, &got); err != nil || got != id {
			continue
		}
		if len(m.Error) != 0 && string(m.Error) != "null" {
			return nil, fmt.Errorf("%s: %s", method, m.Error)
		}
		return m.Result, nil
	}
}

func atomicJSON(path string, v any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	tmp := fmt.Sprintf("%s.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func appendEvent(path string, m message) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	_ = json.NewEncoder(f).Encode(map[string]any{"at": time.Now().UTC().Format(time.RFC3339Nano), "method": m.Method, "params": json.RawMessage(m.Params)})
}

type currentState struct {
	ID         string   `json:"id"`
	Events     []string `json:"events"`
	Phase      string   `json:"phase"`
	ThreadID   string   `json:"thread_id,omitempty"`
	TurnID     string   `json:"turn_id,omitempty"`
	Resolved   any      `json:"resolved,omitempty"`
	Attachable bool     `json:"attachable"`
}

type turnEnvelope struct {
	ThreadID string `json:"threadId"`
	Turn     struct {
		ID     string          `json:"id"`
		Status string          `json:"status"`
		Error  json.RawMessage `json:"error"`
	} `json:"turn"`
}

func readCurrent(path, launch string) (currentState, error) {
	var s currentState
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return s, fmt.Errorf("%w: current launch record is absent", errStaleLaunch)
		}
		return s, err
	}
	if err := json.Unmarshal(b, &s); err != nil {
		return s, err
	}
	if s.ID != launch {
		return s, fmt.Errorf("%w: launch %s no longer owns current state", errStaleLaunch, launch)
	}
	return s, nil
}

func saveCurrent(path string, s currentState) error { return atomicJSON(path, s) }

func reconcileTurn(client *rpcClient, threadID, launch string, onEvent func(message)) (string, string, error) {
	res, err := client.call("thread/read", map[string]any{"threadId": threadID, "includeTurns": true}, onEvent)
	if err != nil {
		return "", "", err
	}
	turnID, status := findTurn(res, launch)
	return turnID, status, nil
}

func findTurn(raw json.RawMessage, launch string) (string, string) {
	var out struct {
		Thread struct {
			Turns []json.RawMessage `json:"turns"`
		} `json:"thread"`
	}
	if json.Unmarshal(raw, &out) != nil {
		return "", ""
	}
	for _, raw := range out.Thread.Turns {
		if !strings.Contains(string(raw), launch) {
			continue
		}
		var turn struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		}
		if json.Unmarshal(raw, &turn) == nil && turn.ID != "" {
			return turn.ID, turn.Status
		}
	}
	return "", ""
}

func findTurnByID(raw json.RawMessage, expected string) (string, string) {
	var out struct {
		Thread struct {
			Turns []json.RawMessage `json:"turns"`
		} `json:"thread"`
	}
	if json.Unmarshal(raw, &out) != nil {
		return "", ""
	}
	for _, raw := range out.Thread.Turns {
		var turn struct {
			ID     string `json:"id"`
			Status string `json:"status"`
		}
		if json.Unmarshal(raw, &turn) == nil && turn.ID == expected {
			return turn.ID, turn.Status
		}
	}
	return "", ""
}

func reconcileTurnID(client *rpcClient, threadID, turnID string, onEvent func(message)) (string, error) {
	res, err := client.call("thread/read", map[string]any{"threadId": threadID, "includeTurns": true}, onEvent)
	if err != nil {
		return "", err
	}
	_, status := findTurnByID(res, turnID)
	return status, nil
}

func runTurn(rawURL, stateDir, launch, brief, cwd string) error {
	return runTurnWithModel(rawURL, stateDir, launch, brief, cwd, "")
}

func runTurnWithModel(rawURL, stateDir, launch, brief, cwd, model string) error {
	currentPath := filepath.Join(stateDir, "current.json")
	s, err := readCurrent(currentPath, launch)
	if err != nil {
		return err
	}
	resumePhase := s.Phase
	progress := filepath.Join(stateDir, "progress", launch+".jsonl")
	threadPath := filepath.Join(stateDir, "chief-of-staff-thread.json")
	var persisted struct {
		ThreadID string `json:"thread_id"`
	}
	if b, readErr := os.ReadFile(threadPath); readErr == nil {
		_ = json.Unmarshal(b, &persisted)
	}

	var client *rpcClient
	for attempt := 0; attempt < 6; attempt++ {
		client, err = dial(rawURL)
		if err == nil {
			break
		}
		time.Sleep(time.Duration(attempt+1) * 200 * time.Millisecond)
	}
	if err != nil {
		return fmt.Errorf("connect to app server: %w", err)
	}
	defer func() {
		if client != nil {
			_ = client.c.Close()
		}
	}()

	threadID := persisted.ThreadID
	if s.ThreadID != "" {
		threadID = s.ThreadID
	}
	var resolved map[string]any
	if threadID == "" {
		params := map[string]any{"cwd": cwd}
		if model != "" {
			params["model"] = model
		}
		res, callErr := client.call("thread/start", params, func(m message) { appendEvent(progress, m) })
		if callErr != nil {
			return callErr
		}
		var out struct {
			Thread struct {
				ID string `json:"id"`
			} `json:"thread"`
		}
		if err := json.Unmarshal(res, &out); err != nil || out.Thread.ID == "" {
			return errors.New("thread/start returned no thread id")
		}
		threadID = out.Thread.ID
		_ = json.Unmarshal(res, &resolved)
		delete(resolved, "thread")
	} else {
		resumeParams := map[string]any{"threadId": threadID, "excludeTurns": true}
		if resumePhase == "submitting-turn" {
			delete(resumeParams, "excludeTurns")
		}
		res, err := client.call("thread/resume", resumeParams, func(m message) { appendEvent(progress, m) })
		if err != nil {
			return err
		}
		if resumePhase == "submitting-turn" {
			turnID, status := findTurn(res, launch)
			if turnID == "" {
				return fmt.Errorf("%w for launch %s", errAmbiguousStart, launch)
			}
			s.TurnID = turnID
			if status != "inProgress" {
				p := turnEnvelope{ThreadID: threadID}
				p.Turn.ID = turnID
				p.Turn.Status = status
				return writeCompletionAck(stateDir, launch, p)
			}
		}
		_ = json.Unmarshal(res, &resolved)
		delete(resolved, "thread")
		if s.TurnID != "" {
			status, readErr := reconcileTurnID(client, threadID, s.TurnID, func(m message) { appendEvent(progress, m) })
			if readErr == nil && status != "" && status != "inProgress" {
				p := turnEnvelope{ThreadID: threadID}
				p.Turn.ID = s.TurnID
				p.Turn.Status = status
				return writeCompletionAck(stateDir, launch, p)
			}
		}
	}
	if model != "" && resolved["model"] != model {
		return fmt.Errorf("Administrator model mismatch: wanted %s, got %v; roll over the idle legacy thread before recovery", model, resolved["model"])
	}
	s.ThreadID, s.Resolved = threadID, resolved
	if resumePhase == "submitting-turn" {
		s.Phase = resumePhase
	} else {
		s.Phase = "starting-turn"
	}
	if err := saveCurrent(currentPath, s); err != nil {
		return err
	}
	if s.TurnID == "" {
		s.Phase = "submitting-turn"
		if err := saveCurrent(currentPath, s); err != nil {
			return err
		}
		var earlyCompletions []turnEnvelope
		res, err := client.call("turn/start", map[string]any{"threadId": threadID, "input": []map[string]string{{"type": "text", "text": brief}}, "cwd": cwd, "clientUserMessageId": launch}, func(m message) {
			appendEvent(progress, m)
			if m.Method == "turn/completed" {
				var done turnEnvelope
				if json.Unmarshal(m.Params, &done) == nil && done.ThreadID == threadID {
					earlyCompletions = append(earlyCompletions, done)
				}
			}
		})
		if err != nil {
			return fmt.Errorf("%w for launch %s: %v", errAmbiguousStart, launch, err)
		}
		var started struct {
			Turn struct {
				ID string `json:"id"`
			} `json:"turn"`
		}
		if err := json.Unmarshal(res, &started); err != nil || started.Turn.ID == "" {
			return errors.New("turn/start returned no turn id")
		}
		s.TurnID = started.Turn.ID
		for _, done := range earlyCompletions {
			if done.Turn.ID == s.TurnID {
				s.Phase = "turn-completed"
				s.Attachable = true
				if err := saveCurrent(currentPath, s); err != nil {
					return err
				}
				return writeCompletionAck(stateDir, launch, done)
			}
		}
	}
	s.Phase = "turn-active"
	s.Attachable = true
	if err := saveCurrent(currentPath, s); err != nil {
		return err
	}
	for reconnects := 0; reconnects < 6; {
		var m message
		if err := client.c.ReadJSON(&m); err != nil {
			client.c.Close()
			client = nil
			for client == nil && reconnects < 6 {
				reconnects++
				time.Sleep(time.Duration(reconnects) * 250 * time.Millisecond)
				client, err = dial(rawURL)
				if err != nil {
					client = nil
					continue
				}
				var observed *turnEnvelope
				onEvent := func(ev message) {
					appendEvent(progress, ev)
					if ev.Method == "turn/completed" {
						var p turnEnvelope
						if json.Unmarshal(ev.Params, &p) == nil && p.ThreadID == threadID && p.Turn.ID == s.TurnID {
							observed = &p
						}
					}
				}
				if _, err = client.call("thread/resume", map[string]any{"threadId": threadID, "excludeTurns": true}, onEvent); err != nil {
					client.c.Close()
					client = nil
					continue
				}
				if observed != nil {
					return writeCompletionAck(stateDir, launch, *observed)
				}
				status, readErr := reconcileTurnID(client, threadID, s.TurnID, onEvent)
				if readErr != nil {
					client.c.Close()
					client = nil
					continue
				}
				if status != "" && status != "inProgress" {
					p := turnEnvelope{ThreadID: threadID}
					p.Turn.ID = s.TurnID
					p.Turn.Status = status
					return writeCompletionAck(stateDir, launch, p)
				}
			}
			continue
		}
		appendEvent(progress, m)
		if m.Method != "turn/completed" {
			continue
		}
		var done turnEnvelope
		if json.Unmarshal(m.Params, &done) != nil || done.ThreadID != threadID || done.Turn.ID != s.TurnID {
			continue
		}
		return writeCompletionAck(stateDir, launch, done)
	}
	return errors.New("app server stream could not be reconnected")
}

func writeCompletionAck(stateDir, launch string, done turnEnvelope) error {
	status := 1
	if done.Turn.Status == "completed" {
		status = 0
	} else if done.Turn.Status == "interrupted" {
		status = 130
	}
	return atomicJSON(filepath.Join(stateDir, "acks", launch+".json"), map[string]any{"id": launch, "status": status, "thread_id": done.ThreadID, "turn_id": done.Turn.ID, "turn_status": done.Turn.Status, "finished_at": time.Now().UTC().Format(time.RFC3339Nano)})
}

func control(rawURL, method, threadID, turnID, text string) error {
	c, err := dial(rawURL)
	if err != nil {
		return err
	}
	defer c.c.Close()
	params := map[string]any{"threadId": threadID}
	if turnID != "" {
		params["turnId"] = turnID
	}
	if method == "turn/steer" {
		delete(params, "turnId")
		params["expectedTurnId"] = turnID
		params["input"] = []map[string]string{{"type": "text", "text": text}}
	}
	_, err = c.call(method, params, nil)
	return err
}

func recordRunResult(stateDir, launch string, runErr error) error {
	if runErr == nil || errors.Is(runErr, errStaleLaunch) {
		return nil
	}
	status := 125
	ambiguous := errors.Is(runErr, errAmbiguousStart)
	if ambiguous {
		status = 126
	}
	_ = atomicJSON(filepath.Join(stateDir, "acks", launch+".json"), map[string]any{"id": launch, "status": status, "error": runErr.Error(), "finished_at": time.Now().UTC().Format(time.RFC3339Nano)})
	if ambiguous {
		fmt.Fprintln(os.Stderr, runErr)
		return nil
	}
	return runErr
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: squad-conductor-appserver serve|run|steer|interrupt|rollover [flags]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet(os.Args[1], flag.ExitOnError)
	url := fs.String("url", "unix:///run/user/1000/squad-app-server-gateway.sock", "App Server WebSocket URL")
	state := fs.String("state", "", "conductor state directory")
	launch := fs.String("launch", "", "launch id")
	brief := fs.String("brief", "", "turn input")
	model := fs.String("model", "", "configured Administrator model")
	cwd := fs.String("cwd", "", "project directory")
	threadID := fs.String("thread", "", "thread id")
	turnID := fs.String("turn", "", "turn id")
	input := fs.String("input", "", "steering input")
	listen := fs.String("listen", "unix:///run/user/1000/squad-app-server-gateway.sock", "gateway listen URL")
	upstream := fs.String("upstream", "unix:///run/user/1000/squad-app-server.sock", "private App Server URL")
	_ = fs.Parse(os.Args[2:])
	var err error
	switch os.Args[1] {
	case "serve":
		err = serveGateway(*listen, *upstream, *state)
	case "run":
		if *state == "" || *launch == "" || *brief == "" || *cwd == "" {
			err = errors.New("run requires --state, --launch, --brief and --cwd")
		} else {
			err = recordRunResult(*state, *launch, runTurnWithModel(*url, *state, *launch, *brief, *cwd, *model))
		}
	case "steer":
		err = control(*url, "turn/steer", *threadID, *turnID, *input)
	case "interrupt":
		err = control(*url, "turn/interrupt", *threadID, *turnID, "")
	case "rollover":
		err = control(*url, "squad/thread/rollover", *threadID, "", "")
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
