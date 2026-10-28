package handlers

import (
	"net/http"
	"os"
	"time"

	"tenplate/integrations"
	"tenplate/middleware"
	"tenplate/models"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"gorm.io/gorm"
)

type IntegrationHandler struct {
	db *gorm.DB
}

func NewIntegrationHandler(db *gorm.DB) *IntegrationHandler {
	return &IntegrationHandler{db: db}
}

func integrationRedirectURI(provider string) string {
	redirectBase := os.Getenv("OAUTH_REDIRECT_BASE_URL")
	if redirectBase == "" {
		redirectBase = "http://localhost:8080"
	}
	return redirectBase + "/api/integrations/oauth/" + provider + "/callback"
}

type integrationStateClaims struct {
	TeamID string `json:"team_id"`
	jwt.RegisteredClaims
}

func (h *IntegrationHandler) requireTeamOwner(c *gin.Context, teamSlug, userID string) (*models.Team, bool) {
	var team models.Team
	if err := h.db.Where("slug = ?", teamSlug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return nil, false
	}
	if team.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the team owner can manage integrations"})
		return nil, false
	}
	return &team, true
}

type integrationResponse struct {
	Provider     string `json:"provider"`
	AccountLabel string `json:"account_label"`
	TargetRef    string `json:"target_ref"`
}

func (h *IntegrationHandler) ListIntegrations(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	team, ok := h.requireTeamOwner(c, c.Param("id"), userID)
	if !ok {
		return
	}

	var rows []models.TeamIntegration
	if err := h.db.Where("team_id = ?", team.ID).Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch integrations"})
		return
	}

	out := make([]integrationResponse, 0, len(rows))
	for _, r := range rows {
		out = append(out, integrationResponse{Provider: r.Provider, AccountLabel: r.AccountLabel, TargetRef: r.TargetRef})
	}
	c.JSON(http.StatusOK, out)
}

// ListIntegrationsForGroup lets any group member see what the group's team
// has connected (not just the owner) — needed by the brainstorm export
// screen, which only knows the group's slug, not its team's.
func (h *IntegrationHandler) ListIntegrationsForGroup(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var group models.Group
	if err := h.db.Preload("Members").Preload("Team").Where("slug = ?", c.Param("id")).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}
	isMember := false
	for _, m := range group.Members {
		if m.ID == userID {
			isMember = true
			break
		}
	}
	if !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this group"})
		return
	}

	if group.Team == nil {
		c.JSON(http.StatusOK, []integrationResponse{})
		return
	}

	var rows []models.TeamIntegration
	if err := h.db.Where("team_id = ?", group.Team.ID).Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch integrations"})
		return
	}
	out := make([]integrationResponse, 0, len(rows))
	for _, r := range rows {
		out = append(out, integrationResponse{Provider: r.Provider, AccountLabel: r.AccountLabel, TargetRef: r.TargetRef})
	}
	c.JSON(http.StatusOK, out)
}

// StartConnect redirects the browser to the provider's consent screen. It's
// reached by a full-page browser navigation (not an XHR with an
// Authorization header), so — like the WebSocket endpoint in
// handlers/slideshow.go — it authenticates via a `?token=` query param
// instead of the usual Bearer header.
func (h *IntegrationHandler) StartConnect(c *gin.Context) {
	tokenStr := c.Query("token")
	claims := &middleware.Claims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return middleware.JWTSecret(), nil
	})
	if tokenStr == "" || err != nil || !token.Valid {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid or missing token"})
		return
	}
	userID := claims.UserID

	team, ok := h.requireTeamOwner(c, c.Param("id"), userID)
	if !ok {
		return
	}

	provider := c.Param("provider")
	p, err := integrations.Get(provider)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	stateClaims := &integrationStateClaims{
		TeamID: team.ID,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(10 * time.Minute)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	state, err := jwt.NewWithClaims(jwt.SigningMethodHS256, stateClaims).SignedString(middleware.JWTSecret())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to start integration connect"})
		return
	}

	c.Redirect(http.StatusFound, p.AuthCodeURL(state, integrationRedirectURI(provider)))
}

// Callback exchanges the auth code, upserts the TeamIntegration, and
// redirects back to the frontend. Public — the provider redirects the
// browser here directly, with no app session attached.
func (h *IntegrationHandler) Callback(c *gin.Context) {
	provider := c.Param("provider")
	p, err := integrations.Get(provider)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	claims := &integrationStateClaims{}
	_, err = jwt.ParseWithClaims(c.Query("state"), claims, func(t *jwt.Token) (interface{}, error) {
		return middleware.JWTSecret(), nil
	})
	if err != nil || claims.TeamID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid or expired integration state"})
		return
	}

	ctx := c.Request.Context()
	token, accountLabel, err := p.Exchange(ctx, c.Query("code"), integrationRedirectURI(provider))
	if err != nil {
		c.JSON(http.StatusBadGateway, gin.H{"error": "failed to connect " + provider})
		return
	}

	var existing models.TeamIntegration
	err = h.db.Where("team_id = ? AND provider = ?", claims.TeamID, provider).First(&existing).Error
	if err == nil {
		h.db.Model(&existing).Updates(map[string]interface{}{
			"access_token":     token.AccessToken,
			"refresh_token":    token.RefreshToken,
			"token_expires_at": token.ExpiresAt,
			"account_label":    accountLabel,
		})
	} else {
		h.db.Create(&models.TeamIntegration{
			TeamID:         claims.TeamID,
			Provider:       provider,
			AccessToken:    token.AccessToken,
			RefreshToken:   token.RefreshToken,
			TokenExpiresAt: token.ExpiresAt,
			AccountLabel:   accountLabel,
		})
	}

	frontendBase := os.Getenv("FRONTEND_BASE_URL")
	if frontendBase == "" {
		frontendBase = "http://localhost:5000"
	}
	c.Redirect(http.StatusFound, frontendBase+"/integrations/callback?connected="+provider)
}

type SetIntegrationTargetRequest struct {
	TargetRef string `json:"target_ref" binding:"required"`
}

func (h *IntegrationHandler) SetTargetRef(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	team, ok := h.requireTeamOwner(c, c.Param("id"), userID)
	if !ok {
		return
	}

	var req SetIntegrationTargetRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	provider := c.Param("provider")
	result := h.db.Model(&models.TeamIntegration{}).
		Where("team_id = ? AND provider = ?", team.ID, provider).
		Update("target_ref", req.TargetRef)
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update target"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": provider + " is not connected"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "target updated"})
}

func (h *IntegrationHandler) Disconnect(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	team, ok := h.requireTeamOwner(c, c.Param("id"), userID)
	if !ok {
		return
	}

	provider := c.Param("provider")
	if err := h.db.Where("team_id = ? AND provider = ?", team.ID, provider).Delete(&models.TeamIntegration{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to disconnect"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "disconnected"})
}
