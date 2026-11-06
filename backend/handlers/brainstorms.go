package handlers

import (
	"net/http"

	"tenplate/models"
	"tenplate/utils"
	"tenplate/ws"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type BrainstormHandler struct {
	db *gorm.DB
}

func NewBrainstormHandler(db *gorm.DB) *BrainstormHandler {
	return &BrainstormHandler{db: db}
}

// brainstormTypes are the valid values for Brainstorm.Type.
var brainstormTypes = map[string]bool{
	"brainstorm": true,
	"card_sort":  true,
	"retro":      true,
}

// retroStyles are the valid values for Brainstorm.RetroStyle when Type == "retro".
var retroStyles = map[string]bool{
	"starfish":            true,
	"start_stop_continue": true,
	"mad_glad":            true,
}

type CreateBrainstormRequest struct {
	Name             string `json:"name" binding:"required,min=2"`
	Type             string `json:"type"`
	RetroStyle       string `json:"retro_style"`
	Description      string `json:"description"`
	ProblemStatement string `json:"problem_statement"`
	EnableProblem    bool   `json:"enable_problem"`
	EnableVote       bool   `json:"enable_vote"`
	EnablePrioritise bool   `json:"enable_prioritise"`
	GuestsEnabled    bool   `json:"guests_enabled"`

	TimerEnabled bool `json:"timer_enabled"`
	TimerMinutes int  `json:"timer_minutes"`

	InterstitialProblem     string `json:"interstitial_problem"`
	InterstitialBrainstorm  string `json:"interstitial_brainstorm"`
	InterstitialGroup       string `json:"interstitial_group"`
	InterstitialVote        string `json:"interstitial_vote"`
	InterstitialPrioritise  string `json:"interstitial_prioritise"`
	InterstitialActionItems string `json:"interstitial_action_items"`
}

// normalizeTimer clamps the timer to a sane duration and forces it off for
// non-retro activities — the countdown only applies to a retro's first step.
func normalizeTimer(isRetro bool, enabled bool, minutes int) (bool, int) {
	if minutes <= 0 {
		minutes = 5
	}
	if minutes > 180 {
		minutes = 180
	}
	if !isRetro {
		return false, minutes
	}
	return enabled, minutes
}

// loadGroupAsMember fetches the group by slug with members preloaded and
// verifies the requesting user is a member.
func (h *BrainstormHandler) loadGroupAsMember(c *gin.Context) (*models.Group, bool) {
	userID := c.MustGet("userID").(string)
	groupSlug := c.Param("id")

	var group models.Group
	if err := h.db.Preload("Members").Preload("Team").Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return nil, false
	}

	for _, m := range group.Members {
		if m.ID == userID {
			return &group, true
		}
	}

	c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this group"})
	return nil, false
}

type brainstormWithUsers struct {
	models.Brainstorm
	ActiveUsers int `json:"active_users"`
}

func (h *BrainstormHandler) ListBrainstorms(c *gin.Context) {
	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	var brainstorms []models.Brainstorm
	if err := h.db.Preload("Creator").Preload("Presenter").Where("group_id = ?", group.ID).Find(&brainstorms).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch brainstorms"})
		return
	}

	resp := make([]brainstormWithUsers, len(brainstorms))
	for i, p := range brainstorms {
		resp[i] = brainstormWithUsers{Brainstorm: p, ActiveUsers: ws.GetClientCount(p.ID)}
	}
	c.JSON(http.StatusOK, resp)
}

func (h *BrainstormHandler) GetBrainstorm(c *gin.Context) {
	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	brainstormSlug := c.Param("bid")

	var brainstorm models.Brainstorm
	if err := h.db.Preload("Creator").Preload("Presenter").
		Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).
		First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	c.JSON(http.StatusOK, brainstorm)
}

func (h *BrainstormHandler) CreateBrainstorm(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	// Only team owners and editors may create brainstorms
	if group.Team != nil {
		isTeamOwner := group.Team.OwnerID == userID
		if !isTeamOwner {
			var tm models.TeamMember
			if err := h.db.Where("team_id = ? AND user_id = ?", group.Team.ID, userID).First(&tm).Error; err != nil || tm.Role != "editor" {
				c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can create brainstorms"})
				return
			}
		}
	}

	var req CreateBrainstormRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if req.Type == "" {
		req.Type = "brainstorm"
	}
	if !brainstormTypes[req.Type] {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid brainstorm type"})
		return
	}
	isCardSort := req.Type == "card_sort"
	isRetro := req.Type == "retro"
	if isRetro && !retroStyles[req.RetroStyle] {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid retro style"})
		return
	}

	groupPlan := "free"
	if group.Team != nil && group.Team.Plan != "" {
		groupPlan = group.Team.Plan
	}

	if groupPlan == "free" {
		var count int64
		h.db.Model(&models.Brainstorm{}).Where("group_id = ?", group.ID).Count(&count)
		if count >= 3 {
			c.JSON(http.StatusForbidden, gin.H{"error": "brainstorm limit reached for this group's plan"})
			return
		}
		// Free groups cannot customize brainstorms or enable guests
		req.EnableProblem = true
		req.EnableVote = true
		req.EnablePrioritise = true
		req.GuestsEnabled = false
		req.TimerEnabled = false
		req.InterstitialProblem = ""
		req.InterstitialBrainstorm = ""
		req.InterstitialGroup = ""
		req.InterstitialVote = ""
		req.InterstitialPrioritise = ""
		req.InterstitialActionItems = ""
	}

	if isCardSort {
		// Card sorting is just two slides — add cards, then group them.
		// None of the brainstorm-pipeline stages apply.
		req.EnableProblem = false
		req.EnableVote = false
		req.EnablePrioritise = false
	}

	if isRetro {
		// Retro is a fixed pipeline: [style board] -> group -> vote -> action items.
		req.EnableProblem = false
		req.EnableVote = true
		req.EnablePrioritise = false
	}

	req.TimerEnabled, req.TimerMinutes = normalizeTimer(isRetro, req.TimerEnabled, req.TimerMinutes)

	slug := utils.UniqueSlug(utils.Slugify(req.Name), func(s string) bool {
		var count int64
		h.db.Model(&models.Brainstorm{}).Where("group_id = ? AND slug = ?", group.ID, s).Count(&count)
		return count > 0
	})

	brainstorm := models.Brainstorm{
		Name:                    req.Name,
		Type:                    req.Type,
		RetroStyle:              req.RetroStyle,
		Slug:                    slug,
		Description:             req.Description,
		ProblemStatement:        req.ProblemStatement,
		GroupID:                 group.ID,
		CreatedBy:               userID,
		EnableProblem:           req.EnableProblem,
		EnableVote:              req.EnableVote,
		EnablePrioritise:        req.EnablePrioritise,
		GuestsEnabled:           req.GuestsEnabled,
		TimerEnabled:            req.TimerEnabled,
		TimerMinutes:            req.TimerMinutes,
		InterstitialProblem:     req.InterstitialProblem,
		InterstitialBrainstorm:  req.InterstitialBrainstorm,
		InterstitialGroup:       req.InterstitialGroup,
		InterstitialVote:        req.InterstitialVote,
		InterstitialPrioritise:  req.InterstitialPrioritise,
		InterstitialActionItems: req.InterstitialActionItems,
	}

	if err := h.db.Create(&brainstorm).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create brainstorm"})
		return
	}
	// UpdateColumns with a map always sets the value even when false,
	// because GORM's zero-value skip only applies to struct-based updates.
	h.db.Model(&brainstorm).UpdateColumns(map[string]any{
		"enable_problem":          req.EnableProblem,
		"enable_vote":             req.EnableVote,
		"enable_prioritise":       req.EnablePrioritise,
		"guests_enabled":          req.GuestsEnabled,
		"timer_enabled":           req.TimerEnabled,
		"timer_minutes":           req.TimerMinutes,
		"interstitial_problem":    req.InterstitialProblem,
		"interstitial_brainstorm": req.InterstitialBrainstorm,
		"interstitial_group":      req.InterstitialGroup,
		"interstitial_vote":        req.InterstitialVote,
		"interstitial_prioritise":  req.InterstitialPrioritise,
		"interstitial_action_items": req.InterstitialActionItems,
	})

	h.db.Preload("Creator").Preload("Presenter").First(&brainstorm, "id = ?", brainstorm.ID)

	c.JSON(http.StatusCreated, brainstorm)
}

func (h *BrainstormHandler) SetPresenter(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	brainstormSlug := c.Param("bid")
	var brainstorm models.Brainstorm
	if err := h.db.Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	if brainstorm.CreatedBy != userID && group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the brainstorm creator or group owner can set the presenter"})
		return
	}

	var req struct {
		UserID *string `json:"user_id"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var presenterUsername *string
	if req.UserID != nil {
		isMember := false
		for _, m := range group.Members {
			if m.ID == *req.UserID {
				isMember = true
				u := m.Username
				presenterUsername = &u
				break
			}
		}
		if !isMember {
			c.JSON(http.StatusBadRequest, gin.H{"error": "user is not a member of this group"})
			return
		}
	}

	h.db.Model(&brainstorm).Update("presenter_id", req.UserID)
	ws.NotifyPresenter(brainstorm.ID, req.UserID, presenterUsername)

	h.db.Preload("Creator").Preload("Presenter").First(&brainstorm, "id = ?", brainstorm.ID)
	c.JSON(http.StatusOK, brainstorm)
}

func (h *BrainstormHandler) UpdateBrainstorm(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	brainstormSlug := c.Param("bid")
	var brainstorm models.Brainstorm
	if err := h.db.Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	if brainstorm.CreatedBy != userID && group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the brainstorm creator or group owner can edit this brainstorm"})
		return
	}

	var req struct {
		Name             string `json:"name" binding:"required,min=2"`
		Description      string `json:"description"`
		ProblemStatement string `json:"problem_statement"`
		EnableProblem    bool   `json:"enable_problem"`
		EnableVote       bool   `json:"enable_vote"`
		EnablePrioritise bool   `json:"enable_prioritise"`
		GuestsEnabled    bool   `json:"guests_enabled"`

		TimerEnabled bool `json:"timer_enabled"`
		TimerMinutes int  `json:"timer_minutes"`

		InterstitialProblem     string `json:"interstitial_problem"`
		InterstitialBrainstorm  string `json:"interstitial_brainstorm"`
		InterstitialGroup       string `json:"interstitial_group"`
		InterstitialVote        string `json:"interstitial_vote"`
		InterstitialPrioritise  string `json:"interstitial_prioritise"`
		InterstitialActionItems string `json:"interstitial_action_items"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	groupPlanForUpdate := "free"
	if group.Team != nil && group.Team.Plan != "" {
		groupPlanForUpdate = group.Team.Plan
	}
	if groupPlanForUpdate == "free" {
		req.EnableProblem = true
		req.EnableVote = true
		req.EnablePrioritise = true
		req.GuestsEnabled = false
		req.TimerEnabled = false
		req.InterstitialProblem = ""
		req.InterstitialBrainstorm = ""
		req.InterstitialGroup = ""
		req.InterstitialVote = ""
		req.InterstitialPrioritise = ""
		req.InterstitialActionItems = ""
	}

	if brainstorm.Type == "card_sort" {
		// Type is immutable after creation and card sorting never has
		// the brainstorm-pipeline stages, regardless of plan.
		req.EnableProblem = false
		req.EnableVote = false
		req.EnablePrioritise = false
	}

	if brainstorm.Type == "retro" {
		// Type/style are immutable after creation; retro is always the
		// same fixed pipeline regardless of plan.
		req.EnableProblem = false
		req.EnableVote = true
		req.EnablePrioritise = false
	}

	req.TimerEnabled, req.TimerMinutes = normalizeTimer(brainstorm.Type == "retro", req.TimerEnabled, req.TimerMinutes)

	h.db.Model(&brainstorm).UpdateColumns(map[string]any{
		"name":                      req.Name,
		"description":               req.Description,
		"problem_statement":         req.ProblemStatement,
		"enable_problem":            req.EnableProblem,
		"enable_vote":               req.EnableVote,
		"enable_prioritise":         req.EnablePrioritise,
		"guests_enabled":            req.GuestsEnabled,
		"timer_enabled":             req.TimerEnabled,
		"timer_minutes":             req.TimerMinutes,
		"interstitial_problem":      req.InterstitialProblem,
		"interstitial_brainstorm":   req.InterstitialBrainstorm,
		"interstitial_group":        req.InterstitialGroup,
		"interstitial_vote":         req.InterstitialVote,
		"interstitial_prioritise":   req.InterstitialPrioritise,
		"interstitial_action_items": req.InterstitialActionItems,
	})

	ws.NotifyTimerConfig(brainstorm.ID, req.TimerEnabled, req.TimerMinutes)

	h.db.Preload("Creator").Preload("Presenter").First(&brainstorm, "id = ?", brainstorm.ID)
	c.JSON(http.StatusOK, brainstorm)
}

func (h *BrainstormHandler) DeleteBrainstorm(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	brainstormSlug := c.Param("bid")

	var brainstorm models.Brainstorm
	if err := h.db.Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	if brainstorm.CreatedBy != userID && group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the brainstorm creator or group owner can delete this brainstorm"})
		return
	}

	h.db.Delete(&brainstorm)
	c.JSON(http.StatusOK, gin.H{"message": "brainstorm deleted"})
}
