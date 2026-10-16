package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"

	"tenplate/middleware"
	"tenplate/models"
	"tenplate/utils"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/endpoints"
	"gorm.io/gorm"
)

type OAuthHandler struct {
	db *gorm.DB
}

func NewOAuthHandler(db *gorm.DB) *OAuthHandler {
	return &OAuthHandler{db: db}
}

// oauthProfile is the normalized result of fetching a provider's profile —
// enough to resolve/create a local user and check team auto-join rules.
type oauthProfile struct {
	ProviderUserID string
	Email          string
	Name           string
	// Orgs holds the domains/org logins/group paths this account belongs to,
	// matched against TeamSSOConfig.OrgMatch for the same provider.
	Orgs []string
}

func oauthConfig(provider string) *oauth2.Config {
	redirectBase := os.Getenv("OAUTH_REDIRECT_BASE_URL")
	if redirectBase == "" {
		redirectBase = "http://localhost:8080"
	}

	switch provider {
	case "google":
		return &oauth2.Config{
			ClientID:     os.Getenv("GOOGLE_CLIENT_ID"),
			ClientSecret: os.Getenv("GOOGLE_CLIENT_SECRET"),
			Endpoint:     endpoints.Google,
			RedirectURL:  redirectBase + "/api/auth/oauth/google/callback",
			Scopes:       []string{"openid", "email", "profile"},
		}
	case "github":
		return &oauth2.Config{
			ClientID:     os.Getenv("GITHUB_CLIENT_ID"),
			ClientSecret: os.Getenv("GITHUB_CLIENT_SECRET"),
			Endpoint:     endpoints.GitHub,
			RedirectURL:  redirectBase + "/api/auth/oauth/github/callback",
			Scopes:       []string{"read:user", "user:email", "read:org"},
		}
	case "gitlab":
		return &oauth2.Config{
			ClientID:     os.Getenv("GITLAB_CLIENT_ID"),
			ClientSecret: os.Getenv("GITLAB_CLIENT_SECRET"),
			Endpoint:     endpoints.GitLab,
			RedirectURL:  redirectBase + "/api/auth/oauth/gitlab/callback",
			Scopes:       []string{"read_user", "read_api"},
		}
	default:
		return nil
	}
}

type oauthStateClaims struct {
	Redirect string `json:"redirect"`
	Nonce    string `json:"nonce"`
	jwt.RegisteredClaims
}

func randomNonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// Start redirects the browser to the provider's consent screen.
func (h *OAuthHandler) Start(c *gin.Context) {
	provider := c.Param("provider")
	cfg := oauthConfig(provider)
	if cfg == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "unsupported provider"})
		return
	}

	redirect := c.Query("redirect")
	if redirect == "" {
		redirect = "/teams"
	}

	claims := &oauthStateClaims{
		Redirect: redirect,
		Nonce:    randomNonce(),
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(10 * time.Minute)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	state, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(middleware.JWTSecret())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to start oauth flow"})
		return
	}

	c.Redirect(http.StatusFound, cfg.AuthCodeURL(state))
}

func parseOAuthState(state string) (*oauthStateClaims, error) {
	claims := &oauthStateClaims{}
	_, err := jwt.ParseWithClaims(state, claims, func(t *jwt.Token) (interface{}, error) {
		return middleware.JWTSecret(), nil
	})
	if err != nil {
		return nil, err
	}
	return claims, nil
}

func fetchJSON(ctx context.Context, client *http.Client, url string, out interface{}) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
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

func fetchGoogleProfile(ctx context.Context, client *http.Client) (*oauthProfile, error) {
	var info struct {
		Sub   string `json:"sub"`
		Email string `json:"email"`
		Name  string `json:"name"`
		HD    string `json:"hd"`
	}
	if err := fetchJSON(ctx, client, "https://www.googleapis.com/oauth2/v3/userinfo", &info); err != nil {
		return nil, err
	}
	var orgs []string
	if info.HD != "" {
		orgs = append(orgs, info.HD)
	}
	return &oauthProfile{ProviderUserID: info.Sub, Email: info.Email, Name: info.Name, Orgs: orgs}, nil
}

func fetchGitHubProfile(ctx context.Context, client *http.Client) (*oauthProfile, error) {
	var user struct {
		ID    int64  `json:"id"`
		Login string `json:"login"`
		Name  string `json:"name"`
		Email string `json:"email"`
	}
	if err := fetchJSON(ctx, client, "https://api.github.com/user", &user); err != nil {
		return nil, err
	}

	email := user.Email
	if email == "" {
		var emails []struct {
			Email    string `json:"email"`
			Primary  bool   `json:"primary"`
			Verified bool   `json:"verified"`
		}
		if err := fetchJSON(ctx, client, "https://api.github.com/user/emails", &emails); err == nil {
			for _, e := range emails {
				if e.Primary && e.Verified {
					email = e.Email
					break
				}
			}
		}
	}

	var orgs []struct {
		Login string `json:"login"`
	}
	_ = fetchJSON(ctx, client, "https://api.github.com/user/orgs", &orgs)
	orgLogins := make([]string, 0, len(orgs))
	for _, o := range orgs {
		orgLogins = append(orgLogins, o.Login)
	}

	name := user.Name
	if name == "" {
		name = user.Login
	}

	return &oauthProfile{
		ProviderUserID: strconv.FormatInt(user.ID, 10),
		Email:          email,
		Name:           name,
		Orgs:           orgLogins,
	}, nil
}

func fetchGitLabProfile(ctx context.Context, client *http.Client) (*oauthProfile, error) {
	var user struct {
		ID       int64  `json:"id"`
		Username string `json:"username"`
		Name     string `json:"name"`
		Email    string `json:"email"`
	}
	if err := fetchJSON(ctx, client, "https://gitlab.com/api/v4/user", &user); err != nil {
		return nil, err
	}

	var groups []struct {
		FullPath string `json:"full_path"`
	}
	_ = fetchJSON(ctx, client, "https://gitlab.com/api/v4/groups?min_access_level=10", &groups)
	paths := make([]string, 0, len(groups))
	for _, g := range groups {
		paths = append(paths, g.FullPath)
	}

	name := user.Name
	if name == "" {
		name = user.Username
	}

	return &oauthProfile{
		ProviderUserID: strconv.FormatInt(user.ID, 10),
		Email:          user.Email,
		Name:           name,
		Orgs:           paths,
	}, nil
}

// Callback exchanges the auth code, resolves/creates the local user, runs
// team auto-join, and redirects back to the frontend with a session token.
func (h *OAuthHandler) Callback(c *gin.Context) {
	provider := c.Param("provider")
	cfg := oauthConfig(provider)
	if cfg == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "unsupported provider"})
		return
	}

	stateClaims, err := parseOAuthState(c.Query("state"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid or expired oauth state"})
		return
	}

	ctx := c.Request.Context()
	token, err := cfg.Exchange(ctx, c.Query("code"))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "failed to exchange oauth code"})
		return
	}
	client := cfg.Client(ctx, token)

	var profile *oauthProfile
	switch provider {
	case "google":
		profile, err = fetchGoogleProfile(ctx, client)
	case "github":
		profile, err = fetchGitHubProfile(ctx, client)
	case "gitlab":
		profile, err = fetchGitLabProfile(ctx, client)
	}
	if err != nil || profile == nil || profile.Email == "" {
		c.JSON(http.StatusBadGateway, gin.H{"error": "failed to fetch provider profile"})
		return
	}

	user, err := h.resolveUser(provider, profile)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to resolve user"})
		return
	}

	h.autoJoinTeams(provider, profile.Orgs, user)

	sessionToken, err := generateToken(user.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate token"})
		return
	}

	frontendBase := os.Getenv("FRONTEND_BASE_URL")
	if frontendBase == "" {
		frontendBase = "http://localhost:5000"
	}
	redirectURL := frontendBase + "/auth/callback?token=" + sessionToken + "&redirect=" + stateClaims.Redirect
	c.Redirect(http.StatusFound, redirectURL)
}

func (h *OAuthHandler) resolveUser(provider string, profile *oauthProfile) (*models.User, error) {
	var identity models.OAuthIdentity
	err := h.db.Where("provider = ? AND provider_user_id = ?", provider, profile.ProviderUserID).First(&identity).Error
	if err == nil {
		var user models.User
		if err := h.db.Where("id = ?", identity.UserID).First(&user).Error; err != nil {
			return nil, err
		}
		return &user, nil
	}
	if err != gorm.ErrRecordNotFound {
		return nil, err
	}

	var user models.User
	err = h.db.Where("email = ?", profile.Email).First(&user).Error
	if err != nil {
		if err != gorm.ErrRecordNotFound {
			return nil, err
		}
		username := utils.UniqueSlug(utils.Slugify(profile.Name), func(s string) bool {
			var count int64
			h.db.Model(&models.User{}).Where("username = ?", s).Count(&count)
			return count > 0
		})
		randomPassword := randomNonce()
		hash, hashErr := bcrypt.GenerateFromPassword([]byte(randomPassword), bcrypt.DefaultCost)
		if hashErr != nil {
			return nil, hashErr
		}
		user = models.User{
			Username: username,
			Email:    profile.Email,
			Password: string(hash),
		}
		if err := h.db.Create(&user).Error; err != nil {
			return nil, err
		}
	}

	link := models.OAuthIdentity{
		UserID:         user.ID,
		Provider:       provider,
		ProviderUserID: profile.ProviderUserID,
		Email:          profile.Email,
	}
	if err := h.db.Create(&link).Error; err != nil {
		return nil, err
	}

	return &user, nil
}

func (h *OAuthHandler) autoJoinTeams(provider string, orgs []string, user *models.User) {
	if len(orgs) == 0 {
		return
	}

	var configs []models.TeamSSOConfig
	if err := h.db.Where("provider = ? AND org_match IN ?", provider, orgs).Find(&configs).Error; err != nil {
		return
	}

	for _, cfg := range configs {
		var team models.Team
		if err := h.db.Preload("Members").Where("id = ?", cfg.TeamID).First(&team).Error; err != nil {
			continue
		}
		alreadyMember := false
		for _, m := range team.Members {
			if m.ID == user.ID {
				alreadyMember = true
				break
			}
		}
		if alreadyMember {
			continue
		}
		_ = h.db.Model(&team).Association("Members").Append(user)
	}
}
