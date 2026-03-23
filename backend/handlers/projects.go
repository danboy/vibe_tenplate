package handlers

import (
	"net/http"

	"tenplate/models"
	"tenplate/utils"
	"tenplate/ws"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type ProjectHandler struct {
	db *gorm.DB
}

func NewProjectHandler(db *gorm.DB) *ProjectHandler {
	return &ProjectHandler{db: db}
}

type CreateProjectRequest struct {
	Name             string `json:"name" binding:"required,min=2"`
	Description      string `json:"description"`
	EnableVote       bool   `json:"enable_vote"`
	EnablePrioritise bool   `json:"enable_prioritise"`
}

// loadGroupAsMember fetches the group by slug with members preloaded and
// verifies the requesting user is a member.
func (h *ProjectHandler) loadGroupAsMember(c *gin.Context) (*models.Group, bool) {
	userID := c.MustGet("userID").(string)
	groupSlug := c.Param("id")

	var group models.Group
	if err := h.db.Preload("Members").Where("slug = ?", groupSlug).First(&group).Error; err != nil {
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

func (h *ProjectHandler) ListProjects(c *gin.Context) {
	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	var projects []models.Project
	if err := h.db.Preload("Creator").Preload("Presenter").Where("group_id = ?", group.ID).Find(&projects).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch projects"})
		return
	}

	c.JSON(http.StatusOK, projects)
}

func (h *ProjectHandler) GetProject(c *gin.Context) {
	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	projectSlug := c.Param("pid")

	var project models.Project
	if err := h.db.Preload("Creator").Preload("Presenter").
		Where("slug = ? AND group_id = ?", projectSlug, group.ID).
		First(&project).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "project not found"})
		return
	}

	c.JSON(http.StatusOK, project)
}

func (h *ProjectHandler) CreateProject(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	var req CreateProjectRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	slug := utils.UniqueSlug(utils.Slugify(req.Name), func(s string) bool {
		var count int64
		h.db.Model(&models.Project{}).Where("group_id = ? AND slug = ?", group.ID, s).Count(&count)
		return count > 0
	})

	project := models.Project{
		Name:             req.Name,
		Slug:             slug,
		Description:      req.Description,
		GroupID:          group.ID,
		CreatedBy:        userID,
		EnableVote:       req.EnableVote,
		EnablePrioritise: req.EnablePrioritise,
	}

	if err := h.db.Create(&project).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create project"})
		return
	}
	// UpdateColumns with a map always sets the value even when false,
	// because GORM's zero-value skip only applies to struct-based updates.
	h.db.Model(&project).UpdateColumns(map[string]any{
		"enable_vote":       req.EnableVote,
		"enable_prioritise": req.EnablePrioritise,
	})

	h.db.Preload("Creator").Preload("Presenter").First(&project, "id = ?", project.ID)

	c.JSON(http.StatusCreated, project)
}

func (h *ProjectHandler) SetPresenter(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	projectSlug := c.Param("pid")
	var project models.Project
	if err := h.db.Where("slug = ? AND group_id = ?", projectSlug, group.ID).First(&project).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "project not found"})
		return
	}

	if project.CreatedBy != userID && group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the project creator or group owner can set the presenter"})
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

	h.db.Model(&project).Update("presenter_id", req.UserID)
	ws.NotifyPresenter(project.ID, req.UserID, presenterUsername)

	h.db.Preload("Creator").Preload("Presenter").First(&project, "id = ?", project.ID)
	c.JSON(http.StatusOK, project)
}

func (h *ProjectHandler) UpdateProject(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	projectSlug := c.Param("pid")
	var project models.Project
	if err := h.db.Where("slug = ? AND group_id = ?", projectSlug, group.ID).First(&project).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "project not found"})
		return
	}

	if project.CreatedBy != userID && group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the project creator or group owner can edit this project"})
		return
	}

	var req struct {
		Name             string `json:"name" binding:"required,min=2"`
		Description      string `json:"description"`
		EnableVote       bool   `json:"enable_vote"`
		EnablePrioritise bool   `json:"enable_prioritise"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	h.db.Model(&project).UpdateColumns(map[string]any{
		"name":              req.Name,
		"description":       req.Description,
		"enable_vote":       req.EnableVote,
		"enable_prioritise": req.EnablePrioritise,
	})

	h.db.Preload("Creator").Preload("Presenter").First(&project, "id = ?", project.ID)
	c.JSON(http.StatusOK, project)
}

func (h *ProjectHandler) DeleteProject(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	group, ok := h.loadGroupAsMember(c)
	if !ok {
		return
	}

	projectSlug := c.Param("pid")

	var project models.Project
	if err := h.db.Where("slug = ? AND group_id = ?", projectSlug, group.ID).First(&project).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "project not found"})
		return
	}

	if project.CreatedBy != userID && group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the project creator or group owner can delete this project"})
		return
	}

	h.db.Delete(&project)
	c.JSON(http.StatusOK, gin.H{"message": "project deleted"})
}
