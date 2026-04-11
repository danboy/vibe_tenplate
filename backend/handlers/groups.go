package handlers

import (
	"net/http"

	"tenplate/models"
	"tenplate/utils"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type GroupHandler struct {
	db *gorm.DB
}

func NewGroupHandler(db *gorm.DB) *GroupHandler {
	return &GroupHandler{db: db}
}

func derefStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

type CreateGroupRequest struct {
	Name        string `json:"name"     binding:"required,min=2"`
	Description string `json:"description"`
	TeamSlug    string `json:"team_slug"`
}

type GroupResponse struct {
	ID          string                `json:"id"`
	Slug        string                `json:"slug"`
	Name        string                `json:"name"`
	Description string                `json:"description"`
	OwnerID     string                `json:"owner_id"`
	MemberCount int                   `json:"member_count"`
	IsMember    bool                  `json:"is_member"`
	Plan        string                `json:"plan"`
	TeamID      string                `json:"team_id,omitempty"`
	MyTeamRole  string                `json:"my_team_role,omitempty"`
	Members     []models.UserResponse `json:"members,omitempty"`
}

func groupToResponse(g models.Group, userID string, includeMembers bool, myTeamRole string) GroupResponse {
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
	plan := "free"
	if g.Team != nil && g.Team.Plan != "" {
		plan = g.Team.Plan
	}
	return GroupResponse{
		ID:          g.ID,
		Slug:        g.Slug,
		Name:        g.Name,
		Description: g.Description,
		OwnerID:     g.OwnerID,
		MemberCount: len(g.Members),
		IsMember:    isMember,
		Plan:        plan,
		TeamID:      derefStr(g.TeamID),
		MyTeamRole:  myTeamRole,
		Members:     members,
	}
}

func (h *GroupHandler) ListGroups(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var groups []models.Group
	if err := h.db.Preload("Members").Preload("Team").Find(&groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch groups"})
		return
	}

	response := make([]GroupResponse, len(groups))
	for i, g := range groups {
		response[i] = groupToResponse(g, userID, false, "")
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

	group := models.Group{
		Name:        req.Name,
		Slug:        slug,
		Description: req.Description,
		OwnerID:     userID,
		Members:     []models.User{user},
	}

	myTeamRole := ""
	if req.TeamSlug != "" {
		var team models.Team
		if err := h.db.Where("slug = ?", req.TeamSlug).First(&team).Error; err != nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
			return
		}
		if team.OwnerID == userID {
			myTeamRole = "owner"
		} else {
			var tm models.TeamMember
			if err := h.db.Where("team_id = ? AND user_id = ?", team.ID, userID).First(&tm).Error; err != nil || tm.Role != "editor" {
				c.JSON(http.StatusForbidden, gin.H{"error": "only team owners and editors can create groups"})
				return
			}
			myTeamRole = "editor"
		}
		group.TeamID = &team.ID
	}

	if err := h.db.Create(&group).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create group"})
		return
	}

	h.db.Preload("Team").Preload("Members").Where("id = ?", group.ID).First(&group)
	c.JSON(http.StatusCreated, groupToResponse(group, userID, true, myTeamRole))
}

func (h *GroupHandler) GetGroup(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	slug := c.Param("id")

	var group models.Group
	if err := h.db.Preload("Members").Preload("Team").Where("slug = ?", slug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	myTeamRole := ""
	if group.Team != nil {
		if group.Team.OwnerID == userID {
			myTeamRole = "owner"
		} else {
			var tm models.TeamMember
			if err := h.db.Where("team_id = ? AND user_id = ?", group.Team.ID, userID).First(&tm).Error; err == nil {
				myTeamRole = tm.Role
			}
		}
	}

	c.JSON(http.StatusOK, groupToResponse(group, userID, true, myTeamRole))
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
	if err := h.db.Preload("Groups.Team").Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	response := make([]GroupResponse, len(user.Groups))
	for i, g := range user.Groups {
		plan := "free"
		if g.Team != nil && g.Team.Plan != "" {
			plan = g.Team.Plan
		}
		response[i] = GroupResponse{
			ID:          g.ID,
			Slug:        g.Slug,
			Name:        g.Name,
			Description: g.Description,
			OwnerID:     g.OwnerID,
			IsMember:    true,
			Plan:        plan,
			TeamID:      derefStr(g.TeamID),
		}
	}

	c.JSON(http.StatusOK, response)
}

func (h *GroupHandler) ListTeamGroups(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	teamSlug := c.Param("id")

	var team models.Team
	if err := h.db.Where("slug = ?", teamSlug).First(&team).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "team not found"})
		return
	}

	var groups []models.Group
	if err := h.db.Preload("Members").Preload("Team").Where("team_id = ?", team.ID).Find(&groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch groups"})
		return
	}

	response := make([]GroupResponse, len(groups))
	for i, g := range groups {
		response[i] = groupToResponse(g, userID, false, "")
	}
	c.JSON(http.StatusOK, response)
}
