package handlers

import (
	"net/http"

	"tenplate/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type GoalHandler struct {
	db *gorm.DB
}

func NewGoalHandler(db *gorm.DB) *GoalHandler {
	return &GoalHandler{db: db}
}

// isTeamMember reports whether userID belongs to teamID.
func (h *GoalHandler) isTeamMember(teamID, userID string) bool {
	var count int64
	h.db.Table("team_members").Where("team_id = ? AND user_id = ?", teamID, userID).Count(&count)
	return count > 0
}

// isOwnerOrEditor reports whether userID may create/edit/delete goals for teamID.
func (h *GoalHandler) isOwnerOrEditor(teamID, userID string) bool {
	var team models.Team
	if err := h.db.Where("id = ?", teamID).First(&team).Error; err != nil {
		return false
	}
	if team.OwnerID == userID {
		return true
	}
	var tm models.TeamMember
	if err := h.db.Where("team_id = ? AND user_id = ?", teamID, userID).First(&tm).Error; err != nil {
		return false
	}
	return tm.Role == "editor"
}

func (h *GoalHandler) loadTeamBySlug(c *gin.Context, slug string) (*models.Team, bool) {
	var team models.Team
	if err := h.db.Where("slug = ?", slug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return nil, false
	}
	return &team, true
}

func (h *GoalHandler) loadGoal(c *gin.Context, goalID string) (*models.Goal, bool) {
	var goal models.Goal
	if err := h.db.Preload("KeyResults").Where("id = ?", goalID).First(&goal).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "goal not found"})
		return nil, false
	}
	return &goal, true
}

func (h *GoalHandler) loadKeyResult(c *gin.Context, keyResultID string) (*models.KeyResult, *models.Goal, bool) {
	var kr models.KeyResult
	if err := h.db.Where("id = ?", keyResultID).First(&kr).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "key result not found"})
		return nil, nil, false
	}
	var goal models.Goal
	if err := h.db.Where("id = ?", kr.GoalID).First(&goal).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "goal not found"})
		return nil, nil, false
	}
	return &kr, &goal, true
}

// ── Goals ────────────────────────────────────────────────────────────────────

func (h *GoalHandler) ListGoals(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	team, ok := h.loadTeamBySlug(c, c.Param("id"))
	if !ok {
		return
	}
	if !h.isTeamMember(team.ID, userID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this team"})
		return
	}

	var goals []models.Goal
	if err := h.db.Preload("KeyResults").Where("team_id = ?", team.ID).Find(&goals).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch goals"})
		return
	}
	c.JSON(http.StatusOK, goals)
}

type CreateGoalRequest struct {
	Title        string                   `json:"title" binding:"required"`
	Unit         string                   `json:"unit"`
	TargetValue  float64                  `json:"target_value"`
	CurrentValue float64                  `json:"current_value"`
	KeyResults   []CreateKeyResultRequest `json:"key_results"`
}

func (h *GoalHandler) CreateGoal(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	team, ok := h.loadTeamBySlug(c, c.Param("id"))
	if !ok {
		return
	}
	if !h.isOwnerOrEditor(team.ID, userID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can create goals"})
		return
	}

	var req CreateGoalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	goal := models.Goal{
		TeamID:       team.ID,
		Title:        req.Title,
		Unit:         req.Unit,
		TargetValue:  req.TargetValue,
		CurrentValue: req.CurrentValue,
	}
	for _, kr := range req.KeyResults {
		goal.KeyResults = append(goal.KeyResults, models.KeyResult{
			Title:        kr.Title,
			Unit:         kr.Unit,
			TargetValue:  kr.TargetValue,
			CurrentValue: kr.CurrentValue,
		})
	}

	if err := h.db.Create(&goal).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create goal"})
		return
	}
	c.JSON(http.StatusCreated, goal)
}

type UpdateGoalRequest struct {
	Title        string  `json:"title" binding:"required"`
	Unit         string  `json:"unit"`
	TargetValue  float64 `json:"target_value"`
	CurrentValue float64 `json:"current_value"`
}

func (h *GoalHandler) UpdateGoal(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	goal, ok := h.loadGoal(c, c.Param("id"))
	if !ok {
		return
	}
	if !h.isOwnerOrEditor(goal.TeamID, userID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can edit goals"})
		return
	}

	var req UpdateGoalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	updates := map[string]interface{}{
		"title":         req.Title,
		"unit":          req.Unit,
		"target_value":  req.TargetValue,
		"current_value": req.CurrentValue,
	}
	if err := h.db.Model(goal).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update goal"})
		return
	}

	goal, _ = h.loadGoal(c, goal.ID)
	c.JSON(http.StatusOK, goal)
}

func (h *GoalHandler) DeleteGoal(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	goal, ok := h.loadGoal(c, c.Param("id"))
	if !ok {
		return
	}
	if !h.isOwnerOrEditor(goal.TeamID, userID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can delete goals"})
		return
	}

	if err := h.db.Where("goal_id = ?", goal.ID).Delete(&models.KeyResult{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete goal"})
		return
	}
	if err := h.db.Delete(&models.Goal{}, "id = ?", goal.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete goal"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "goal deleted"})
}

// ── Key Results ──────────────────────────────────────────────────────────────

type CreateKeyResultRequest struct {
	Title        string  `json:"title" binding:"required"`
	Unit         string  `json:"unit"`
	TargetValue  float64 `json:"target_value"`
	CurrentValue float64 `json:"current_value"`
}

func (h *GoalHandler) CreateKeyResult(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	goal, ok := h.loadGoal(c, c.Param("id"))
	if !ok {
		return
	}
	if !h.isOwnerOrEditor(goal.TeamID, userID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can add key results"})
		return
	}

	var req CreateKeyResultRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	kr := models.KeyResult{
		GoalID:       goal.ID,
		Title:        req.Title,
		Unit:         req.Unit,
		TargetValue:  req.TargetValue,
		CurrentValue: req.CurrentValue,
	}
	if err := h.db.Create(&kr).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create key result"})
		return
	}
	c.JSON(http.StatusCreated, kr)
}

type UpdateKeyResultRequest struct {
	Title        string  `json:"title" binding:"required"`
	Unit         string  `json:"unit"`
	TargetValue  float64 `json:"target_value"`
	CurrentValue float64 `json:"current_value"`
}

func (h *GoalHandler) UpdateKeyResult(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	kr, goal, ok := h.loadKeyResult(c, c.Param("id"))
	if !ok {
		return
	}
	if !h.isOwnerOrEditor(goal.TeamID, userID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can edit key results"})
		return
	}

	var req UpdateKeyResultRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	updates := map[string]interface{}{
		"title":         req.Title,
		"unit":          req.Unit,
		"target_value":  req.TargetValue,
		"current_value": req.CurrentValue,
	}
	if err := h.db.Model(kr).Updates(updates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update key result"})
		return
	}
	c.JSON(http.StatusOK, kr)
}

func (h *GoalHandler) DeleteKeyResult(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	kr, goal, ok := h.loadKeyResult(c, c.Param("id"))
	if !ok {
		return
	}
	if !h.isOwnerOrEditor(goal.TeamID, userID) {
		c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can delete key results"})
		return
	}

	if err := h.db.Delete(&models.KeyResult{}, "id = ?", kr.ID).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete key result"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "key result deleted"})
}
