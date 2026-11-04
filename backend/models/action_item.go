package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

type ActionItem struct {
	ID           string         `json:"id"           gorm:"primaryKey;type:text"`
	CreatedAt    time.Time      `json:"created_at"`
	UpdatedAt    time.Time      `json:"updated_at"`
	DeletedAt    gorm.DeletedAt `json:"-"             gorm:"index"`
	BrainstormID string         `json:"brainstorm_id" gorm:"not null;index;type:text"`
	Content      string         `json:"content"`
	CreatedBy    string         `json:"created_by"    gorm:"type:text"`
	Author       string         `json:"author"`
}

func (a *ActionItem) BeforeCreate(tx *gorm.DB) error {
	if a.ID == "" {
		a.ID = uuid.New().String()
	}
	return nil
}
