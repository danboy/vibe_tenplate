package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// TeamIntegration stores a team-level OAuth connection to a third-party
// provider (GitHub, Asana, ...) used to export brainstorm note-clusters as
// issues/tasks. Unlike OAuthIdentity (login-only), this persists a usable
// API token.
type TeamIntegration struct {
	ID             string     `json:"id"              gorm:"primaryKey;type:text"`
	CreatedAt      time.Time  `json:"created_at"`
	UpdatedAt      time.Time  `json:"updated_at"`
	TeamID         string     `json:"team_id"         gorm:"type:text;not null;uniqueIndex:idx_team_provider_integration"`
	Provider       string     `json:"provider"        gorm:"type:text;not null;uniqueIndex:idx_team_provider_integration"`
	AccessToken    string     `json:"-"               gorm:"type:text;not null"`
	RefreshToken   string     `json:"-"               gorm:"type:text"`
	TokenExpiresAt *time.Time `json:"-"`
	AccountLabel   string     `json:"account_label"`
	TargetRef      string     `json:"target_ref"`
}

func (t *TeamIntegration) BeforeCreate(tx *gorm.DB) error {
	if t.ID == "" {
		t.ID = uuid.New().String()
	}
	return nil
}
