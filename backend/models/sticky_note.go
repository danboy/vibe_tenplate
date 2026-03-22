package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

type StickyNote struct {
	ID        string         `json:"id"         gorm:"primaryKey;type:text"`
	CreatedAt time.Time      `json:"created_at"`
	UpdatedAt time.Time      `json:"updated_at"`
	DeletedAt gorm.DeletedAt `json:"-"          gorm:"index"`
	ProjectID string         `json:"project_id" gorm:"not null;index;type:text"`
	Content   string         `json:"content"`
	PosX      float64        `json:"pos_x"`
	PosY      float64        `json:"pos_y"`
	Color     string         `json:"color"`
	CreatedBy string         `json:"created_by" gorm:"type:text"`
	Author    string         `json:"author"`
	ParentID    *string        `json:"parent_id"   gorm:"type:text"`
	IsGroup     bool           `json:"is_group"`
	MatrixCost  *float64       `json:"matrix_cost"`
	MatrixValue *float64       `json:"matrix_value"`
}

func (n *StickyNote) BeforeCreate(tx *gorm.DB) error {
	if n.ID == "" {
		n.ID = uuid.New().String()
	}
	return nil
}
