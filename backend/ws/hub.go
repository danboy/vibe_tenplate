package ws

import (
	"encoding/json"
	"log"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"tenplate/models"

	"gorm.io/gorm"
)

// Message is the envelope for all WebSocket messages.
type Message struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

func buildMessage(msgType string, payload any) ([]byte, error) {
	p, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	return json.Marshal(Message{Type: msgType, Payload: p})
}

// Hub maintains the set of active clients for one brainstorm and broadcasts messages.
type Hub struct {
	brainstormID    string
	clients      map[*Client]bool
	broadcast    chan []byte
	register     chan *Client
	unregister   chan *Client
	db           *gorm.DB
	currentSlide int
	mu           sync.Mutex // protects currentSlide
	matrixLocks  map[string]string // noteID → userID currently dragging
	matrixMu     sync.Mutex        // protects matrixLocks
	clientCount  atomic.Int32

	// blurNotes, when set by the presenter, hides other participants' sticky
	// note contents on the brainstorm step until toggled off. Ephemeral —
	// resets with the hub, same as the matrix locks and timer state.
	blurMu    sync.Mutex
	blurNotes bool

	// Countdown timer for the first retro step. The configured duration is
	// never cached here — every call site already has (or cheaply fetches)
	// the current Brainstorm row, so duration is read from the DB each time
	// instead of risking a second, manually-synced source of truth. endsAt
	// is only meaningful while running, remainingSeconds only while paused.
	timerMu               sync.Mutex
	timerRunning          bool
	timerEndsAt           time.Time
	timerRemainingSeconds int
}

func newHub(brainstormID string, db *gorm.DB) *Hub {
	h := &Hub{
		brainstormID:   brainstormID,
		clients:     make(map[*Client]bool),
		broadcast:   make(chan []byte, 256),
		register:    make(chan *Client),
		unregister:  make(chan *Client),
		db:          db,
		matrixLocks: make(map[string]string),
	}

	// Brainstorms with the problem statement stage disabled (e.g. card
	// sorting) should start on the first enabled slide, not slide 0.
	var brainstorm models.Brainstorm
	if err := db.Select("enable_problem", "timer_enabled", "timer_minutes").
		First(&brainstorm, "id = ?", brainstormID).Error; err == nil {
		if !brainstorm.EnableProblem {
			h.currentSlide = 1
		}
		if brainstorm.TimerEnabled {
			h.timerRemainingSeconds = brainstorm.TimerMinutes * 60
		}
	}

	go h.run()
	return h
}

func (h *Hub) run() {
	for {
		select {
		case client := <-h.register:
			h.clients[client] = true
			h.clientCount.Add(1)
			h.sendInit(client)
			h.broadcastPresence()

		case client := <-h.unregister:
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				h.clientCount.Add(-1)
				close(client.send)
				h.broadcastPresence()
				// Release any matrix locks held by this client.
				h.matrixMu.Lock()
				var released []string
				for noteID, userID := range h.matrixLocks {
					if userID == client.userID {
						delete(h.matrixLocks, noteID)
						released = append(released, noteID)
					}
				}
				h.matrixMu.Unlock()
				for _, noteID := range released {
					if data, err := buildMessage("matrix_drag_end", map[string]any{"id": noteID}); err == nil {
						h.broadcast <- data
					}
				}
			}

		case data := <-h.broadcast:
			for client := range h.clients {
				select {
				case client.send <- data:
				default:
					delete(h.clients, client)
					close(client.send)
				}
			}
		}
	}
}

// sendInit sends the current state to a newly connected client.
// Must be called from the run() goroutine so clients map access is safe.
func (h *Hub) sendInit(client *Client) {
	var notes []models.StickyNote
	h.db.Where("brainstorm_id = ?", h.brainstormID).Find(&notes)
	if notes == nil {
		notes = []models.StickyNote{}
	}

	var votes []models.NoteVote
	h.db.Where("brainstorm_id = ?", h.brainstormID).Find(&votes)
	if votes == nil {
		votes = []models.NoteVote{}
	}

	var actionItems []models.ActionItem
	h.db.Where("brainstorm_id = ?", h.brainstormID).Find(&actionItems)
	if actionItems == nil {
		actionItems = []models.ActionItem{}
	}

	var brainstorm models.Brainstorm
	h.db.Where("id = ?", h.brainstormID).First(&brainstorm)

	h.mu.Lock()
	slide := h.currentSlide
	h.mu.Unlock()

	h.blurMu.Lock()
	blurNotes := h.blurNotes
	h.blurMu.Unlock()

	data, err := buildMessage("init", map[string]any{
		"notes":              notes,
		"slide":              slide,
		"votes":              votes,
		"action_items":       actionItems,
		"problem_statement":  brainstorm.ProblemStatement,
		"timer":              h.timerSnapshot(timerDuration(&brainstorm)),
		"blur_notes":         blurNotes,
		"connected_count":    int(h.clientCount.Load()),
	})
	if err != nil {
		log.Println("ws: sendInit build error:", err)
		return
	}
	select {
	case client.send <- data:
	default:
		delete(h.clients, client)
		close(client.send)
	}
}

// broadcastPresence tells connected clients how many are currently connected.
// Must be called from the run() goroutine so clientCount is read consistently
// with the register/unregister event that triggered it.
func (h *Hub) broadcastPresence() {
	data, err := buildMessage("presence", map[string]any{"count": int(h.clientCount.Load())})
	if err != nil {
		return
	}
	h.broadcast <- data
}

// isAuthorizedPresenter reports whether userID may drive presenter-only
// controls (slide changes, problem statement edits, the retro timer) for
// this brainstorm.
func isAuthorizedPresenter(brainstorm *models.Brainstorm, userID string) bool {
	if brainstorm.PresenterID != nil {
		return *brainstorm.PresenterID == userID
	}
	return brainstorm.CreatedBy == userID
}

// timerDuration returns the configured timer length in seconds for a
// brainstorm row (0 if the timer isn't enabled). Call sites already have —
// or cheaply fetch — the row for an authorization check, so this just reads
// off it rather than trusting a cached copy that could drift out of sync.
func timerDuration(brainstorm *models.Brainstorm) int {
	if !brainstorm.TimerEnabled {
		return 0
	}
	return brainstorm.TimerMinutes * 60
}

// timerSnapshot returns the current timer state for sending to clients.
// Must be safe to call from any goroutine.
func (h *Hub) timerSnapshot(durationSeconds int) map[string]any {
	h.timerMu.Lock()
	defer h.timerMu.Unlock()
	var endsAt *time.Time
	if h.timerRunning {
		endsAt = &h.timerEndsAt
	}
	return map[string]any{
		"duration_seconds":  durationSeconds,
		"running":           h.timerRunning,
		"ends_at":           endsAt,
		"remaining_seconds": h.timerRemainingSeconds,
	}
}

// pauseTimerLocked pauses the timer if running. Caller must hold timerMu.
func (h *Hub) pauseTimerLocked() {
	if h.timerRunning {
		remaining := int(time.Until(h.timerEndsAt).Seconds())
		if remaining < 0 {
			remaining = 0
		}
		h.timerRemainingSeconds = remaining
		h.timerRunning = false
	}
}

// pauseTimer pauses the timer if it's running and returns the resulting
// snapshot plus whether it actually changed anything (so callers can skip
// broadcasting a no-op). Safe to call from any goroutine.
func (h *Hub) pauseTimer(durationSeconds int) (map[string]any, bool) {
	h.timerMu.Lock()
	wasRunning := h.timerRunning
	h.pauseTimerLocked()
	h.timerMu.Unlock()
	if !wasRunning {
		return nil, false
	}
	return h.timerSnapshot(durationSeconds), true
}

// handleMessage processes an inbound message from a client.
// Called from ReadPump goroutines — only uses channels to interact with hub state.
func (h *Hub) handleMessage(client *Client, raw []byte) {
	var msg struct {
		Type    string          `json:"type"`
		Payload json.RawMessage `json:"payload"`
	}
	if err := json.Unmarshal(raw, &msg); err != nil {
		return
	}

	switch msg.Type {
	case "problem_statement_update":
		var p struct {
			Text string `json:"text"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		var brainstorm models.Brainstorm
		if h.db.Where("id = ?", h.brainstormID).First(&brainstorm).Error != nil {
			return
		}
		if !isAuthorizedPresenter(&brainstorm, client.userID) {
			return
		}
		h.db.Model(&models.Brainstorm{}).
			Where("id = ?", h.brainstormID).
			Update("problem_statement", p.Text)
		if data, err := buildMessage("problem_statement_update", map[string]any{"text": p.Text}); err == nil {
			h.broadcast <- data
		}

	case "note_create":
		var p struct {
			Content string  `json:"content"`
			PosX    float64 `json:"pos_x"`
			PosY    float64 `json:"pos_y"`
			Color   string  `json:"color"`
			Column  *string `json:"column,omitempty"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		note := models.StickyNote{
			BrainstormID: h.brainstormID,
			Content:   p.Content,
			PosX:      p.PosX,
			PosY:      p.PosY,
			Color:     p.Color,
			CreatedBy: client.userID,
			Author:    client.username,
			Column:    p.Column,
		}
		h.db.Create(&note)
		if data, err := buildMessage("note_create", note); err == nil {
			h.broadcast <- data
		}

	case "note_move":
		var p struct {
			ID     string  `json:"id"`
			PosX   float64 `json:"pos_x"`
			PosY   float64 `json:"pos_y"`
			Column *string `json:"column,omitempty"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).
			Updates(map[string]any{"pos_x": p.PosX, "pos_y": p.PosY, "column": p.Column})
		if data, err := buildMessage("note_move", p); err == nil {
			h.broadcast <- data
		}

	case "note_update":
		var p struct {
			ID      string `json:"id"`
			Content string `json:"content"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).
			Update("content", p.Content)
		if data, err := buildMessage("note_update", p); err == nil {
			h.broadcast <- data
		}

	case "note_delete":
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		// Deleting a group note must not orphan its children — clear their
		// parent_id first so they fall back to ungrouped instead of being
		// left pointing at a group that no longer exists.
		var children []models.StickyNote
		h.db.Where("parent_id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).Find(&children)
		for _, child := range children {
			h.db.Model(&models.StickyNote{}).
				Where("id = ? AND brainstorm_id = ?", child.ID, h.brainstormID).
				Update("parent_id", gorm.Expr("NULL"))
			if data, err := buildMessage("note_group", map[string]any{"id": child.ID, "parent_id": nil}); err == nil {
				h.broadcast <- data
			}
		}
		h.db.Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).Delete(&models.StickyNote{})
		if data, err := buildMessage("note_delete", p); err == nil {
			h.broadcast <- data
		}
		h.clearVotes(p.ID)

	case "action_item_create":
		var p struct {
			Content string `json:"content"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		item := models.ActionItem{
			BrainstormID: h.brainstormID,
			Content:      p.Content,
			CreatedBy:    client.userID,
			Author:       client.username,
		}
		h.db.Create(&item)
		if data, err := buildMessage("action_item_create", item); err == nil {
			h.broadcast <- data
		}

	case "action_item_update":
		var p struct {
			ID      string `json:"id"`
			Content string `json:"content"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.db.Model(&models.ActionItem{}).
			Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).
			Update("content", p.Content)
		if data, err := buildMessage("action_item_update", p); err == nil {
			h.broadcast <- data
		}

	case "action_item_delete":
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.db.Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).Delete(&models.ActionItem{})
		if data, err := buildMessage("action_item_delete", p); err == nil {
			h.broadcast <- data
		}

	case "matrix_drag_start":
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.matrixMu.Lock()
		if _, locked := h.matrixLocks[p.ID]; locked {
			h.matrixMu.Unlock()
			return // already held by someone else
		}
		h.matrixLocks[p.ID] = client.userID
		h.matrixMu.Unlock()
		if data, err := buildMessage("matrix_drag_start", map[string]any{
			"id": p.ID, "user_id": client.userID,
		}); err == nil {
			h.broadcast <- data
		}

	case "matrix_drag_end":
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.matrixMu.Lock()
		if h.matrixLocks[p.ID] != client.userID {
			h.matrixMu.Unlock()
			return // can only release your own lock
		}
		delete(h.matrixLocks, p.ID)
		h.matrixMu.Unlock()
		if data, err := buildMessage("matrix_drag_end", map[string]any{"id": p.ID}); err == nil {
			h.broadcast <- data
		}

	case "matrix_move":
		var p struct {
			ID    string  `json:"id"`
			Cost  float64 `json:"cost"`
			Value float64 `json:"value"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			log.Printf("matrix_move: unmarshal failed payload=%s", string(msg.Payload))
			return
		}
		res := h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).
			Updates(map[string]any{"matrix_cost": p.Cost, "matrix_value": p.Value})
		log.Printf("matrix_move: id=%s cost=%.3f value=%.3f db_rows=%d db_err=%v clients=%d",
			p.ID, p.Cost, p.Value, res.RowsAffected, res.Error, len(h.clients))
		if data, err := buildMessage("matrix_move", map[string]any{
			"id": p.ID, "cost": p.Cost, "value": p.Value,
		}); err == nil {
			h.broadcast <- data
		}

	case "matrix_remove":
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).
			Updates(map[string]any{"matrix_cost": nil, "matrix_value": nil})
		if data, err := buildMessage("matrix_remove", map[string]any{"id": p.ID}); err == nil {
			h.broadcast <- data
		}

	case "slide_change":
		log.Printf("slide_change: received raw=%s user=%s", string(msg.Payload), client.userID)
		var p struct {
			Slide int `json:"slide"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			log.Printf("slide_change: unmarshal failed")
			return
		}
		var brainstorm models.Brainstorm
		if h.db.Where("id = ?", h.brainstormID).First(&brainstorm).Error != nil {
			log.Printf("slide_change: brainstorm not found %s", h.brainstormID)
			return
		}
		authorized := isAuthorizedPresenter(&brainstorm, client.userID)
		log.Printf("slide_change: slide=%d user=%s createdBy=%s presenterID=%v authorized=%v",
			p.Slide, client.userID, brainstorm.CreatedBy, brainstorm.PresenterID, authorized)
		if !authorized {
			return
		}
		h.mu.Lock()
		h.currentSlide = p.Slide
		h.mu.Unlock()
		if data, err := buildMessage("slide_change", map[string]any{"slide": p.Slide}); err == nil {
			h.broadcast <- data
			log.Printf("slide_change: broadcast sent to %d clients", len(h.clients))
		}
		// Leaving the retro board (slide 1) pauses the timer — it's only
		// meant to be running while everyone's looking at it.
		if brainstorm.Type == "retro" && p.Slide != 1 {
			if snapshot, paused := h.pauseTimer(timerDuration(&brainstorm)); paused {
				if data, err := buildMessage("timer_update", snapshot); err == nil {
					h.broadcast <- data
				}
			}
		}

	case "timer_start", "timer_pause", "timer_reset":
		var brainstorm models.Brainstorm
		if h.db.Select("id", "created_by", "presenter_id", "timer_enabled", "timer_minutes").
			Where("id = ?", h.brainstormID).First(&brainstorm).Error != nil {
			return
		}
		if !isAuthorizedPresenter(&brainstorm, client.userID) {
			return
		}
		duration := timerDuration(&brainstorm)
		h.timerMu.Lock()
		if duration == 0 {
			// Timer isn't enabled for this brainstorm — nothing to control.
			h.timerMu.Unlock()
			return
		}
		switch msg.Type {
		case "timer_start":
			if !h.timerRunning {
				h.timerRunning = true
				h.timerEndsAt = time.Now().Add(time.Duration(h.timerRemainingSeconds) * time.Second)
			}
		case "timer_pause":
			h.pauseTimerLocked()
		case "timer_reset":
			h.timerRunning = false
			h.timerRemainingSeconds = duration
		}
		h.timerMu.Unlock()
		if data, err := buildMessage("timer_update", h.timerSnapshot(duration)); err == nil {
			h.broadcast <- data
		}

	case "blur_toggle":
		var p struct {
			Enabled bool `json:"enabled"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		var brainstorm models.Brainstorm
		if h.db.Where("id = ?", h.brainstormID).First(&brainstorm).Error != nil {
			return
		}
		if !isAuthorizedPresenter(&brainstorm, client.userID) {
			return
		}
		h.blurMu.Lock()
		h.blurNotes = p.Enabled
		h.blurMu.Unlock()
		if data, err := buildMessage("blur_update", map[string]any{"enabled": p.Enabled}); err == nil {
			h.broadcast <- data
		}

	case "note_group":
		var p struct {
			DraggedID string `json:"dragged_id"`
			TargetID  string `json:"target_id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}

		var target models.StickyNote
		if h.db.Where("id = ? AND brainstorm_id = ?", p.TargetID, h.brainstormID).First(&target).Error != nil {
			return
		}

		var parentID string
		if target.IsGroup {
			// Dragged note joins the target group directly.
			parentID = target.ID
		} else if target.ParentID != nil {
			// Target is already a child; dragged joins the same group.
			parentID = *target.ParentID
		} else {
			// Neither note is grouped — create a new group note above them.
			var dragged models.StickyNote
			if h.db.Where("id = ? AND brainstorm_id = ?", p.DraggedID, h.brainstormID).First(&dragged).Error != nil {
				return
			}
			groupNote := models.StickyNote{
				BrainstormID: h.brainstormID,
				Content:   "",
				PosX:      (dragged.PosX + target.PosX) / 2,
				PosY:      math.Min(dragged.PosY, target.PosY) - 110,
				Color:     "#FFFFFF",
				CreatedBy: client.userID,
				Author:    client.username,
				IsGroup:   true,
			}
			if err := h.db.Create(&groupNote).Error; err != nil {
				return
			}
			parentID = groupNote.ID
			if data, err := buildMessage("note_create", groupNote); err == nil {
				h.broadcast <- data
			}
			// Make target a child of the new group note.
			h.db.Model(&models.StickyNote{}).
				Where("id = ? AND brainstorm_id = ?", p.TargetID, h.brainstormID).
				Update("parent_id", parentID)
			if data, err := buildMessage("note_group", map[string]any{"id": p.TargetID, "parent_id": parentID}); err == nil {
				h.broadcast <- data
			}
			h.clearVotes(p.TargetID)
		}

		// Make dragged note a child.
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", p.DraggedID, h.brainstormID).
			Update("parent_id", parentID)
		if data, err := buildMessage("note_group", map[string]any{"id": p.DraggedID, "parent_id": parentID}); err == nil {
			h.broadcast <- data
		}
		h.clearVotes(p.DraggedID)
		h.restackGroup(parentID)

	case "note_group_new":
		// Dragged note is pulled onto open board space (not onto an existing
		// group) — it gets a brand-new group of its own rather than merging
		// into whatever happens to be nearby.
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		var dragged models.StickyNote
		if h.db.Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).First(&dragged).Error != nil {
			return
		}
		if dragged.IsGroup {
			return
		}
		oldParentID := dragged.ParentID

		groupNote := models.StickyNote{
			BrainstormID: h.brainstormID,
			Content:      "",
			PosX:         dragged.PosX,
			PosY:         dragged.PosY - 110,
			Color:        "#FFFFFF",
			CreatedBy:    client.userID,
			Author:       client.username,
			IsGroup:      true,
		}
		if err := h.db.Create(&groupNote).Error; err != nil {
			return
		}
		if data, err := buildMessage("note_create", groupNote); err == nil {
			h.broadcast <- data
		}
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).
			Update("parent_id", groupNote.ID)
		if data, err := buildMessage("note_group", map[string]any{"id": p.ID, "parent_id": groupNote.ID}); err == nil {
			h.broadcast <- data
		}
		h.clearVotes(p.ID)

		// If that was the dragged note's only remaining link to its old
		// group, the old group is now empty — clean it up same as ungroup.
		if oldParentID != nil {
			var remaining int64
			h.db.Model(&models.StickyNote{}).
				Where("parent_id = ? AND brainstorm_id = ?", *oldParentID, h.brainstormID).
				Count(&remaining)
			if remaining == 0 {
				h.db.Where("id = ? AND brainstorm_id = ?", *oldParentID, h.brainstormID).Delete(&models.StickyNote{})
				if data, err := buildMessage("note_delete", map[string]any{"id": *oldParentID}); err == nil {
					h.broadcast <- data
				}
				h.clearVotes(*oldParentID)
			} else {
				h.restackGroup(*oldParentID)
			}
		}

	case "note_ungroup":
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		var note models.StickyNote
		if h.db.Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).First(&note).Error != nil {
			return
		}
		if note.ParentID == nil {
			return
		}
		parentID := *note.ParentID
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", p.ID, h.brainstormID).
			Update("parent_id", gorm.Expr("NULL"))
		if data, err := buildMessage("note_group", map[string]any{"id": p.ID, "parent_id": nil}); err == nil {
			h.broadcast <- data
		}
		// If the group note is now empty, delete it.
		var remaining int64
		h.db.Model(&models.StickyNote{}).
			Where("parent_id = ? AND brainstorm_id = ?", parentID, h.brainstormID).
			Count(&remaining)
		if remaining == 0 {
			h.db.Where("id = ? AND brainstorm_id = ?", parentID, h.brainstormID).Delete(&models.StickyNote{})
			if data, err := buildMessage("note_delete", map[string]any{"id": parentID}); err == nil {
				h.broadcast <- data
			}
			h.clearVotes(parentID)
		} else {
			h.restackGroup(parentID)
		}

	case "vote":
		var p struct {
			NoteID string `json:"note_id"`
			Count  int    `json:"count"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		if p.Count < 0 {
			p.Count = 0
		}
		// Validate total votes for this user across the brainstorm won't exceed 4.
		var otherVotes []models.NoteVote
		h.db.Where("brainstorm_id = ? AND user_id = ? AND note_id != ?", h.brainstormID, client.userID, p.NoteID).
			Find(&otherVotes)
		total := 0
		for _, v := range otherVotes {
			total += v.Count
		}
		if total+p.Count > 4 {
			return
		}
		// Upsert the vote for this user+note.
		var vote models.NoteVote
		err := h.db.Where("brainstorm_id = ? AND note_id = ? AND user_id = ?",
			h.brainstormID, p.NoteID, client.userID).First(&vote).Error
		if err != nil {
			vote = models.NoteVote{
				BrainstormID: h.brainstormID,
				NoteID:    p.NoteID,
				UserID:    client.userID,
				Count:     p.Count,
			}
			h.db.Create(&vote)
		} else {
			h.db.Model(&vote).Update("count", p.Count)
		}
		if data, err := buildMessage("vote", map[string]any{
			"note_id": p.NoteID,
			"user_id": client.userID,
			"count":   p.Count,
		}); err == nil {
			h.broadcast <- data
		}
	}
}

// clearVotes deletes any votes cast on noteID and tells clients to drop them
// locally too. Call whenever a note stops being independently votable — it
// joins a group, or it (or a group it is) gets deleted — so the stars it
// was holding go back to each voter's pool instead of being stuck forever.
func (h *Hub) clearVotes(noteID string) {
	var count int64
	h.db.Model(&models.NoteVote{}).
		Where("note_id = ? AND brainstorm_id = ?", noteID, h.brainstormID).
		Count(&count)
	if count == 0 {
		return
	}
	h.db.Where("note_id = ? AND brainstorm_id = ?", noteID, h.brainstormID).
		Delete(&models.NoteVote{})
	if data, err := buildMessage("votes_cleared", map[string]any{"note_id": noteID}); err == nil {
		h.broadcast <- data
	}
}

// restackGroup repositions all children of a group note into a vertical stack
// directly below the group note header. Called whenever membership changes.
func (h *Hub) restackGroup(parentID string) {
	var groupNote models.StickyNote
	if h.db.Where("id = ? AND brainstorm_id = ?", parentID, h.brainstormID).First(&groupNote).Error != nil {
		return
	}
	var children []models.StickyNote
	h.db.Where("parent_id = ? AND brainstorm_id = ?", parentID, h.brainstormID).
		Order("created_at asc").
		Find(&children)

	// groupNoteHeight: approximate rendered height of the group header card.
	// noteHeight: matches _noteMinHeight in Flutter (screen px at scale=1).
	// Children stack in a vertical column directly below the group note, no gap.
	const noteHeight = 90.0
	for i, child := range children {
		newX := groupNote.PosX
		newY := groupNote.PosY - float64(i+1)*noteHeight
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND brainstorm_id = ?", child.ID, h.brainstormID).
			Updates(map[string]any{"pos_x": newX, "pos_y": newY})
		if data, err := buildMessage("note_move", map[string]any{
			"id": child.ID, "pos_x": newX, "pos_y": newY,
		}); err == nil {
			h.broadcast <- data
		}
	}
}

// Manager keeps one hub per brainstorm, creating on demand.
var manager = &hubManager{hubs: make(map[string]*Hub)}

type hubManager struct {
	mu   sync.Mutex
	hubs map[string]*Hub
}

func GetHub(brainstormID string, db *gorm.DB) *Hub {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if h, ok := manager.hubs[brainstormID]; ok {
		return h
	}
	h := newHub(brainstormID, db)
	manager.hubs[brainstormID] = h
	return h
}

// getHub returns the already-running hub for a brainstorm, if any, without
// creating one — for notifying an existing session, as opposed to GetHub's
// create-on-demand for a client that's actually connecting.
func getHub(brainstormID string) (*Hub, bool) {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	h, ok := manager.hubs[brainstormID]
	return h, ok
}

// Register enqueues a client to be added to the hub.
func (h *Hub) Register(client *Client) {
	h.register <- client
}

// GetClientCount returns the number of active WebSocket connections for a brainstorm.
// Returns 0 if no hub exists for the brainstorm.
func GetClientCount(brainstormID string) int {
	h, ok := getHub(brainstormID)
	if !ok {
		return 0
	}
	return int(h.clientCount.Load())
}

// NotifyTimerConfig tells an existing hub's connected clients about a timer
// config change (no-op if no hub is running yet — it'll pick up the new
// config from the DB on creation). Resets to a fresh, paused state at the
// new duration, matching timer_reset, since a config change mid-countdown
// has no sensible "resume".
func NotifyTimerConfig(brainstormID string, enabled bool, minutes int) {
	h, ok := getHub(brainstormID)
	if !ok {
		return
	}
	duration := 0
	if enabled {
		duration = minutes * 60
	}
	h.timerMu.Lock()
	h.timerRunning = false
	h.timerRemainingSeconds = duration
	h.timerMu.Unlock()
	if data, err := buildMessage("timer_update", h.timerSnapshot(duration)); err == nil {
		h.broadcast <- data
	}
}

// NotifyPresenter broadcasts a presenter_change message to an existing hub (no-op if none).
func NotifyPresenter(brainstormID string, presenterID *string, presenterUsername *string) {
	h, ok := getHub(brainstormID)
	if !ok {
		return
	}
	if data, err := buildMessage("presenter_change", map[string]any{
		"presenter_id":       presenterID,
		"presenter_username": presenterUsername,
	}); err == nil {
		h.broadcast <- data
	}
}
