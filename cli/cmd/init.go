package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/iksnerd/elixir-nexus/cli/client"
	"github.com/iksnerd/elixir-nexus/cli/ui"
	"github.com/spf13/cobra"
)

const (
	defaultOllamaURL   = "http://localhost:11434"
	defaultOllamaModel = "embeddinggemma:300m"
	mcpServerName      = "code-nexus"
	readyTimeout       = 3 * time.Minute
)

var (
	initEmbeddings string
	initWorkspace  string
	initNoMCP      bool
	initNoIndex    bool
	initDryRun     bool
)

var initCmd = &cobra.Command{
	Use:   "init [project]",
	Short: "Start CodeNexus, connect it to a project and index it",
	Long: `Sets up everything the README's Quick Start does by hand.

  1. Checks that Docker is running.
  2. Uses Ollama embeddings if Ollama has the model, otherwise TF-IDF.
  3. Writes ~/.nexus/docker-compose.yml and starts CodeNexus and Qdrant.
  4. Adds a code-nexus entry to <project>/.mcp.json.
  5. Indexes the project.

If a server already answers at --server, it is left alone and only steps 4 and 5 run.
The project directory (or --workspace) is mounted read-only into the container.`,
	Example: `  nexus init
  nexus init ~/projects/my-app
  nexus init --workspace ~/projects ~/projects/my-app
  nexus init --embeddings tfidf --dry-run`,
	Args: cobra.MaximumNArgs(1),
	RunE: runInit,
}

func init() {
	initCmd.Flags().StringVar(&initEmbeddings, "embeddings", "auto", "embedding backend: auto, ollama or tfidf")
	initCmd.Flags().StringVar(&initWorkspace, "workspace", "", "directory to mount read-only (default: the project)")
	initCmd.Flags().BoolVar(&initNoMCP, "no-mcp", false, "do not touch <project>/.mcp.json")
	initCmd.Flags().BoolVar(&initNoIndex, "no-index", false, "do not index the project")
	initCmd.Flags().BoolVar(&initDryRun, "dry-run", false, "print what would happen and change nothing")
	rootCmd.AddCommand(initCmd)
}

func runInit(cmd *cobra.Command, args []string) error {
	projectArg := "."
	if len(args) == 1 {
		projectArg = args[0]
	}
	project, err := absDir(projectArg)
	if err != nil {
		return err
	}
	workspace := project
	if initWorkspace != "" {
		if workspace, err = absDir(initWorkspace); err != nil {
			return err
		}
	}
	if !within(workspace, project) {
		return fmt.Errorf("project %s is outside the mounted workspace %s", project, workspace)
	}

	probe := client.New(serverURL)
	probe.HTTPClient.Timeout = 3 * time.Second
	_, probeErr := probe.CallTool("get_status", map[string]any{})
	running := probeErr == nil

	if running {
		step("CodeNexus already answers at %s, leaving it as is", serverURL)
	} else if err := startStack(workspace); err != nil {
		return err
	}

	if !initNoMCP {
		if err := connectMCP(project); err != nil {
			return err
		}
	}

	if initNoIndex {
		return nil
	}
	return indexProject(project)
}

// startStack writes the compose files under ~/.nexus and brings the stack up.
func startStack(workspace string) error {
	if err := checkDocker(); err != nil {
		return err
	}

	model := os.Getenv("OLLAMA_MODEL")
	if model == "" {
		model = defaultOllamaModel
	}
	available := ollamaHasModel(defaultOllamaURL, model)
	embeddings, err := pickEmbeddings(initEmbeddings, available)
	if err != nil {
		return fmt.Errorf("%w\n\nInstall the model with: ollama pull %s", err, model)
	}
	if embeddings == "tfidf" && initEmbeddings == "auto" {
		warn("Ollama model %s not found at %s: using TF-IDF embeddings (faster to index, weaker semantic matches)", model, defaultOllamaURL)
		warn("For semantic search: ollama pull %s, then re-run with --embeddings ollama", model)
	} else {
		step("Embeddings: %s", embeddings)
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return fmt.Errorf("find home directory: %w", err)
	}
	dir := filepath.Join(home, ".nexus")
	composePath := filepath.Join(dir, "docker-compose.yml")
	envPath := filepath.Join(dir, ".env")
	env := renderEnv(workspace, embeddings)

	if initDryRun {
		step("Would write %s and %s, mounting %s", composePath, envPath, workspace)
		step("Would run: %s", strings.Join(composeArgs(composePath, envPath, "up", "-d"), " "))
		return nil
	}

	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}
	if err := os.WriteFile(composePath, []byte(composeYAML), 0o644); err != nil {
		return fmt.Errorf("write %s: %w", composePath, err)
	}
	if err := os.WriteFile(envPath, []byte(env), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", envPath, err)
	}
	step("Wrote %s (mounts %s read-only)", composePath, workspace)

	var upErr error
	ui.Spin("Starting CodeNexus and Qdrant…", func() {
		upErr = runCompose(composeArgs(composePath, envPath, "up", "-d"))
	})
	if upErr != nil {
		return upErr
	}

	var waitErr error
	ui.Spin("Waiting for the server…", func() {
		waitErr = waitReady(serverURL, readyTimeout)
	})
	if waitErr != nil {
		return waitErr
	}
	step("Server is up: MCP at %s/mcp, dashboard at http://localhost:4100", serverURL)
	return nil
}

func connectMCP(project string) error {
	path := filepath.Join(project, ".mcp.json")
	url := strings.TrimRight(serverURL, "/") + "/mcp"

	existing, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read %s: %w", path, err)
	}
	out, changed, err := mergeMCPConfig(existing, url)
	if err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	if !changed {
		step("%s already has a %s entry, leaving it", path, mcpServerName)
		return nil
	}
	if initDryRun {
		step("Would add a %s entry to %s", mcpServerName, path)
		return nil
	}
	if err := os.WriteFile(path, out, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	step("Added %s to %s (restart your MCP client to pick it up)", mcpServerName, path)
	return nil
}

func indexProject(project string) error {
	if initDryRun {
		step("Would index %s", project)
		return nil
	}
	var (
		raw []byte
		err error
	)
	ui.Spin("Indexing "+project+"…", func() {
		raw, err = mcpClient.CallTool("reindex", map[string]any{"path": project})
	})
	if err != nil {
		return fmt.Errorf("index %s: %w", project, err)
	}
	if jsonOut {
		fmt.Println(string(raw))
		return nil
	}
	step("Indexed %s", project)
	return nil
}

// checkDocker fails early, with the fix, when Docker or Compose is unusable.
func checkDocker() error {
	if _, err := exec.LookPath("docker"); err != nil {
		return errors.New("docker not found on PATH: install Docker Desktop (https://docs.docker.com/get-docker/) and re-run")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := exec.CommandContext(ctx, "docker", "info").Run(); err != nil {
		return errors.New("docker is installed but not running: start Docker Desktop and re-run")
	}
	return nil
}

func composeArgs(composePath, envPath string, rest ...string) []string {
	base := []string{"docker", "compose"}
	if err := exec.Command("docker", "compose", "version").Run(); err != nil {
		if _, lookErr := exec.LookPath("docker-compose"); lookErr == nil {
			base = []string{"docker-compose"}
		}
	}
	base = append(base, "-p", "nexus", "-f", composePath, "--env-file", envPath)
	return append(base, rest...)
}

func runCompose(args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	out, err := exec.CommandContext(ctx, args[0], args[1:]...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s failed: %w\n%s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// waitReady polls get_status until the server answers and Qdrant is healthy.
func waitReady(url string, timeout time.Duration) error {
	c := client.New(url)
	c.HTTPClient.Timeout = 5 * time.Second
	deadline := time.Now().Add(timeout)
	var last error
	for time.Now().Before(deadline) {
		raw, err := c.CallTool("get_status", map[string]any{})
		if err == nil {
			var s struct {
				Qdrant string `json:"qdrant"`
			}
			if json.Unmarshal(raw, &s) == nil && s.Qdrant == "ok" {
				return nil
			}
			last = errors.New("server is up but Qdrant is not healthy yet")
		} else {
			last = err
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("server not ready after %s (last: %v)\nCheck: docker logs code_nexus", timeout, last)
}

func ollamaHasModel(baseURL, model string) bool {
	c := http.Client{Timeout: 2 * time.Second}
	resp, err := c.Get(strings.TrimRight(baseURL, "/") + "/api/tags")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil || resp.StatusCode != http.StatusOK {
		return false
	}
	return hasModel(body, model)
}

// hasModel reports whether an Ollama /api/tags response lists the model. A
// name without a tag matches any tag of that model.
func hasModel(tags []byte, model string) bool {
	var resp struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if json.Unmarshal(tags, &resp) != nil {
		return false
	}
	for _, m := range resp.Models {
		if m.Name == model || (!strings.Contains(model, ":") && strings.HasPrefix(m.Name, model+":")) {
			return true
		}
	}
	return false
}

// pickEmbeddings resolves --embeddings. Asking for ollama when it is not
// available is an error: silently falling back would hide a setup problem.
func pickEmbeddings(mode string, ollamaAvailable bool) (string, error) {
	switch mode {
	case "auto":
		if ollamaAvailable {
			return "ollama", nil
		}
		return "tfidf", nil
	case "tfidf":
		return "tfidf", nil
	case "ollama":
		if !ollamaAvailable {
			return "", fmt.Errorf("--embeddings ollama: no Ollama with the model at %s", defaultOllamaURL)
		}
		return "ollama", nil
	default:
		return "", fmt.Errorf("--embeddings must be auto, ollama or tfidf, got %q", mode)
	}
}

// renderEnv is the compose .env. EMBEDDING_BACKEND stays empty for Ollama,
// which is the server's default.
func renderEnv(workspace, embeddings string) string {
	backend := ""
	if embeddings == "tfidf" {
		backend = "tfidf"
	}
	return fmt.Sprintf("WORKSPACE=%s\nWORKSPACE_HOST=%s\nEMBEDDING_BACKEND=%s\n", workspace, workspace, backend)
}

// mergeMCPConfig adds the code-nexus server to a .mcp.json document and keeps
// everything else. It never overwrites an existing code-nexus entry; in that
// case it returns the input unchanged with changed=false.
func mergeMCPConfig(existing []byte, url string) (out []byte, changed bool, err error) {
	doc := map[string]json.RawMessage{}
	if len(strings.TrimSpace(string(existing))) > 0 {
		if err := json.Unmarshal(existing, &doc); err != nil {
			return nil, false, fmt.Errorf("not valid JSON, fix or remove it first: %w", err)
		}
	}

	servers := map[string]json.RawMessage{}
	if raw, ok := doc["mcpServers"]; ok {
		if err := json.Unmarshal(raw, &servers); err != nil {
			return nil, false, fmt.Errorf("mcpServers is not an object: %w", err)
		}
	}
	if _, ok := servers[mcpServerName]; ok {
		return existing, false, nil
	}

	entry, err := json.Marshal(map[string]string{"type": "http", "url": url})
	if err != nil {
		return nil, false, err
	}
	servers[mcpServerName] = entry
	if doc["mcpServers"], err = json.Marshal(servers); err != nil {
		return nil, false, err
	}

	out, err = json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return nil, false, err
	}
	return append(out, '\n'), true, nil
}

func absDir(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", fmt.Errorf("resolve %s: %w", p, err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("%s: %w", abs, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%s is not a directory", abs)
	}
	return abs, nil
}

// within reports whether path is dir or lies under it.
func within(dir, path string) bool {
	rel, err := filepath.Rel(dir, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func step(format string, a ...any) {
	fmt.Println(ui.SuccessStyle.Render("  ✓ " + fmt.Sprintf(format, a...)))
}

func warn(format string, a ...any) {
	fmt.Println(ui.WarningStyle.Render("  ! " + fmt.Sprintf(format, a...)))
}
