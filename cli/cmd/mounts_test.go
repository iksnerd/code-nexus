package cmd

import (
	"strings"
	"testing"
)

func TestResolveReindexPath(t *testing.T) {
	const cwd, home = "/work/app", "/Users/me"
	cases := []struct{ arg, want string }{
		{".", "/work/app"},
		{"./api", "/work/app/api"},
		{"../other", "/work/other"},
		{"~", "/Users/me"},
		{"~/projects/x", "/Users/me/projects/x"},
		// Bare names and absolute paths are the server's to resolve.
		{"my-app", "my-app"},
		{"/abs/path", "/abs/path"},
		{"", ""},
	}
	for _, c := range cases {
		if got := resolveReindexPath(c.arg, cwd, home); got != c.want {
			t.Errorf("resolveReindexPath(%q) = %q, want %q", c.arg, got, c.want)
		}
	}
}

func TestEnvGetSet(t *testing.T) {
	env := "A=1\nB=\n"

	if v, ok := envGet(env, "A"); !ok || v != "1" {
		t.Errorf("envGet A = %q, %v", v, ok)
	}
	if v, ok := envGet(env, "B"); !ok || v != "" {
		t.Errorf("an empty value is still set: %q, %v", v, ok)
	}
	if _, ok := envGet(env, "C"); ok {
		t.Error("C should be unset")
	}

	if got := envSet(env, "A", "2"); got != "A=2\nB=\n" {
		t.Errorf("replace: %q", got)
	}
	if got := envSet(env, "C", "3"); got != "A=1\nB=\nC=3\n" {
		t.Errorf("append: %q", got)
	}
	// A key that only shares a prefix must not be replaced.
	if got := envSet("WORKSPACE_2=x\n", "WORKSPACE", "y"); got != "WORKSPACE_2=x\nWORKSPACE=y\n" {
		t.Errorf("prefix collision: %q", got)
	}
}

func TestWorkspaces(t *testing.T) {
	env := renderEnv("/a", "tfidf")
	env, _ = addWorkspace(env, "/b")

	got := workspaces(env)
	if len(got) != 2 || got[0] != "/a" || got[1] != "/b" {
		t.Errorf("workspaces = %v", got)
	}
}

func TestAddWorkspaceUsesNextFreeSlot(t *testing.T) {
	env := renderEnv("/a", "ollama")

	out, err := addWorkspace(env, "/b")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range []string{"WORKSPACE_2=/b", "WORKSPACE_HOST_2=/b"} {
		if !strings.Contains(out, line+"\n") {
			t.Errorf("missing %q in:\n%s", line, out)
		}
	}
	if !strings.Contains(out, "WORKSPACE=/a\n") {
		t.Error("the first mount must survive")
	}

	out, err = addWorkspace(out, "/c")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "WORKSPACE_3=/c\n") {
		t.Errorf("third mount should take slot 3:\n%s", out)
	}
}

func TestAddWorkspaceFull(t *testing.T) {
	env := renderEnv("/1", "ollama")
	for _, p := range []string{"/2", "/3", "/4", "/5"} {
		var err error
		if env, err = addWorkspace(env, p); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := addWorkspace(env, "/6"); err == nil {
		t.Error("a sixth mount must be an error that points at --workspace")
	} else if !strings.Contains(err.Error(), "--workspace") {
		t.Errorf("error should name the way out: %v", err)
	}
}
