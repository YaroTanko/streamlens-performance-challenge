// Package analyzer reads and aggregates StreamLens event streams.
package analyzer

import "time"

const (
	// DefaultWindow is used when Config.Window is zero.
	DefaultWindow = time.Minute
	// DefaultTopK is used when Config.TopK is zero.
	DefaultTopK = 3
)

// Config controls filtering and aggregation.
// From is inclusive, To is exclusive, and an empty Types list allows all event
// types. Zero values for Window and TopK select their documented defaults.
type Config struct {
	From   *time.Time
	To     *time.Time
	Types  []string
	Window time.Duration
	TopK   int
}

// TopUser is a user's total value within one aggregate group.
type TopUser struct {
	UserID string  `json:"user_id"`
	Value  float64 `json:"value"`
}

// Group is the aggregate for one UTC window, tenant, and event type.
type Group struct {
	WindowStart time.Time `json:"window_start"`
	TenantID    string    `json:"tenant_id"`
	Type        string    `json:"type"`
	Count       int       `json:"count"`
	Sum         float64   `json:"sum"`
	UniqueUsers int       `json:"unique_users"`
	TopUsers    []TopUser `json:"top_users"`
}
