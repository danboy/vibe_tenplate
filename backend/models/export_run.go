package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// ExportRun records one "export this brainstorm" action. Re-running export
// is not deduplicated against prior runs — each click creates a new run.
type ExportRun struct {
	ID           string         `json:"id"            gorm:"primaryKey;type:text"`
	CreatedAt    time.Time      `json:"created_at"`
	BrainstormID string         `json:"brainstorm_id" gorm:"type:text;not null;index"`
	Provider     string         `json:"provider"`
	CreatedBy    string         `json:"created_by"     gorm:"type:text"`
	Items        []ExportedItem `json:"items,omitempty" gorm:"foreignKey:ExportRunID"`
}

func (e *ExportRun) BeforeCreate(tx *gorm.DB) error {
	if e.ID == "" {
		e.ID = uuid.New().String()
	}
	return nil
}

// ExportedItem is one issue/task created (or attempted) as part of an
// ExportRun — one per note-cluster (group-header note + children, or a
// standalone note).
type ExportedItem struct {
	ID           string    `json:"id"            gorm:"primaryKey;type:text"`
	CreatedAt    time.Time `json:"created_at"`
	ExportRunID  string    `json:"export_run_id" gorm:"type:text;not null;index"`
	SourceNoteID string    `json:"source_note_id"`
	Title        string    `json:"title"`
	ExternalURL  string    `json:"external_url"`
	Error        string    `json:"error,omitempty"`
}

func (e *ExportedItem) BeforeCreate(tx *gorm.DB) error {
	if e.ID == "" {
		e.ID = uuid.New().String()
	}
	return nil
}
