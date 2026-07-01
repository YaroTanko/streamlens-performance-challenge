package analyzer

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"slices"
	"time"
	"unicode/utf8"
)

type normalizedConfig struct {
	from   *time.Time
	to     *time.Time
	types  map[string]struct{} // O(1) lookup map instead of slice
	window time.Duration
	topK   int
}

type event struct {
	lineNumber int
	timestamp  time.Time
	tenantID   string
	userID     string
	typeName   string
	value      float64
}

// aggregateKey is used as map key to avoid string allocation via fmt.Sprintf
type aggregateKey struct {
	windowStart time.Time
	tenantID    string
	typeName    string
}

type aggregate struct {
	count int
	sum   float64
	users map[string]float64 // O(1) lookups for active users
}

func Analyze(ctx context.Context, input io.Reader, config Config) ([]Group, error) {
	if ctx == nil {
		return nil, errors.New("context must not be nil")
	}
	if input == nil {
		return nil, errors.New("input must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	cfg, err := normalizeConfig(config)
	if err != nil {
		return nil, err
	}

	aggregates, err := readAndAggregate(ctx, input, cfg)
	if err != nil {
		return nil, err
	}

	result := make([]Group, 0, len(aggregates))
	for key, group := range aggregates {
		if err := ctx.Err(); err != nil {
			return nil, err
		}

		allUsers := make([]TopUser, 0, len(group.users))
		for uID, val := range group.users {
			allUsers = append(allUsers, TopUser{UserID: uID, Value: val})
		}

		// Use modern generic SortFunc to avoid reflection overhead
		slices.SortFunc(allUsers, func(a, b TopUser) int {
			if a.Value != b.Value {
				if a.Value > b.Value {
					return -1
				}
				return 1
			}
			if a.UserID < b.UserID {
				return -1
			}
			if a.UserID > b.UserID {
				return 1
			}
			return 0
		})

		if len(allUsers) > cfg.topK {
			allUsers = allUsers[:cfg.topK]
		}

		result = append(result, Group{
			WindowStart: key.windowStart,
			TenantID:    key.tenantID,
			Type:        key.typeName,
			Count:       group.count,
			Sum:         group.sum,
			UniqueUsers: len(group.users),
			TopUsers:    allUsers,
		})
	}

	slices.SortFunc(result, func(a, b Group) int {
		if !a.WindowStart.Equal(b.WindowStart) {
			if a.WindowStart.Before(b.WindowStart) {
				return -1
			}
			return 1
		}
		if a.TenantID != b.TenantID {
			if a.TenantID < b.TenantID {
				return -1
			}
			return 1
		}
		if a.Type < b.Type {
			return -1
		}
		if a.Type > b.Type {
			return 1
		}
		return 0
	})

	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return result, nil
}

func normalizeConfig(config Config) (normalizedConfig, error) {
	if config.Window < 0 {
		return normalizedConfig{}, errors.New("window must be positive")
	}
	if config.TopK < 0 {
		return normalizedConfig{}, errors.New("top-k must be positive")
	}

	window := config.Window
	if window == 0 {
		window = DefaultWindow
	}
	topK := config.TopK
	if topK == 0 {
		topK = DefaultTopK
	}

	var typesMap map[string]struct{}
	if len(config.Types) > 0 {
		typesMap = make(map[string]struct{}, len(config.Types))
		for _, t := range config.Types {
			typesMap[t] = struct{}{}
		}
	}

	return normalizedConfig{
		from:   config.From,
		to:     config.To,
		types:  typesMap,
		window: window,
		topK:   topK,
	}, nil
}

func readAndAggregate(ctx context.Context, input io.Reader, config normalizedConfig) (map[aggregateKey]*aggregate, error) {
	scanner := bufio.NewScanner(input)
	aggregates := make(map[aggregateKey]*aggregate)
	lineNumber := 0

	for scanner.Scan() {
		lineNumber++
		if err := ctx.Err(); err != nil {
			return nil, err
		}

		// Get bytes slice without allocating a string immediately
		lineBytes := scanner.Bytes()
		trimmedBytes := bytes.TrimSpace(lineBytes)
		if len(trimmedBytes) == 0 {
			continue
		}

		if !utf8.Valid(trimmedBytes) {
			return nil, fmt.Errorf("line %d: input is not valid UTF-8", lineNumber)
		}

		item, err := parseEventBytes(trimmedBytes)
		if err != nil {
			return nil, fmt.Errorf("line %d: %w", lineNumber, err)
		}
		item.lineNumber = lineNumber

		if eventAllowed(item, config) {
			if err := addEvent(aggregates, config, item); err != nil {
				return nil, err
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("line %d: read input: %w", lineNumber+1, err)
	}

	return aggregates, nil
}

func addEvent(aggregates map[aggregateKey]*aggregate, config normalizedConfig, item event) error {
	windowStart := item.timestamp.UTC().Truncate(config.window)
	key := aggregateKey{
		windowStart: windowStart,
		tenantID:    item.tenantID,
		typeName:    item.typeName,
	}

	group, ok := aggregates[key]
	if !ok {
		group = &aggregate{
			users: make(map[string]float64),
		}
		aggregates[key] = group
	}

	currentUserSum := group.users[item.userID] // Returns 0.0 if not present
	nextUserSum := currentUserSum + item.value
	if math.IsInf(nextUserSum, 0) {
		return fmt.Errorf("line %d: user sum overflow for user_id %q", item.lineNumber, item.userID)
	}

	nextGroupSum := group.sum + item.value
	if math.IsInf(nextGroupSum, 0) {
		return fmt.Errorf(
			"line %d: group sum overflow for tenant_id %q and type %q",
			item.lineNumber,
			item.tenantID,
			item.typeName,
		)
	}

	group.count++
	group.sum = nextGroupSum
	group.users[item.userID] = nextUserSum

	return nil
}

// Concrete schema for single-pass structural decoding
type jsonEventSchema struct {
	Timestamp string          `json:"timestamp"`
	TenantID  string          `json:"tenant_id"`
	UserID    string          `json:"user_id"`
	Type      string          `json:"type"`
	Value     json.RawMessage `json:"value"`
}

func parseEventBytes(line []byte) (event, error) {
	var schema jsonEventSchema
	if err := json.Unmarshal(line, &schema); err != nil {
		return event{}, fmt.Errorf("invalid JSON: %w", err)
	}

	if schema.Timestamp == "" {
		return event{}, errors.New("timestamp is required")
	}
	timestamp, err := time.Parse(time.RFC3339Nano, schema.Timestamp)
	if err != nil {
		return event{}, fmt.Errorf("timestamp must be RFC3339Nano with an explicit offset: %w", err)
	}

	if schema.TenantID == "" {
		return event{}, errors.New("tenant_id is required and must not be empty")
	}
	if schema.UserID == "" {
		return event{}, errors.New("user_id is required and must not be empty")
	}
	if schema.Type == "" {
		return event{}, errors.New("type is required and must not be empty")
	}

	if len(schema.Value) == 0 {
		return event{}, errors.New("value is required")
	}

	trimmedVal := bytes.TrimSpace(schema.Value)
	if len(trimmedVal) == 0 || (trimmedVal[0] != '-' && (trimmedVal[0] < '0' || trimmedVal[0] > '9')) {
		return event{}, errors.New("value must be a number")
	}

	var value float64
	if err := json.Unmarshal(trimmedVal, &value); err != nil {
		return event{}, errors.New("value must be a number")
	}

	if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
		return event{}, errors.New("value must be finite and greater than or equal to zero")
	}

	return event{
		timestamp: timestamp,
		tenantID:  schema.TenantID,
		userID:    schema.UserID,
		typeName:  schema.Type,
		value:     value,
	}, nil
}

func eventAllowed(item event, config normalizedConfig) bool {
	if config.from != nil && item.timestamp.Before(*config.from) {
		return false
	}
	if config.to != nil && !item.timestamp.Before(*config.to) {
		return false
	}
	if len(config.types) == 0 {
		return true
	}
	_, allowed := config.types[item.typeName]
	return allowed
}
