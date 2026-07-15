package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	manifestSchemaVersion = 1
	coreFilename          = "manifest-core.json"
	envelopeFilename      = "manifest.json"
)

type repeatedFlag []string

func (values *repeatedFlag) String() string {
	return strings.Join(*values, ",")
}

func (values *repeatedFlag) Set(value string) error {
	*values = append(*values, value)
	return nil
}

type revision struct {
	Name string `json:"name"`
	SHA  string `json:"sha"`
}

type namedValue struct {
	Name  string `json:"name"`
	Value string `json:"value"`
}

type artifactEvidence struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	SHA256    string `json:"sha256"`
	SizeBytes int64  `json:"size_bytes"`
}

type coreManifest struct {
	SchemaVersion int                `json:"schema_version"`
	Revisions     []revision         `json:"revisions"`
	Parameters    []namedValue       `json:"parameters"`
	Environment   []namedValue       `json:"environment"`
	Artifacts     []artifactEvidence `json:"artifacts"`
}

type coreReference struct {
	Path      string `json:"path"`
	SHA256    string `json:"sha256"`
	SizeBytes int64  `json:"size_bytes"`
}

type envelopeManifest struct {
	SchemaVersion int           `json:"schema_version"`
	GeneratedAt   string        `json:"generated_at"`
	Runner        []namedValue  `json:"runner"`
	Core          coreReference `json:"core"`
}

func main() {
	if exitCode := mainExitCode(os.Args[1:], os.Stdout, os.Stderr, time.Now); exitCode != 0 {
		os.Exit(exitCode)
	}
}

func mainExitCode(args []string, stdout, stderr io.Writer, now func() time.Time) int {
	err := run(args, stdout, now)
	if err == nil || errors.Is(err, flag.ErrHelp) {
		return 0
	}
	if stderr == nil {
		stderr = io.Discard
	}
	_, _ = fmt.Fprintf(stderr, "evidencemanifest: %v\n", err)
	return 1
}

func run(args []string, stdout io.Writer, now func() time.Time) error {
	flags := flag.NewFlagSet("evidencemanifest", flag.ContinueOnError)
	commandOutput := stdout
	if commandOutput == nil {
		commandOutput = io.Discard
	}
	flags.SetOutput(commandOutput)

	root := flags.String("root", ".", "quiescent trusted root directory for artifact paths")
	outputDirectory := flags.String("output-dir", "", "new directory to publish with manifest-core.json and manifest.json")
	generatedAt := flags.String("generated-at", "", "optional RFC3339 timestamp for the envelope")

	var revisionFlags repeatedFlag
	var parameterFlags repeatedFlag
	var environmentFlags repeatedFlag
	var artifactFlags repeatedFlag
	var runnerFlags repeatedFlag
	flags.Var(&revisionFlags, "revision", "stable revision name=<40-character lowercase Git SHA>")
	flags.Var(&parameterFlags, "parameter", "stable assessment parameter name=value")
	flags.Var(&environmentFlags, "environment", "stable environment fact name=value")
	flags.Var(&artifactFlags, "artifact", "artifact name=relative/path (relative to -root)")
	flags.Var(&runnerFlags, "runner", "volatile runner metadata name=value")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected positional arguments: %s", strings.Join(flags.Args(), " "))
	}
	if *outputDirectory == "" {
		return errors.New("-output-dir is required")
	}

	revisions, err := parseRevisions(revisionFlags)
	if err != nil {
		return err
	}
	parameters, err := parseNamedValues("parameter", parameterFlags)
	if err != nil {
		return err
	}
	environment, err := parseNamedValues("environment", environmentFlags)
	if err != nil {
		return err
	}
	runner, err := parseNamedValues("runner", runnerFlags)
	if err != nil {
		return err
	}
	timestamp, err := envelopeTimestamp(*generatedAt, now)
	if err != nil {
		return err
	}

	rootDirectory, err := resolvedDirectory(*root)
	if err != nil {
		return fmt.Errorf("artifact root: %w", err)
	}
	manifestDirectory, err := resolveOutputDestination(*outputDirectory)
	if err != nil {
		return fmt.Errorf("output directory: %w", err)
	}
	artifacts, err := collectArtifacts(rootDirectory, manifestDirectory, artifactFlags)
	if err != nil {
		return err
	}

	core := coreManifest{
		SchemaVersion: manifestSchemaVersion,
		Revisions:     revisions,
		Parameters:    parameters,
		Environment:   environment,
		Artifacts:     artifacts,
	}
	coreJSON, err := marshalManifest(core)
	if err != nil {
		return fmt.Errorf("encode core manifest: %w", err)
	}
	coreDigest := sha256.Sum256(coreJSON)
	coreSHA := hex.EncodeToString(coreDigest[:])

	envelope := envelopeManifest{
		SchemaVersion: manifestSchemaVersion,
		GeneratedAt:   timestamp,
		Runner:        runner,
		Core: coreReference{
			Path:      coreFilename,
			SHA256:    coreSHA,
			SizeBytes: int64(len(coreJSON)),
		},
	}
	envelopeJSON, err := marshalManifest(envelope)
	if err != nil {
		return fmt.Errorf("encode manifest envelope: %w", err)
	}

	if err := publishGeneration(manifestDirectory, coreJSON, envelopeJSON); err != nil {
		return err
	}
	if stdout != nil {
		if _, err := fmt.Fprintf(stdout, "%s sha256=%s\n", coreFilename, coreSHA); err != nil {
			return fmt.Errorf("write stdout: %w", err)
		}
	}
	return nil
}

func parseRevisions(raw []string) ([]revision, error) {
	if len(raw) == 0 {
		return nil, errors.New("at least one -revision is required")
	}
	seen := make(map[string]struct{}, len(raw))
	result := make([]revision, 0, len(raw))
	for _, item := range raw {
		name, value, err := parseAssignment("revision", item)
		if err != nil {
			return nil, err
		}
		if _, exists := seen[name]; exists {
			return nil, fmt.Errorf("duplicate revision name %q", name)
		}
		if !isLowerHex(value, 40) {
			return nil, fmt.Errorf("revision %q must be a 40-character lowercase hexadecimal Git SHA", name)
		}
		seen[name] = struct{}{}
		result = append(result, revision{Name: name, SHA: value})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func parseNamedValues(kind string, raw []string) ([]namedValue, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("at least one -%s is required", kind)
	}
	seen := make(map[string]struct{}, len(raw))
	result := make([]namedValue, 0, len(raw))
	for _, item := range raw {
		name, value, err := parseAssignment(kind, item)
		if err != nil {
			return nil, err
		}
		if _, exists := seen[name]; exists {
			return nil, fmt.Errorf("duplicate %s name %q", kind, name)
		}
		seen[name] = struct{}{}
		result = append(result, namedValue{Name: name, Value: value})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func parseAssignment(kind, raw string) (string, string, error) {
	separator := strings.IndexByte(raw, '=')
	if separator <= 0 {
		return "", "", fmt.Errorf("-%s value %q must use name=value", kind, raw)
	}
	name, value := raw[:separator], raw[separator+1:]
	if !validName(name) {
		return "", "", fmt.Errorf("invalid %s name %q (use 1-64 ASCII letters, digits, '.', '_' or '-', starting with a letter)", kind, name)
	}
	if err := validateValue(value); err != nil {
		return "", "", fmt.Errorf("invalid %s value for %q: %w", kind, name, err)
	}
	return name, value, nil
}

func validName(value string) bool {
	if len(value) == 0 || len(value) > 64 || !asciiLetter(value[0]) {
		return false
	}
	for i := 1; i < len(value); i++ {
		character := value[i]
		if !asciiLetter(character) && (character < '0' || character > '9') && character != '.' && character != '_' && character != '-' {
			return false
		}
	}
	return true
}

func asciiLetter(value byte) bool {
	return value >= 'A' && value <= 'Z' || value >= 'a' && value <= 'z'
}

func validateValue(value string) error {
	if value == "" {
		return errors.New("value is empty")
	}
	if !utf8.ValidString(value) {
		return errors.New("value is not valid UTF-8")
	}
	if strings.TrimSpace(value) != value {
		return errors.New("leading or trailing whitespace is not allowed")
	}
	for _, character := range value {
		if unicode.IsControl(character) {
			return errors.New("control characters are not allowed")
		}
	}
	return nil
}

func isLowerHex(value string, length int) bool {
	if len(value) != length {
		return false
	}
	for i := range value {
		if value[i] < '0' || value[i] > '9' {
			if value[i] < 'a' || value[i] > 'f' {
				return false
			}
		}
	}
	return true
}

func envelopeTimestamp(value string, now func() time.Time) (string, error) {
	if value == "" {
		if now == nil {
			return "", errors.New("clock is unavailable")
		}
		return now().UTC().Format(time.RFC3339Nano), nil
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return "", fmt.Errorf("-generated-at must be RFC3339: %w", err)
	}
	return parsed.UTC().Format(time.RFC3339Nano), nil
}

func resolvedDirectory(directory string) (string, error) {
	if directory == "" {
		return "", errors.New("path is empty")
	}
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(absolute)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fmt.Errorf("%q is not a directory", directory)
	}
	return resolved, nil
}

func resolveOutputDestination(directory string) (string, error) {
	if directory == "" {
		return "", errors.New("path is empty")
	}
	absolute, err := filepath.Abs(directory)
	if err != nil {
		return "", err
	}
	parent := filepath.Dir(absolute)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return "", err
	}
	resolvedParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return "", err
	}
	parentInfo, err := os.Stat(resolvedParent)
	if err != nil {
		return "", err
	}
	if !parentInfo.IsDir() {
		return "", fmt.Errorf("parent %q is not a directory", parent)
	}
	destination := filepath.Join(resolvedParent, filepath.Base(absolute))
	if err := requireAbsent(destination); err != nil {
		return "", err
	}
	return destination, nil
}

func requireAbsent(filename string) error {
	_, err := os.Lstat(filename)
	if err == nil {
		return fmt.Errorf("%q already exists", filename)
	}
	if !os.IsNotExist(err) {
		return err
	}
	return nil
}

// Artifact containment uses portable path checks and repeated identity checks,
// not platform-specific openat traversal. The trusted parent must keep the
// artifact root quiescent while this command runs; concurrent path mutation is
// outside this command's security model and causes a best-effort failure.
func collectArtifacts(rootDirectory, manifestDirectory string, raw []string) ([]artifactEvidence, error) {
	if len(raw) == 0 {
		return nil, errors.New("at least one -artifact is required")
	}
	seenNames := make(map[string]struct{}, len(raw))
	seenPaths := make(map[string]string, len(raw))
	seenFiles := make([]struct {
		name string
		info os.FileInfo
	}, 0, len(raw))
	result := make([]artifactEvidence, 0, len(raw))
	for _, item := range raw {
		name, artifactPath, err := parseAssignment("artifact", item)
		if err != nil {
			return nil, err
		}
		if _, exists := seenNames[name]; exists {
			return nil, fmt.Errorf("duplicate artifact name %q", name)
		}
		canonicalPath, err := validateArtifactPath(artifactPath)
		if err != nil {
			return nil, fmt.Errorf("artifact %q: %w", name, err)
		}
		if previous, exists := seenPaths[canonicalPath]; exists {
			return nil, fmt.Errorf("duplicate artifact path %q for %q and %q", canonicalPath, previous, name)
		}
		intendedPath := filepath.Join(rootDirectory, filepath.FromSlash(canonicalPath))
		if isManifestOutput(intendedPath, manifestDirectory) {
			return nil, fmt.Errorf("artifact %q resolves to a manifest output", name)
		}
		absolutePath, fileInfo, err := regularArtifactPath(rootDirectory, canonicalPath)
		if err != nil {
			return nil, fmt.Errorf("artifact %q (%s): %w", name, canonicalPath, err)
		}
		if isManifestOutput(absolutePath, manifestDirectory) {
			return nil, fmt.Errorf("artifact %q resolves to a manifest output", name)
		}
		for _, previous := range seenFiles {
			if os.SameFile(fileInfo, previous.info) {
				return nil, fmt.Errorf("artifact %q resolves to the same file as artifact %q", name, previous.name)
			}
		}
		digest, size, err := digestFile(absolutePath, fileInfo)
		if err != nil {
			return nil, fmt.Errorf("artifact %q (%s): %w", name, canonicalPath, err)
		}
		postPath, postInfo, err := regularArtifactPath(rootDirectory, canonicalPath)
		if err != nil || !samePath(absolutePath, postPath) || !sameFileSnapshot(fileInfo, postInfo) {
			if err != nil {
				return nil, fmt.Errorf("artifact %q (%s) changed after hashing: %w", name, canonicalPath, err)
			}
			return nil, fmt.Errorf("artifact %q (%s) changed after hashing", name, canonicalPath)
		}
		seenNames[name] = struct{}{}
		seenPaths[canonicalPath] = name
		seenFiles = append(seenFiles, struct {
			name string
			info os.FileInfo
		}{name: name, info: fileInfo})
		result = append(result, artifactEvidence{
			Name:      name,
			Path:      canonicalPath,
			SHA256:    digest,
			SizeBytes: size,
		})
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}

func validateArtifactPath(value string) (string, error) {
	if err := validateValue(value); err != nil {
		return "", err
	}
	if strings.ContainsRune(value, '\\') {
		return "", errors.New("backslashes are not allowed; use a portable slash-separated path")
	}
	if strings.ContainsRune(value, ':') {
		return "", errors.New("colons are not allowed in portable artifact paths")
	}
	if path.IsAbs(value) {
		return "", errors.New("path must be relative to -root")
	}
	cleaned := path.Clean(value)
	if cleaned == "." || cleaned != value || cleaned == ".." || strings.HasPrefix(cleaned, "../") {
		return "", errors.New("path must be a canonical non-escaping relative path")
	}
	return cleaned, nil
}

func regularArtifactPath(rootDirectory, relativePath string) (string, os.FileInfo, error) {
	current := rootDirectory
	parts := strings.Split(relativePath, "/")
	var finalInfo os.FileInfo
	for index, part := range parts {
		current = filepath.Join(current, filepath.FromSlash(part))
		info, err := os.Lstat(current)
		if err != nil {
			return "", nil, err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return "", nil, errors.New("symlink artifacts and symlink path components are not allowed")
		}
		if index < len(parts)-1 && !info.IsDir() {
			return "", nil, errors.New("non-directory artifact path component")
		}
		if index == len(parts)-1 && !info.Mode().IsRegular() {
			return "", nil, errors.New("artifact is not a regular file")
		}
		finalInfo = info
	}
	return current, finalInfo, nil
}

func samePath(left, right string) bool {
	return filepath.Clean(left) == filepath.Clean(right)
}

func isManifestOutput(artifactPath, manifestDirectory string) bool {
	for _, filename := range []string{coreFilename, envelopeFilename} {
		outputPath := filepath.Join(manifestDirectory, filename)
		if samePath(artifactPath, outputPath) {
			return true
		}
	}
	return false
}

func digestFile(filename string, expected os.FileInfo) (string, int64, error) {
	file, err := os.Open(filename)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()

	opened, err := file.Stat()
	if err != nil {
		return "", 0, err
	}
	if !opened.Mode().IsRegular() {
		return "", 0, errors.New("artifact is not a regular file")
	}
	if !sameFileSnapshot(expected, opened) {
		return "", 0, errors.New("opened artifact differs from the pre-hash path inspection")
	}
	digester := sha256.New()
	bytesRead, err := io.Copy(digester, file)
	if err != nil {
		return "", 0, err
	}
	after, err := file.Stat()
	if err != nil {
		return "", 0, err
	}
	if bytesRead != opened.Size() || !sameFileSnapshot(opened, after) {
		return "", 0, errors.New("artifact changed while it was being hashed")
	}
	return hex.EncodeToString(digester.Sum(nil)), bytesRead, nil
}

func sameFileSnapshot(left, right os.FileInfo) bool {
	return left != nil && right != nil &&
		left.Mode().IsRegular() && right.Mode().IsRegular() &&
		os.SameFile(left, right) &&
		left.Size() == right.Size() &&
		left.ModTime().Equal(right.ModTime())
}

func marshalManifest(value any) ([]byte, error) {
	encoded, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(encoded, '\n'), nil
}

type generationFileWriter func(string, []byte, os.FileMode) error

func publishGeneration(outputDirectory string, coreJSON, envelopeJSON []byte) error {
	return publishGenerationWithWriter(outputDirectory, coreJSON, envelopeJSON, writeSyncedFile)
}

func publishGenerationWithWriter(outputDirectory string, coreJSON, envelopeJSON []byte, writeFile generationFileWriter) error {
	if writeFile == nil {
		return errors.New("generation file writer is unavailable")
	}
	if err := requireAbsent(outputDirectory); err != nil {
		return fmt.Errorf("output directory: %w", err)
	}
	parentDirectory := filepath.Dir(outputDirectory)
	stagingDirectory, err := os.MkdirTemp(parentDirectory, ".evidencemanifest-staging-*")
	if err != nil {
		return fmt.Errorf("create staging directory: %w", err)
	}
	published := false
	defer func() {
		if !published {
			_ = os.RemoveAll(stagingDirectory)
		}
	}()

	if err := os.Chmod(stagingDirectory, 0o755); err != nil {
		return fmt.Errorf("set staging directory mode: %w", err)
	}
	if err := writeFile(filepath.Join(stagingDirectory, coreFilename), coreJSON, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", coreFilename, err)
	}
	if err := writeFile(filepath.Join(stagingDirectory, envelopeFilename), envelopeJSON, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", envelopeFilename, err)
	}
	if err := syncDirectory(stagingDirectory); err != nil {
		return fmt.Errorf("sync staging directory: %w", err)
	}

	// Publishing relies on a quiescent trusted parent directory. The standard
	// library has no portable atomic rename-without-replace operation, so the
	// second absence check detects ordinary races but is not an adversarial
	// no-clobber primitive on every platform.
	if err := requireAbsent(outputDirectory); err != nil {
		return fmt.Errorf("output directory: %w", err)
	}
	if err := os.Rename(stagingDirectory, outputDirectory); err != nil {
		return fmt.Errorf("publish generation: %w", err)
	}
	published = true
	if err := syncDirectory(parentDirectory); err != nil {
		return fmt.Errorf("sync output parent: %w", err)
	}
	return nil
}

func writeSyncedFile(filename string, contents []byte, mode os.FileMode) (err error) {
	file, err := os.OpenFile(filename, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := file.Close(); err == nil && closeErr != nil {
			err = closeErr
		}
	}()
	written, err := file.Write(contents)
	if err != nil {
		return err
	}
	if written != len(contents) {
		return io.ErrShortWrite
	}
	if err := file.Sync(); err != nil {
		return err
	}
	return nil
}

func syncDirectory(directory string) error {
	file, err := os.Open(directory)
	if err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}
