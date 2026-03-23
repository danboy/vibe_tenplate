package ws

import (
	"encoding/json"
	"log"
	"math"
	"sync"

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

// Hub maintains the set of active clients for one project and broadcasts messages.
type Hub struct {
	projectID    string
	clients      map[*Client]bool
	broadcast    chan []byte
	register     chan *Client
	unregister   chan *Client
	db           *gorm.DB
	currentSlide int
	mu           sync.Mutex // protects currentSlide
	matrixLocks  map[string]string // noteID → userID currently dragging
	matrixMu     sync.Mutex        // protects matrixLocks
}

func newHub(projectID string, db *gorm.DB) *Hub {
	h := &Hub{
		projectID:   projectID,
		clients:     make(map[*Client]bool),
		broadcast:   make(chan []byte, 256),
		register:    make(chan *Client),
		unregister:  make(chan *Client),
		db:          db,
		matrixLocks: make(map[string]string),
	}
	go h.run()
	return h
}

func (h *Hub) run() {
	for {
		select {
		case client := <-h.register:
			h.clients[client] = true
			h.sendInit(client)

		case client := <-h.unregister:
			if _, ok := h.clients[client]; ok {
				delete(h.clients, client)
				close(client.send)
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
	h.db.Where("project_id = ?", h.projectID).Find(&notes)
	if notes == nil {
		notes = []models.StickyNote{}
	}

	var votes []models.NoteVote
	h.db.Where("project_id = ?", h.projectID).Find(&votes)
	if votes == nil {
		votes = []models.NoteVote{}
	}

	h.mu.Lock()
	slide := h.currentSlide
	h.mu.Unlock()

	data, err := buildMessage("init", map[string]any{"notes": notes, "slide": slide, "votes": votes})
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
	case "note_create":
		var p struct {
			Content string  `json:"content"`
			PosX    float64 `json:"pos_x"`
			PosY    float64 `json:"pos_y"`
			Color   string  `json:"color"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		note := models.StickyNote{
			ProjectID: h.projectID,
			Content:   p.Content,
			PosX:      p.PosX,
			PosY:      p.PosY,
			Color:     p.Color,
			CreatedBy: client.userID,
			Author:    client.username,
		}
		h.db.Create(&note)
		if data, err := buildMessage("note_create", note); err == nil {
			h.broadcast <- data
		}

	case "note_move":
		var p struct {
			ID   string  `json:"id"`
			PosX float64 `json:"pos_x"`
			PosY float64 `json:"pos_y"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND project_id = ?", p.ID, h.projectID).
			Updates(map[string]any{"pos_x": p.PosX, "pos_y": p.PosY})
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
			Where("id = ? AND project_id = ?", p.ID, h.projectID).
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
		h.db.Where("id = ? AND project_id = ?", p.ID, h.projectID).Delete(&models.StickyNote{})
		if data, err := buildMessage("note_delete", p); err == nil {
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
			Where("id = ? AND project_id = ?", p.ID, h.projectID).
			Updates(map[string]any{"matrix_cost": p.Cost, "matrix_value": p.Value})
		log.Printf("matrix_move: id=%s cost=%.3f value=%.3f db_rows=%d db_err=%v clients=%d",
			p.ID, p.Cost, p.Value, res.RowsAffected, res.Error, len(h.clients))
		if data, err := buildMessage("matrix_move", map[string]any{
			"id": p.ID, "cost": p.Cost, "value": p.Value,
		}); err == nil {
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
		var project models.Project
		if h.db.Where("id = ?", h.projectID).First(&project).Error != nil {
			log.Printf("slide_change: project not found %s", h.projectID)
			return
		}
		authorized := (project.PresenterID != nil && *project.PresenterID == client.userID) ||
			(project.PresenterID == nil && project.CreatedBy == client.userID)
		log.Printf("slide_change: slide=%d user=%s createdBy=%s presenterID=%v authorized=%v",
			p.Slide, client.userID, project.CreatedBy, project.PresenterID, authorized)
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

	case "note_group":
		var p struct {
			DraggedID string `json:"dragged_id"`
			TargetID  string `json:"target_id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}

		var target models.StickyNote
		if h.db.Where("id = ? AND project_id = ?", p.TargetID, h.projectID).First(&target).Error != nil {
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
			if h.db.Where("id = ? AND project_id = ?", p.DraggedID, h.projectID).First(&dragged).Error != nil {
				return
			}
			groupNote := models.StickyNote{
				ProjectID: h.projectID,
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
				Where("id = ? AND project_id = ?", p.TargetID, h.projectID).
				Update("parent_id", parentID)
			if data, err := buildMessage("note_group", map[string]any{"id": p.TargetID, "parent_id": parentID}); err == nil {
				h.broadcast <- data
			}
		}

		// Make dragged note a child.
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND project_id = ?", p.DraggedID, h.projectID).
			Update("parent_id", parentID)
		if data, err := buildMessage("note_group", map[string]any{"id": p.DraggedID, "parent_id": parentID}); err == nil {
			h.broadcast <- data
		}
		h.restackGroup(parentID)

	case "note_ungroup":
		var p struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(msg.Payload, &p) != nil {
			return
		}
		var note models.StickyNote
		if h.db.Where("id = ? AND project_id = ?", p.ID, h.projectID).First(&note).Error != nil {
			return
		}
		if note.ParentID == nil {
			return
		}
		parentID := *note.ParentID
		h.db.Model(&models.StickyNote{}).
			Where("id = ? AND project_id = ?", p.ID, h.projectID).
			Update("parent_id", gorm.Expr("NULL"))
		if data, err := buildMessage("note_group", map[string]any{"id": p.ID, "parent_id": nil}); err == nil {
			h.broadcast <- data
		}
		// If the group note is now empty, delete it.
		var remaining int64
		h.db.Model(&models.StickyNote{}).
			Where("parent_id = ? AND project_id = ?", parentID, h.projectID).
			Count(&remaining)
		if remaining == 0 {
			h.db.Where("id = ? AND project_id = ?", parentID, h.projectID).Delete(&models.StickyNote{})
			if data, err := buildMessage("note_delete", map[string]any{"id": parentID}); err == nil {
				h.broadcast <- data
			}
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
		// Validate total votes for this user across the project won't exceed 4.
		var otherVotes []models.NoteVote
		h.db.Where("project_id = ? AND user_id = ? AND note_id != ?", h.projectID, client.userID, p.NoteID).
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
		err := h.db.Where("project_id = ? AND note_id = ? AND user_id = ?",
			h.projectID, p.NoteID, client.userID).First(&vote).Error
		if err != nil {
			vote = models.NoteVote{
				ProjectID: h.projectID,
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

// restackGroup repositions all children of a group note into a vertical stack
// directly below the group note header. Called whenever membership changes.
func (h *Hub) restackGroup(parentID string) {
	var groupNote models.StickyNote
	if h.db.Where("id = ? AND project_id = ?", parentID, h.projectID).First(&groupNote).Error != nil {
		return
	}
	var children []models.StickyNote
	h.db.Where("parent_id = ? AND project_id = ?", parentID, h.projectID).
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
			Where("id = ? AND project_id = ?", child.ID, h.projectID).
			Updates(map[string]any{"pos_x": newX, "pos_y": newY})
		if data, err := buildMessage("note_move", map[string]any{
			"id": child.ID, "pos_x": newX, "pos_y": newY,
		}); err == nil {
			h.broadcast <- data
		}
	}
}

// Manager keeps one hub per project, creating on demand.
var manager = &hubManager{hubs: make(map[string]*Hub)}

type hubManager struct {
	mu   sync.Mutex
	hubs map[string]*Hub
}

func GetHub(projectID string, db *gorm.DB) *Hub {
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if h, ok := manager.hubs[projectID]; ok {
		return h
	}
	h := newHub(projectID, db)
	manager.hubs[projectID] = h
	return h
}

// Register enqueues a client to be added to the hub.
func (h *Hub) Register(client *Client) {
	h.register <- client
}

// NotifyPresenter broadcasts a presenter_change message to an existing hub (no-op if none).
func NotifyPresenter(projectID string, presenterID *string, presenterUsername *string) {
	manager.mu.Lock()
	h, ok := manager.hubs[projectID]
	manager.mu.Unlock()
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
