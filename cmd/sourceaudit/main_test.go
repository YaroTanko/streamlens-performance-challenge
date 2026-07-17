package main

import (
	"strings"
	"testing"
)

const testTypesSource = `package analyzer

type Config struct{}
`

func TestAuditAcceptsLegitimateAndShadowedCode(t *testing.T) {
	t.Parallel()

	tests := map[string]string{
		"fmt formatting": `package analyzer
import "fmt"
func candidate(value int) string { return fmt.Sprintf("%d", value) }
`,
		"commented constructs": `package analyzer
// import "unsafe"
// fmt.Println("BenchmarkAnalyze")
func candidate() int { return 1 }
`,
		"shadowed print and fmt": `package analyzer
type printer struct{}
func (printer) Println(string) {}
func candidate() {
	fmt := printer{}
	fmt.Println("local")
	print := func(string) {}
	print("local")
}
`,
	}

	for name, source := range tests {
		name, source := name, source
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if err := auditSource(source); err != nil {
				t.Fatalf("audit rejected legitimate source: %v", err)
			}
		})
	}
}

func TestAuditRejectsResolvedBypasses(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		source string
		want   string
	}{
		"escaped unsafe import": {
			source: "package analyzer\nimport \"un\\u0073afe\"\nvar _ = unsafe.Sizeof(0)\n",
			want:   `import "unsafe"`,
		},
		"comment separated import": {
			source: "package analyzer\nimport/**/\"unsafe\"\nvar _ = unsafe.Sizeof(0)\n",
			want:   `import "unsafe"`,
		},
		"semicolon imports": {
			source: "package analyzer\nimport(\"fmt\"; \"unsafe\")\nvar _ = fmt.Sprintf\nvar _ = unsafe.Sizeof(0)\n",
			want:   `import "unsafe"`,
		},
		"flag": {
			source: "package analyzer\nimport \"flag\"\nvar _ = flag.Args\n",
			want:   `import "flag"`,
		},
		"slog": {
			source: "package analyzer\nimport \"log/slog\"\nvar _ = slog.Info\n",
			want:   `import "log/slog"`,
		},
		"aliased fmt print": {
			source: "package analyzer\nimport output \"fmt\"\nfunc candidate() { output.Println(\"x\") }\n",
			want:   "fmt.Println",
		},
		"builtin print": {
			source: "package analyzer\nfunc candidate() { print(\"x\") }\n",
			want:   "builtin print",
		},
		"os file write": {
			source: "package analyzer\nimport \"os\"\nfunc candidate(file *os.File) { _, _ = file.Write([]byte(\"x\")) }\n",
			want:   `import "os"`,
		},
		"os file close": {
			source: "package analyzer\nimport host \"os\"\nfunc candidate(file *host.File) { _ = file.Close() }\n",
			want:   `import "os"`,
		},
		"promoted os file write": {
			source: "package analyzer\nimport \"os\"\ntype wrapper struct { *os.File }\nfunc candidate(file wrapper) { _, _ = file.Write([]byte(\"x\")) }\n",
			want:   `import "os"`,
		},
		"os file concealed as io writer": {
			source: "package analyzer\nimport (\"io\"; \"os\")\nfunc candidate(file *os.File) { var writer io.Writer = file; _, _ = writer.Write([]byte(\"x\")) }\n",
			want:   `import "os"`,
		},
		"runtime gomaxprocs": {
			source: "package analyzer\nimport machine \"runtime\"\nfunc candidate() { machine.GOMAXPROCS(1) }\n",
			want:   "runtime.GOMAXPROCS",
		},
		"runtime gc": {
			source: "package analyzer\nimport \"runtime\"\nfunc candidate() { runtime.GC() }\n",
			want:   "runtime.GC",
		},
		"folded benchmark marker": {
			source: "package analyzer\nconst marker = \"Benchmark\" + \"Analyze\"\n",
			want:   `benchmark marker "BenchmarkAnalyze"`,
		},
	}

	for name, test := range tests {
		name, test := name, test
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			err := auditSource(test.source)
			if err == nil {
				t.Fatal("audit unexpectedly accepted source")
			}
			if !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error %q does not name construct %q", err, test.want)
			}
			if !strings.Contains(err.Error(), "internal/analyzer/engine.go:") {
				t.Fatalf("error does not name engine path and position: %v", err)
			}
		})
	}
}

func TestAuditRequiresExactSourcesToTypeCheck(t *testing.T) {
	t.Parallel()
	err := auditSource("package analyzer\nfunc candidate() { missing() }\n")
	if err == nil || !strings.Contains(err.Error(), "cannot type-check exact candidate analyzer sources") {
		t.Fatalf("expected type-check failure, got %v", err)
	}
}

func auditSource(source string) error {
	return audit(auditInput{
		engineName:  "internal/analyzer/engine.go",
		engine:      []byte(source),
		typesName:   "internal/analyzer/types.go",
		typesSource: []byte(testTypesSource),
	})
}
