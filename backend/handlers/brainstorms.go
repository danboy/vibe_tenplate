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

type CreateBrainstormRequest struct {
	Name             string `json:"name" binding:"required,min=2"`
	Description      string `json:"description"`
	ProblemStatement string `json:"problem_statement"`
	EnableProblem    bool   `json:"enable_problem"`
	EnableVote       bool   `json:"enable_vote"`
	EnablePrioritise bool   `json:"enable_prioritise"`
	GuestsEnabled    bool   `json:"guests_enabled"`

	InterstitialProblem    string `json:"interstitial_problem"`
	InterstitialBrainstorm string `json:"interstitial_brainstorm"`
	InterstitialGroup      string `json:"interstitial_group"`
	InterstitialVote       string `json:"interstitial_vote"`
	InterstitialPrioritise string `json:"interstitial_prioritise"`
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
		req.InterstitialProblem = ""
		req.InterstitialBrainstorm = ""
		req.InterstitialGroup = ""
		req.InterstitialVote = ""
		req.InterstitialPrioritise = ""
	}

	slug := utils.UniqueSlug(utils.Slugify(req.Name), func(s string) bool {
		var count int64
		h.db.Model(&models.Brainstorm{}).Where("group_id = ? AND slug = ?", group.ID, s).Count(&count)
		return count > 0
	})

	brainstorm := models.Brainstorm{
		Name:                   req.Name,
		Slug:                   slug,
		Description:            req.Description,
		ProblemStatement:       req.ProblemStatement,
		GroupID:                group.ID,
		CreatedBy:              userID,
		EnableProblem:          req.EnableProblem,
		EnableVote:             req.EnableVote,
		EnablePrioritise:       req.EnablePrioritise,
		GuestsEnabled:          req.GuestsEnabled,
		InterstitialProblem:    req.InterstitialProblem,
		InterstitialBrainstorm: req.InterstitialBrainstorm,
		InterstitialGroup:      req.InterstitialGroup,
		InterstitialVote:       req.InterstitialVote,
		InterstitialPrioritise: req.InterstitialPrioritise,
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
		"interstitial_problem":    req.InterstitialProblem,
		"interstitial_brainstorm": req.InterstitialBrainstorm,
		"interstitial_group":      req.InterstitialGroup,
		"interstitial_vote":       req.InterstitialVote,
		"interstitial_prioritise": req.InterstitialPrioritise,
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

		InterstitialProblem    string `json:"interstitial_problem"`
		InterstitialBrainstorm string `json:"interstitial_brainstorm"`
		InterstitialGroup      string `json:"interstitial_group"`
		InterstitialVote       string `json:"interstitial_vote"`
		InterstitialPrioritise string `json:"interstitial_prioritise"`
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
		req.InterstitialProblem = ""
		req.InterstitialBrainstorm = ""
		req.InterstitialGroup = ""
		req.InterstitialVote = ""
		req.InterstitialPrioritise = ""
	}

	h.db.Model(&brainstorm).UpdateColumns(map[string]any{
		"name":                    req.Name,
		"description":             req.Description,
		"problem_statement":       req.ProblemStatement,
		"enable_problem":          req.EnableProblem,
		"enable_vote":             req.EnableVote,
		"enable_prioritise":       req.EnablePrioritise,
		"guests_enabled":          req.GuestsEnabled,
		"interstitial_problem":    req.InterstitialProblem,
		"interstitial_brainstorm": req.InterstitialBrainstorm,
		"interstitial_group":      req.InterstitialGroup,
		"interstitial_vote":       req.InterstitialVote,
		"interstitial_prioritise": req.InterstitialPrioritise,
	})

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
