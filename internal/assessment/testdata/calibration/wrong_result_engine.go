package analyzer

import (
	"context"
	"io"
)

// Analyze deliberately returns a plausible but incorrect empty result. The
// fixture is copied to a private candidate checkout and must only run through
// the isolated assessment entry point.
func Analyze(_ context.Context, _ io.Reader, _ Config) ([]Group, error) {
	return []Group{}, nil
}
