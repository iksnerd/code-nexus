package cmd

import (
	"bytes"
	"strings"
	"testing"
)

func TestDeadCodeArgsSendsPathPrefix(t *testing.T) {
	args := deadCodeArgs("/workspace/app/lib")
	if args["path_prefix"] != "/workspace/app/lib" {
		t.Fatalf("want path_prefix, got %v", args)
	}
	if len(deadCodeArgs("")) != 0 {
		t.Fatalf("no prefix must send no arguments")
	}
}

func TestRenderDeadCodeShowsEverySection(t *testing.T) {
	raw := []byte(`{
	  "dead_functions": [{"name": "top", "qualified_name": "A.top/0", "entity_type": "function", "file_path": "lib/a.ex", "start_line": 2}],
	  "dead_via_dead_callers": [{"name": "leaf", "qualified_name": "B.leaf/1", "entity_type": "function", "file_path": "lib/b.ex", "start_line": 5,
	    "chain": ["A.top/0", "B.leaf/1"], "dead_callers": ["A.top/0"]}],
	  "unsure": [{"name": "check", "qualified_name": "C.check/3", "entity_type": "function", "file_path": "lib/c.ex", "start_line": 9,
	    "reason": "only a short-name match: ?check/3"}],
	  "total_public": 10, "dead_count": 1
	}`)

	var out bytes.Buffer
	renderDeadCode(&out, raw)
	text := out.String()

	for _, want := range []string{
		"1 / 10", "A.top/0", "lib/a.ex:2",
		"Called only by dead code (1)", "B.leaf/1", "A.top/0 → B.leaf/1",
		"Unsure: reached only dynamically (1)", "C.check/3", "only a short-name match: ?check/3",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("output lacks %q:\n%s", want, text)
		}
	}
}
