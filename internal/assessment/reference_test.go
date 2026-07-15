//go:build reference

package assessment_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"sort"
	"testing"
	"time"

	"github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer"
	"github.com/YaroTanko/streamlens-performance-challenge/internal/benchfixture"
)

// TestReferenceScenarioResults independently checks the compact benchmark
// snapshots. It is opt-in because it duplicates the aggregation work solely
// for maintainer calibration:
//
//	go test -tags reference -run '^TestReferenceScenarioResults$' ./internal/assessment
func TestReferenceScenarioResults(t *testing.T) {
	for _, scenario := range benchfixture.Scenarios() {
		scenario := scenario
		t.Run(scenario.Name, func(t *testing.T) {
			groups, err := referenceAnalyze(scenario)
			if err != nil {
				t.Fatalf("reference analysis: %v", err)
			}
			assertScenarioResult(t, scenario, groups)
		})
	}
}

type referenceEvent struct {
	Timestamp string  `json:"timestamp"`
	TenantID  string  `json:"tenant_id"`
	UserID    string  `json:"user_id"`
	Type      string  `json:"type"`
	Value     float64 `json:"value"`
}

type referenceKey struct {
	windowStart time.Time
	tenantID    string
	typeName    string
}

type referenceAggregate struct {
	count int
	sum   float64
	users map[string]float64
}

func referenceAnalyze(scenario benchfixture.Scenario) ([]analyzer.Group, error) {
	window := scenario.Config.Window
	if window == 0 {
		window = analyzer.DefaultWindow
	}
	topK := scenario.Config.TopK
	if topK == 0 {
		topK = analyzer.DefaultTopK
	}
	allowedTypes := make(map[string]bool, len(scenario.Config.Types))
	for _, typeName := range scenario.Config.Types {
		allowedTypes[typeName] = true
	}

	aggregates := make(map[referenceKey]*referenceAggregate)
	decoder := json.NewDecoder(bytes.NewReader(scenario.Input))
	for {
		var event referenceEvent
		if err := decoder.Decode(&event); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("decode fixture: %w", err)
		}

		timestamp, err := time.Parse(time.RFC3339Nano, event.Timestamp)
		if err != nil {
			return nil, fmt.Errorf("parse timestamp %q: %w", event.Timestamp, err)
		}
		if scenario.Config.From != nil && timestamp.Before(*scenario.Config.From) {
			continue
		}
		if scenario.Config.To != nil && !timestamp.Before(*scenario.Config.To) {
			continue
		}
		if len(allowedTypes) > 0 && !allowedTypes[event.Type] {
			continue
		}

		key := referenceKey{
			windowStart: timestamp.UTC().Truncate(window),
			tenantID:    event.TenantID,
			typeName:    event.Type,
		}
		aggregate := aggregates[key]
		if aggregate == nil {
			aggregate = &referenceAggregate{users: make(map[string]float64)}
			aggregates[key] = aggregate
		}
		aggregate.count++
		aggregate.sum += event.Value
		aggregate.users[event.UserID] += event.Value
		if math.IsInf(aggregate.sum, 0) || math.IsInf(aggregate.users[event.UserID], 0) {
			return nil, errors.New("fixture sum overflow")
		}
	}

	groups := make([]analyzer.Group, 0, len(aggregates))
	for key, aggregate := range aggregates {
		topUsers := make([]analyzer.TopUser, 0, len(aggregate.users))
		for userID, value := range aggregate.users {
			topUsers = append(topUsers, analyzer.TopUser{UserID: userID, Value: value})
		}
		sort.Slice(topUsers, func(i, j int) bool {
			if topUsers[i].Value != topUsers[j].Value {
				return topUsers[i].Value > topUsers[j].Value
			}
			return topUsers[i].UserID < topUsers[j].UserID
		})
		if len(topUsers) > topK {
			topUsers = topUsers[:topK]
		}
		groups = append(groups, analyzer.Group{
			WindowStart: key.windowStart,
			TenantID:    key.tenantID,
			Type:        key.typeName,
			Count:       aggregate.count,
			Sum:         aggregate.sum,
			UniqueUsers: len(aggregate.users),
			TopUsers:    topUsers,
		})
	}
	sort.Slice(groups, func(i, j int) bool {
		if !groups[i].WindowStart.Equal(groups[j].WindowStart) {
			return groups[i].WindowStart.Before(groups[j].WindowStart)
		}
		if groups[i].TenantID != groups[j].TenantID {
			return groups[i].TenantID < groups[j].TenantID
		}
		return groups[i].Type < groups[j].Type
	})
	return groups, nil
}
