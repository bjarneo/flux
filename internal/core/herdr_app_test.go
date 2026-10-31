package core

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"slices"
	"testing"

	"flux/internal/hc"
)

func TestHerdrAppLive(t *testing.T) {
	terms := []hc.Terminal{
		{Address: "t4", State: "live", Cwd: "/home/u/Work", Title: "OC | Docs", Labels: map[string]string{"where": "Work / 1"},
			Status: &hc.Status{App: "opencode", State: "working", Title: "Docs"}},
		{Address: "t8", State: "live", Cwd: "/home/u/repos", Title: "flux review", Labels: map[string]string{"where": "repos / 2"},
			Status: &hc.Status{App: "claude-code", State: "error"}, Foreground: &hc.Foreground{Cwd: "/home/u/repos/flux"}},
		{Address: "yoga/t1", State: "live", Cwd: "/home/u", Title: "bash", Labels: map[string]string{"where": "~ / 1"}},
		{Address: "t9", State: "finished", Status: &hc.Status{App: "codex", State: "done"}},
	}
	live := herdrAppLive(terms)
	wantAgents := []HerdrAgent{
		{Pane: "t4", Agent: "opencode", Status: "working", Title: "Docs", Project: "Work", Workspace: "Work"},
		{Pane: "t8", Agent: "claude", Status: "unknown", Title: "flux review", Project: "flux", Workspace: "repos"},
	}
	if !slices.Equal(live.Agents, wantAgents) {
		t.Fatalf("agents %+v", live.Agents)
	}
	wantTerms := []HerdrTerminal{{Pane: "yoga/t1", Title: "bash", Project: "u", Workspace: "yoga: ~"}}
	if !slices.Equal(live.Terminals, wantTerms) {
		t.Fatalf("terminals %+v", live.Terminals)
	}
	if live.Workspaces != nil || live.Kinds != nil {
		t.Fatalf("the herdr app has no workspaces or kinds: %+v", live)
	}
}

func TestHerdrAppIDs(t *testing.T) {
	live := qualifyHerdrLive(herdrAppSession, herdrLive{Terminals: []HerdrTerminal{{Pane: "yoga/t1"}}})
	id := live.Terminals[0].Pane
	if id != "herdr-app/yoga/t1" || !herdrApp(id) || herdrAppAddress(id) != "yoga/t1" {
		t.Fatalf("id %q, app %v, address %q", id, herdrApp(id), herdrAppAddress(id))
	}
	if herdrApp("w5:p1") || herdrApp("omarchy/w5:p1") {
		t.Fatal("a herdr pane counts as the herdr app")
	}
}

// TestReadHerdrAppFallsBackToScreen checks that a history read that
// fails, as on a slow machine, falls back to the screen alone.
func TestReadHerdrAppFallsBackToScreen(t *testing.T) {
	path := filepath.Join(t.TempDir(), "hc.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	asked := make(chan float64, 4)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				line, err := bufio.NewReader(conn).ReadBytes('\n')
				if err != nil {
					return
				}
				var req struct {
					Params struct {
						Lines float64 `json:"lines"`
					} `json:"params"`
				}
				_ = json.Unmarshal(line, &req)
				asked <- req.Params.Lines
				if req.Params.Lines > 0 {
					conn.Write([]byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"instance1 didn't answer within 30 s","data":{"kind":"unavailable"}}}` + "\n"))
					return
				}
				conn.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":{"text":"screen row","complete":true,"how":"screen"}}` + "\n"))
			}()
		}
	}()
	d := &Daemon{hcPath: path}
	text, truncated, err := d.readHerdrApp(context.Background(), "herdr-app/instance1/t1", 200)
	if err != nil || text != "screen row" || !truncated {
		t.Fatalf("read = %q, %v, %v", text, truncated, err)
	}
	if a, b := <-asked, <-asked; a != 200 || b != 0 {
		t.Fatalf("asked for %v then %v lines", a, b)
	}
}
