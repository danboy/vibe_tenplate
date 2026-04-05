package handlers

import (
	"net/http"
	"time"

	"tenplate/middleware"
	"tenplate/models"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type GuestHandler struct {
	db *gorm.DB
}

func NewGuestHandler(db *gorm.DB) *GuestHandler {
	return &GuestHandler{db: db}
}

// GetGuestProject returns basic project info for unauthenticated users.
// Used by the frontend to decide whether to show the guest join prompt.
func (h *GuestHandler) GetGuestProject(c *gin.Context) {
	groupSlug := c.Param("id")
	projectSlug := c.Param("pid")

	var group models.Group
	if err := h.db.Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	var project models.Project
	if err := h.db.Where("slug = ? AND group_id = ?", projectSlug, group.ID).First(&project).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "project not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"id":             project.ID,
		"name":           project.Name,
		"guests_enabled": project.GuestsEnabled,
		"enable_problem": project.EnableProblem,
	})
}

// GuestJoin issues a short-lived guest JWT for the given project.
func (h *GuestHandler) GuestJoin(c *gin.Context) {
	projectID := c.Param("id")

	var project models.Project
	if err := h.db.Where("id = ?", projectID).First(&project).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "project not found"})
		return
	}

	if !project.GuestsEnabled {
		c.JSON(http.StatusForbidden, gin.H{"error": "guest access is not enabled for this project"})
		return
	}

	var req struct {
		DisplayName string `json:"display_name" binding:"required,min=1,max=50"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	claims := &middleware.Claims{
		UserID:      "guest:" + uuid.New().String(),
		DisplayName: req.DisplayName,
		IsGuest:     true,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(4 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	signed, err := token.SignedString(middleware.JWTSecret())
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate token"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"token": signed})
}
