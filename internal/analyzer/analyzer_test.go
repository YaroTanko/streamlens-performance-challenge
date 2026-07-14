package analyzer_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/YaroTanko/streamlens-performance-challenge/internal/analyzer"
)

func TestAnalyzeAggregatesValidEventsAndUsesDefaults(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		"",
		`{"timestamp":"2026-01-15T12:34:56.123Z","tenant_id":"acme","user_id":"user-2","type":"purchase","value":2.5,"ignored":{"anything":true}}`,
		"   ",
		`{"timestamp":"2026-01-15T12:34:57Z","tenant_id":"acme","user_id":"user-1","type":"purchase","value":5}`,
		`{"timestamp":"2026-01-15T12:34:58Z","tenant_id":"acme","user_id":"user-2","type":"purchase","value":3}`,
	}, "\n")

	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}

	want := []analyzer.Group{{
		WindowStart: mustTime(t, "2026-01-15T12:34:00Z"),
		TenantID:    "acme",
		Type:        "purchase",
		Count:       3,
		Sum:         10.5,
		UniqueUsers: 2,
		TopUsers: []analyzer.TopUser{
			{UserID: "user-2", Value: 5.5},
			{UserID: "user-1", Value: 5},
		},
	}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Analyze() = %#v, want %#v", got, want)
	}
}

func TestAnalyzeFiltersBeforeAggregation(t *testing.T) {
	t.Parallel()

	from := mustTime(t, "2026-01-15T12:00:00Z")
	to := mustTime(t, "2026-01-15T12:10:00Z")
	input := strings.Join([]string{
		eventLine("2026-01-15T11:59:59Z", "acme", "before", "purchase", 100),
		eventLine("2026-01-15T14:00:00+02:00", "acme", "included", "purchase", 7),
		eventLine("2026-01-15T12:05:00Z", "acme", "wrong-type", "click", 100),
		eventLine("2026-01-15T12:10:00Z", "acme", "at-to", "purchase", 100),
	}, "\n")

	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{
		From:  &from,
		To:    &to,
		Types: []string{"purchase"},
		TopK:  1,
	})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if len(got) != 1 || got[0].Count != 1 || got[0].Sum != 7 || got[0].TopUsers[0].UserID != "included" {
		t.Fatalf("Analyze() = %#v, want only the inclusive-from purchase event", got)
	}
}

func TestAnalyzeAlignsWindowsInUTC(t *testing.T) {
	t.Parallel()

	input := eventLine("2026-01-15T14:34:56.789+02:00", "acme", "user", "view", 1)
	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{Window: 5 * time.Minute})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}

	want := mustTime(t, "2026-01-15T12:30:00Z")
	if len(got) != 1 || !got[0].WindowStart.Equal(want) || got[0].WindowStart.Location() != time.UTC {
		t.Fatalf("window start = %v, want %v in UTC", got[0].WindowStart, want)
	}
}

func TestAnalyzeUsesGoTimeTruncateAnchor(t *testing.T) {
	t.Parallel()

	input := eventLine("2026-01-15T12:34:56Z", "acme", "user", "view", 1)
	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{Window: 7 * time.Minute})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}

	want := mustTime(t, "2026-01-15T12:28:00Z")
	if len(got) != 1 || !got[0].WindowStart.Equal(want) {
		t.Fatalf("window start = %v, want Go time.Truncate anchor %v", got[0].WindowStart, want)
	}
}

func TestAnalyzeOrdersGroupsAndTopUsers(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		eventLine("2026-01-15T12:01:00Z", "acme", "later", "click", 1),
		eventLine("2026-01-15T12:00:05Z", "beta", "user", "click", 1),
		eventLine("2026-01-15T12:00:04Z", "acme", "z-user", "purchase", 5),
		eventLine("2026-01-15T12:00:03Z", "acme", "a-user", "purchase", 5),
		eventLine("2026-01-15T12:00:02Z", "acme", "ignored-by-top-k", "purchase", 1),
		eventLine("2026-01-15T12:00:01Z", "acme", "user", "click", 1),
	}, "\n")

	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{TopK: 2})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}

	wantKeys := []string{
		"2026-01-15T12:00:00Z/acme/click",
		"2026-01-15T12:00:00Z/acme/purchase",
		"2026-01-15T12:00:00Z/beta/click",
		"2026-01-15T12:01:00Z/acme/click",
	}
	if len(got) != len(wantKeys) {
		t.Fatalf("got %d groups, want %d: %#v", len(got), len(wantKeys), got)
	}
	for index, group := range got {
		key := group.WindowStart.Format(time.RFC3339Nano) + "/" + group.TenantID + "/" + group.Type
		if key != wantKeys[index] {
			t.Errorf("group %d key = %q, want %q", index, key, wantKeys[index])
		}
	}

	purchase := got[1]
	wantTop := []analyzer.TopUser{{UserID: "a-user", Value: 5}, {UserID: "z-user", Value: 5}}
	if purchase.UniqueUsers != 3 || !reflect.DeepEqual(purchase.TopUsers, wantTop) {
		t.Fatalf("purchase users = (%d, %#v), want (3, %#v)", purchase.UniqueUsers, purchase.TopUsers, wantTop)
	}
}

func TestAnalyzeReportsValidationErrorsWithLineNumbers(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		line     string
		wantText string
	}{
		{name: "malformed JSON", line: `{`, wantText: "invalid JSON"},
		{name: "non-object", line: `[]`, wantText: "invalid JSON"},
		{name: "missing timestamp", line: `{"tenant_id":"t","user_id":"u","type":"x","value":1}`, wantText: "timestamp"},
		{name: "timestamp type", line: `{"timestamp":1,"tenant_id":"t","user_id":"u","type":"x","value":1}`, wantText: "timestamp"},
		{name: "timestamp without offset", line: `{"timestamp":"2026-01-15T12:00:00","tenant_id":"t","user_id":"u","type":"x","value":1}`, wantText: "timestamp"},
		{name: "empty tenant", line: eventLine("2026-01-15T12:00:00Z", "", "u", "x", 1), wantText: "tenant_id"},
		{name: "empty user", line: eventLine("2026-01-15T12:00:00Z", "t", "", "x", 1), wantText: "user_id"},
		{name: "empty type", line: eventLine("2026-01-15T12:00:00Z", "t", "u", "", 1), wantText: "type"},
		{name: "missing value", line: `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","user_id":"u","type":"x"}`, wantText: "value"},
		{name: "value type", line: `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","user_id":"u","type":"x","value":"1"}`, wantText: "value"},
		{name: "null value", line: `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","user_id":"u","type":"x","value":null}`, wantText: "value"},
		{name: "negative value", line: eventLine("2026-01-15T12:00:00Z", "t", "u", "x", -1), wantText: "value"},
		{name: "non-finite value", line: `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","user_id":"u","type":"x","value":1e9999}`, wantText: "value"},
	}

	valid := eventLine("2026-01-15T12:00:00Z", "t", "u", "x", 1)
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			input := "\n" + valid + "\n" + test.line
			_, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
			if err == nil {
				t.Fatal("Analyze() error = nil")
			}
			if !strings.Contains(err.Error(), "line 3") || !strings.Contains(err.Error(), test.wantText) {
				t.Fatalf("Analyze() error = %q, want line 3 and %q", err, test.wantText)
			}
		})
	}
}

func TestAnalyzeRequiresExactLowercaseFieldNames(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		line     string
		wantText string
	}{
		{
			name:     "timestamp",
			line:     `{"Timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","user_id":"u","type":"x","value":1}`,
			wantText: "timestamp",
		},
		{
			name:     "tenant_id",
			line:     `{"timestamp":"2026-01-15T12:00:00Z","TENANT_ID":"t","user_id":"u","type":"x","value":1}`,
			wantText: "tenant_id",
		},
		{
			name:     "user_id",
			line:     `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","User_ID":"u","type":"x","value":1}`,
			wantText: "user_id",
		},
		{
			name:     "type",
			line:     `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","user_id":"u","Type":"x","value":1}`,
			wantText: "type",
		},
		{
			name:     "value",
			line:     `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"t","user_id":"u","type":"x","Value":1}`,
			wantText: "value",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := analyzer.Analyze(context.Background(), strings.NewReader(test.line), analyzer.Config{})
			if err == nil || !strings.Contains(err.Error(), "line 1") || !strings.Contains(err.Error(), test.wantText) {
				t.Fatalf("Analyze() error = %v, want line 1 error for exact field %q", err, test.wantText)
			}
		})
	}
}

func TestAnalyzeIgnoresDifferentlyCasedUnknownFields(t *testing.T) {
	t.Parallel()

	input := `{"timestamp":"2026-01-15T12:00:00Z","Timestamp":"not-used","tenant_id":"tenant","Tenant_ID":"not-used","user_id":"user","User_ID":"not-used","type":"purchase","Type":"not-used","value":3,"Value":999}`
	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if len(got) != 1 || got[0].TenantID != "tenant" || got[0].Type != "purchase" || got[0].Sum != 3 {
		t.Fatalf("Analyze() = %#v, want values from exact lowercase keys", got)
	}
}

func TestAnalyzeDoesNotConvertUnknownFields(t *testing.T) {
	t.Parallel()

	input := `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"tenant","user_id":"user","type":"purchase","value":3,"ignored":1e9999}`
	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if len(got) != 1 || got[0].Sum != 3 {
		t.Fatalf("Analyze() = %#v, want the unknown out-of-range number ignored", got)
	}
}

func TestAnalyzeDuplicateExactFieldsUseLastValue(t *testing.T) {
	t.Parallel()

	t.Run("last values are valid", func(t *testing.T) {
		input := `{"timestamp":"not-a-time","timestamp":"2026-01-15T12:00:00Z","tenant_id":"","tenant_id":"tenant-last","user_id":"user-first","user_id":"user-last","type":"view","type":"purchase","value":1e9999,"value":3}`
		got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
		if err != nil {
			t.Fatalf("Analyze() error = %v", err)
		}
		if len(got) != 1 || got[0].TenantID != "tenant-last" || got[0].Type != "purchase" || got[0].Sum != 3 {
			t.Fatalf("Analyze() = %#v, want last duplicate field values", got)
		}
		if len(got[0].TopUsers) != 1 || got[0].TopUsers[0].UserID != "user-last" {
			t.Fatalf("top users = %#v, want last duplicate user_id", got[0].TopUsers)
		}
	})

	t.Run("last value is invalid", func(t *testing.T) {
		input := `{"timestamp":"2026-01-15T12:00:00Z","tenant_id":"tenant","user_id":"user","type":"purchase","value":1,"value":-1}`
		_, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
		if err == nil || !strings.Contains(err.Error(), "line 1") || !strings.Contains(err.Error(), "value") {
			t.Fatalf("Analyze() error = %v, want invalid last duplicate value on line 1", err)
		}
	})
}

func TestAnalyzeIgnoresWhitespaceOnlyLines(t *testing.T) {
	t.Parallel()

	valid := eventLine("2026-01-15T12:00:00Z", "tenant", "user", "purchase", 2)
	input := " \t\r\n\u00a0\t\n" + valid + "\n\u3000\t"
	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if len(got) != 1 || got[0].Count != 1 || got[0].Sum != 2 {
		t.Fatalf("Analyze() = %#v, want only the non-whitespace event", got)
	}
}

func TestAnalyzeRejectsInvalidUTF8(t *testing.T) {
	t.Parallel()

	input := append([]byte("\n"), []byte{0xff, '\n'}...)
	_, err := analyzer.Analyze(context.Background(), bytes.NewReader(input), analyzer.Config{})
	if err == nil || !strings.Contains(err.Error(), "line 2") || !strings.Contains(err.Error(), "UTF-8") {
		t.Fatalf("Analyze() error = %v, want UTF-8 error on line 2", err)
	}
}

func TestAnalyzeSupportsLargeInputLines(t *testing.T) {
	t.Parallel()

	largeUserID := strings.Repeat("u", 70*1024)
	input := eventLine("2026-01-15T12:00:00Z", "tenant", largeUserID, "view", 1)
	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if len(got) != 1 || len(got[0].TopUsers) != 1 || got[0].TopUsers[0].UserID != largeUserID {
		t.Fatalf("large user ID was not preserved (groups=%d)", len(got))
	}
}

func TestAnalyzeReturnsContextError(t *testing.T) {
	t.Parallel()

	t.Run("already canceled", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		_, err := analyzer.Analyze(ctx, strings.NewReader(""), analyzer.Config{})
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Analyze() error = %v, want context.Canceled", err)
		}
	})

	t.Run("canceled while reading", func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		input := &cancelingReader{
			data:   []byte(eventLine("2026-01-15T12:00:00Z", "t", "u", "x", 1)),
			cancel: cancel,
		}
		_, err := analyzer.Analyze(ctx, input, analyzer.Config{})
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Analyze() error = %v, want context.Canceled", err)
		}
	})
}

func TestAnalyzeRejectsNilContextAndInput(t *testing.T) {
	t.Parallel()

	if _, err := analyzer.Analyze(nil, strings.NewReader(""), analyzer.Config{}); err == nil {
		t.Fatal("Analyze() with nil context returned nil error")
	}
	if _, err := analyzer.Analyze(context.Background(), nil, analyzer.Config{}); err == nil {
		t.Fatal("Analyze() with nil input returned nil error")
	}
}

func TestAnalyzeRejectsInvalidConfiguration(t *testing.T) {
	t.Parallel()

	tests := []analyzer.Config{
		{Window: -time.Nanosecond},
		{TopK: -1},
	}
	for _, config := range tests {
		if _, err := analyzer.Analyze(context.Background(), strings.NewReader(""), config); err == nil {
			t.Fatalf("Analyze() with config %#v returned nil error", config)
		}
	}
}

func TestAnalyzeEmptyInputReturnsEmptySlice(t *testing.T) {
	t.Parallel()

	got, err := analyzer.Analyze(context.Background(), strings.NewReader("\n  \n"), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if got == nil {
		t.Fatal("Analyze() returned a nil slice, want a non-nil empty slice")
	}
	encoded, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	if string(encoded) != "[]" {
		t.Fatalf("empty result JSON = %s, want []", encoded)
	}
}

func TestAnalyzeUsesSequentialInputOrderForSums(t *testing.T) {
	t.Parallel()

	values := []float64{1e16, 1, 1}
	lines := make([]string, 0, len(values))
	want := float64(0)
	for _, value := range values {
		lines = append(lines, eventLine("2026-01-15T12:00:00Z", "tenant", "user", "purchase", value))
		want += value
	}

	got, err := analyzer.Analyze(context.Background(), strings.NewReader(strings.Join(lines, "\n")), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if len(got) != 1 || len(got[0].TopUsers) != 1 {
		t.Fatalf("Analyze() = %#v, want one group with one user", got)
	}
	if got[0].Sum != want {
		t.Fatalf("group sum = %.17g, want sequential sum %.17g", got[0].Sum, want)
	}
	if got[0].TopUsers[0].Value != want {
		t.Fatalf("user sum = %.17g, want sequential sum %.17g", got[0].TopUsers[0].Value, want)
	}
}

func TestAnalyzeRejectsUserSumOverflow(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		eventLine("2026-01-15T12:00:00Z", "tenant", "same-user", "purchase", math.MaxFloat64),
		eventLine("2026-01-15T12:00:01Z", "tenant", "same-user", "purchase", math.MaxFloat64),
	}, "\n")
	_, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err == nil || !strings.Contains(err.Error(), "line 2") || !strings.Contains(err.Error(), "user sum overflow") {
		t.Fatalf("Analyze() error = %v, want user sum overflow on line 2", err)
	}
}

func TestAnalyzeRejectsGroupSumOverflow(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		eventLine("2026-01-15T12:00:00Z", "tenant", "user-1", "purchase", math.MaxFloat64),
		eventLine("2026-01-15T12:00:01Z", "tenant", "user-2", "purchase", math.MaxFloat64),
	}, "\n")
	_, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err == nil || !strings.Contains(err.Error(), "line 2") || !strings.Contains(err.Error(), "group sum overflow") {
		t.Fatalf("Analyze() error = %v, want group sum overflow on line 2", err)
	}
}

func TestAnalyzeReturnsTheEarliestLineError(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		eventLine("2026-01-15T12:00:00Z", "tenant", "same-user", "purchase", math.MaxFloat64),
		eventLine("2026-01-15T12:00:01Z", "tenant", "same-user", "purchase", math.MaxFloat64),
		`{"timestamp":`,
	}, "\n")
	_, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err == nil || !strings.Contains(err.Error(), "line 2") || !strings.Contains(err.Error(), "user sum overflow") {
		t.Fatalf("Analyze() error = %v, want the overflow encountered before malformed line 3", err)
	}
}

func TestAnalyzeUsesCollisionFreeGroupingKeys(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		eventLine("2026-01-15T12:00:00Z", "a\x00b", "u1", "c", 1),
		eventLine("2026-01-15T12:00:00Z", "a", "u2", "b\x00c", 2),
	}, "\n")
	got, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
	if err != nil {
		t.Fatalf("Analyze() error = %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("Analyze() returned %d groups, want 2: %#v", len(got), got)
	}
}

func TestAnalyzeOutputIsDeterministic(t *testing.T) {
	t.Parallel()

	input := strings.Join([]string{
		eventLine("2026-01-15T12:02:00Z", "z", "u1", "view", 2),
		eventLine("2026-01-15T12:01:00Z", "a", "u2", "purchase", 2),
		eventLine("2026-01-15T12:01:00Z", "a", "u1", "purchase", 2),
	}, "\n")

	var first []byte
	for attempt := 0; attempt < 20; attempt++ {
		groups, err := analyzer.Analyze(context.Background(), strings.NewReader(input), analyzer.Config{})
		if err != nil {
			t.Fatalf("Analyze() error = %v", err)
		}
		encoded, err := json.Marshal(groups)
		if err != nil {
			t.Fatalf("json.Marshal() error = %v", err)
		}
		if attempt == 0 {
			first = encoded
			continue
		}
		if !bytes.Equal(encoded, first) {
			t.Fatalf("attempt %d JSON = %s, first = %s", attempt, encoded, first)
		}
	}
}

func TestAnalyzeReportsReaderErrorsWithNextLineNumber(t *testing.T) {
	t.Parallel()

	sentinel := errors.New("read failure")
	input := io.MultiReader(
		strings.NewReader(eventLine("2026-01-15T12:00:00Z", "t", "u", "x", 1)+"\n"),
		errorReader{err: sentinel},
	)
	_, err := analyzer.Analyze(context.Background(), input, analyzer.Config{})
	if !errors.Is(err, sentinel) || !strings.Contains(err.Error(), "line 2") {
		t.Fatalf("Analyze() error = %v, want wrapped reader error on line 2", err)
	}
}

type cancelingReader struct {
	data   []byte
	cancel context.CancelFunc
	done   bool
}

func (reader *cancelingReader) Read(destination []byte) (int, error) {
	if reader.done {
		return 0, io.EOF
	}
	reader.done = true
	reader.cancel()
	return copy(destination, reader.data), io.EOF
}

type errorReader struct {
	err error
}

func (reader errorReader) Read([]byte) (int, error) {
	return 0, reader.err
}

func eventLine(timestamp, tenantID, userID, typeName string, value float64) string {
	payload, err := json.Marshal(struct {
		Timestamp string  `json:"timestamp"`
		TenantID  string  `json:"tenant_id"`
		UserID    string  `json:"user_id"`
		Type      string  `json:"type"`
		Value     float64 `json:"value"`
	}{
		Timestamp: timestamp,
		TenantID:  tenantID,
		UserID:    userID,
		Type:      typeName,
		Value:     value,
	})
	if err != nil {
		panic(err)
	}
	return string(payload)
}

func mustTime(t *testing.T, value string) time.Time {
	t.Helper()
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		t.Fatalf("time.Parse(%q): %v", value, err)
	}
	return parsed
}
