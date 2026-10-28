// Package integrations implements third-party export targets (GitHub,
// Asana, ...) behind a common Provider interface, so adding a new target is
// a new file plus a registry entry rather than a change to the export flow.
package integrations

import (
	"context"
	"fmt"
	"time"
)

// OAuthToken is the normalized result of an OAuth code exchange or refresh.
// Expiry is nil for providers (like GitHub's classic OAuth apps) whose
// tokens don't expire.
type OAuthToken struct {
	AccessToken  string
	RefreshToken string
	ExpiresAt    *time.Time
}

// Provider is one export target.
type Provider interface {
	// Name is the stable identifier used in routes, DB rows, and API payloads.
	Name() string

	// AuthCodeURL builds the consent-screen URL for state/redirectURI.
	AuthCodeURL(state, redirectURI string) string

	// Exchange trades an auth code for a token and a human-readable label
	// for the connected account (e.g. a GitHub login or Asana workspace name).
	Exchange(ctx context.Context, code, redirectURI string) (*OAuthToken, string, error)

	// Refresh returns a new token from a refresh token. Providers whose
	// tokens never expire (GitHub) just return nil, nil.
	Refresh(ctx context.Context, refreshToken string) (*OAuthToken, error)

	// CreateItem creates one issue/task under targetRef and returns its
	// external id and a URL a human can open.
	CreateItem(ctx context.Context, accessToken, targetRef, title, body string) (externalID, externalURL string, err error)
}

var registry = map[string]Provider{}

// Register adds a provider to the registry. Called from each provider's
// init() so the registry is populated just by importing this package.
func Register(p Provider) {
	registry[p.Name()] = p
}

// Get returns the provider for name, or an error if it's not registered.
func Get(name string) (Provider, error) {
	p, ok := registry[name]
	if !ok {
		return nil, fmt.Errorf("unknown integration provider %q", name)
	}
	return p, nil
}

// Names lists all registered provider names.
func Names() []string {
	names := make([]string, 0, len(registry))
	for name := range registry {
		names = append(names, name)
	}
	return names
}
