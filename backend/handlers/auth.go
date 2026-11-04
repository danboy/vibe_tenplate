package handlers

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"tenplate/mail"
	"tenplate/middleware"
	"tenplate/models"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

type AuthHandler struct {
	db *gorm.DB
}

func NewAuthHandler(db *gorm.DB) *AuthHandler {
	return &AuthHandler{db: db}
}

type RegisterRequest struct {
	Username string `json:"username" binding:"required,min=3"`
	Email    string `json:"email" binding:"required,email"`
	Password string `json:"password" binding:"required,min=6"`
}

type LoginRequest struct {
	Email    string `json:"email" binding:"required,email"`
	Password string `json:"password" binding:"required"`
}

type ForgotPasswordRequest struct {
	Email string `json:"email" binding:"required,email"`
}

type ResetPasswordRequest struct {
	Token    string `json:"token" binding:"required"`
	Password string `json:"password" binding:"required,min=6"`
}

// passwordResetClaims is a distinct claims shape from middleware.Claims
// (login sessions) and oauthStateClaims. Purpose is load-bearing, not
// defensive: every JWT in this app is signed with the same JWTSecret(), and
// Go's JSON unmarshal silently zero-fills missing fields, so without this
// check a valid 7-day login token would also pass as a reset token.
type passwordResetClaims struct {
	UserID  string `json:"user_id"`
	Purpose string `json:"purpose"`
	jwt.RegisteredClaims
}

const passwordResetPurpose = "password_reset"

type AuthResponse struct {
	Token string              `json:"token"`
	User  models.UserResponse `json:"user"`
}

func generateToken(userID string) (string, error) {
	claims := &middleware.Claims{
		UserID: userID,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(7 * 24 * time.Hour)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	return token.SignedString(middleware.JWTSecret())
}

func (h *AuthHandler) Register(c *gin.Context) {
	var req RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to hash password"})
		return
	}

	user := models.User{
		Username: req.Username,
		Email:    req.Email,
		Password: string(hash),
	}

	if err := h.db.Create(&user).Error; err != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "username or email already exists"})
		return
	}

	token, err := generateToken(user.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate token"})
		return
	}

	c.JSON(http.StatusCreated, AuthResponse{Token: token, User: user.ToResponse()})
}

func (h *AuthHandler) Login(c *gin.Context) {
	var req LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var user models.User
	if err := h.db.Where("email = ?", req.Email).First(&user).Error; err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.Password), []byte(req.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid credentials"})
		return
	}

	token, err := generateToken(user.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to generate token"})
		return
	}

	c.JSON(http.StatusOK, AuthResponse{Token: token, User: user.ToResponse()})
}

func (h *AuthHandler) GetMe(c *gin.Context) {
	userID := c.MustGet("userID").(string)

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	c.JSON(http.StatusOK, user.ToResponse())
}

func (h *AuthHandler) ForgotPassword(c *gin.Context) {
	var req ForgotPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// Always respond identically whether or not the email exists, and never
	// block the response on the outbound mail send — both matter for not
	// leaking account existence (a found-user branch that waits on a real
	// HTTP call to Mailgun before responding is a timing side-channel).
	const genericMsg = "if that email exists, we've sent a reset link"

	var user models.User
	if err := h.db.Where("email = ?", req.Email).First(&user).Error; err != nil {
		c.JSON(http.StatusOK, gin.H{"message": genericMsg})
		return
	}

	claims := &passwordResetClaims{
		UserID:  user.ID,
		Purpose: passwordResetPurpose,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(30 * time.Minute)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString(middleware.JWTSecret())
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"message": genericMsg})
		return
	}
	link := fmt.Sprintf("%s/auth/reset-password?token=%s", os.Getenv("FRONTEND_BASE_URL"), token)

	go func() {
		if err := mail.SendPasswordResetEmail(user.Email, link); err != nil {
			log.Println("password reset email failed:", err)
		}
	}()

	c.JSON(http.StatusOK, gin.H{"message": genericMsg})
}

func (h *AuthHandler) ResetPassword(c *gin.Context) {
	var req ResetPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	claims := &passwordResetClaims{}
	_, err := jwt.ParseWithClaims(req.Token, claims, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return middleware.JWTSecret(), nil
	})
	if err != nil || claims.Purpose != passwordResetPurpose {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid or expired token"})
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to hash password"})
		return
	}

	// Atomic validate-and-consume: a token is only honored if it was issued
	// after the user's last successful reset (or there hasn't been one yet).
	// This closes the race where two requests carrying the same token could
	// otherwise both read a stale PasswordChangedAt before either commits.
	issuedAt := claims.IssuedAt.Time
	res := h.db.Model(&models.User{}).
		Where("id = ? AND (password_changed_at IS NULL OR password_changed_at < ?)", claims.UserID, issuedAt).
		UpdateColumns(map[string]any{"password": string(hash), "password_changed_at": time.Now()})
	if res.RowsAffected == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid or expired token"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "password updated"})
}

