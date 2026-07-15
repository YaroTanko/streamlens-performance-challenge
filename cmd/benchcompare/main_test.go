package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestParseBenchmarksAndMedian(t *testing.T) {
	input := strings.NewReader(framed(3, "Analyze/Balanced"))

	parsed, err := parseBenchmarks(input)
	if err != nil {
		t.Fatalf("parseBenchmarks() error: %v", err)
	}
	got := aggregateSamples(parsed)["Analyze/Balanced"]
	if got[metricTime] != 1000 || got[metricBytes] != 200 || got[metricAllocs] != 10 {
		t.Fatalf("median aggregate = %#v", got)
	}
}

func TestParseBenchmarksRejectsInvalidFraming(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"outside row", "BenchmarkAnalyze/Balanced-2 1 1 ns/op 1 B/op 1 allocs/op\n", "outside"},
		{"missing end", sampleBegin(1, "token") + validSampleBody(benchmarkRow("Analyze/Balanced", 1, 1, 1)), "missing an end"},
		{"end without begin", "@@BENCHCOMPARE SAMPLE END 1 token\n", "missing or out-of-order"},
		{"nested begin", sampleBegin(1, "token") + sampleBegin(1, "token"), "out-of-order"},
		{"out of order", framedSample(2, "token", validSampleBody(benchmarkRow("Analyze/Balanced", 1, 1, 1))), "out-of-order"},
		{"duplicate sample", framedSample(1, "token", validSampleBody(benchmarkRow("Analyze/Balanced", 1, 1, 1))) + sampleBegin(1, "token"), "out-of-order"},
		{"duplicate row", framedSample(1, "token", validSampleBody(benchmarkRow("Analyze/Balanced", 1, 1, 1)+benchmarkRow("Analyze/Balanced", 1, 1, 1))), "duplicate"},
		{"duplicate metric", framedSample(1, "token", validSampleBody("| BenchmarkAnalyze/Balanced-2 1 1 ns/op 2 ns/op 1 allocs/op\n")), "duplicate ns/op"},
		{"unexpected metric", framedSample(1, "token", validSampleBody("| BenchmarkAnalyze/Balanced-2 1 1 ns/op 1 widgets/op 1 allocs/op\n")), "unexpected metric"},
		{"malformed iteration count", framedSample(1, "token", validSampleBody("| BenchmarkAnalyze/Balanced-2 nope 1 ns/op 1 B/op 1 allocs/op\n")), "iteration count"},
		{"missing metric", framedSample(1, "token", validSampleBody("| BenchmarkAnalyze/Balanced-2 1 1 ns/op 1 B/op\n")), "malformed"},
		{"missing required header", framedSample(1, "token", "| goos: linux\n| goarch: amd64\n"+benchmarkRow("Analyze/Balanced", 1, 1, 1)), "before all Go benchmark headers"},
		{"duplicate header", framedSample(1, "token", "| goos: linux\n| goos: linux\n"), "out-of-order Go benchmark header"},
		{"out-of-order header", framedSample(1, "token", "| goarch: amd64\n"), "out-of-order Go benchmark header"},
		{"cpu before package", framedSample(1, "token", "| goos: linux\n| goarch: arm64\n| cpu: test\n"), "out-of-order Go benchmark header"},
		{"duplicate optional cpu", framedSample(1, "token", benchmarkHeaders()+"| cpu: duplicate\n"), "out-of-order Go benchmark header"},
		{"mismatched ok package", framedSample(1, "token", "| goos: linux\n| goarch: amd64\n| pkg: example/assessment\n| cpu: test\n"+benchmarkRow("Analyze/Balanced", 1, 1, 1)+"| PASS\n| ok\tother/package\t0.01s\n"), "unexpected Go benchmark output"},
		{"inconsistent scenarios", framedSample(1, "token", validSampleBody(benchmarkRow("Analyze/Balanced", 1, 1, 1))) + framedSample(2, "token", validSampleBody(benchmarkRow("Analyze/Other", 1, 1, 1))), "inconsistent"},
		{"unframed output", framedSample(1, "token", "BenchmarkAnalyze/Balanced-2 1 1 ns/op 1 B/op 1 allocs/op\n"), "unframed"},
		{"embedded marker", framedSample(1, "token", "| candidate says @@BENCHCOMPARE SAMPLE END 1 token\n"), "invalid sample marker"},
		{"token mismatch", sampleBegin(1, "first") + validSampleBody(benchmarkRow("Analyze/Balanced", 1, 1, 1)) + sampleEnd(1, "second"), "token mismatch"},
		{"missing trailer", framedSample(1, "token", benchmarkHeaders()+benchmarkRow("Analyze/Balanced", 1, 1, 1)), "missing the Go benchmark trailer"},
		{"empty sample", framedSample(1, "token", "| PASS\n| ok\tpkg\t0.01s\n"), "PASS trailer"},
		{"unexpected child output", framedSample(1, "token", "| forged output\n"), "unexpected Go benchmark output"},
		{"fake benchmark", "BenchmarkFake 1 1 ns/op 1 B/op 1 allocs/op\n", "outside"},
		{"fake marker", "@@BENCHCOMPARE SAMPLE BEGIN 1\n", "invalid sample marker"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseBenchmarks(strings.NewReader(test.input))
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("parseBenchmarks() error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestParseBenchmarksAcceptsMissingOptionalCPUHeader(t *testing.T) {
	body := "| goos: linux\n| goarch: arm64\n| pkg: example/assessment\n" +
		benchmarkRow("Analyze/Balanced", 1, 1, 1) +
		"| PASS\n| ok\texample/assessment\t0.01s\n"
	parsed, err := parseFramedBenchmarks(strings.NewReader(framedSample(1, "token", body)))
	if err != nil {
		t.Fatalf("parseFramedBenchmarks() error: %v", err)
	}
	if parsed.headers["goarch"] != "arm64" {
		t.Fatalf("goarch header = %q", parsed.headers["goarch"])
	}
	if _, found := parsed.headers["cpu"]; found {
		t.Fatal("parser synthesized an absent optional cpu header")
	}
}

func TestValidateFramingRejectsProtocolMismatch(t *testing.T) {
	baseline, err := parseFramedBenchmarks(strings.NewReader(framed(2, "Analyze/Balanced")))
	if err != nil {
		t.Fatal(err)
	}
	candidate, err := parseFramedBenchmarks(strings.NewReader(framed(1, "Analyze/Balanced")))
	if err != nil {
		t.Fatal(err)
	}
	if err := validateFraming(baseline, candidate, 1); err == nil || !strings.Contains(err.Error(), "count") {
		t.Fatalf("count validation error = %v", err)
	}
	candidate, err = parseFramedBenchmarks(strings.NewReader(framedWithIDs([]int{1, 3}, "Analyze/Balanced")))
	if err != nil {
		if !strings.Contains(err.Error(), "out-of-order") {
			t.Fatal(err)
		}
	} else {
		t.Fatal("non-sequential IDs were accepted")
	}
	candidate, err = parseFramedBenchmarks(strings.NewReader(framed(2, "Analyze/Balanced")))
	if err != nil {
		t.Fatal(err)
	}
	candidate.sampleIDs[0] = 2
	if err := validateFraming(baseline, candidate, 1); err == nil || !strings.Contains(err.Error(), "ID") {
		t.Fatalf("ID validation error = %v", err)
	}
	candidate.sampleIDs[0] = 1
	candidate.token = "different"
	if err := validateFraming(baseline, candidate, 1); err == nil || !strings.Contains(err.Error(), "token") {
		t.Fatalf("token validation error = %v", err)
	}
	candidate.token = baseline.token
	candidate.headers["cpu"] = "different"
	if err := validateFraming(baseline, candidate, 1); err == nil || !strings.Contains(err.Error(), "header") {
		t.Fatalf("header validation error = %v", err)
	}
	if err := validateFraming(baseline, baseline, 3); err == nil || !strings.Contains(err.Error(), "at least 3") {
		t.Fatalf("minimum-sample validation error = %v", err)
	}
}

func framed(count int, scenario string) string {
	ids := make([]int, count)
	for i := range ids {
		ids[i] = i + 1
	}
	return framedWithIDs(ids, scenario)
}

func framedWithIDs(ids []int, scenario string) string {
	values := [...][3]int{
		{1000, 200, 10},
		{900, 180, 9},
		{5000, 900, 90},
	}
	var output strings.Builder
	for index, id := range ids {
		value := values[index%len(values)]
		output.WriteString(framedSample(
			id,
			"token",
			validSampleBody(benchmarkRow(scenario, value[0], value[1], value[2])),
		))
	}
	return output.String()
}

func sampleBegin(id int, token string) string {
	return fmt.Sprintf("@@BENCHCOMPARE SAMPLE BEGIN %d %s\n", id, token)
}

func sampleEnd(id int, token string) string {
	return fmt.Sprintf("@@BENCHCOMPARE SAMPLE END %d %s\n", id, token)
}

func framedSample(id int, token, body string) string {
	return sampleBegin(id, token) + body + sampleEnd(id, token)
}

func benchmarkRow(scenario string, nanoseconds, bytes, allocations int) string {
	return fmt.Sprintf(
		"| Benchmark%s-2 1 %d ns/op %d B/op %d allocs/op\n",
		scenario,
		nanoseconds,
		bytes,
		allocations,
	)
}

func validSampleBody(row string) string {
	return benchmarkHeaders() + row + "| PASS\n| ok\texample/assessment\t0.01s\n"
}

func benchmarkHeaders() string {
	return "| goos: linux\n| goarch: amd64\n| pkg: example/assessment\n| cpu: test\n"
}

func TestCompareRejectsInjectedBenchmarkScenario(t *testing.T) {
	baseline, err := parseFramedBenchmarks(strings.NewReader(framed(3, "Analyze/Balanced")))
	if err != nil {
		t.Fatal(err)
	}
	candidate, err := parseFramedBenchmarks(strings.NewReader(framed(3, "Analyze/Fake")))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := compare(baseline.values, candidate.values, 3); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Fatalf("compare() error = %v, want missing benchmark", err)
	}
}

func TestRunnerPreservesFailedSampleDiagnostics(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("runner requires Bash")
	}

	temporary := t.TempDir()
	fakeBin := filepath.Join(temporary, "bin")
	baseline := filepath.Join(temporary, "baseline")
	candidate := filepath.Join(temporary, "candidate")
	output := filepath.Join(temporary, "results")
	for _, directory := range []string{fakeBin, baseline, candidate, output} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	staleFailure := filepath.Join(output, "candidate-sample-5-failed.txt")
	if err := os.WriteFile(staleFailure, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	fakeGo := []byte("#!/usr/bin/env bash\nif [[ ${1:-} == version ]]; then echo 'go version go-test'; exit 0; fi\necho 'sentinel benchmark failure'\nexit 17\n")
	if err := os.WriteFile(filepath.Join(fakeBin, "go"), fakeGo, 0o755); err != nil {
		t.Fatal(err)
	}

	command := exec.Command(
		"bash",
		filepath.Join("..", "..", "scripts", "run-benchmarks.sh"),
		baseline,
		candidate,
		output,
	)
	command.Env = append(os.Environ(), "PATH="+fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"), "BENCH_SAMPLES=5")
	combined, err := command.CombinedOutput()
	if exitError, ok := err.(*exec.ExitError); !ok || exitError.ExitCode() != 17 {
		t.Fatalf("runner error = %v, output:\n%s", err, combined)
	}
	if !strings.Contains(string(combined), "sentinel benchmark failure") {
		t.Fatalf("runner hid failure diagnostics:\n%s", combined)
	}
	failurePath := filepath.Join(output, "baseline-sample-1-failed.txt")
	failure, readErr := os.ReadFile(failurePath)
	if readErr != nil || !strings.Contains(string(failure), "sentinel benchmark failure") {
		t.Fatalf("failure artifact = %q, error = %v", failure, readErr)
	}
	if temporaryFiles, globErr := filepath.Glob(filepath.Join(output, "*.tmp")); globErr != nil || len(temporaryFiles) != 0 {
		t.Fatalf("temporary files = %v, error = %v", temporaryFiles, globErr)
	}
	if _, statErr := os.Stat(staleFailure); !os.IsNotExist(statErr) {
		t.Fatalf("stale failure artifact was not removed: %v", statErr)
	}
}

func TestRunnerProducesParseableFramedSamples(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("runner requires Bash")
	}

	temporary := t.TempDir()
	fakeBin := filepath.Join(temporary, "bin")
	baselineDirectory := filepath.Join(temporary, "baseline")
	candidateDirectory := filepath.Join(temporary, "candidate")
	output := filepath.Join(temporary, "results")
	for _, directory := range []string{fakeBin, baselineDirectory, candidateDirectory} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	fakeGo := []byte(`#!/usr/bin/env bash
if [[ ${1:-} == version ]]; then
  echo 'go version go-test'
  exit 0
fi
printf '%s\n' \
  'goos: linux' \
  'goarch: amd64' \
  'pkg: example/assessment' \
  'cpu: test' \
  'BenchmarkAnalyze/Balanced-2 1 100 ns/op 20 B/op 2 allocs/op' \
  'BenchmarkAnalyze/HighCardinality-2 1 200 ns/op 30 B/op 3 allocs/op' \
  'BenchmarkAnalyze/MostlyFiltered-2 1 300 ns/op 40 B/op 4 allocs/op' \
  'PASS' \
  $'ok\texample/assessment\t0.01s'
`)
	if err := os.WriteFile(filepath.Join(fakeBin, "go"), fakeGo, 0o755); err != nil {
		t.Fatal(err)
	}

	command := exec.Command(
		"bash",
		filepath.Join("..", "..", "scripts", "run-benchmarks.sh"),
		baselineDirectory,
		candidateDirectory,
		output,
	)
	command.Env = append(os.Environ(), "PATH="+fakeBin+string(os.PathListSeparator)+os.Getenv("PATH"), "BENCH_SAMPLES=5")
	if combined, err := command.CombinedOutput(); err != nil {
		t.Fatalf("runner error = %v, output:\n%s", err, combined)
	}

	baseline, err := parseFile(filepath.Join(output, "baseline.txt"))
	if err != nil {
		t.Fatalf("parse baseline: %v", err)
	}
	candidate, err := parseFile(filepath.Join(output, "candidate.txt"))
	if err != nil {
		t.Fatalf("parse candidate: %v", err)
	}
	if err := validateFraming(baseline, candidate, 5); err != nil {
		t.Fatalf("validate framing: %v", err)
	}
	if len(baseline.values) != 3 || len(candidate.values) != 3 {
		t.Fatalf("scenario counts = baseline %d, candidate %d", len(baseline.values), len(candidate.values))
	}
}

func TestCompareAssignsIndependentAndOverallTiers(t *testing.T) {
	baseline := sampleSet(100, 100, 100)
	candidate := sampleSet(15, 45, 75)

	result, err := compare(baseline, candidate, 3)
	if err != nil {
		t.Fatalf("compare() error: %v", err)
	}
	if !result.passed {
		t.Fatalf("passed = false, reasons: %v", result.reasons)
	}
	if result.tiers[metricTime] != "Staff" {
		t.Errorf("time tier = %q", result.tiers[metricTime])
	}
	if result.tiers[metricBytes] != "Senior" {
		t.Errorf("bytes tier = %q", result.tiers[metricBytes])
	}
	if result.tiers[metricAllocs] != "Middle" {
		t.Errorf("allocs tier = %q", result.tiers[metricAllocs])
	}
	if result.overallTier != "Staff" {
		t.Errorf("overall tier = %q", result.overallTier)
	}
}

func TestCompareRejectsRegressionOverLimit(t *testing.T) {
	baseline := sampleSet(100, 100, 100)
	candidate := sampleSet(50, 121, 100)

	result, err := compare(baseline, candidate, 3)
	if err != nil {
		t.Fatalf("compare() error: %v", err)
	}
	if result.passed {
		t.Fatal("passed = true, want false")
	}
	if !strings.Contains(strings.Join(result.reasons, " "), "regressed") {
		t.Fatalf("reasons = %v", result.reasons)
	}
}

func TestCompareRejectsPerScenarioRegressionOverLimit(t *testing.T) {
	baseline := sampleSetWithScenarios(
		[3]float64{100, 100, 100},
		[3]float64{100, 100, 100},
	)
	candidate := sampleSetWithScenarios(
		[3]float64{60, 60, 60},
		[3]float64{140, 60, 60},
	)

	result, err := compare(baseline, candidate, 3)
	if err != nil {
		t.Fatalf("compare() error: %v", err)
	}
	if result.passed {
		t.Fatal("passed = true, want false")
	}
	reasons := strings.Join(result.reasons, " ")
	if !strings.Contains(reasons, "HighCardinality ns/op regressed by 40.00%") {
		t.Fatalf("reasons = %v", result.reasons)
	}
}

func TestCompareRequiresMinimumSampleCount(t *testing.T) {
	baseline := sampleSet(100, 100, 100)
	candidate := sampleSet(80, 80, 80)
	candidate["Analyze/Balanced"][metricTime] = candidate["Analyze/Balanced"][metricTime][:2]

	_, err := compare(baseline, candidate, 3)
	if err == nil || !strings.Contains(err.Error(), "at least 3 samples") {
		t.Fatalf("compare() error = %v", err)
	}
}

func TestCompareAllowsZeroCandidateMetric(t *testing.T) {
	baseline := sampleSet(100, 100, 100)
	candidate := sampleSet(100, 0, 100)

	result, err := compare(baseline, candidate, 3)
	if err != nil {
		t.Fatalf("compare() error: %v", err)
	}
	if result.geomean[metricBytes] != 100 || result.tiers[metricBytes] != "Staff" {
		t.Fatalf("bytes improvement = %v, tier = %q", result.geomean[metricBytes], result.tiers[metricBytes])
	}
}

func TestCompareAllowsExactAggregateBoundaries(t *testing.T) {
	baseline := sampleSet(100, 100, 100)
	candidate := sampleSet(80, 120, 100)

	result, err := compare(baseline, candidate, 3)
	if err != nil {
		t.Fatalf("compare() error: %v", err)
	}
	if !result.passed {
		t.Fatalf("passed = false, reasons: %v", result.reasons)
	}
	if result.tiers[metricTime] != "Middle" {
		t.Fatalf("time tier = %q", result.tiers[metricTime])
	}
}

func TestCompareAllowsExactPerScenarioRegressionBoundary(t *testing.T) {
	baseline := sampleSetWithScenarios(
		[3]float64{100, 100, 100},
		[3]float64{100, 100, 100},
	)
	candidate := sampleSetWithScenarios(
		[3]float64{70, 50, 100},
		[3]float64{130, 50, 100},
	)

	result, err := compare(baseline, candidate, 3)
	if err != nil {
		t.Fatalf("compare() error: %v", err)
	}
	if !result.passed {
		t.Fatalf("passed = false, reasons: %v", result.reasons)
	}
}

func sampleSet(timeValue, byteValue, allocValue float64) samples {
	return samples{
		"Analyze/Balanced": {
			metricTime:   {timeValue, timeValue, timeValue},
			metricBytes:  {byteValue, byteValue, byteValue},
			metricAllocs: {allocValue, allocValue, allocValue},
		},
	}
}

func sampleSetWithScenarios(balanced, highCardinality [3]float64) samples {
	result := make(samples)
	for name, values := range map[string][3]float64{
		"Analyze/Balanced":        balanced,
		"Analyze/HighCardinality": highCardinality,
	} {
		result[name] = map[string][]float64{
			metricTime:   {values[0], values[0], values[0]},
			metricBytes:  {values[1], values[1], values[1]},
			metricAllocs: {values[2], values[2], values[2]},
		}
	}
	return result
}
