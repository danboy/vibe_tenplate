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
	teamHandler := handlers.NewTeamHandler(db)
	brainstormHandler := handlers.NewBrainstormHandler(db)
	slideshowHandler := handlers.NewSlideshowHandler(db)
	guestHandler := handlers.NewGuestHandler(db)
	billingHandler := handlers.NewBillingHandler(db)
	adminHandler := handlers.NewAdminHandler(db)
	oauthHandler := handlers.NewOAuthHandler(db)

	// WebSocket — auth is handled inside the handler via ?token= query param
	r.GET("/ws/brainstorms/:id", slideshowHandler.Connect)

	// Stripe webhook — must be outside auth middleware; reads raw body for sig verification
	r.POST("/stripe/webhook", billingHandler.HandleWebhook)

	api := r.Group("/api")
	{
		auth := api.Group("/auth")
		{
			auth.POST("/register", authHandler.Register)
			auth.POST("/login", authHandler.Login)
			auth.GET("/oauth/:provider/start", oauthHandler.Start)
			auth.GET("/oauth/:provider/callback", oauthHandler.Callback)
		}

		// Public guest endpoints — no auth required
		guest := api.Group("/guest")
		{
			guest.GET("/groups/:id/brainstorms/:bid", guestHandler.GetGuestBrainstorm)
			guest.POST("/brainstorms/:id/join", guestHandler.GuestJoin)
		}

		protected := api.Group("/")
		protected.Use(middleware.AuthMiddleware())
		{
			protected.GET("/users/me", authHandler.GetMe)
			protected.GET("/users/me/groups", groupHandler.GetMyGroups)
			protected.GET("/users/me/teams", teamHandler.ListMyTeams)

			// Teams
			protected.GET("/teams", teamHandler.ListTeams)
			protected.POST("/teams", teamHandler.CreateTeam)
			protected.POST("/teams/join-by-code", teamHandler.JoinByCode)
			protected.GET("/teams/:id", teamHandler.GetTeam)
			protected.POST("/teams/:id/join", teamHandler.JoinTeam)
			protected.POST("/teams/:id/leave", teamHandler.LeaveTeam)
			protected.PATCH("/teams/:id/members/:userId", teamHandler.UpdateMemberRole)
			protected.GET("/teams/:id/groups", groupHandler.ListTeamGroups)
			protected.POST("/teams/:id/checkout", teamHandler.CreateCheckoutSession)
			protected.POST("/teams/:id/billing-portal", teamHandler.CreatePortalSession)
			protected.GET("/teams/:id/sso", teamHandler.ListSSOConfigs)
			protected.PUT("/teams/:id/sso/:provider", teamHandler.UpsertSSOConfig)
			protected.DELETE("/teams/:id/sso/:provider", teamHandler.DeleteSSOConfig)

			// Groups
			protected.GET("/groups", groupHandler.ListGroups)
			protected.POST("/groups", groupHandler.CreateGroup)
			protected.GET("/groups/:id", groupHandler.GetGroup)
			protected.POST("/groups/:id/join", groupHandler.JoinGroup)
			protected.POST("/groups/:id/leave", groupHandler.LeaveGroup)

			// Brainstorms
			protected.GET("/groups/:id/brainstorms", brainstormHandler.ListBrainstorms)
			protected.POST("/groups/:id/brainstorms", brainstormHandler.CreateBrainstorm)
			protected.GET("/groups/:id/brainstorms/:bid", brainstormHandler.GetBrainstorm)
			protected.PATCH("/groups/:id/brainstorms/:bid", brainstormHandler.UpdateBrainstorm)
			protected.DELETE("/groups/:id/brainstorms/:bid", brainstormHandler.DeleteBrainstorm)
			protected.PUT("/groups/:id/brainstorms/:bid/presenter", brainstormHandler.SetPresenter)

			// Admin routes
			admin := protected.Group("/admin")
			admin.Use(middleware.AdminMiddleware(db))
			{
				admin.GET("/teams", adminHandler.ListAllTeams)
				admin.PATCH("/teams/:id/plan", adminHandler.UpdateTeamPlan)
			}
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
