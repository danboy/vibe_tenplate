package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

// OAuthIdentity links a User to an external SSO provider account so repeat
// logins from the same provider account resolve to the same local user.
type OAuthIdentity struct {
	ID             string    `json:"id"               gorm:"primaryKey;type:text"`
	CreatedAt      time.Time `json:"created_at"`
	UserID         string    `json:"user_id"          gorm:"type:text;not null;index"`
	Provider       string    `json:"provider"         gorm:"type:text;not null;uniqueIndex:idx_provider_account"`
	ProviderUserID string    `json:"provider_user_id" gorm:"type:text;not null;uniqueIndex:idx_provider_account"`
	Email          string    `json:"email"            gorm:"type:text"`
}

func (o *OAuthIdentity) BeforeCreate(tx *gorm.DB) error {
	if o.ID == "" {
		o.ID = uuid.New().String()
	}
	return nil
}
