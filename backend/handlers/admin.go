package handlers

import (
	"net/http"
	"time"

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

// ── Users ────────────────────────────────────────────────────────────────────

type adminUserSummary struct {
	ID        string    `json:"id"`
	Username  string    `json:"username"`
	Email     string    `json:"email"`
	IsAdmin   bool      `json:"is_admin"`
	CreatedAt time.Time `json:"created_at"`
}

// ListUsers returns every user for admin use.
func (h *AdminHandler) ListUsers(c *gin.Context) {
	var users []models.User
	if err := h.db.Find(&users).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch users"})
		return
	}
	resp := make([]adminUserSummary, len(users))
	for i, u := range users {
		resp[i] = adminUserSummary{
			ID:        u.ID,
			Username:  u.Username,
			Email:     u.Email,
			IsAdmin:   u.IsAdmin,
			CreatedAt: u.CreatedAt,
		}
	}
	c.JSON(http.StatusOK, resp)
}

// deleteUserCascade hard-deletes a user and everything that would otherwise
// block it via an enforced FK. Brainstorms/activities the user created are
// kept, just with attribution cleared (loose reference, same as
// StickyNote.CreatedBy elsewhere in this app).
func deleteUserCascade(tx *gorm.DB, userID string) error {
	// Defuse the legacy pre-rename `projects` table's FK to users before it
	// can block this delete with a confusing error from a dead table.
	if err := tx.Exec(`UPDATE projects SET created_by = NULL WHERE created_by = ?`, userID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`UPDATE projects SET presenter_id = NULL WHERE presenter_id = ?`, userID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`UPDATE brainstorms SET created_by = NULL WHERE created_by = ?`, userID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`UPDATE brainstorms SET presenter_id = NULL WHERE presenter_id = ?`, userID).Error; err != nil {
		return err
	}
	// Actual table name is o_auth_identities — GORM's naming strategy splits
	// "OAuth" into "o_auth" rather than treating it as one word.
	if err := tx.Exec(`DELETE FROM o_auth_identities WHERE user_id = ?`, userID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM user_groups WHERE user_id = ?`, userID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM team_members WHERE user_id = ?`, userID).Error; err != nil {
		return err
	}
	return tx.Unscoped().Delete(&models.User{}, "id = ?", userID).Error
}

// DeleteUser permanently deletes a user account.
func (h *AdminHandler) DeleteUser(c *gin.Context) {
	adminID := c.MustGet("userID").(string)
	targetID := c.Param("id")

	if targetID == adminID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot delete your own account"})
		return
	}

	err := h.db.Transaction(func(tx *gorm.DB) error {
		return deleteUserCascade(tx, targetID)
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete user"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "user deleted"})
}

// ── Brainstorms (activities) ─────────────────────────────────────────────────

type adminActivitySummary struct {
	ID              string    `json:"id"`
	Slug            string    `json:"slug"`
	Name            string    `json:"name"`
	Type            string    `json:"type"`
	GroupID         string    `json:"group_id"`
	GroupName       string    `json:"group_name"`
	GroupSlug       string    `json:"group_slug"`
	TeamName        string    `json:"team_name"`
	CreatedBy       string    `json:"created_by"`
	CreatorUsername string    `json:"creator_username"`
	CreatedAt       time.Time `json:"created_at"`
}

// ListBrainstorms returns every brainstorm across every group for admin use,
// enriched with group/team names since Brainstorm only carries a loose
// GroupID.
func (h *AdminHandler) ListBrainstorms(c *gin.Context) {
	var brainstorms []models.Brainstorm
	if err := h.db.Preload("Creator").Find(&brainstorms).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch activities"})
		return
	}

	groupIDs := make([]string, 0, len(brainstorms))
	seen := map[string]bool{}
	for _, b := range brainstorms {
		if !seen[b.GroupID] {
			seen[b.GroupID] = true
			groupIDs = append(groupIDs, b.GroupID)
		}
	}
	var groups []models.Group
	if len(groupIDs) > 0 {
		h.db.Preload("Team").Where("id IN ?", groupIDs).Find(&groups)
	}
	groupByID := make(map[string]models.Group, len(groups))
	for _, g := range groups {
		groupByID[g.ID] = g
	}

	resp := make([]adminActivitySummary, len(brainstorms))
	for i, b := range brainstorms {
		g := groupByID[b.GroupID]
		teamName := ""
		if g.Team != nil {
			teamName = g.Team.Name
		}
		creatorUsername := ""
		if b.Creator != nil {
			creatorUsername = b.Creator.Username
		}
		resp[i] = adminActivitySummary{
			ID:              b.ID,
			Slug:            b.Slug,
			Name:            b.Name,
			Type:            b.Type,
			GroupID:         b.GroupID,
			GroupName:       g.Name,
			GroupSlug:       g.Slug,
			TeamName:        teamName,
			CreatedBy:       b.CreatedBy,
			CreatorUsername: creatorUsername,
			CreatedAt:       b.CreatedAt,
		}
	}
	c.JSON(http.StatusOK, resp)
}

// deleteBrainstormDescendants deletes every row that references a set of
// brainstorms, in FK-safe order (exported_items before export_runs is the
// one enforced constraint here; the rest have no enforced FK but are
// cleaned up to avoid leaving orphans). brainstormFilterSQL is a SQL
// fragment such as "brainstorm_id = ?" or
// "brainstorm_id IN (SELECT id FROM brainstorms WHERE group_id = ?)" that
// identifies the brainstorms in scope; args are its placeholder values.
// Scoping this way lets a group/team-wide delete clear every descendant
// row with one statement per table instead of looping per brainstorm.
func deleteBrainstormDescendants(tx *gorm.DB, brainstormFilterSQL string, args ...interface{}) error {
	statements := []string{
		`DELETE FROM exported_items WHERE export_run_id IN (SELECT id FROM export_runs WHERE ` + brainstormFilterSQL + `)`,
		`DELETE FROM export_runs WHERE ` + brainstormFilterSQL,
		`DELETE FROM action_items WHERE ` + brainstormFilterSQL,
		`DELETE FROM note_votes WHERE ` + brainstormFilterSQL,
		`DELETE FROM sticky_notes WHERE ` + brainstormFilterSQL,
	}
	for _, stmt := range statements {
		if err := tx.Exec(stmt, args...).Error; err != nil {
			return err
		}
	}
	return nil
}

// deleteBrainstormCascade hard-deletes a single brainstorm and every row
// that references it.
func deleteBrainstormCascade(tx *gorm.DB, brainstormID string) error {
	if err := deleteBrainstormDescendants(tx, "brainstorm_id = ?", brainstormID); err != nil {
		return err
	}
	return tx.Unscoped().Delete(&models.Brainstorm{}, "id = ?", brainstormID).Error
}

// DeleteBrainstorm permanently deletes a brainstorm/activity and its notes,
// votes, action items, and export history, regardless of group membership.
func (h *AdminHandler) DeleteBrainstorm(c *gin.Context) {
	brainstormID := c.Param("id")
	err := h.db.Transaction(func(tx *gorm.DB) error {
		return deleteBrainstormCascade(tx, brainstormID)
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete activity"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "activity deleted"})
}

// ── Groups ───────────────────────────────────────────────────────────────────

type adminGroupSummary struct {
	ID            string    `json:"id"`
	Slug          string    `json:"slug"`
	Name          string    `json:"name"`
	TeamID        *string   `json:"team_id"`
	TeamName      string    `json:"team_name"`
	OwnerID       string    `json:"owner_id"`
	OwnerUsername string    `json:"owner_username"`
	MemberCount   int       `json:"member_count"`
	CreatedAt     time.Time `json:"created_at"`
}

// ListGroups returns every group across every team for admin use, enriched
// with team and owner names since Group only carries loose id columns for
// both.
func (h *AdminHandler) ListGroups(c *gin.Context) {
	var groups []models.Group
	if err := h.db.Preload("Team").Find(&groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch groups"})
		return
	}

	ownerIDs := make([]string, 0, len(groups))
	seen := map[string]bool{}
	for _, g := range groups {
		if g.OwnerID != "" && !seen[g.OwnerID] {
			seen[g.OwnerID] = true
			ownerIDs = append(ownerIDs, g.OwnerID)
		}
	}
	var owners []models.User
	if len(ownerIDs) > 0 {
		h.db.Select("id", "username").Where("id IN ?", ownerIDs).Find(&owners)
	}
	usernameByID := make(map[string]string, len(owners))
	for _, u := range owners {
		usernameByID[u.ID] = u.Username
	}

	// Aggregate member counts in one query rather than preloading every
	// member row just to take len() of each group's slice.
	var counts []struct {
		GroupID string
		Count   int
	}
	h.db.Table("user_groups").
		Select("group_id, count(*) as count").
		Group("group_id").
		Scan(&counts)
	countByGroupID := make(map[string]int, len(counts))
	for _, cnt := range counts {
		countByGroupID[cnt.GroupID] = cnt.Count
	}

	resp := make([]adminGroupSummary, len(groups))
	for i, g := range groups {
		teamName := ""
		if g.Team != nil {
			teamName = g.Team.Name
		}
		resp[i] = adminGroupSummary{
			ID:            g.ID,
			Slug:          g.Slug,
			Name:          g.Name,
			TeamID:        g.TeamID,
			TeamName:      teamName,
			OwnerID:       g.OwnerID,
			OwnerUsername: usernameByID[g.OwnerID],
			MemberCount:   countByGroupID[g.ID],
			CreatedAt:     g.CreatedAt,
		}
	}
	c.JSON(http.StatusOK, resp)
}

// deleteGroupCascade hard-deletes a group, every brainstorm under it, and
// its membership rows, in FK-safe order. Scoped with a single batch of
// statements rather than looping per brainstorm.
func deleteGroupCascade(tx *gorm.DB, groupID string) error {
	const brainstormsInGroup = "brainstorm_id IN (SELECT id FROM brainstorms WHERE group_id = ?)"
	if err := deleteBrainstormDescendants(tx, brainstormsInGroup, groupID); err != nil {
		return err
	}
	if err := tx.Unscoped().Delete(&models.Brainstorm{}, "group_id = ?", groupID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM user_groups WHERE group_id = ?`, groupID).Error; err != nil {
		return err
	}
	return tx.Unscoped().Delete(&models.Group{}, "id = ?", groupID).Error
}

// DeleteGroup permanently deletes a group and everything under it.
func (h *AdminHandler) DeleteGroup(c *gin.Context) {
	groupID := c.Param("id")
	err := h.db.Transaction(func(tx *gorm.DB) error {
		return deleteGroupCascade(tx, groupID)
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete group"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "group deleted"})
}

// ── Teams ────────────────────────────────────────────────────────────────────

// deleteTeamCascade hard-deletes a team and everything under it: every
// group (and in turn every brainstorm/note/vote/action item/export in
// those groups), goals/key results, SSO configs, integrations, and
// memberships. Scoped with batches of statements rather than looping per
// group.
func deleteTeamCascade(tx *gorm.DB, teamID string) error {
	const brainstormsInTeam = "brainstorm_id IN (SELECT id FROM brainstorms WHERE group_id IN (SELECT id FROM groups WHERE team_id = ?))"
	if err := deleteBrainstormDescendants(tx, brainstormsInTeam, teamID); err != nil {
		return err
	}
	const groupsInTeam = "group_id IN (SELECT id FROM groups WHERE team_id = ?)"
	if err := tx.Unscoped().Delete(&models.Brainstorm{}, groupsInTeam, teamID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM user_groups WHERE `+groupsInTeam, teamID).Error; err != nil {
		return err
	}
	if err := tx.Unscoped().Delete(&models.Group{}, "team_id = ?", teamID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM key_results WHERE goal_id IN (SELECT id FROM goals WHERE team_id = ?)`, teamID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM goals WHERE team_id = ?`, teamID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM team_sso_configs WHERE team_id = ?`, teamID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM team_integrations WHERE team_id = ?`, teamID).Error; err != nil {
		return err
	}
	if err := tx.Exec(`DELETE FROM team_members WHERE team_id = ?`, teamID).Error; err != nil {
		return err
	}
	return tx.Unscoped().Delete(&models.Team{}, "id = ?", teamID).Error
}

// DeleteTeam permanently deletes a team and everything under it.
func (h *AdminHandler) DeleteTeam(c *gin.Context) {
	teamID := c.Param("id")
	err := h.db.Transaction(func(tx *gorm.DB) error {
		return deleteTeamCascade(tx, teamID)
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to delete team"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "team deleted"})
}
