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

// GetGuestBrainstorm returns basic project info for unauthenticated users.
// Used by the frontend to decide whether to show the guest join prompt.
func (h *GuestHandler) GetGuestBrainstorm(c *gin.Context) {
	groupSlug := c.Param("id")
	brainstormSlug := c.Param("bid")

	var group models.Group
	if err := h.db.Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	var brainstorm models.Brainstorm
	if err := h.db.Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"id":             brainstorm.ID,
		"name":           brainstorm.Name,
		"guests_enabled": brainstorm.GuestsEnabled,
		"enable_problem": brainstorm.EnableProblem,
	})
}

// GuestJoin issues a short-lived guest JWT for the given brainstorm.
func (h *GuestHandler) GuestJoin(c *gin.Context) {
	brainstormID := c.Param("id")

	var brainstorm models.Brainstorm
	if err := h.db.Where("id = ?", brainstormID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	if !brainstorm.GuestsEnabled {
		c.JSON(http.StatusForbidden, gin.H{"error": "guest access is not enabled for this brainstorm"})
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
