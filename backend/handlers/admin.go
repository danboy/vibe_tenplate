package handlers

import (
	"net/http"

	"tenplate/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type AdminHandler struct {
	db *gorm.DB
}

func NewAdminHandler(db *gorm.DB) *AdminHandler {
	return &AdminHandler{db: db}
}

// ListAllTeams returns all teams with basic info for admin use.
func (h *AdminHandler) ListAllTeams(c *gin.Context) {
	var teams []models.Team
	if err := h.db.Find(&teams).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch teams"})
		return
	}
	c.JSON(http.StatusOK, teams)
}

// UpdateTeamPlan sets a team's plan directly without payment.
func (h *AdminHandler) UpdateTeamPlan(c *gin.Context) {
	teamID := c.Param("id")

	var req struct {
		Plan string `json:"plan" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	switch req.Plan {
	case "free", "standard", "pro":
	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid plan; must be free, standard, or pro"})
		return
	}

	result := h.db.Model(&models.Team{}).Where("id = ?", teamID).Update("plan", req.Plan)
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to update plan"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}

	var team models.Team
	h.db.Where("id = ?", teamID).First(&team)
	c.JSON(http.StatusOK, team)
}
