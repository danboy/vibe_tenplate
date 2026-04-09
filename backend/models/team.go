package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

type Team struct {
	ID          string         `json:"id"          gorm:"primaryKey;type:text"`
	CreatedAt   time.Time      `json:"created_at"`
	UpdatedAt   time.Time      `json:"updated_at"`
	DeletedAt   gorm.DeletedAt `json:"-"           gorm:"index"`
	Name        string         `json:"name"        gorm:"not null"`
	Slug        string         `json:"slug"        gorm:"uniqueIndex;not null;type:text"`
	Description string         `json:"description"`
	OwnerID     string         `json:"owner_id"    gorm:"type:text"`
	IsPrivate            bool    `json:"is_private"  gorm:"default:false"`
	JoinCode             string  `json:"join_code"   gorm:"type:text"`
	Plan                 string  `json:"plan"        gorm:"type:text;not null;default:'free'"`
	StripeSubscriptionID string  `json:"-"           gorm:"type:text"`
	Members []User  `json:"members,omitempty" gorm:"many2many:team_members;"`
	Groups  []Group `json:"groups,omitempty"  gorm:"foreignKey:TeamID"`
}

func (t *Team) BeforeCreate(tx *gorm.DB) error {
	if t.ID == "" {
		t.ID = uuid.New().String()
	}
	return nil
}
