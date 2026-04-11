package models

type TeamMember struct {
	TeamID string `gorm:"primaryKey;type:text"`
	UserID string `gorm:"primaryKey;type:text"`
	Role   string `gorm:"type:text;not null;default:'member'"`
}
