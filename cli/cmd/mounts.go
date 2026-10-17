package cmd

import (
	"fmt"
	"path/filepath"
	"strings"
)

// maxWorkspaces is the number of host directories the container can mount
// (WORKSPACE and WORKSPACE_2 to WORKSPACE_5).
const maxWorkspaces = 5

// resolveReindexPath turns a path the shell would resolve (".", "./x", "../x",
// "~", "~/x") into the absolute host path the server translates. Bare project
// names and absolute paths pass through: the server resolves those itself.
func resolveReindexPath(arg, cwd, home string) string {
	switch {
	case arg == "~":
		return home
	case strings.HasPrefix(arg, "~/"):
		return filepath.Join(home, arg[2:])
	case arg == "." || arg == ".." || strings.HasPrefix(arg, "./") || strings.HasPrefix(arg, "../"):
		return filepath.Join(cwd, arg)
	default:
		return arg
	}
}

// envGet reads KEY from dotenv text. A key set to an empty value is still set.
func envGet(env, key string) (string, bool) {
	prefix := key + "="
	for line := range strings.SplitSeq(env, "\n") {
		if v, ok := strings.CutPrefix(line, prefix); ok {
			return v, true
		}
	}
	return "", false
}

// envSet replaces KEY's line, or appends one when the key is not there.
func envSet(env, key, value string) string {
	prefix := key + "="
	lines := strings.Split(strings.TrimSuffix(env, "\n"), "\n")
	for i, line := range lines {
		if strings.HasPrefix(line, prefix) {
			lines[i] = prefix + value
			return strings.Join(lines, "\n") + "\n"
		}
	}
	if env == "" {
		return prefix + value + "\n"
	}
	return strings.Join(lines, "\n") + "\n" + prefix + value + "\n"
}

func workspaceKeys(slot int) (dir, host string) {
	if slot == 1 {
		return "WORKSPACE", "WORKSPACE_HOST"
	}
	return fmt.Sprintf("WORKSPACE_%d", slot), fmt.Sprintf("WORKSPACE_HOST_%d", slot)
}

// workspaces lists the host directories the env mounts, in slot order.
func workspaces(env string) []string {
	var dirs []string
	for slot := 1; slot <= maxWorkspaces; slot++ {
		key, _ := workspaceKeys(slot)
		if dir, _ := envGet(env, key); dir != "" {
			dirs = append(dirs, dir)
		}
	}
	return dirs
}

// addWorkspace mounts one more host directory in the first free slot.
func addWorkspace(env, dir string) (string, error) {
	for slot := 1; slot <= maxWorkspaces; slot++ {
		key, hostKey := workspaceKeys(slot)
		if used, _ := envGet(env, key); used != "" {
			continue
		}
		return envSet(envSet(env, key, dir), hostKey, dir), nil
	}
	return "", fmt.Errorf("all %d mounts are in use: re-run with --workspace <a directory that contains the projects>", maxWorkspaces)
}
