package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testSHA = "0123456789abcdef0123456789abcdef01234567"

const schemaV1GoldenCore = `{
  "schema_version": 1,
  "revisions": [
    {
      "name": "baseline",
      "sha": "0123456789abcdef0123456789abcdef01234567"
    }
  ],
  "parameters": [
    {
      "name": "samples",
      "value": "7"
    }
  ],
  "environment": [
    {
      "name": "go_version",
      "value": "go1.26.5"
    }
  ],
  "artifacts": [
    {
      "name": "report",
      "path": "report.md",
      "sha256": "331d26d6d8f862e46ba900811be8a7a1e4dbaa229b14c99becfd5e5151490d95",
      "size_bytes": 7
    }
  ]
}
`

const schemaV1GoldenCoreSHA256 = "3712fe63bcf044732c1be2cb7acd2f025a6914de2188ae489d04a60b19ab2f2a"

func TestRunWritesDeterministicCoreAndVolatileEnvelope(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, filepath.Join(root, "baseline.txt"), "baseline benchmark\n")
	writeTestFile(t, filepath.Join(root, "nested", "report.md"), "# report\n")

	firstOutput := filepath.Join(root, "first")
	secondOutput := filepath.Join(root, "second")
	firstArgs := []string{
		"-root", root,
		"-output-dir", firstOutput,
		"-revision", "candidate=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"-revision", "baseline=" + testSHA,
		"-parameter", "samples=7",
		"-parameter", "benchtime=300ms",
		"-environment", "go_version=go1.26.5",
		"-environment", "goarch=arm64",
		"-artifact", "report=nested/report.md",
		"-artifact", "baseline=baseline.txt",
		"-runner", "source=github-actions",
		"-runner", "image=ubuntu-24.04",
		"-generated-at", "2026-07-15T12:00:00+03:00",
	}
	secondArgs := []string{
		"-output-dir", secondOutput,
		"-root", root,
		"-artifact", "baseline=baseline.txt",
		"-artifact", "report=nested/report.md",
		"-environment", "goarch=arm64",
		"-environment", "go_version=go1.26.5",
		"-parameter", "benchtime=300ms",
		"-parameter", "samples=7",
		"-revision", "baseline=" + testSHA,
		"-revision", "candidate=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"-runner", "image=ubuntu-24.04.20260714.1",
		"-runner", "source=local",
		"-generated-at", "2026-07-16T00:01:02Z",
	}

	var stdout bytes.Buffer
	if err := run(firstArgs, &stdout, nil); err != nil {
		t.Fatalf("first run: %v", err)
	}
	if !strings.HasPrefix(stdout.String(), coreFilename+" sha256=") {
		t.Fatalf("stdout = %q", stdout.String())
	}
	if err := run(secondArgs, nil, nil); err != nil {
		t.Fatalf("second run: %v", err)
	}

	firstCore := readTestFile(t, filepath.Join(firstOutput, coreFilename))
	secondCore := readTestFile(t, filepath.Join(secondOutput, coreFilename))
	if !bytes.Equal(firstCore, secondCore) {
		t.Fatalf("stable core differs across argument order and volatile inputs:\nfirst:\n%s\nsecond:\n%s", firstCore, secondCore)
	}
	if bytes.Contains(firstCore, []byte("generated_at")) || bytes.Contains(firstCore, []byte("ubuntu")) || bytes.Contains(firstCore, []byte("source")) {
		t.Fatalf("core contains volatile data:\n%s", firstCore)
	}

	var core coreManifest
	if err := json.Unmarshal(firstCore, &core); err != nil {
		t.Fatalf("decode core: %v", err)
	}
	if got, want := entryNames(core.Revisions), []string{"baseline", "candidate"}; !equalStrings(got, want) {
		t.Fatalf("revision order = %v, want %v", got, want)
	}
	if got, want := entryNames(core.Parameters), []string{"benchtime", "samples"}; !equalStrings(got, want) {
		t.Fatalf("parameter order = %v, want %v", got, want)
	}
	if got, want := entryNames(core.Environment), []string{"go_version", "goarch"}; !equalStrings(got, want) {
		t.Fatalf("environment order = %v, want %v", got, want)
	}
	if len(core.Artifacts) != 2 || core.Artifacts[0].Name != "baseline" || core.Artifacts[1].Name != "report" {
		t.Fatalf("artifacts = %+v", core.Artifacts)
	}
	wantArtifactDigest := sha256.Sum256([]byte("baseline benchmark\n"))
	if got, want := core.Artifacts[0].SHA256, hex.EncodeToString(wantArtifactDigest[:]); got != want {
		t.Fatalf("baseline sha256 = %s, want %s", got, want)
	}
	if got, want := core.Artifacts[0].SizeBytes, int64(len("baseline benchmark\n")); got != want {
		t.Fatalf("baseline size = %d, want %d", got, want)
	}

	firstEnvelope := decodeEnvelope(t, filepath.Join(firstOutput, envelopeFilename))
	secondEnvelope := decodeEnvelope(t, filepath.Join(secondOutput, envelopeFilename))
	if firstEnvelope.GeneratedAt != "2026-07-15T09:00:00Z" {
		t.Fatalf("normalized generated_at = %q", firstEnvelope.GeneratedAt)
	}
	if firstEnvelope.GeneratedAt == secondEnvelope.GeneratedAt || equalNamedValues(firstEnvelope.Runner, secondEnvelope.Runner) {
		t.Fatalf("volatile envelope data was not isolated: first=%+v second=%+v", firstEnvelope, secondEnvelope)
	}
	coreDigest := sha256.Sum256(firstCore)
	if got, want := firstEnvelope.Core.SHA256, hex.EncodeToString(coreDigest[:]); got != want {
		t.Fatalf("envelope core sha256 = %s, want %s", got, want)
	}
	if got, want := firstEnvelope.Core.SizeBytes, int64(len(firstCore)); got != want {
		t.Fatalf("envelope core size = %d, want %d", got, want)
	}
}

func TestManifestCoreSchemaV1Golden(t *testing.T) {
	_, output, args := validInvocation(t)
	if err := run(args, nil, nil); err != nil {
		t.Fatalf("run: %v", err)
	}
	core := readTestFile(t, filepath.Join(output, coreFilename))
	if got, want := string(core), schemaV1GoldenCore; got != want {
		t.Fatalf("schema v1 core changed:\ngot:\n%s\nwant:\n%s", got, want)
	}
	digest := sha256.Sum256(core)
	if got := hex.EncodeToString(digest[:]); got != schemaV1GoldenCoreSHA256 {
		t.Fatalf("schema v1 core sha256 = %s, want %s", got, schemaV1GoldenCoreSHA256)
	}
}

func TestHelpIsUsefulAndExitsSuccessfully(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	exitCode := mainExitCode([]string{"-h"}, &stdout, &stderr, time.Now)
	if exitCode != 0 {
		t.Fatalf("exit code = %d, want 0; stderr=%q", exitCode, stderr.String())
	}
	if stderr.Len() != 0 {
		t.Fatalf("stderr = %q", stderr.String())
	}
	for _, fragment := range []string{"Usage of evidencemanifest:", "-artifact", "-output-dir", "quiescent trusted root"} {
		if !strings.Contains(stdout.String(), fragment) {
			t.Fatalf("help does not contain %q:\n%s", fragment, stdout.String())
		}
	}

	stdout.Reset()
	err := run([]string{"--help"}, &stdout, time.Now)
	if !errors.Is(err, flag.ErrHelp) {
		t.Fatalf("run help error = %v, want flag.ErrHelp", err)
	}
}

func TestRunReportsStdoutWriteError(t *testing.T) {
	_, output, args := validInvocation(t)
	wantErr := errors.New("injected stdout failure")
	err := run(args, errorWriter{err: wantErr}, time.Now)
	if !errors.Is(err, wantErr) || !strings.Contains(err.Error(), "write stdout") {
		t.Fatalf("error = %v, want wrapped stdout failure", err)
	}
	if _, statErr := os.Stat(filepath.Join(output, coreFilename)); statErr != nil {
		t.Fatalf("published core missing after stdout failure: %v", statErr)
	}
}

func TestRunUsesClockOnlyForEnvelope(t *testing.T) {
	root, output, args := validInvocation(t)
	_ = root
	args = removeFlag(args, "-generated-at")
	wantTime := time.Date(2026, 7, 15, 12, 34, 56, 123, time.FixedZone("test", 3*60*60))
	if err := run(args, nil, func() time.Time { return wantTime }); err != nil {
		t.Fatalf("run: %v", err)
	}
	envelope := decodeEnvelope(t, filepath.Join(output, envelopeFilename))
	if got, want := envelope.GeneratedAt, "2026-07-15T09:34:56.000000123Z"; got != want {
		t.Fatalf("generated_at = %q, want %q", got, want)
	}
}

func TestRunRejectsInvalidAndDuplicateInputs(t *testing.T) {
	tests := []struct {
		name       string
		modifyArgs func([]string) []string
		want       string
	}{
		{
			name: "invalid revision SHA",
			modifyArgs: func(args []string) []string {
				return replaceFlagValue(args, "-revision", "baseline=ABC")
			},
			want: "40-character lowercase hexadecimal",
		},
		{
			name: "duplicate revision name",
			modifyArgs: func(args []string) []string {
				return append(args, "-revision", "baseline=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
			},
			want: "duplicate revision name",
		},
		{
			name: "duplicate parameter name",
			modifyArgs: func(args []string) []string {
				return append(args, "-parameter", "samples=5")
			},
			want: "duplicate parameter name",
		},
		{
			name: "duplicate environment name",
			modifyArgs: func(args []string) []string {
				return append(args, "-environment", "go_version=other")
			},
			want: "duplicate environment name",
		},
		{
			name: "duplicate runner name",
			modifyArgs: func(args []string) []string {
				return append(args, "-runner", "source=other")
			},
			want: "duplicate runner name",
		},
		{
			name: "invalid assignment",
			modifyArgs: func(args []string) []string {
				return append(args, "-parameter", "missing-separator")
			},
			want: "must use name=value",
		},
		{
			name: "empty value",
			modifyArgs: func(args []string) []string {
				return append(args, "-environment", "empty=")
			},
			want: "value is empty",
		},
		{
			name: "unicode control character",
			modifyArgs: func(args []string) []string {
				return append(args, "-runner", "host=line\u0085break")
			},
			want: "control characters",
		},
		{
			name: "invalid timestamp",
			modifyArgs: func(args []string) []string {
				return append(args, "-generated-at", "yesterday")
			},
			want: "must be RFC3339",
		},
		{
			name: "positional argument",
			modifyArgs: func(args []string) []string {
				return append(args, "unexpected")
			},
			want: "unexpected positional arguments",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, args := validInvocation(t)
			err := run(test.modifyArgs(args), nil, time.Now)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestRunRequiresEveryEvidenceCategory(t *testing.T) {
	for _, flagName := range []string{"-revision", "-parameter", "-environment", "-artifact", "-runner"} {
		t.Run(strings.TrimPrefix(flagName, "-"), func(t *testing.T) {
			_, _, args := validInvocation(t)
			args = removeFlag(args, flagName)
			err := run(args, nil, time.Now)
			if err == nil || !strings.Contains(err.Error(), "at least one "+flagName+" is required") {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestRunRejectsUnsafeArtifactPaths(t *testing.T) {
	tests := []struct {
		name string
		path string
		want string
	}{
		{name: "absolute", path: "/tmp/report.md", want: "must be relative"},
		{name: "escape", path: "../report.md", want: "non-escaping"},
		{name: "non-canonical dot", path: "./report.md", want: "canonical"},
		{name: "non-canonical duplicate slash", path: "nested//report.md", want: "canonical"},
		{name: "backslash", path: `nested\report.md`, want: "backslashes"},
		{name: "windows drive", path: "C:/report.md", want: "colons"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, _, args := validInvocation(t)
			args = replaceFlagValue(args, "-artifact", "report="+test.path)
			err := run(args, nil, time.Now)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestRunRejectsMissingDuplicateAndNonRegularArtifacts(t *testing.T) {
	t.Run("missing", func(t *testing.T) {
		_, _, args := validInvocation(t)
		args = replaceFlagValue(args, "-artifact", "report=missing.txt")
		err := run(args, nil, time.Now)
		if err == nil || !os.IsNotExist(unwrapPathError(err)) {
			t.Fatalf("error = %v, want missing file", err)
		}
	})

	t.Run("duplicate name", func(t *testing.T) {
		root, _, args := validInvocation(t)
		writeTestFile(t, filepath.Join(root, "other.txt"), "other")
		args = append(args, "-artifact", "report=other.txt")
		err := run(args, nil, time.Now)
		if err == nil || !strings.Contains(err.Error(), "duplicate artifact name") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("duplicate path", func(t *testing.T) {
		_, _, args := validInvocation(t)
		args = append(args, "-artifact", "copy=report.md")
		err := run(args, nil, time.Now)
		if err == nil || !strings.Contains(err.Error(), "duplicate artifact path") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("hard link", func(t *testing.T) {
		root, _, args := validInvocation(t)
		if err := os.Link(filepath.Join(root, "report.md"), filepath.Join(root, "report-hardlink.md")); err != nil {
			t.Skipf("hard links unavailable: %v", err)
		}
		args = append(args, "-artifact", "copy=report-hardlink.md")
		err := run(args, nil, time.Now)
		if err == nil || !strings.Contains(err.Error(), "same file") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("directory", func(t *testing.T) {
		root, _, args := validInvocation(t)
		if err := os.Mkdir(filepath.Join(root, "directory"), 0o755); err != nil {
			t.Fatal(err)
		}
		args = replaceFlagValue(args, "-artifact", "report=directory")
		err := run(args, nil, time.Now)
		if err == nil || !strings.Contains(err.Error(), "not a regular file") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("symlink", func(t *testing.T) {
		root, _, args := validInvocation(t)
		if err := os.Symlink("report.md", filepath.Join(root, "report-link.md")); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		args = replaceFlagValue(args, "-artifact", "report=report-link.md")
		err := run(args, nil, time.Now)
		if err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Fatalf("error = %v", err)
		}
	})

	t.Run("symlink path component", func(t *testing.T) {
		root, _, args := validInvocation(t)
		writeTestFile(t, filepath.Join(root, "actual", "nested-report.md"), "nested")
		if err := os.Symlink("actual", filepath.Join(root, "alias")); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		args = replaceFlagValue(args, "-artifact", "report=alias/nested-report.md")
		err := run(args, nil, time.Now)
		if err == nil || !strings.Contains(err.Error(), "symlink") {
			t.Fatalf("error = %v", err)
		}
	})
}

func TestRunRejectsManifestSelfHashing(t *testing.T) {
	for _, filename := range []string{coreFilename, envelopeFilename} {
		t.Run(filename, func(t *testing.T) {
			root, output, args := validInvocation(t)
			args = replaceFlagValue(args, "-artifact", "report="+filepath.ToSlash(relativeTestPath(t, root, filepath.Join(output, filename))))
			err := run(args, nil, time.Now)
			if err == nil || !strings.Contains(err.Error(), "resolves to a manifest output") {
				t.Fatalf("error = %v", err)
			}
		})
	}
}

func TestRunRejectsExistingOutputGeneration(t *testing.T) {
	_, output, args := validInvocation(t)
	coreSentinel := []byte("existing core\n")
	envelopeSentinel := []byte("existing envelope\n")
	writeTestFile(t, filepath.Join(output, coreFilename), string(coreSentinel))
	writeTestFile(t, filepath.Join(output, envelopeFilename), string(envelopeSentinel))

	if err := run(args, nil, time.Now); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("error = %v, want existing-output failure", err)
	}
	if got := readTestFile(t, filepath.Join(output, coreFilename)); !bytes.Equal(got, coreSentinel) {
		t.Fatalf("core was replaced after failure: %q", got)
	}
	if got := readTestFile(t, filepath.Join(output, envelopeFilename)); !bytes.Equal(got, envelopeSentinel) {
		t.Fatalf("envelope was replaced after failure: %q", got)
	}
}

func TestPublishGenerationCleansUpAfterSecondWriteFailure(t *testing.T) {
	parent := t.TempDir()
	output := filepath.Join(parent, "generation")
	wantErr := errors.New("injected second write failure")
	writes := 0
	writer := func(filename string, contents []byte, mode os.FileMode) error {
		writes++
		if writes == 2 {
			return wantErr
		}
		return writeSyncedFile(filename, contents, mode)
	}

	err := publishGenerationWithWriter(output, []byte("core\n"), []byte("envelope\n"), writer)
	if !errors.Is(err, wantErr) || !strings.Contains(err.Error(), envelopeFilename) {
		t.Fatalf("error = %v, want wrapped second-write error", err)
	}
	if writes != 2 {
		t.Fatalf("writes = %d, want 2", writes)
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		t.Fatalf("partial generation was published: %v", err)
	}
	entries, err := os.ReadDir(parent)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("staging directory was not cleaned up: %v", entries)
	}
}

func TestDigestFileRejectsDifferentPreInspectedIdentity(t *testing.T) {
	directory := t.TempDir()
	first := filepath.Join(directory, "first.txt")
	second := filepath.Join(directory, "second.txt")
	writeTestFile(t, first, "same-size\n")
	writeTestFile(t, second, "different\n")
	expected, err := os.Lstat(first)
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = digestFile(second, expected)
	if err == nil || !strings.Contains(err.Error(), "differs from the pre-hash path inspection") {
		t.Fatalf("error = %v, want identity mismatch", err)
	}
}

func validInvocation(t *testing.T) (root, output string, args []string) {
	t.Helper()
	root = t.TempDir()
	output = filepath.Join(root, "output")
	writeTestFile(t, filepath.Join(root, "report.md"), "report\n")
	args = []string{
		"-root", root,
		"-output-dir", output,
		"-revision", "baseline=" + testSHA,
		"-parameter", "samples=7",
		"-environment", "go_version=go1.26.5",
		"-artifact", "report=report.md",
		"-runner", "source=local",
		"-generated-at", "2026-07-15T00:00:00Z",
	}
	return root, output, args
}

func replaceFlagValue(args []string, flagName, replacement string) []string {
	result := append([]string(nil), args...)
	for index := 0; index+1 < len(result); index++ {
		if result[index] == flagName {
			result[index+1] = replacement
			return result
		}
	}
	panic("flag not found: " + flagName)
}

func removeFlag(args []string, flagName string) []string {
	result := make([]string, 0, len(args)-2)
	for index := 0; index < len(args); index++ {
		if args[index] == flagName && index+1 < len(args) {
			index++
			continue
		}
		result = append(result, args[index])
	}
	return result
}

func writeTestFile(t *testing.T, filename, contents string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(filename), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filename, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readTestFile(t *testing.T, filename string) []byte {
	t.Helper()
	contents, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}
	return contents
}

func decodeEnvelope(t *testing.T, filename string) envelopeManifest {
	t.Helper()
	var envelope envelopeManifest
	if err := json.Unmarshal(readTestFile(t, filename), &envelope); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	return envelope
}

func entryNames[T interface{ revision | namedValue }](entries []T) []string {
	result := make([]string, len(entries))
	for index, entry := range entries {
		switch value := any(entry).(type) {
		case revision:
			result[index] = value.Name
		case namedValue:
			result[index] = value.Name
		}
	}
	return result
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func equalNamedValues(left, right []namedValue) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func relativeTestPath(t *testing.T, base, target string) string {
	t.Helper()
	relative, err := filepath.Rel(base, target)
	if err != nil {
		t.Fatal(err)
	}
	return relative
}

func unwrapPathError(err error) error {
	for err != nil {
		pathError, ok := err.(*os.PathError)
		if ok {
			return pathError
		}
		unwrapper, ok := err.(interface{ Unwrap() error })
		if !ok {
			return err
		}
		err = unwrapper.Unwrap()
	}
	return nil
}

type errorWriter struct {
	err error
}

func (writer errorWriter) Write([]byte) (int, error) {
	return 0, writer.err
}
