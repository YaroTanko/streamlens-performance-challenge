package main

import (
	"strings"
	"testing"
)

func TestParseBenchmarksAndMedian(t *testing.T) {
	input := strings.NewReader(`goos: linux
BenchmarkAnalyze/Balanced-2 10 1000 ns/op 200 B/op 10 allocs/op
BenchmarkAnalyze/Balanced-2 10 900 ns/op 180 B/op 9 allocs/op
BenchmarkAnalyze/Balanced-2 10 5000 ns/op 900 B/op 90 allocs/op
PASS
`)

	parsed, err := parseBenchmarks(input)
	if err != nil {
		t.Fatalf("parseBenchmarks() error: %v", err)
	}
	got := aggregateSamples(parsed)["Analyze/Balanced"]
	if got[metricTime] != 1000 || got[metricBytes] != 200 || got[metricAllocs] != 10 {
		t.Fatalf("median aggregate = %#v", got)
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
