package cmd

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestHasModel(t *testing.T) {
	tags := []byte(`{"models":[{"name":"embeddinggemma:300m"},{"name":"llama3:8b"}]}`)

	if !hasModel(tags, "embeddinggemma:300m") {
		t.Error("exact tag should match")
	}
	if !hasModel(tags, "embeddinggemma") {
		t.Error("a bare name should match any tag of that model")
	}
	if hasModel(tags, "nomic-embed-text") {
		t.Error("an absent model must not match")
	}
	if hasModel([]byte(`not json`), "embeddinggemma:300m") {
		t.Error("unparseable output means not available")
	}
}

func TestPickEmbeddings(t *testing.T) {
	cases := []struct {
		mode      string
		available bool
		want      string
		wantErr   bool
	}{
		{"auto", true, "ollama", false},
		{"auto", false, "tfidf", false},
		{"tfidf", true, "tfidf", false},
		{"ollama", true, "ollama", false},
		{"ollama", false, "", true},
		{"bogus", true, "", true},
	}
	for _, c := range cases {
		got, err := pickEmbeddings(c.mode, c.available)
		if (err != nil) != c.wantErr || got != c.want {
			t.Errorf("pickEmbeddings(%q, %v) = %q, %v; want %q, err=%v", c.mode, c.available, got, err, c.want, c.wantErr)
		}
	}
}

func TestRenderEnv(t *testing.T) {
	env := renderEnv("/Users/me/app", "tfidf")
	for _, line := range []string{
		"WORKSPACE=/Users/me/app",
		"WORKSPACE_HOST=/Users/me/app",
		"EMBEDDING_BACKEND=tfidf",
	} {
		if !strings.Contains(env, line+"\n") {
			t.Errorf("env missing %q:\n%s", line, env)
		}
	}

	// The default backend is the compose file's own default (Ollama): leave it unset.
	if !strings.Contains(renderEnv("/x", "ollama"), "EMBEDDING_BACKEND=\n") {
		t.Error("ollama should leave EMBEDDING_BACKEND empty")
	}
}

func TestMergeMCPConfigNewFile(t *testing.T) {
	out, changed, err := mergeMCPConfig(nil, "http://localhost:3002/mcp")
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	var cfg map[string]map[string]map[string]string
	if err := json.Unmarshal(out, &cfg); err != nil {
		t.Fatal(err)
	}
	got := cfg["mcpServers"]["code-nexus"]
	if got["type"] != "http" || got["url"] != "http://localhost:3002/mcp" {
		t.Errorf("unexpected entry: %v", got)
	}
}

func TestMergeMCPConfigKeepsOtherServers(t *testing.T) {
	existing := []byte(`{"mcpServers":{"other":{"command":"x"}},"extra":1}`)
	out, changed, err := mergeMCPConfig(existing, "http://localhost:3002/mcp")
	if err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	var cfg map[string]json.RawMessage
	if err := json.Unmarshal(out, &cfg); err != nil {
		t.Fatal(err)
	}
	if _, ok := cfg["extra"]; !ok {
		t.Error("unrelated top-level keys must survive")
	}
	var servers map[string]json.RawMessage
	if err := json.Unmarshal(cfg["mcpServers"], &servers); err != nil {
		t.Fatal(err)
	}
	if _, ok := servers["other"]; !ok {
		t.Error("existing servers must survive")
	}
	if _, ok := servers["code-nexus"]; !ok {
		t.Error("code-nexus entry missing")
	}
}

func TestMergeMCPConfigLeavesExistingEntry(t *testing.T) {
	existing := []byte(`{"mcpServers":{"code-nexus":{"type":"http","url":"http://elsewhere:9/mcp"}}}`)
	out, changed, err := mergeMCPConfig(existing, "http://localhost:3002/mcp")
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Error("an existing code-nexus entry must not be overwritten")
	}
	if string(out) != string(existing) {
		t.Errorf("output must equal input when unchanged, got %s", out)
	}
}

func TestMergeMCPConfigRejectsBadJSON(t *testing.T) {
	if _, _, err := mergeMCPConfig([]byte(`{oops`), "http://localhost:3002/mcp"); err == nil {
		t.Error("invalid JSON must be an error, not silently replaced")
	}
}

// composeLines is a compose file's content lines: no blanks, no comments, so a
// reworded comment is not drift but a changed port or healthcheck is.
func composeLines(s string) map[string]bool {
	lines := map[string]bool{}
	for line := range strings.SplitSeq(s, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" && !strings.HasPrefix(trimmed, "#") {
			lines[trimmed] = true
		}
	}
	return lines
}

// The embedded compose file is a copy of the repo's. Every content line must
// match both ways, so a port, healthcheck or restart policy cannot drift.
func TestEmbeddedComposeMatchesRepoCompose(t *testing.T) {
	repo, err := os.ReadFile("../../docker-compose.yml")
	if err != nil {
		t.Skip("repo compose file not reachable:", err)
	}
	want, got := composeLines(string(repo)), composeLines(composeYAML)
	for line := range want {
		if !got[line] {
			t.Errorf("embedded compose lacks %q", line)
		}
	}
	for line := range got {
		if !want[line] {
			t.Errorf("repo compose lacks %q", line)
		}
	}
}
