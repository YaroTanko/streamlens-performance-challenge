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
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

type normalizedConfig struct {
	from   *time.Time
	to     *time.Time
	types  []string
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

type userTotal struct {
	userID string
	value  float64
}

type aggregate struct {
	windowStart time.Time
	tenantID    string
	typeName    string
	count       int
	sum         float64
	users       []userTotal
}

// Analyze reads all events from input and returns deterministically ordered
// aggregate groups. Processing stops at the first invalid event or cancellation.
func Analyze(ctx context.Context, input io.Reader, config Config) ([]Group, error) {
	// Smoke-test candidate change.
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
	for _, group := range aggregates {
		if err := ctx.Err(); err != nil {
			return nil, err
		}

		allUsers := make([]TopUser, 0, len(group.users))
		for _, user := range group.users {
			allUsers = append(allUsers, TopUser{UserID: user.userID, Value: user.value})
		}
		sort.Slice(allUsers, func(i, j int) bool {
			if allUsers[i].Value != allUsers[j].Value {
				return allUsers[i].Value > allUsers[j].Value
			}
			return allUsers[i].UserID < allUsers[j].UserID
		})
		if len(allUsers) > cfg.topK {
			allUsers = allUsers[:cfg.topK]
		}

		result = append(result, Group{
			WindowStart: group.windowStart,
			TenantID:    group.tenantID,
			Type:        group.typeName,
			Count:       group.count,
			Sum:         group.sum,
			UniqueUsers: len(group.users),
			TopUsers:    allUsers,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		if !result[i].WindowStart.Equal(result[j].WindowStart) {
			return result[i].WindowStart.Before(result[j].WindowStart)
		}
		if result[i].TenantID != result[j].TenantID {
			return result[i].TenantID < result[j].TenantID
		}
		return result[i].Type < result[j].Type
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

	return normalizedConfig{
		from:   config.From,
		to:     config.To,
		types:  config.Types,
		window: window,
		topK:   topK,
	}, nil
}

func readAndAggregate(ctx context.Context, input io.Reader, config normalizedConfig) (map[string]*aggregate, error) {
	reader := bufio.NewReader(input)
	aggregates := make(map[string]*aggregate)
	lineNumber := 0

	for {
		line, readErr := reader.ReadString('\n')
		if len(line) > 0 {
			lineNumber++
		}

		if readErr != nil && !errors.Is(readErr, io.EOF) {
			failureLine := lineNumber
			if len(line) == 0 {
				failureLine++
			}
			return nil, fmt.Errorf("line %d: read input: %w", failureLine, readErr)
		}

		if len(line) > 0 {
			if err := ctx.Err(); err != nil {
				return nil, err
			}

			trimmed := strings.TrimSpace(line)
			if trimmed != "" {
				if !utf8.ValidString(trimmed) {
					return nil, fmt.Errorf("line %d: input is not valid UTF-8", lineNumber)
				}
				item, err := parseEvent(trimmed)
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
		}

		if errors.Is(readErr, io.EOF) {
			break
		}
	}

	return aggregates, nil
}

func addEvent(aggregates map[string]*aggregate, config normalizedConfig, item event) error {
	windowStart := item.timestamp.UTC().Truncate(config.window)
	key := fmt.Sprintf(
		"%s:%d:%s:%d:%s",
		windowStart.Format(time.RFC3339Nano),
		len(item.tenantID),
		item.tenantID,
		len(item.typeName),
		item.typeName,
	)
	group, ok := aggregates[key]
	if !ok {
		group = &aggregate{
			windowStart: windowStart,
			tenantID:    item.tenantID,
			typeName:    item.typeName,
			users:       make([]userTotal, 0),
		}
		aggregates[key] = group
	}

	userIndex := -1
	for index := range group.users {
		if group.users[index].userID == item.userID {
			userIndex = index
			break
		}
	}

	nextUserSum := item.value
	if userIndex >= 0 {
		nextUserSum = group.users[userIndex].value + item.value
		if math.IsInf(nextUserSum, 0) {
			return fmt.Errorf("line %d: user sum overflow for user_id %q", item.lineNumber, item.userID)
		}
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
	if userIndex < 0 {
		group.users = append(group.users, userTotal{userID: item.userID, value: item.value})
	} else {
		group.users[userIndex].value = nextUserSum
	}
	return nil
}

func parseEvent(line string) (event, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &fields); err != nil {
		return event{}, fmt.Errorf("invalid JSON: %w", err)
	}

	timestampText, err := requiredString(fields, "timestamp")
	if err != nil {
		return event{}, err
	}
	timestamp, err := time.Parse(time.RFC3339Nano, timestampText)
	if err != nil {
		return event{}, fmt.Errorf("timestamp must be RFC3339Nano with an explicit offset: %w", err)
	}

	tenantID, err := requiredString(fields, "tenant_id")
	if err != nil {
		return event{}, err
	}
	userID, err := requiredString(fields, "user_id")
	if err != nil {
		return event{}, err
	}
	typeName, err := requiredString(fields, "type")
	if err != nil {
		return event{}, err
	}

	valueField, ok := fields["value"]
	if !ok {
		return event{}, errors.New("value is required")
	}
	valueField = bytes.TrimSpace(valueField)
	if len(valueField) == 0 || (valueField[0] != '-' && (valueField[0] < '0' || valueField[0] > '9')) {
		return event{}, errors.New("value must be a number")
	}
	var value float64
	if err := json.Unmarshal(valueField, &value); err != nil {
		return event{}, errors.New("value must be a number")
	}
	if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 {
		return event{}, errors.New("value must be finite and greater than or equal to zero")
	}

	return event{
		timestamp: timestamp,
		tenantID:  tenantID,
		userID:    userID,
		typeName:  typeName,
		value:     value,
	}, nil
}

func requiredString(fields map[string]json.RawMessage, name string) (string, error) {
	value, ok := fields[name]
	if !ok {
		return "", fmt.Errorf("%s is required", name)
	}
	var text string
	if err := json.Unmarshal(value, &text); err != nil {
		return "", fmt.Errorf("%s must be a string", name)
	}
	if text == "" {
		return "", fmt.Errorf("%s must not be empty", name)
	}
	return text, nil
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
	for _, allowedType := range config.types {
		if item.typeName == allowedType {
			return true
		}
	}
	return false
}
