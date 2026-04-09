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

	if err := db.AutoMigrate(&models.User{}, &models.Team{}, &models.Group{}, &models.Project{}, &models.StickyNote{}, &models.NoteVote{}); err != nil {
		log.Fatal("failed to migrate database:", err)
	}

	log.Println("database initialized")
	return db
}
