// Command benchcompare compares repeated Go benchmark samples and writes the
// assessment result as Markdown.
package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	metricTime       = "ns/op"
	metricBytes      = "B/op"
	metricAllocs     = "allocs/op"
	thresholdEpsilon = 1e-9
)

var metricOrder = []string{metricTime, metricBytes, metricAllocs}
var requiredBenchmarkHeaderOrder = []string{"goos", "goarch", "pkg"}
var benchmarkHeaderOrder = []string{"goos", "goarch", "pkg", "cpu"}

type samples map[string]map[string][]float64

type benchmarkData struct {
	values    samples
	sampleIDs []int
	token     string
	headers   map[string]string
}

type aggregate map[string]map[string]float64

type comparison struct {
	baseline    aggregate
	candidate   aggregate
	improvement map[string]map[string]float64
	geomean     map[string]float64
	tiers       map[string]string
	overallTier string
	passed      bool
	reasons     []string
}

func main() {
	baselinePath := flag.String("baseline", "", "path to immutable baseline benchmark output")
	candidatePath := flag.String("candidate", "", "path to candidate benchmark output")
	outputPath := flag.String("output", "", "optional path for the Markdown report")
	minimumSamples := flag.Int("min-samples", 5, "minimum samples required for every scenario")
	flag.Parse()

	if *baselinePath == "" || *candidatePath == "" {
		flag.Usage()
		os.Exit(2)
	}

	report, passed, err := compareFiles(*baselinePath, *candidatePath, *minimumSamples)
	if err != nil {
		report = fmt.Sprintf("# Benchmark comparison\n\n❌ Comparison failed: %s\n", err)
	}

	if writeErr := writeReport(os.Stdout, *outputPath, report); writeErr != nil {
		fmt.Fprintf(os.Stderr, "write report: %v\n", writeErr)
		os.Exit(2)
	}
	if err != nil {
		os.Exit(2)
	}
	if !passed {
		os.Exit(1)
	}
}

func compareFiles(baselinePath, candidatePath string, minimumSamples int) (string, bool, error) {
	if minimumSamples < 1 {
		return "", false, errors.New("min-samples must be positive")
	}

	baseline, err := parseFile(baselinePath)
	if err != nil {
		return "", false, fmt.Errorf("parse baseline: %w", err)
	}
	candidate, err := parseFile(candidatePath)
	if err != nil {
		return "", false, fmt.Errorf("parse candidate: %w", err)
	}

	if err := validateFraming(baseline, candidate, minimumSamples); err != nil {
		return "", false, err
	}
	result, err := compare(baseline.values, candidate.values, minimumSamples)
	if err != nil {
		return "", false, err
	}
	return result.markdown(), result.passed, nil
}

func parseFile(path string) (benchmarkData, error) {
	file, err := os.Open(path)
	if err != nil {
		return benchmarkData{}, err
	}
	defer file.Close()

	return parseFramedBenchmarks(file)
}

func parseBenchmarks(input io.Reader) (samples, error) {
	parsed, err := parseFramedBenchmarks(input)
	if err != nil {
		return nil, err
	}
	return parsed.values, nil
}

func parseFramedBenchmarks(input io.Reader) (benchmarkData, error) {
	parsed := benchmarkData{values: make(samples)}
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	inSample := false
	expectedSample := 1
	seenInSample := make(map[string]bool)
	var sampleScenarios map[string]bool
	var expectedScenarios map[string]bool
	var sampleHeaders map[string]string
	seenBenchmark := false
	seenPass := false
	seenOK := false
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "@@BENCHCOMPARE") {
			fields := strings.Fields(line)
			if len(fields) != 5 || fields[0] != "@@BENCHCOMPARE" || fields[1] != "SAMPLE" || (fields[2] != "BEGIN" && fields[2] != "END") {
				return benchmarkData{}, errors.New("invalid sample marker")
			}
			id, parseErr := strconv.Atoi(fields[3])
			if parseErr != nil || id < 1 || fields[4] == "" {
				return benchmarkData{}, errors.New("invalid sample marker")
			}
			if parsed.token == "" {
				parsed.token = fields[4]
			} else if fields[4] != parsed.token {
				return benchmarkData{}, errors.New("sample marker token mismatch")
			}
			if fields[2] == "BEGIN" {
				if inSample || id != expectedSample {
					return benchmarkData{}, fmt.Errorf("out-of-order or duplicate sample %d", id)
				}
				inSample = true
				seenInSample = make(map[string]bool)
				sampleScenarios = make(map[string]bool)
				sampleHeaders = make(map[string]string, len(benchmarkHeaderOrder))
				seenBenchmark = false
				seenPass = false
				seenOK = false
				continue
			}
			if !inSample || id != expectedSample || len(seenInSample) == 0 {
				return benchmarkData{}, fmt.Errorf("missing or out-of-order sample %d", id)
			}
			if !seenPass || !seenOK {
				return benchmarkData{}, fmt.Errorf("sample %d is missing the Go benchmark trailer", id)
			}
			if !hasRequiredBenchmarkHeaders(sampleHeaders) {
				return benchmarkData{}, fmt.Errorf("sample %d is missing Go benchmark headers", id)
			}
			if parsed.headers == nil {
				parsed.headers = cloneStrings(sampleHeaders)
			} else if !sameStrings(parsed.headers, sampleHeaders) {
				return benchmarkData{}, errors.New("inconsistent Go benchmark headers between samples")
			}
			if expectedScenarios == nil {
				expectedScenarios = cloneSet(sampleScenarios)
			} else if !sameSet(expectedScenarios, sampleScenarios) {
				return benchmarkData{}, errors.New("inconsistent scenario set between samples")
			}
			inSample = false
			parsed.sampleIDs = append(parsed.sampleIDs, id)
			expectedSample++
			continue
		}
		if !inSample {
			if strings.TrimSpace(line) != "" {
				return benchmarkData{}, errors.New("output outside a sample")
			}
			continue
		}
		if !strings.HasPrefix(line, "| ") {
			return benchmarkData{}, errors.New("unframed output inside a sample")
		}
		line = strings.TrimPrefix(line, "| ")
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if !strings.HasPrefix(fields[0], "Benchmark") {
			switch {
			case isBenchmarkHeader(line):
				if seenBenchmark || seenPass || seenOK {
					return benchmarkData{}, errors.New("benchmark header appears after benchmark rows")
				}
				key, value, ok := parseBenchmarkHeader(line)
				if !ok || !validNextBenchmarkHeader(sampleHeaders, key) {
					return benchmarkData{}, fmt.Errorf("unexpected or out-of-order Go benchmark header: %q", line)
				}
				sampleHeaders[key] = value
			case line == "PASS":
				if !seenBenchmark || seenPass || seenOK {
					return benchmarkData{}, errors.New("invalid Go benchmark PASS trailer")
				}
				seenPass = true
			case isBenchmarkOK(line, sampleHeaders["pkg"]):
				if !seenPass || seenOK {
					return benchmarkData{}, errors.New("invalid Go benchmark ok trailer")
				}
				seenOK = true
			default:
				return benchmarkData{}, fmt.Errorf("unexpected Go benchmark output: %q", line)
			}
			continue
		}
		if seenPass || seenOK {
			return benchmarkData{}, errors.New("benchmark row appears after the Go benchmark trailer")
		}
		if !hasRequiredBenchmarkHeaders(sampleHeaders) {
			return benchmarkData{}, errors.New("benchmark row appears before all Go benchmark headers")
		}
		if len(fields) != 8 {
			return benchmarkData{}, errors.New("malformed benchmark row")
		}
		iterations, parseErr := strconv.ParseUint(fields[1], 10, 64)
		if parseErr != nil || iterations == 0 {
			return benchmarkData{}, fmt.Errorf("invalid benchmark iteration count: %q", fields[1])
		}

		name := canonicalName(fields[0])
		if seenInSample[name] {
			return benchmarkData{}, fmt.Errorf("duplicate benchmark row in sample: %s", name)
		}
		seenInSample[name] = true
		sampleScenarios[name] = true
		seenBenchmark = true
		metrics := make(map[string]float64, len(metricOrder))
		for i := 2; i < len(fields); i += 2 {
			if !isMetric(fields[i+1]) {
				return benchmarkData{}, fmt.Errorf("benchmark %s reports unexpected metric %s", name, fields[i+1])
			}
			value, parseErr := strconv.ParseFloat(fields[i], 64)
			if parseErr != nil || math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
				return benchmarkData{}, fmt.Errorf("invalid %s value for %s: %q", fields[i+1], name, fields[i])
			}
			if _, duplicate := metrics[fields[i+1]]; duplicate {
				return benchmarkData{}, fmt.Errorf("benchmark %s reports duplicate %s", name, fields[i+1])
			}
			metrics[fields[i+1]] = value
		}

		for _, metric := range metricOrder {
			value, ok := metrics[metric]
			if !ok {
				return benchmarkData{}, fmt.Errorf("benchmark %s does not report %s", name, metric)
			}
			if parsed.values[name] == nil {
				parsed.values[name] = make(map[string][]float64, len(metricOrder))
			}
			parsed.values[name][metric] = append(parsed.values[name][metric], value)
		}
	}
	if err := scanner.Err(); err != nil {
		return benchmarkData{}, err
	}
	if inSample {
		return benchmarkData{}, errors.New("sample is missing an end marker")
	}
	if len(parsed.sampleIDs) == 0 || len(parsed.values) == 0 {
		return benchmarkData{}, errors.New("no framed Go benchmark rows found")
	}
	// Each scenario's number of values must equal the number of closed samples.
	for name, metrics := range parsed.values {
		for _, metric := range metricOrder {
			if len(metrics[metric]) != len(parsed.sampleIDs) {
				return benchmarkData{}, fmt.Errorf("inconsistent scenario set between samples: %s", name)
			}
		}
	}
	return parsed, nil
}

func isBenchmarkHeader(line string) bool {
	key, _, ok := parseBenchmarkHeader(line)
	return ok && key != ""
}

func hasRequiredBenchmarkHeaders(headers map[string]string) bool {
	for _, key := range requiredBenchmarkHeaderOrder {
		if headers[key] == "" {
			return false
		}
	}
	return true
}

func validNextBenchmarkHeader(headers map[string]string, key string) bool {
	if _, duplicate := headers[key]; duplicate {
		return false
	}
	if key == "cpu" {
		return hasRequiredBenchmarkHeaders(headers)
	}
	if len(headers) >= len(requiredBenchmarkHeaderOrder) {
		return false
	}
	return key == requiredBenchmarkHeaderOrder[len(headers)]
}

func parseBenchmarkHeader(line string) (string, string, bool) {
	key, value, found := strings.Cut(line, ": ")
	if !found || value == "" {
		return "", "", false
	}
	for _, expected := range benchmarkHeaderOrder {
		if key == expected {
			return key, value, true
		}
	}
	return "", "", false
}

func isBenchmarkOK(line, expectedPackage string) bool {
	fields := strings.Fields(line)
	if len(fields) != 3 || fields[0] != "ok" || expectedPackage == "" || fields[1] != expectedPackage {
		return false
	}
	_, err := time.ParseDuration(fields[2])
	return err == nil
}

func cloneStrings(input map[string]string) map[string]string {
	output := make(map[string]string, len(input))
	for key, value := range input {
		output[key] = value
	}
	return output
}

func sameStrings(left, right map[string]string) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range left {
		if right[key] != value {
			return false
		}
	}
	return true
}

func cloneSet(input map[string]bool) map[string]bool {
	output := make(map[string]bool, len(input))
	for key := range input {
		output[key] = true
	}
	return output
}

func sameSet(left, right map[string]bool) bool {
	if len(left) != len(right) {
		return false
	}
	for key := range left {
		if !right[key] {
			return false
		}
	}
	return true
}

func validateFraming(baseline, candidate benchmarkData, minimumSamples int) error {
	if len(baseline.sampleIDs) < minimumSamples || len(candidate.sampleIDs) < minimumSamples {
		return fmt.Errorf("sample count must be at least %d (baseline %d, candidate %d)", minimumSamples, len(baseline.sampleIDs), len(candidate.sampleIDs))
	}
	if len(baseline.sampleIDs) != len(candidate.sampleIDs) {
		return fmt.Errorf("baseline/candidate sample-count mismatch: %d versus %d", len(baseline.sampleIDs), len(candidate.sampleIDs))
	}
	if baseline.token != candidate.token {
		return errors.New("baseline/candidate sample-marker token mismatch")
	}
	if !sameStrings(baseline.headers, candidate.headers) {
		return errors.New("baseline/candidate Go benchmark header mismatch")
	}
	for i := range baseline.sampleIDs {
		if baseline.sampleIDs[i] != candidate.sampleIDs[i] {
			return fmt.Errorf("baseline/candidate sample-ID mismatch at position %d", i+1)
		}
	}
	return nil
}

func canonicalName(name string) string {
	name = strings.TrimPrefix(name, "Benchmark")
	separator := strings.LastIndexByte(name, '-')
	if separator < 0 || separator == len(name)-1 {
		return name
	}
	for _, character := range name[separator+1:] {
		if character < '0' || character > '9' {
			return name
		}
	}
	return name[:separator]
}

func isMetric(value string) bool {
	for _, metric := range metricOrder {
		if value == metric {
			return true
		}
	}
	return false
}

func compare(baselineSamples, candidateSamples samples, minimumSamples int) (*comparison, error) {
	if err := validateSamples(baselineSamples, candidateSamples, minimumSamples); err != nil {
		return nil, err
	}

	result := &comparison{
		baseline:    aggregateSamples(baselineSamples),
		candidate:   aggregateSamples(candidateSamples),
		improvement: make(map[string]map[string]float64),
		geomean:     make(map[string]float64, len(metricOrder)),
		tiers:       make(map[string]string, len(metricOrder)),
		passed:      true,
	}

	benchmarks := sortedNames(result.baseline)
	for _, name := range benchmarks {
		result.improvement[name] = make(map[string]float64, len(metricOrder))
		for _, metric := range metricOrder {
			baseline := result.baseline[name][metric]
			candidate := result.candidate[name][metric]
			result.improvement[name][metric] = improvement(baseline, candidate)
			if result.improvement[name][metric] < -30-thresholdEpsilon {
				result.passed = false
				result.reasons = append(result.reasons, fmt.Sprintf(
					"%s %s regressed by %.2f%%, exceeding the 30%% per-scenario limit",
					displayName(name), metric, -result.improvement[name][metric],
				))
			}
		}
	}

	bestTier := 0
	metricReachedTarget := false
	for _, metric := range metricOrder {
		ratios := make([]float64, 0, len(benchmarks))
		for _, name := range benchmarks {
			ratios = append(ratios, result.candidate[name][metric]/result.baseline[name][metric])
		}
		result.geomean[metric] = (1 - geometricMean(ratios)) * 100
		result.tiers[metric] = tier(result.geomean[metric])
		bestTier = max(bestTier, tierRank(result.tiers[metric]))
		if result.geomean[metric] >= 20-thresholdEpsilon {
			metricReachedTarget = true
		}
		if result.geomean[metric] < -20-thresholdEpsilon {
			result.passed = false
			result.reasons = append(result.reasons, fmt.Sprintf(
				"%s regressed by %.2f%%, exceeding the 20%% limit",
				metric, -result.geomean[metric],
			))
		}
	}

	result.overallTier = tierName(bestTier)
	if !metricReachedTarget {
		result.passed = false
		result.reasons = append(result.reasons, "no metric improved by at least 20%")
	}
	if result.passed {
		result.reasons = append(result.reasons, "at least one aggregate metric improved by 20% or more, no aggregate metric regressed by more than 20%, and no scenario metric regressed by more than 30%")
	}

	return result, nil
}

func validateSamples(baseline, candidate samples, minimumSamples int) error {
	if len(baseline) != len(candidate) {
		return fmt.Errorf("benchmark set differs: baseline has %d scenarios, candidate has %d", len(baseline), len(candidate))
	}
	for name, baselineMetrics := range baseline {
		candidateMetrics, ok := candidate[name]
		if !ok {
			return fmt.Errorf("candidate is missing benchmark %s", name)
		}
		for _, metric := range metricOrder {
			baselineValues := baselineMetrics[metric]
			candidateValues := candidateMetrics[metric]
			if len(baselineValues) < minimumSamples || len(candidateValues) < minimumSamples {
				return fmt.Errorf(
					"benchmark %s metric %s needs at least %d samples (baseline %d, candidate %d)",
					name, metric, minimumSamples, len(baselineValues), len(candidateValues),
				)
			}
			for _, value := range baselineValues {
				if value <= 0 {
					return fmt.Errorf("baseline benchmark %s metric %s must be greater than zero", name, metric)
				}
			}
			for _, value := range candidateValues {
				if value < 0 {
					return fmt.Errorf("candidate benchmark %s metric %s must not be negative", name, metric)
				}
			}
		}
	}
	return nil
}

func aggregateSamples(input samples) aggregate {
	result := make(aggregate, len(input))
	for name, metrics := range input {
		result[name] = make(map[string]float64, len(metricOrder))
		for _, metric := range metricOrder {
			result[name][metric] = median(metrics[metric])
		}
	}
	return result
}

func median(values []float64) float64 {
	ordered := append([]float64(nil), values...)
	sort.Float64s(ordered)
	middle := len(ordered) / 2
	if len(ordered)%2 == 1 {
		return ordered[middle]
	}
	return (ordered[middle-1] + ordered[middle]) / 2
}

func geometricMean(values []float64) float64 {
	logSum := 0.0
	for _, value := range values {
		logSum += math.Log(value)
	}
	return math.Exp(logSum / float64(len(values)))
}

func improvement(baseline, candidate float64) float64 {
	return (baseline - candidate) / baseline * 100
}

func tier(improvement float64) string {
	switch {
	case improvement >= 75-thresholdEpsilon:
		return "Staff"
	case improvement >= 50-thresholdEpsilon:
		return "Senior"
	case improvement >= 20-thresholdEpsilon:
		return "Middle"
	default:
		return "Below target"
	}
}

func tierRank(name string) int {
	switch name {
	case "Middle":
		return 1
	case "Senior":
		return 2
	case "Staff":
		return 3
	default:
		return 0
	}
}

func tierName(rank int) string {
	switch rank {
	case 1:
		return "Middle"
	case 2:
		return "Senior"
	case 3:
		return "Staff"
	default:
		return "Below target"
	}
}

func sortedNames(values aggregate) []string {
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func (result *comparison) markdown() string {
	var output strings.Builder
	output.WriteString("# Benchmark comparison\n\n")
	output.WriteString("Each scenario value is the median of repeated samples. Positive percentages mean improvement.\n\n")
	output.WriteString("| Scenario | Metric | Baseline | Candidate | Improvement |\n")
	output.WriteString("| --- | ---: | ---: | ---: | ---: |\n")
	for _, name := range sortedNames(result.baseline) {
		for _, metric := range metricOrder {
			fmt.Fprintf(
				&output,
				"| %s | %s | %s | %s | %+.2f%% |\n",
				displayName(name), metric,
				formatMetric(metric, result.baseline[name][metric]),
				formatMetric(metric, result.candidate[name][metric]),
				result.improvement[name][metric],
			)
		}
	}

	output.WriteString("\n## Geometric-mean result\n\n")
	output.WriteString("| Metric | Improvement | Tier |\n")
	output.WriteString("| --- | ---: | --- |\n")
	for _, metric := range metricOrder {
		fmt.Fprintf(&output, "| %s | %+.2f%% | %s |\n", metric, result.geomean[metric], result.tiers[metric])
	}

	fmt.Fprintf(&output, "\n**Overall optimization tier: %s**\n\n", result.overallTier)
	if result.passed {
		fmt.Fprintf(&output, "✅ **Performance gate passed:** %s.\n", result.reasons[0])
	} else {
		output.WriteString("❌ **Performance gate failed:**\n\n")
		for _, reason := range result.reasons {
			fmt.Fprintf(&output, "- %s.\n", reason)
		}
	}
	return output.String()
}

func displayName(name string) string {
	if separator := strings.IndexByte(name, '/'); separator >= 0 {
		return name[separator+1:]
	}
	return name
}

func formatMetric(metric string, value float64) string {
	if metric == metricAllocs {
		return fmt.Sprintf("%.2f", value)
	}
	return fmt.Sprintf("%.0f", value)
}

func writeReport(stdout io.Writer, outputPath, report string) error {
	if _, err := io.WriteString(stdout, report); err != nil {
		return err
	}
	if outputPath == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(outputPath), 0o755); err != nil {
		return err
	}
	return os.WriteFile(outputPath, []byte(report), 0o644)
}
