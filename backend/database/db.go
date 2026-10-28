package database

import (
	"log"
	"os"

	"tenplate/models"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func InitDB() *gorm.DB {
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		dsn = "host=localhost user=postgres password=postgres dbname=tenplate port=5432 sslmode=disable"
	}

	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{})
	if err != nil {
		log.Fatal("failed to connect to database:", err)
	}

	if err := db.SetupJoinTable(&models.Team{}, "Members", &models.TeamMember{}); err != nil {
		log.Fatal("failed to setup team join table:", err)
	}
	if err := db.SetupJoinTable(&models.User{}, "Teams", &models.TeamMember{}); err != nil {
		log.Fatal("failed to setup user join table:", err)
	}

	// Rename legacy columns from the projects → brainstorms rename.
	// HasColumn checks for the old name; if present we rename before AutoMigrate
	// tries to add a new NOT NULL column and fails on existing rows.
	if db.Migrator().HasColumn(&models.StickyNote{}, "project_id") {
		if err := db.Exec("ALTER TABLE sticky_notes RENAME COLUMN project_id TO brainstorm_id").Error; err != nil {
			log.Fatal("failed to rename sticky_notes.project_id: ", err)
		}
	}
	if db.Migrator().HasColumn(&models.NoteVote{}, "project_id") {
		if err := db.Exec("ALTER TABLE note_votes RENAME COLUMN project_id TO brainstorm_id").Error; err != nil {
			log.Fatal("failed to rename note_votes.project_id: ", err)
		}
	}

	if err := db.AutoMigrate(&models.User{}, &models.Team{}, &models.Group{}, &models.Brainstorm{}, &models.StickyNote{}, &models.NoteVote{}, &models.OAuthIdentity{}, &models.TeamSSOConfig{}, &models.Goal{}, &models.KeyResult{}, &models.TeamIntegration{}, &models.ExportRun{}, &models.ExportedItem{}); err != nil {
		log.Fatal("failed to migrate database:", err)
	}

	log.Println("database initialized")
	return db
}
