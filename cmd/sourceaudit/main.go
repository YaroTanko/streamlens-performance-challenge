// Command sourceaudit applies the assessment's narrow source policy to an
// analyzer implementation without executing candidate code.
package main

import (
	"flag"
	"fmt"
	"go/ast"
	"go/constant"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"io"
	"os"
	"strconv"
	"strings"
)

var prohibitedImports = map[string]struct{}{
	"C":             {},
	"flag":          {},
	"log":           {},
	"log/slog":      {},
	"log/syslog":    {},
	"os":            {},
	"os/exec":       {},
	"runtime/debug": {},
	"runtime/pprof": {},
	"runtime/trace": {},
	"syscall":       {},
	"testing":       {},
	"unsafe":        {},
}

var benchmarkMarkers = []string{
	"BenchmarkAnalyze",
	"internal/assessment",
	"-test.bench",
	"testing.B",
}

type auditInput struct {
	engineName  string
	engine      []byte
	typesName   string
	typesSource []byte
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(arguments []string, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("sourceaudit", flag.ContinueOnError)
	flags.SetOutput(stderr)
	enginePath := flags.String("engine", "", "path to candidate engine.go blob")
	typesPath := flags.String("types", "", "path to protected types.go blob")
	engineName := flags.String("engine-name", "internal/analyzer/engine.go", "logical engine filename")
	typesName := flags.String("types-name", "internal/analyzer/types.go", "logical types filename")
	if err := flags.Parse(arguments); err != nil {
		return 2
	}
	if flags.NArg() != 0 || *enginePath == "" || *typesPath == "" {
		fmt.Fprintln(stderr, "usage: sourceaudit -engine <engine.go> -types <types.go>")
		return 2
	}

	engineSource, err := os.ReadFile(*enginePath)
	if err != nil {
		fmt.Fprintf(stderr, "source audit: read %s: %v\n", *engineName, err)
		return 1
	}
	typesSource, err := os.ReadFile(*typesPath)
	if err != nil {
		fmt.Fprintf(stderr, "source audit: read %s: %v\n", *typesName, err)
		return 1
	}

	err = audit(auditInput{
		engineName:  *engineName,
		engine:      engineSource,
		typesName:   *typesName,
		typesSource: typesSource,
	})
	if err != nil {
		fmt.Fprintf(stderr, "source audit: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, "Source audit passed.")
	return 0
}

func audit(input auditInput) error {
	files := token.NewFileSet()
	typesFile, err := parser.ParseFile(files, input.typesName, input.typesSource, parser.ParseComments|parser.AllErrors)
	if err != nil {
		return fmt.Errorf("cannot parse protected %s: %w", input.typesName, err)
	}
	engineFile, err := parser.ParseFile(files, input.engineName, input.engine, parser.ParseComments|parser.AllErrors)
	if err != nil {
		return fmt.Errorf("cannot parse %s: %w", input.engineName, err)
	}
	if typesFile.Name.Name != "analyzer" || engineFile.Name.Name != "analyzer" {
		return fmt.Errorf("%s and %s must both declare package analyzer", input.engineName, input.typesName)
	}

	if err := auditImports(files, engineFile); err != nil {
		return err
	}
	if err := auditDirectives(files, engineFile); err != nil {
		return err
	}

	information := &types.Info{
		Defs:  make(map[*ast.Ident]types.Object),
		Uses:  make(map[*ast.Ident]types.Object),
		Types: make(map[ast.Expr]types.TypeAndValue),
	}
	configuration := &types.Config{Importer: importer.Default()}
	if _, err := configuration.Check("github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer", files, []*ast.File{typesFile, engineFile}, information); err != nil {
		return fmt.Errorf("cannot type-check exact candidate analyzer sources: %w", err)
	}

	if err := auditResolvedUses(files, engineFile, information); err != nil {
		return err
	}
	return auditBenchmarkStrings(files, engineFile, information)
}

func auditImports(files *token.FileSet, file *ast.File) error {
	for _, specification := range file.Imports {
		path, err := strconv.Unquote(specification.Path.Value)
		if err != nil {
			return reject(files, specification.Path.Pos(), specification.Path.Value, "invalid import path")
		}
		if _, prohibited := prohibitedImports[path]; prohibited {
			return reject(files, specification.Path.Pos(), fmt.Sprintf("import %q", path), "package is prohibited by candidate source policy")
		}
	}
	return nil
}

func auditDirectives(files *token.FileSet, file *ast.File) error {
	for _, group := range file.Comments {
		for _, comment := range group.List {
			text := comment.Text
			if strings.HasPrefix(text, "//go:linkname") || strings.HasPrefix(text, "//go:cgo_") {
				construct := strings.Fields(strings.TrimPrefix(text, "//"))[0]
				return reject(files, comment.Pos(), construct, "unsafe compiler or cgo directive is prohibited")
			}
			trimmed := strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(text, "/*"), "*/"))
			if strings.HasPrefix(trimmed, "#cgo") {
				return reject(files, comment.Pos(), "#cgo", "cgo directive is prohibited")
			}
		}
	}
	return nil
}

func auditResolvedUses(files *token.FileSet, file *ast.File, information *types.Info) error {
	var violation error
	ast.Inspect(file, func(node ast.Node) bool {
		if violation != nil {
			return false
		}
		identifier, ok := node.(*ast.Ident)
		if !ok {
			return true
		}
		object := information.Uses[identifier]
		if object == nil {
			return true
		}

		if builtin, ok := object.(*types.Builtin); ok && (builtin.Name() == "print" || builtin.Name() == "println") {
			violation = reject(files, identifier.Pos(), "builtin "+builtin.Name(), "direct diagnostic output is prohibited")
			return false
		}

		packagePath := objectPackagePath(object)
		if packagePath == "fmt" && isPackageFunction(object, "Print", "Printf", "Println") {
			violation = reject(files, identifier.Pos(), "fmt."+object.Name(), "direct diagnostic output is prohibited")
			return false
		}
		if packagePath == "runtime" {
			switch object.(type) {
			case *types.Func, *types.Var:
				violation = reject(files, identifier.Pos(), "runtime."+object.Name(), "runtime inspection or global-state mutation is prohibited")
				return false
			}
		}
		return true
	})
	return violation
}

func auditBenchmarkStrings(files *token.FileSet, file *ast.File, information *types.Info) error {
	var violation error
	ast.Inspect(file, func(node ast.Node) bool {
		if violation != nil {
			return false
		}
		expression, ok := node.(ast.Expr)
		if !ok {
			return true
		}
		value := information.Types[expression].Value
		if value == nil || value.Kind() != constant.String {
			return true
		}
		text := constant.StringVal(value)
		for _, marker := range benchmarkMarkers {
			if strings.Contains(text, marker) {
				violation = reject(files, expression.Pos(), fmt.Sprintf("benchmark marker %q", marker), "benchmark detection is prohibited")
				return false
			}
		}
		return true
	})
	return violation
}

func isPackageFunction(object types.Object, names ...string) bool {
	function, ok := object.(*types.Func)
	if !ok || function.Type().(*types.Signature).Recv() != nil {
		return false
	}
	for _, name := range names {
		if function.Name() == name {
			return true
		}
	}
	return false
}

func objectPackagePath(object types.Object) string {
	if object.Pkg() == nil {
		return ""
	}
	return object.Pkg().Path()
}

func reject(files *token.FileSet, position token.Pos, construct, reason string) error {
	location := files.Position(position)
	return fmt.Errorf("%s:%d:%d: rejected %s: %s", location.Filename, location.Line, location.Column, construct, reason)
}
