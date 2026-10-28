package integrations

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/endpoints"
)

type githubProvider struct{}

func init() {
	Register(&githubProvider{})
}

func (g *githubProvider) Name() string { return "github" }

// githubConfig reuses the app's existing GitHub OAuth App (GITHUB_CLIENT_ID/
// SECRET, already used for login SSO) but requests the "repo" scope needed
// to create issues — GitHub lets the same app be re-authorized with a
// different scope set per authorization, so no new app is required.
func githubConfig(redirectURI string) *oauth2.Config {
	return &oauth2.Config{
		ClientID:     os.Getenv("GITHUB_CLIENT_ID"),
		ClientSecret: os.Getenv("GITHUB_CLIENT_SECRET"),
		Endpoint:     endpoints.GitHub,
		RedirectURL:  redirectURI,
		Scopes:       []string{"repo"},
	}
}

func (g *githubProvider) AuthCodeURL(state, redirectURI string) string {
	return githubConfig(redirectURI).AuthCodeURL(state)
}

func (g *githubProvider) Exchange(ctx context.Context, code, redirectURI string) (*OAuthToken, string, error) {
	cfg := githubConfig(redirectURI)
	token, err := cfg.Exchange(ctx, code)
	if err != nil {
		return nil, "", err
	}

	var user struct {
		Login string `json:"login"`
	}
	if err := githubGet(ctx, token.AccessToken, "https://api.github.com/user", &user); err != nil {
		return nil, "", err
	}

	// Classic GitHub OAuth App tokens don't expire.
	return &OAuthToken{AccessToken: token.AccessToken}, user.Login, nil
}

func (g *githubProvider) Refresh(ctx context.Context, refreshToken string) (*OAuthToken, error) {
	return nil, nil
}

func (g *githubProvider) CreateItem(ctx context.Context, accessToken, targetRef, title, body string) (string, string, error) {
	targetRef = strings.TrimSpace(strings.TrimPrefix(targetRef, "/"))
	parts := strings.SplitN(targetRef, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", fmt.Errorf("target repo must look like \"owner/repo\", got %q", targetRef)
	}

	payload, err := json.Marshal(map[string]string{"title": title, "body": body})
	if err != nil {
		return "", "", err
	}

	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/issues", parts[0], parts[1])
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Authorization", "token "+accessToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusCreated {
		return "", "", fmt.Errorf("github issue create failed (%d): %s", resp.StatusCode, string(respBody))
	}

	var issue struct {
		Number  int    `json:"number"`
		HTMLURL string `json:"html_url"`
	}
	if err := json.Unmarshal(respBody, &issue); err != nil {
		return "", "", err
	}

	return fmt.Sprintf("%d", issue.Number), issue.HTMLURL, nil
}

func githubGet(ctx context.Context, accessToken, url string, out interface{}) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "token "+accessToken)
	req.Header.Set("Accept", "application/vnd.github+json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	return json.Unmarshal(body, out)
}
