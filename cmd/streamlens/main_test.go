package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer"
)

func TestRunReadsStandardInputAndWritesJSON(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		`{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"acme","user_id":"u1","type":"purchase","value":4}`,
		`{"timestamp":"2026-01-15T12:00:01Z","tenant_id":"acme","user_id":"u2","type":"view","value":100}`,
	}, "\n")
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	exitCode := run(
		context.Background(),
		[]string{"-types", "purchase", "-window", "5m", "-top-k", "1"},
		strings.NewReader(input),
		&stdout,
		&stderr,
	)
	if exitCode != 0 {
		t.Fatalf("run() exit code = %d, stderr = %q", exitCode, stderr.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("run() stderr = %q, want empty", stderr.String())
	}

	var groups []analyzer.Group
	if err := json.Unmarshal(stdout.Bytes(), &groups); err != nil {
		t.Fatalf("json.Unmarshal(output) error = %v; output = %q", err, stdout.String())
	}
	if len(groups) != 1 || groups[0].Type != "purchase" || groups[0].Count != 1 {
		t.Fatalf("run() groups = %#v, want one purchase group", groups)
	}
}

func TestRunReadsInputFile(t *testing.T) {
	t.Parallel()

	inputPath := filepath.Join(t.TempDir(), "events.ndjson")
	input := `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"acme","user_id":"u1","type":"purchase","value":4}`
	if err := os.WriteFile(inputPath, []byte(input), 0o600); err != nil {
		t.Fatalf("os.WriteFile() error = %v", err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := run(context.Background(), []string{"-input", inputPath}, strings.NewReader("not used"), &stdout, &stderr)
	if exitCode != 0 {
		t.Fatalf("run() exit code = %d, stderr = %q", exitCode, stderr.String())
	}
	if !strings.Contains(stdout.String(), `"tenant_id":"acme"`) {
		t.Fatalf("run() stdout = %q, want acme group", stdout.String())
	}
}

func TestRunReportsProcessingFailure(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := run(context.Background(), nil, strings.NewReader("not-json"), &stdout, &stderr)
	if exitCode == 0 {
		t.Fatalf("run() exit code = 0, stderr = %q", stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("run() stdout = %q, want empty", stdout.String())
	}
	if !strings.Contains(stderr.String(), "line 1") {
		t.Fatalf("run() stderr = %q, want line number", stderr.String())
	}
}

func TestRunValidatesFlags(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "window", args: []string{"-window", "0s"}, want: "window must be positive"},
		{name: "top-k", args: []string{"-top-k", "0"}, want: "top-k must be positive"},
		{name: "from", args: []string{"-from", "not-a-time"}, want: "from must be"},
		{name: "to", args: []string{"-to", "2026-01-15T12:00:00"}, want: "to must be"},
		{name: "positional", args: []string{"events.ndjson"}, want: "unexpected positional"},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stdout bytes.Buffer
			var stderr bytes.Buffer
			exitCode := run(context.Background(), test.args, strings.NewReader(""), &stdout, &stderr)
			if exitCode == 0 || !strings.Contains(stderr.String(), test.want) {
				t.Fatalf("run() = %d, stderr = %q; want nonzero and %q", exitCode, stderr.String(), test.want)
			}
		})
	}
}

func TestRunWritesEmptyArrayForEmptyInput(t *testing.T) {
	t.Parallel()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := run(context.Background(), nil, strings.NewReader("\n"), &stdout, &stderr)
	if exitCode != 0 {
		t.Fatalf("run() exit code = %d, stderr = %q", exitCode, stderr.String())
	}
	if stdout.String() != "[]\n" {
		t.Fatalf("run() stdout = %q, want %q", stdout.String(), "[]\n")
	}
}
