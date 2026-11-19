package handlers

import (
	"bytes"
	"encoding/csv"
	"fmt"
	"math"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"tenplate/integrations"
	"tenplate/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type ExportHandler struct {
	db *gorm.DB
}

func NewExportHandler(db *gorm.DB) *ExportHandler {
	return &ExportHandler{db: db}
}

// noteCluster is one group-header note plus its children, or a single
// standalone note — the unit exported as one issue/task.
type noteCluster struct {
	header   models.StickyNote
	children []models.StickyNote
}

func (nc noteCluster) title() string {
	t := strings.TrimSpace(nc.header.Content)
	if t == "" {
		t = "Untitled"
	}
	return t
}

func (nc noteCluster) body() string {
	if len(nc.children) == 0 {
		return ""
	}
	var b strings.Builder
	for _, child := range nc.children {
		content := strings.TrimSpace(child.Content)
		if content == "" {
			continue
		}
		b.WriteString("- [ ] ")
		b.WriteString(content)
		b.WriteString("\n")
	}
	return b.String()
}

func buildClusters(notes []models.StickyNote) []noteCluster {
	childrenByParent := map[string][]models.StickyNote{}
	for _, n := range notes {
		if n.ParentID != nil {
			childrenByParent[*n.ParentID] = append(childrenByParent[*n.ParentID], n)
		}
	}

	var clusters []noteCluster
	for _, n := range notes {
		if n.ParentID != nil {
			continue // it's a child, folded into its header's cluster below
		}
		if n.IsGroup {
			clusters = append(clusters, noteCluster{header: n, children: childrenByParent[n.ID]})
		} else {
			clusters = append(clusters, noteCluster{header: n})
		}
	}
	return clusters
}

func (h *ExportHandler) requireExportPermission(c *gin.Context, group *models.Group, brainstorm *models.Brainstorm, userID string) bool {
	isPresenter := brainstorm.PresenterID != nil && *brainstorm.PresenterID == userID
	if isPresenter || brainstorm.CreatedBy == userID || group.OwnerID == userID {
		return true
	}
	c.JSON(http.StatusForbidden, gin.H{"error": "only the presenter, brainstorm creator, or group owner can export"})
	return false
}

type ExportRequest struct {
	Provider string `json:"provider" binding:"required,oneof=github asana"`
}

func (h *ExportHandler) Export(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	groupSlug := c.Param("id")
	brainstormSlug := c.Param("bid")

	var group models.Group
	if err := h.db.Preload("Team").Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	var brainstorm models.Brainstorm
	if err := h.db.Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	if !h.requireExportPermission(c, &group, &brainstorm, userID) {
		return
	}

	var req ExportRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	if group.Team == nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "this group isn't part of a team — ask a team owner to set one up with an export integration"})
		return
	}

	var integration models.TeamIntegration
	if err := h.db.Where("team_id = ? AND provider = ?", group.Team.ID, req.Provider).First(&integration).Error; err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "your team hasn't connected " + req.Provider + " yet — ask the team owner to connect it in team settings"})
		return
	}
	if strings.TrimSpace(integration.TargetRef) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "your team owner hasn't set a target repo/project for " + req.Provider + " yet"})
		return
	}

	provider, err := integrations.Get(req.Provider)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	ctx := c.Request.Context()
	accessToken := integration.AccessToken
	if integration.TokenExpiresAt != nil && integration.TokenExpiresAt.Before(time.Now()) {
		refreshed, err := provider.Refresh(ctx, integration.RefreshToken)
		if err != nil {
			c.JSON(http.StatusBadGateway, gin.H{"error": "failed to refresh " + req.Provider + " token — try reconnecting it in team settings"})
			return
		}
		if refreshed != nil {
			h.db.Model(&integration).Updates(map[string]interface{}{
				"access_token":     refreshed.AccessToken,
				"refresh_token":    refreshed.RefreshToken,
				"token_expires_at": refreshed.ExpiresAt,
			})
			accessToken = refreshed.AccessToken
		}
	}

	var notes []models.StickyNote
	if err := h.db.Where("brainstorm_id = ?", brainstorm.ID).Find(&notes).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to load notes"})
		return
	}

	clusters := buildClusters(notes)
	run := models.ExportRun{
		BrainstormID: brainstorm.ID,
		Provider:     req.Provider,
		CreatedBy:    userID,
	}
	if err := h.db.Create(&run).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to start export"})
		return
	}

	for _, cluster := range clusters {
		item := models.ExportedItem{
			ExportRunID:  run.ID,
			SourceNoteID: cluster.header.ID,
			Title:        cluster.title(),
		}
		_, externalURL, err := provider.CreateItem(ctx, accessToken, integration.TargetRef, cluster.title(), cluster.body())
		if err != nil {
			item.Error = fmt.Sprintf("%v", err)
		} else {
			item.ExternalURL = externalURL
		}
		h.db.Create(&item)
	}

	h.db.Preload("Items").First(&run, "id = ?", run.ID)
	c.JSON(http.StatusCreated, run)
}

func (h *ExportHandler) ListExportRuns(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	groupSlug := c.Param("id")
	brainstormSlug := c.Param("bid")

	var group models.Group
	if err := h.db.Preload("Members").Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}
	isMember := false
	for _, m := range group.Members {
		if m.ID == userID {
			isMember = true
			break
		}
	}
	if !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member of this group"})
		return
	}

	var brainstorm models.Brainstorm
	if err := h.db.Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	var runs []models.ExportRun
	if err := h.db.Preload("Items").Where("brainstorm_id = ?", brainstorm.ID).Order("created_at desc").Find(&runs).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to fetch export history"})
		return
	}
	c.JSON(http.StatusOK, runs)
}

// matrixBucket is a quadrant of the cost/value prioritize matrix, in the
// display order (Quick Wins, Strategic, Fill-ins, Time Sinks) used for
// ranking exported rows.
type matrixBucket struct {
	name       string
	order      int
	idealCost  float64
	idealValue float64
}

var matrixBuckets = []matrixBucket{
	{name: "quick_wins", order: 0, idealCost: 0, idealValue: 1},
	{name: "strategic", order: 1, idealCost: 1, idealValue: 1},
	{name: "fill_ins", order: 2, idealCost: 0, idealValue: 0},
	{name: "time_sinks", order: 3, idealCost: 1, idealValue: 0},
}

// bucketFor mirrors the frontend's _CostValueMatrix quadrant split: cost and
// value are both normalized 0..1, divided at the midpoint.
func bucketFor(cost, value float64) matrixBucket {
	switch {
	case cost < 0.5 && value >= 0.5:
		return matrixBuckets[0] // quick wins: low cost, high value
	case cost >= 0.5 && value >= 0.5:
		return matrixBuckets[1] // strategic: high cost, high value
	case cost < 0.5 && value < 0.5:
		return matrixBuckets[2] // fill-ins: low cost, low value
	default:
		return matrixBuckets[3] // time sinks: high cost, low value
	}
}

// exportDataRow is one placed note, ranked by its position in the
// prioritize matrix.
type exportDataRow struct {
	ID          string  `json:"id"`
	Content     string  `json:"content"`
	Group       string  `json:"group"`
	MatrixCost  float64 `json:"matrix_cost"`
	MatrixValue float64 `json:"matrix_value"`
	Bucket      string  `json:"bucket"`
	Votes       int     `json:"votes"`
}

func (h *ExportHandler) ExportData(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	groupSlug := c.Param("id")
	brainstormSlug := c.Param("bid")

	var group models.Group
	if err := h.db.Preload("Team").Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}

	var brainstorm models.Brainstorm
	if err := h.db.Where("slug = ? AND group_id = ?", brainstormSlug, group.ID).First(&brainstorm).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "brainstorm not found"})
		return
	}

	if !h.requireExportPermission(c, &group, &brainstorm, userID) {
		return
	}

	var notes []models.StickyNote
	if err := h.db.Where("brainstorm_id = ?", brainstorm.ID).Find(&notes).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to load notes"})
		return
	}
	contentByID := make(map[string]string, len(notes))
	for _, n := range notes {
		// Group-header notes are synthetic containers created with empty
		// content (see ws/hub.go's note_group_new) — mirror the frontend's
		// "Untitled group" fallback so the group column isn't blank.
		if n.Content == "" && n.IsGroup {
			contentByID[n.ID] = "Untitled group"
		} else {
			contentByID[n.ID] = n.Content
		}
	}

	var votes []models.NoteVote
	if err := h.db.Where("brainstorm_id = ?", brainstorm.ID).Find(&votes).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to load votes"})
		return
	}
	votesByNote := make(map[string]int, len(votes))
	for _, v := range votes {
		votesByNote[v.NoteID] += v.Count
	}

	type rankedRow struct {
		row      exportDataRow
		order    int
		distance float64
	}
	var ranked []rankedRow
	for _, n := range notes {
		if n.MatrixCost == nil || n.MatrixValue == nil {
			continue
		}
		cost, value := *n.MatrixCost, *n.MatrixValue
		bucket := bucketFor(cost, value)
		group := ""
		if n.ParentID != nil {
			group = contentByID[*n.ParentID]
		}
		ranked = append(ranked, rankedRow{
			row: exportDataRow{
				ID:          n.ID,
				Content:     n.Content,
				Group:       group,
				MatrixCost:  cost,
				MatrixValue: value,
				Bucket:      bucket.name,
				Votes:       votesByNote[n.ID],
			},
			order:    bucket.order,
			distance: math.Hypot(cost-bucket.idealCost, value-bucket.idealValue),
		})
	}
	sort.SliceStable(ranked, func(i, j int) bool {
		if ranked[i].order != ranked[j].order {
			return ranked[i].order < ranked[j].order
		}
		return ranked[i].distance < ranked[j].distance
	})
	rows := make([]exportDataRow, len(ranked))
	for i, r := range ranked {
		rows[i] = r.row
	}

	format := c.DefaultQuery("format", "json")
	filenameBase := fmt.Sprintf("brainstorm-%s-export", brainstorm.Slug)

	switch format {
	case "csv":
		var buf bytes.Buffer
		w := csv.NewWriter(&buf)
		_ = w.Write([]string{"id", "content", "group", "matrix_cost", "matrix_value", "bucket", "votes"})
		for _, r := range rows {
			_ = w.Write([]string{
				r.ID,
				r.Content,
				r.Group,
				strconv.FormatFloat(r.MatrixCost, 'f', -1, 64),
				strconv.FormatFloat(r.MatrixValue, 'f', -1, 64),
				r.Bucket,
				strconv.Itoa(r.Votes),
			})
		}
		w.Flush()
		c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%q", filenameBase+".csv"))
		c.Data(http.StatusOK, "text/csv", buf.Bytes())
	default:
		c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%q", filenameBase+".json"))
		c.JSON(http.StatusOK, rows)
	}
}
