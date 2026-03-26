package main

import (
	"log"
	"net/http"
	"os"

	"tenplate/database"
	"tenplate/handlers"
	"tenplate/middleware"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
)

func corsMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		c.Header("Access-Control-Allow-Origin", "*")
		c.Header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

func main() {
	if err := godotenv.Load(); err != nil {
		log.Println("no .env file found, using environment variables")
	}

	db := database.InitDB()

	r := gin.Default()
	r.Use(corsMiddleware())

	authHandler := handlers.NewAuthHandler(db)
	groupHandler := handlers.NewGroupHandler(db)
	projectHandler := handlers.NewProjectHandler(db)
	slideshowHandler := handlers.NewSlideshowHandler(db)

	// WebSocket — auth is handled inside the handler via ?token= query param
	r.GET("/ws/projects/:id", slideshowHandler.Connect)

	api := r.Group("/api")
	{
		auth := api.Group("/auth")
		{
			auth.POST("/register", authHandler.Register)
			auth.POST("/login", authHandler.Login)
		}

		protected := api.Group("/")
		protected.Use(middleware.AuthMiddleware())
		{
			protected.GET("/users/me", authHandler.GetMe)
			protected.GET("/users/me/groups", groupHandler.GetMyGroups)
			protected.GET("/groups", groupHandler.ListGroups)
			protected.POST("/groups", groupHandler.CreateGroup)
			protected.POST("/groups/join-by-code", groupHandler.JoinByCode)
			protected.GET("/groups/:id", groupHandler.GetGroup)
			protected.POST("/groups/:id/join", groupHandler.JoinGroup)
			protected.POST("/groups/:id/leave", groupHandler.LeaveGroup)
			protected.GET("/groups/:id/projects", projectHandler.ListProjects)
			protected.POST("/groups/:id/projects", projectHandler.CreateProject)
			protected.GET("/groups/:id/projects/:pid", projectHandler.GetProject)
			protected.PATCH("/groups/:id/projects/:pid", projectHandler.UpdateProject)
			protected.DELETE("/groups/:id/projects/:pid", projectHandler.DeleteProject)
			protected.PUT("/groups/:id/projects/:pid/presenter", projectHandler.SetPresenter)
		}
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("server starting on :%s", port)
	if err := r.Run(":" + port); err != nil {
		log.Fatal(err)
	}
}
