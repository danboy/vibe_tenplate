package integrations

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type asanaProvider struct{}

func init() {
	Register(&asanaProvider{})
}

func (a *asanaProvider) Name() string { return "asana" }

const (
	asanaAuthorizeURL = "https://app.asana.com/-/oauth_authorize"
	asanaTokenURL     = "https://app.asana.com/-/oauth_token"
	asanaAPIBase      = "https://app.asana.com/api/1.0"
)

func (a *asanaProvider) AuthCodeURL(state, redirectURI string) string {
	v := url.Values{}
	v.Set("client_id", os.Getenv("ASANA_CLIENT_ID"))
	v.Set("redirect_uri", redirectURI)
	v.Set("response_type", "code")
	v.Set("state", state)
	return asanaAuthorizeURL + "?" + v.Encode()
}

type asanaTokenResponse struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	Data         struct {
		Name string `json:"name"`
	} `json:"data"`
}

func asanaTokenRequest(ctx context.Context, form url.Values) (*asanaTokenResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, asanaTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("asana token request failed (%d): %s", resp.StatusCode, string(body))
	}

	var out asanaTokenResponse
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (a *asanaProvider) Exchange(ctx context.Context, code, redirectURI string) (*OAuthToken, string, error) {
	form := url.Values{}
	form.Set("grant_type", "authorization_code")
	form.Set("client_id", os.Getenv("ASANA_CLIENT_ID"))
	form.Set("client_secret", os.Getenv("ASANA_CLIENT_SECRET"))
	form.Set("redirect_uri", redirectURI)
	form.Set("code", code)

	tok, err := asanaTokenRequest(ctx, form)
	if err != nil {
		return nil, "", err
	}

	expiresAt := time.Now().Add(time.Duration(tok.ExpiresIn) * time.Second)
	return &OAuthToken{
		AccessToken:  tok.AccessToken,
		RefreshToken: tok.RefreshToken,
		ExpiresAt:    &expiresAt,
	}, tok.Data.Name, nil
}

func (a *asanaProvider) Refresh(ctx context.Context, refreshToken string) (*OAuthToken, error) {
	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("client_id", os.Getenv("ASANA_CLIENT_ID"))
	form.Set("client_secret", os.Getenv("ASANA_CLIENT_SECRET"))
	form.Set("refresh_token", refreshToken)

	tok, err := asanaTokenRequest(ctx, form)
	if err != nil {
		return nil, err
	}

	expiresAt := time.Now().Add(time.Duration(tok.ExpiresIn) * time.Second)
	newRefresh := tok.RefreshToken
	if newRefresh == "" {
		newRefresh = refreshToken
	}
	return &OAuthToken{
		AccessToken:  tok.AccessToken,
		RefreshToken: newRefresh,
		ExpiresAt:    &expiresAt,
	}, nil
}

func (a *asanaProvider) CreateItem(ctx context.Context, accessToken, targetRef, title, body string) (string, string, error) {
	targetRef = strings.TrimSpace(targetRef)
	if targetRef == "" {
		return "", "", fmt.Errorf("target Asana project GID is not set")
	}

	payload, err := json.Marshal(map[string]interface{}{
		"data": map[string]interface{}{
			"name":     title,
			"notes":    body,
			"projects": []string{targetRef},
		},
	})
	if err != nil {
		return "", "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, asanaAPIBase+"/tasks?opt_fields=permalink_url", bytes.NewReader(payload))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("asana task create failed (%d): %s", resp.StatusCode, string(respBody))
	}

	var out struct {
		Data struct {
			GID          string `json:"gid"`
			PermalinkURL string `json:"permalink_url"`
		} `json:"data"`
	}
	if err := json.Unmarshal(respBody, &out); err != nil {
		return "", "", err
	}

	return out.Data.GID, out.Data.PermalinkURL, nil
}
