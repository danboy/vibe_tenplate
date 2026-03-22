package handlers

import (
	"net/http"

	"tenplate/middleware"
	"tenplate/models"
	"tenplate/ws"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"github.com/gorilla/websocket"
	"gorm.io/gorm"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  1024,
	WriteBufferSize: 1024,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

type SlideshowHandler struct {
	db *gorm.DB
}

func NewSlideshowHandler(db *gorm.DB) *SlideshowHandler {
	return &SlideshowHandler{db: db}
}

func (h *SlideshowHandler) Connect(c *gin.Context) {
	// WebSocket clients can't send custom headers, so the JWT comes as a query param.
	tokenStr := c.Query("token")
	if tokenStr == "" {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "missing token"})
		return
	}

	claims := &middleware.Claims{}
	token, err := jwt.ParseWithClaims(tokenStr, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return middleware.JWTSecret(), nil
	})
	if err != nil || !token.Valid {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid token"})
		return
	}

	// The WS route uses the project UUID directly.
	projectID := c.Param("id")

	var project models.Project
	if err := h.db.Where("id = ?", projectID).First(&project).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "project not found"})
		return
	}

	// Verify the user is a member of the project's group.
	var group models.Group
	if err := h.db.Preload("Members").Where("id = ?", project.GroupID).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}
	isMember := false
	for _, m := range group.Members {
		if m.ID == claims.UserID {
			isMember = true
			break
		}
	}
	if !isMember {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a member"})
		return
	}

	var user models.User
	h.db.First(&user, claims.UserID)

	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		return
	}

	hub := ws.GetHub(projectID, h.db)
	client := ws.NewClient(hub, conn, claims.UserID, user.Username)

	hub.Register(client)

	go client.WritePump()
	go client.ReadPump()
}
