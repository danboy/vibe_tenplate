package models

import (
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type NoteVote struct {
	ID        string `json:"id"         gorm:"primaryKey;type:text"`
	ProjectID string `json:"project_id" gorm:"not null;index;type:text"`
	NoteID    string `json:"note_id"    gorm:"not null;index;type:text"`
	UserID    string `json:"user_id"    gorm:"not null;type:text"`
	Count     int    `json:"count"      gorm:"not null;default:0"`
}

func (v *NoteVote) BeforeCreate(tx *gorm.DB) error {
	if v.ID == "" {
		v.ID = uuid.New().String()
	}
	return nil
}
