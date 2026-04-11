package handlers

import (
	"log"
	"math/rand"
	"net/http"
	"os"

	"tenplate/models"
	"tenplate/utils"

	"github.com/gin-gonic/gin"
	stripelib "github.com/stripe/stripe-go/v76"
	checkoutsession "github.com/stripe/stripe-go/v76/checkout/session"
	portalsession "github.com/stripe/stripe-go/v76/billingportal/session"
	"gorm.io/gorm"
)

type TeamHandler struct {
	db *gorm.DB
}

func NewTeamHandler(db *gorm.DB) *TeamHandler {
	stripelib.Key = os.Getenv("STRIPE_SECRET_KEY")
	return &TeamHandler{db: db}
}

func generateTeamJoinCode() string {
	const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 8)
	for i := range b {
		b[i] = chars[rand.Intn(len(chars))]
	}
	return string(b)
}

type TeamMemberResponse struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
	Role     string `json:"role"`
}

type TeamResponse struct {
	ID          string               `json:"id"`
	Slug        string               `json:"slug"`
	Name        string               `json:"name"`
	Description string               `json:"description"`
	OwnerID     string               `json:"owner_id"`
	Plan        string               `json:"plan"`
	IsPrivate   bool                 `json:"is_private"`
	JoinCode    string               `json:"join_code,omitempty"`
	MemberCount int                  `json:"member_count"`
	IsMember    bool                 `json:"is_member"`
	Members     []TeamMemberResponse `json:"members,omitempty"`
}

func teamToResponse(t models.Team, userID string, includeMembers bool, roleMap map[string]string) TeamResponse {
	isMember := false
	var members []TeamMemberResponse
	for _, m := range t.Members {
		if m.ID == userID {
			isMember = true
		}
		if includeMembers {
			role := "member"
			if m.ID == t.OwnerID {
				role = "owner"
			} else if roleMap != nil {
				if r, ok := roleMap[m.ID]; ok {
					role = r
				}
			}
			members = append(members, TeamMemberResponse{
				ID:       m.ID,
				Username: m.Username,
				Email:    m.Email,
				Role:     role,
			})
		}
	}
	plan := t.Plan
	if plan == "" {
		plan = "free"
	}
	joinCode := ""
	if t.OwnerID == userID {
		joinCode = t.JoinCode
	}
	return TeamResponse{
		ID:          t.ID,
		Slug:        t.Slug,
		Name:        t.Name,
		Description: t.Description,
		OwnerID:     t.OwnerID,
		Plan:        plan,
		IsPrivate:   t.IsPrivate,
		JoinCode:    joinCode,
		MemberCount: len(t.Members),
		IsMember:    isMember,
		Members:     members,
	}
}

type CreateTeamRequest struct {
	Name        string `json:"name"        binding:"required,min=2"`
	Description string `json:"description"`
	IsPrivate   bool   `json:"is_private"`
}

func (h *TeamHandler) CreateTeam(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var req CreateTeamRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	slug := utils.UniqueSlug(utils.Slugify(req.Name), func(s string) bool {
		var count int64
		h.db.Model(&models.Team{}).Where("slug = ?", s).Count(&count)
		return count > 0
	})

	joinCode := ""
	if req.IsPrivate {
		joinCode = generateTeamJoinCode()
	}

	team := models.Team{
		Name:        req.Name,
		Slug:        slug,
		Description: req.Description,
		OwnerID:     userID,
		IsPrivate:   req.IsPrivate,
		JoinCode:    joinCode,
		Members:     []models.User{user},
	}

	if err := h.db.Create(&team).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create team"})
		return
	}

	c.JSON(http.StatusCreated, TeamResponse{
		ID:          team.ID,
		Slug:        team.Slug,
		Name:        team.Name,
		Description: team.Description,
		OwnerID:     team.OwnerID,
		Plan:        "free",
		IsPrivate:   team.IsPrivate,
		JoinCode:    team.JoinCode,
		MemberCount: 1,
		IsMember:    true,
	})
}

func (h *TeamHandler) GetTeam(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	slug := c.Param("id")

	var team models.Team
	if err := h.db.Preload("Members").Where("slug = ?", slug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}

	var teamMembers []models.TeamMember
	h.db.Where("team_id = ?", team.ID).Find(&teamMembers)
	roleMap := map[string]string{}
	for _, tm := range teamMembers {
		roleMap[tm.UserID] = tm.Role
	}

	c.JSON(http.StatusOK, teamToResponse(team, userID, true, roleMap))
}

func (h *TeamHandler) ListTeams(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var teams []models.Team
	if err := h.db.Preload("Members").Find(&teams).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch teams"})
		return
	}

	response := make([]TeamResponse, len(teams))
	for i, t := range teams {
		response[i] = teamToResponse(t, userID, false, nil)
	}
	c.JSON(http.StatusOK, response)
}

func (h *TeamHandler) ListMyTeams(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var user models.User
	if err := h.db.Preload("Teams.Members").Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	response := make([]TeamResponse, len(user.Teams))
	for i, t := range user.Teams {
		response[i] = teamToResponse(t, userID, false, nil)
	}

	c.JSON(http.StatusOK, response)
}

// ── Membership ────────────────────────────────────────────────────────────────

type JoinTeamRequest struct {
	Code string `json:"code"`
}

func (h *TeamHandler) JoinTeam(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	slug := c.Param("id")

	var team models.Team
	if err := h.db.Preload("Members").Where("slug = ?", slug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}

	for _, m := range team.Members {
		if m.ID == userID {
			c.JSON(http.StatusConflict, gin.H{"error": "already a member"})
			return
		}
	}

	if team.IsPrivate {
		var req JoinTeamRequest
		_ = c.ShouldBindJSON(&req)
		if req.Code != team.JoinCode {
			c.JSON(http.StatusForbidden, gin.H{"error": "invalid invite code"})
			return
		}
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	if err := h.db.Model(&team).Association("Members").Append(&user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to join team"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "successfully joined team"})
}

func (h *TeamHandler) JoinByCode(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var req JoinTeamRequest
	if err := c.ShouldBindJSON(&req); err != nil || req.Code == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "code is required"})
		return
	}

	var team models.Team
	if err := h.db.Preload("Members").Where("join_code = ? AND is_private = ?", req.Code, true).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "invalid invite code"})
		return
	}

	// Already a member — still return success so the client can navigate
	for _, m := range team.Members {
		if m.ID == userID {
			c.JSON(http.StatusOK, gin.H{"slug": team.Slug, "name": team.Name})
			return
		}
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	if err := h.db.Model(&team).Association("Members").Append(&user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to join team"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"slug": team.Slug, "name": team.Name})
}

func (h *TeamHandler) LeaveTeam(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	slug := c.Param("id")

	var team models.Team
	if err := h.db.Where("slug = ?", slug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}
	if team.OwnerID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "owner cannot leave their own team"})
		return
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	if err := h.db.Model(&team).Association("Members").Delete(&user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to leave team"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "successfully left team"})
}

// ── Roles ────────────────────────────────────────────────────────────────────

type UpdateMemberRoleRequest struct {
	Role string `json:"role" binding:"required,oneof=member editor"`
}

func (h *TeamHandler) UpdateMemberRole(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	teamSlug := c.Param("id")
	targetUserID := c.Param("userId")

	var req UpdateMemberRoleRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "role must be 'member' or 'editor'"})
		return
	}

	var team models.Team
	if err := h.db.Where("slug = ?", teamSlug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}

	// Only owner or editors may manage roles
	isOwner := team.OwnerID == userID
	if !isOwner {
		var callerRole models.TeamMember
		if err := h.db.Where("team_id = ? AND user_id = ?", team.ID, userID).First(&callerRole).Error; err != nil || callerRole.Role != "editor" {
			c.JSON(http.StatusForbidden, gin.H{"error": "only owners and editors can change member roles"})
			return
		}
	}

	if targetUserID == team.OwnerID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot change the owner's role"})
		return
	}

	result := h.db.Model(&models.TeamMember{}).
		Where("team_id = ? AND user_id = ?", team.ID, targetUserID).
		Update("role", req.Role)
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update role"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "member not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "role updated"})
}

// ── Billing ──────────────────────────────────────────────────────────────────

func (h *TeamHandler) CreateCheckoutSession(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	teamSlug := c.Param("id")

	var req CheckoutRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if req.Plan != "standard" && req.Plan != "pro" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid plan"})
		return
	}

	priceID := planToPriceID(req.Plan)
	if priceID == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "price not configured"})
		return
	}

	var team models.Team
	if err := h.db.Where("slug = ?", teamSlug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}
	if team.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the team owner can change the plan"})
		return
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	params := &stripelib.CheckoutSessionParams{
		Mode: stripelib.String("subscription"),
		LineItems: []*stripelib.CheckoutSessionLineItemParams{
			{Price: stripelib.String(priceID), Quantity: stripelib.Int64(1)},
		},
		SuccessURL: stripelib.String(req.SuccessURL),
		CancelURL:  stripelib.String(req.CancelURL),
		Metadata: map[string]string{
			"team_id": team.ID,
			"plan":    req.Plan,
			"user_id": userID,
		},
	}
	if user.StripeCustomerID != "" {
		params.Customer = stripelib.String(user.StripeCustomerID)
	} else {
		params.CustomerEmail = stripelib.String(user.Email)
	}

	s, err := checkoutsession.New(params)
	if err != nil {
		log.Printf("stripe checkout error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create checkout session"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"url": s.URL})
}

func (h *TeamHandler) CreatePortalSession(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	teamSlug := c.Param("id")

	var req PortalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var team models.Team
	if err := h.db.Where("slug = ?", teamSlug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}
	if team.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the team owner can manage billing"})
		return
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}
	if user.StripeCustomerID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "no billing account found for this team"})
		return
	}

	params := &stripelib.BillingPortalSessionParams{
		Customer:  stripelib.String(user.StripeCustomerID),
		ReturnURL: stripelib.String(req.ReturnURL),
	}
	s, err := portalsession.New(params)
	if err != nil {
		log.Printf("stripe portal error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create portal session"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"url": s.URL})
}
