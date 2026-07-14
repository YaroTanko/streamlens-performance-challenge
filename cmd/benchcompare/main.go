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
)

const (
	metricTime       = "ns/op"
	metricBytes      = "B/op"
	metricAllocs     = "allocs/op"
	thresholdEpsilon = 1e-9
)

var metricOrder = []string{metricTime, metricBytes, metricAllocs}

type samples map[string]map[string][]float64

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

	result, err := compare(baseline, candidate, minimumSamples)
	if err != nil {
		return "", false, err
	}
	return result.markdown(), result.passed, nil
}

func parseFile(path string) (samples, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	return parseBenchmarks(file)
}

func parseBenchmarks(input io.Reader) (samples, error) {
	parsed := make(samples)
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 4 || !strings.HasPrefix(fields[0], "Benchmark") {
			continue
		}

		name := canonicalName(fields[0])
		metrics := make(map[string]float64, len(metricOrder))
		for i := 2; i+1 < len(fields); i++ {
			if !isMetric(fields[i+1]) {
				continue
			}
			value, parseErr := strconv.ParseFloat(fields[i], 64)
			if parseErr != nil || math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
				return nil, fmt.Errorf("invalid %s value for %s: %q", fields[i+1], name, fields[i])
			}
			metrics[fields[i+1]] = value
			i++
		}

		for _, metric := range metricOrder {
			value, ok := metrics[metric]
			if !ok {
				return nil, fmt.Errorf("benchmark %s does not report %s", name, metric)
			}
			if parsed[name] == nil {
				parsed[name] = make(map[string][]float64, len(metricOrder))
			}
			parsed[name][metric] = append(parsed[name][metric], value)
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(parsed) == 0 {
		return nil, errors.New("no Go benchmark rows found")
	}
	return parsed, nil
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
