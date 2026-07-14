package benchfixture

import (
	"bytes"
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

func TestScenariosAreDeterministic(t *testing.T) {
	first := Scenarios()
	second := Scenarios()
	want := []struct {
		name       string
		eventCount int
	}{
		{name: "Balanced", eventCount: 40_000},
		{name: "HighCardinality", eventCount: 15_000},
		{name: "MostlyFiltered", eventCount: 30_000},
	}

	if len(first) != len(want) || len(second) != len(want) {
		t.Fatalf("scenario counts = %d and %d, want %d", len(first), len(second), len(want))
	}
	for i := range want {
		if first[i].Name != want[i].name {
			t.Errorf("scenario %d name = %q, want %q", i, first[i].Name, want[i].name)
		}
		if got := bytes.Count(first[i].Input, []byte{'\n'}); got != want[i].eventCount {
			t.Errorf("scenario %s event count = %d, want %d", first[i].Name, got, want[i].eventCount)
		}
		if !bytes.Equal(first[i].Input, second[i].Input) {
			t.Errorf("scenario %s input is not deterministic", first[i].Name)
		}
	}
}

func TestScenarioShapes(t *testing.T) {
	scenarios := Scenarios()
	balanced := inspectScenario(t, scenarios[0])
	if balanced.groups > 40 || balanced.maxUsersPerGroup < 150 {
		t.Fatalf("Balanced shape = %#v, want dense groups with repeated users", balanced)
	}

	highCardinality := inspectScenario(t, scenarios[1])
	if highCardinality.groups < 14_000 {
		t.Fatalf("HighCardinality groups = %d, want at least 14000", highCardinality.groups)
	}

	mostlyFiltered := inspectScenario(t, scenarios[2])
	if mostlyFiltered.accepted >= mostlyFiltered.total/10 {
		t.Fatalf("MostlyFiltered accepted %d of %d, want less than 10%%", mostlyFiltered.accepted, mostlyFiltered.total)
	}
}

type scenarioShape struct {
	total            int
	accepted         int
	groups           int
	maxUsersPerGroup int
}

func inspectScenario(t *testing.T, scenario Scenario) scenarioShape {
	t.Helper()

	window := scenario.Config.Window
	if window == 0 {
		window = time.Minute
	}
	allowedTypes := make(map[string]struct{}, len(scenario.Config.Types))
	for _, eventType := range scenario.Config.Types {
		allowedTypes[eventType] = struct{}{}
	}

	groupUsers := make(map[string]map[string]struct{})
	shape := scenarioShape{}
	for _, line := range bytes.Split(scenario.Input, []byte{'\n'}) {
		if len(line) == 0 {
			continue
		}
		shape.total++

		var event fixtureEvent
		if err := json.Unmarshal(line, &event); err != nil {
			t.Fatalf("decode %s fixture event: %v", scenario.Name, err)
		}
		timestamp, err := time.Parse(time.RFC3339Nano, event.Timestamp)
		if err != nil {
			t.Fatalf("parse %s fixture timestamp: %v", scenario.Name, err)
		}
		if scenario.Config.From != nil && timestamp.Before(*scenario.Config.From) {
			continue
		}
		if scenario.Config.To != nil && !timestamp.Before(*scenario.Config.To) {
			continue
		}
		if len(allowedTypes) > 0 {
			if _, ok := allowedTypes[event.Type]; !ok {
				continue
			}
		}

		shape.accepted++
		key := fmt.Sprintf("%s\x00%s\x00%s", timestamp.UTC().Truncate(window).Format(time.RFC3339Nano), event.TenantID, event.Type)
		if groupUsers[key] == nil {
			groupUsers[key] = make(map[string]struct{})
		}
		groupUsers[key][event.UserID] = struct{}{}
	}
	shape.groups = len(groupUsers)
	for _, users := range groupUsers {
		if len(users) > shape.maxUsersPerGroup {
			shape.maxUsersPerGroup = len(users)
		}
	}
	return shape
}
