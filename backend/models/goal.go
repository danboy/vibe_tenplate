package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// Goal is a team-level objective. KPI goals use Unit/TargetValue/CurrentValue
// directly; OKR goals leave those zero and track progress via KeyResults.
type Goal struct {
	ID           string         `json:"id"            gorm:"primaryKey;type:text"`
	CreatedAt    time.Time      `json:"created_at"`
	UpdatedAt    time.Time      `json:"updated_at"`
	DeletedAt    gorm.DeletedAt `json:"-"              gorm:"index"`
	TeamID       string         `json:"team_id"        gorm:"type:text;not null;index"`
	Title        string         `json:"title"          gorm:"not null"`
	Unit         string         `json:"unit"`
	TargetValue  float64        `json:"target_value"`
	CurrentValue float64        `json:"current_value"`
	KeyResults   []KeyResult    `json:"key_results,omitempty" gorm:"foreignKey:GoalID"`
}

func (g *Goal) BeforeCreate(tx *gorm.DB) error {
	if g.ID == "" {
		g.ID = uuid.New().String()
	}
	return nil
}
