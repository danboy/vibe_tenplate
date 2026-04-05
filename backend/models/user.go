package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

type User struct {
	ID        string         `json:"id"       gorm:"primaryKey;type:text"`
	CreatedAt time.Time      `json:"created_at"`
	UpdatedAt time.Time      `json:"updated_at"`
	DeletedAt gorm.DeletedAt `json:"-"        gorm:"index"`
	Username  string         `json:"username" gorm:"uniqueIndex;not null"`
	Email     string         `json:"email"    gorm:"uniqueIndex;not null"`
	Password         string         `json:"-"        gorm:"not null"`
	StripeCustomerID string         `json:"-"        gorm:"type:text"`
	Groups           []Group        `json:"groups,omitempty" gorm:"many2many:user_groups;"`
}

func (u *User) BeforeCreate(tx *gorm.DB) error {
	if u.ID == "" {
		u.ID = uuid.New().String()
	}
	return nil
}

type UserResponse struct {
	ID       string `json:"id"`
	Username string `json:"username"`
	Email    string `json:"email"`
}

func (u *User) ToResponse() UserResponse {
	return UserResponse{
		ID:       u.ID,
		Username: u.Username,
		Email:    u.Email,
	}
}
