package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// TeamSSOConfig lets a team owner trust an SSO provider's org/domain: anyone
// who signs in via that provider and belongs to OrgMatch is auto-added to
// the team.
type TeamSSOConfig struct {
	ID        string    `json:"id"         gorm:"primaryKey;type:text"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	TeamID    string    `json:"team_id"    gorm:"type:text;not null;uniqueIndex:idx_team_provider"`
	Provider  string    `json:"provider"   gorm:"type:text;not null;uniqueIndex:idx_team_provider"`
	OrgMatch  string    `json:"org_match"  gorm:"type:text;not null"`
}

func (t *TeamSSOConfig) BeforeCreate(tx *gorm.DB) error {
	if t.ID == "" {
		t.ID = uuid.New().String()
	}
	return nil
}
