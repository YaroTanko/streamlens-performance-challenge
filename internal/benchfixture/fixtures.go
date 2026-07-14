// Package benchfixture provides deterministic workloads for the assessment
// benchmarks. Fixture construction is intentionally kept outside the timed
// benchmark region.
package benchfixture

import (
	"bytes"
	"encoding/json"
	"fmt"
	"time"

	"github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer"
)

// Scenario is one complete analyzer benchmark workload.
type Scenario struct {
	Name   string
	Input  []byte
	Config analyzer.Config
}

// Scenarios returns the benchmark workloads in their stable reporting order.
func Scenarios() []Scenario {
	return []Scenario{
		balanced(),
		highCardinality(),
		mostlyFiltered(),
	}
}

type fixtureEvent struct {
	Timestamp string  `json:"timestamp"`
	TenantID  string  `json:"tenant_id"`
	UserID    string  `json:"user_id"`
	Type      string  `json:"type"`
	Value     float64 `json:"value"`
}

var fixtureBase = time.Date(2026, time.January, 15, 12, 0, 0, 0, time.UTC)

func balanced() Scenario {
	const eventCount = 40_000
	eventTypes := [...]string{"click", "purchase"}

	input := encodeEvents(eventCount, func(i int) fixtureEvent {
		return fixtureEvent{
			Timestamp: timestampWithin(i, 2*time.Minute, 11),
			TenantID:  fmt.Sprintf("tenant-%02d", mixed(i, 17)%2),
			UserID:    fmt.Sprintf("user-%04d", mixed(i, 23)%4_000),
			Type:      eventTypes[mixed(i, 31)%uint64(len(eventTypes))],
			Value:     valueFor(i, 41),
		}
	})

	from := fixtureBase.Add(5 * time.Second)
	to := fixtureBase.Add(time.Minute + 55*time.Second)
	return Scenario{
		Name:  "Balanced",
		Input: input,
		Config: analyzer.Config{
			From:   &from,
			To:     &to,
			Types:  []string{"click", "purchase"},
			Window: time.Minute,
			TopK:   3,
		},
	}
}

func highCardinality() Scenario {
	const eventCount = 15_000
	eventTypes := [...]string{
		"click", "download", "error", "login", "logout",
		"purchase", "refund", "search", "signup", "view",
	}

	input := encodeEvents(eventCount, func(i int) fixtureEvent {
		return fixtureEvent{
			Timestamp: timestampWithin(i, 3*time.Hour, 53),
			TenantID:  fmt.Sprintf("tenant-%03d", mixed(i, 59)%500),
			UserID:    fmt.Sprintf("user-%05d", mixed(i, 61)%9_000),
			Type:      eventTypes[mixed(i, 67)%uint64(len(eventTypes))],
			Value:     valueFor(i, 71),
		}
	})

	return Scenario{
		Name:  "HighCardinality",
		Input: input,
		Config: analyzer.Config{
			Window: time.Minute,
			TopK:   5,
		},
	}
}

func mostlyFiltered() Scenario {
	const eventCount = 30_000
	nonMatchingTypes := [...]string{"click", "download", "login", "search", "view"}

	input := encodeEvents(eventCount, func(i int) fixtureEvent {
		eventType := nonMatchingTypes[mixed(i, 79)%uint64(len(nonMatchingTypes))]
		if i%25 == 0 {
			eventType = "purchase"
		}
		return fixtureEvent{
			Timestamp: timestampWithin(i, 2*time.Hour, 83),
			TenantID:  fmt.Sprintf("tenant-%02d", mixed(i, 89)%20),
			UserID:    fmt.Sprintf("user-%04d", mixed(i, 97)%2_000),
			Type:      eventType,
			Value:     valueFor(i, 101),
		}
	})

	from := fixtureBase.Add(10 * time.Minute)
	to := fixtureBase.Add(110 * time.Minute)
	return Scenario{
		Name:  "MostlyFiltered",
		Input: input,
		Config: analyzer.Config{
			From:   &from,
			To:     &to,
			Types:  []string{"purchase"},
			Window: time.Minute,
			TopK:   3,
		},
	}
}

func encodeEvents(count int, eventAt func(int) fixtureEvent) []byte {
	var output bytes.Buffer
	output.Grow(count * 145)
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	for i := 0; i < count; i++ {
		if err := encoder.Encode(eventAt(i)); err != nil {
			panic(fmt.Sprintf("encode benchmark fixture: %v", err))
		}
	}
	return output.Bytes()
}

func timestampWithin(i int, span time.Duration, salt uint64) string {
	nanoseconds := mixed(i, salt) % uint64(span)
	return fixtureBase.Add(time.Duration(nanoseconds)).Format(time.RFC3339Nano)
}

func valueFor(i int, salt uint64) float64 {
	return float64(mixed(i, salt)%25_000+1) / 100
}

// mixed is a small, deterministic integer mixer. It gives the fixture broad
// key coverage without introducing a random seed or runtime dependency.
func mixed(i int, salt uint64) uint64 {
	x := uint64(i) + salt*0x9e3779b97f4a7c15
	x ^= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ^= x >> 27
	x *= 0x94d049bb133111eb
	return x ^ (x >> 31)
}
