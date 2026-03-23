package handlers

import (
	"math/rand"
	"net/http"

	"tenplate/models"
	"tenplate/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

func generateJoinCode() string {
	const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	b := make([]byte, 8)
	for i := range b {
		b[i] = chars[rand.Intn(len(chars))]
	}
	return string(b)
}

type GroupHandler struct {
	db *gorm.DB
}

func NewGroupHandler(db *gorm.DB) *GroupHandler {
	return &GroupHandler{db: db}
}

type CreateGroupRequest struct {
	Name        string `json:"name" binding:"required,min=2"`
	Description string `json:"description"`
	IsPrivate   bool   `json:"is_private"`
}

type GroupResponse struct {
	ID          string                `json:"id"`
	Slug        string                `json:"slug"`
	Name        string                `json:"name"`
	Description string                `json:"description"`
	OwnerID     string                `json:"owner_id"`
	MemberCount int                   `json:"member_count"`
	IsMember    bool                  `json:"is_member"`
	IsPrivate   bool                  `json:"is_private"`
	JoinCode    string                `json:"join_code,omitempty"`
	Members     []models.UserResponse `json:"members,omitempty"`
}

func groupToResponse(g models.Group, userID string, includeMembers bool) GroupResponse {
	isMember := false
	var members []models.UserResponse
	for _, m := range g.Members {
		if m.ID == userID {
			isMember = true
		}
		if includeMembers {
			members = append(members, m.ToResponse())
		}
	}
	joinCode := ""
	if g.OwnerID == userID {
		joinCode = g.JoinCode
	}
	return GroupResponse{
		ID:          g.ID,
		Slug:        g.Slug,
		Name:        g.Name,
		Description: g.Description,
		OwnerID:     g.OwnerID,
		MemberCount: len(g.Members),
		IsMember:    isMember,
		IsPrivate:   g.IsPrivate,
		JoinCode:    joinCode,
		Members:     members,
	}
}

func (h *GroupHandler) ListGroups(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var groups []models.Group
	if err := h.db.Preload("Members").Find(&groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch groups"})
		return
	}

	response := make([]GroupResponse, len(groups))
	for i, g := range groups {
		response[i] = groupToResponse(g, userID, false)
	}
	c.JSON(http.StatusOK, response)
}

func (h *GroupHandler) CreateGroup(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var req CreateGroupRequest
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
		h.db.Model(&models.Group{}).Where("slug = ?", s).Count(&count)
		return count > 0
	})

	joinCode := ""
	if req.IsPrivate {
		joinCode = generateJoinCode()
	}

	group := models.Group{
		Name:        req.Name,
		Slug:        slug,
		Description: req.Description,
		OwnerID:     userID,
		IsPrivate:   req.IsPrivate,
		JoinCode:    joinCode,
		Members:     []models.User{user},
	}

	if err := h.db.Create(&group).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create group"})
		return
	}

	c.JSON(http.StatusCreated, GroupResponse{
		ID:          group.ID,
		Slug:        group.Slug,
		Name:        group.Name,
		Description: group.Description,
		OwnerID:     group.OwnerID,
		MemberCount: 1,
		IsMember:    true,
		IsPrivate:   group.IsPrivate,
		JoinCode:    group.JoinCode,
	})
}

func (h *GroupHandler) GetGroup(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	slug := c.Param("id")

	var group models.Group
	if err := h.db.Preload("Members").Where("slug = ?", slug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	c.JSON(http.StatusOK, groupToResponse(group, userID, true))
}

type JoinGroupRequest struct {
	Code string `json:"code"`
}

func (h *GroupHandler) JoinGroup(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	slug := c.Param("id")

	var group models.Group
	if err := h.db.Preload("Members").Where("slug = ?", slug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	for _, m := range group.Members {
		if m.ID == userID {
			c.JSON(http.StatusConflict, gin.H{"error": "already a member"})
			return
		}
	}

	if group.IsPrivate {
		var req JoinGroupRequest
		_ = c.ShouldBindJSON(&req)
		if req.Code != group.JoinCode {
			c.JSON(http.StatusForbidden, gin.H{"error": "invalid invite code"})
			return
		}
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	if err := h.db.Model(&group).Association("Members").Append(&user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to join group"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "successfully joined group"})
}

func (h *GroupHandler) JoinByCode(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var req JoinGroupRequest
	if err := c.ShouldBindJSON(&req); err != nil || req.Code == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "code is required"})
		return
	}

	var group models.Group
	if err := h.db.Preload("Members").Where("join_code = ? AND is_private = ?", req.Code, true).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "invalid invite code"})
		return
	}

	for _, m := range group.Members {
		if m.ID == userID {
			c.JSON(http.StatusOK, gin.H{"slug": group.Slug, "name": group.Name})
			return
		}
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	if err := h.db.Model(&group).Association("Members").Append(&user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to join group"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"slug": group.Slug, "name": group.Name})
}

func (h *GroupHandler) LeaveGroup(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	slug := c.Param("id")

	var group models.Group
	if err := h.db.Where("slug = ?", slug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	if group.OwnerID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "owner cannot leave their own group"})
		return
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	if err := h.db.Model(&group).Association("Members").Delete(&user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to leave group"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "successfully left group"})
}

func (h *GroupHandler) GetMyGroups(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var user models.User
	if err := h.db.Preload("Groups").Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	response := make([]GroupResponse, len(user.Groups))
	for i, g := range user.Groups {
		joinCode := ""
		if g.OwnerID == userID {
			joinCode = g.JoinCode
		}
		response[i] = GroupResponse{
			ID:          g.ID,
			Slug:        g.Slug,
			Name:        g.Name,
			Description: g.Description,
			OwnerID:     g.OwnerID,
			IsMember:    true,
			IsPrivate:   g.IsPrivate,
			JoinCode:    joinCode,
		}
	}

	c.JSON(http.StatusOK, response)
}
