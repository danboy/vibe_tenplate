package middleware

import (
	"net/http"

	"tenplate/models"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

// AdminMiddleware checks that the authenticated user has is_admin = true.
// Must be placed after AuthMiddleware.
func AdminMiddleware(db *gorm.DB) gin.HandlerFunc {
	return func(c *gin.Context) {
		userID := c.MustGet("userID").(string)

		var user models.User
		if err := db.Select("is_admin").Where("id = ?", userID).First(&user).Error; err != nil {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "user not found"})
			c.Abort()
			return
		}

		if !user.IsAdmin {
			c.JSON(http.StatusForbidden, gin.H{"error": "admin access required"})
			c.Abort()
			return
		}

		c.Next()
	}
}
