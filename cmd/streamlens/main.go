package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer"
)

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	flags := flag.NewFlagSet("streamlens", flag.ContinueOnError)
	flags.SetOutput(stderr)

	var inputPath string
	var fromText string
	var toText string
	var typesText string
	var window time.Duration
	var topK int

	flags.StringVar(&inputPath, "input", "", "NDJSON input file (default: standard input)")
	flags.StringVar(&fromText, "from", "", "inclusive RFC3339Nano lower timestamp bound")
	flags.StringVar(&toText, "to", "", "exclusive RFC3339Nano upper timestamp bound")
	flags.StringVar(&typesText, "types", "", "comma-separated event-type allow-list")
	flags.DurationVar(&window, "window", analyzer.DefaultWindow, "positive fixed aggregation window")
	flags.IntVar(&topK, "top-k", analyzer.DefaultTopK, "positive number of top users per group")

	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintln(stderr, "streamlens: unexpected positional arguments")
		return 2
	}
	if window <= 0 {
		fmt.Fprintln(stderr, "streamlens: window must be positive")
		return 2
	}
	if topK <= 0 {
		fmt.Fprintln(stderr, "streamlens: top-k must be positive")
		return 2
	}

	from, err := parseOptionalTime("from", fromText)
	if err != nil {
		fmt.Fprintf(stderr, "streamlens: %v\n", err)
		return 2
	}
	to, err := parseOptionalTime("to", toText)
	if err != nil {
		fmt.Fprintf(stderr, "streamlens: %v\n", err)
		return 2
	}

	input := stdin
	if inputPath != "" && inputPath != "-" {
		file, err := os.Open(inputPath)
		if err != nil {
			fmt.Fprintf(stderr, "streamlens: open input: %v\n", err)
			return 1
		}
		defer file.Close()
		input = file
	}

	groups, err := analyzer.Analyze(ctx, input, analyzer.Config{
		From:   from,
		To:     to,
		Types:  parseTypes(typesText),
		Window: window,
		TopK:   topK,
	})
	if err != nil {
		fmt.Fprintf(stderr, "streamlens: analyze input: %v\n", err)
		return 1
	}

	encoder := json.NewEncoder(stdout)
	if err := encoder.Encode(groups); err != nil {
		fmt.Fprintf(stderr, "streamlens: write output: %v\n", err)
		return 1
	}
	return 0
}

func parseOptionalTime(name, value string) (*time.Time, error) {
	if value == "" {
		return nil, nil
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return nil, fmt.Errorf("%s must be an RFC3339Nano timestamp with an explicit offset: %w", name, err)
	}
	return &parsed, nil
}

func parseTypes(value string) []string {
	if value == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	types := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			types = append(types, trimmed)
		}
	}
	return types
}
