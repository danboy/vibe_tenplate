package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// KeyResult is one measurable result under an OKR-style Goal.
type KeyResult struct {
	ID           string         `json:"id"            gorm:"primaryKey;type:text"`
	CreatedAt    time.Time      `json:"created_at"`
	UpdatedAt    time.Time      `json:"updated_at"`
	DeletedAt    gorm.DeletedAt `json:"-"              gorm:"index"`
	GoalID       string         `json:"goal_id"        gorm:"type:text;not null;index"`
	Title        string         `json:"title"          gorm:"not null"`
	Unit         string         `json:"unit"`
	TargetValue  float64        `json:"target_value"`
	CurrentValue float64        `json:"current_value"`
}

func (k *KeyResult) BeforeCreate(tx *gorm.DB) error {
	if k.ID == "" {
		k.ID = uuid.New().String()
	}
	return nil
}
