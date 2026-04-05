package models

import (
	"time"

	"github.com/google/uuid"
	"gorm.io/gorm"
)

type Project struct {
	ID          string         `json:"id"          gorm:"primaryKey;type:text"`
	CreatedAt   time.Time      `json:"created_at"`
	UpdatedAt   time.Time      `json:"updated_at"`
	DeletedAt   gorm.DeletedAt `json:"-"           gorm:"index"`
	Name        string         `json:"name"        gorm:"not null"`
	Slug        string         `json:"slug"        gorm:"uniqueIndex:idx_group_project_slug;not null;type:text"`
	Description string         `json:"description"`
	GroupID     string         `json:"group_id"    gorm:"not null;index;uniqueIndex:idx_group_project_slug;type:text"`
	CreatedBy   string         `json:"created_by"  gorm:"type:text"`
	Creator     *User          `json:"creator,omitempty"   gorm:"foreignKey:CreatedBy"`
	PresenterID      *string        `json:"presenter_id"        gorm:"type:text"`
	Presenter        *User          `json:"presenter,omitempty" gorm:"foreignKey:PresenterID"`
	EnableProblem      bool   `json:"enable_problem"      gorm:"not null;default:true"`
	EnableVote         bool   `json:"enable_vote"         gorm:"not null;default:true"`
	EnablePrioritise   bool   `json:"enable_prioritise"   gorm:"not null;default:true"`
	ProblemStatement   string `json:"problem_statement"   gorm:"type:text;not null;default:''"`

	GuestsEnabled bool   `json:"guests_enabled" gorm:"not null;default:false"`

	// Custom interstitial descriptions (empty = use app default)
	InterstitialProblem    string `json:"interstitial_problem"    gorm:"type:text;not null;default:''"`
	InterstitialBrainstorm string `json:"interstitial_brainstorm" gorm:"type:text;not null;default:''"`
	InterstitialGroup      string `json:"interstitial_group"      gorm:"type:text;not null;default:''"`
	InterstitialVote       string `json:"interstitial_vote"       gorm:"type:text;not null;default:''"`
	InterstitialPrioritise string `json:"interstitial_prioritise" gorm:"type:text;not null;default:''"`
}

func (p *Project) BeforeCreate(tx *gorm.DB) error {
	if p.ID == "" {
		p.ID = uuid.New().String()
	}
	return nil
}
