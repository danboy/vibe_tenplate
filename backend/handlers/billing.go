package handlers

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"

	"tenplate/models"

	"github.com/gin-gonic/gin"
	stripelib "github.com/stripe/stripe-go/v76"
	"github.com/stripe/stripe-go/v76/webhook"
	"gorm.io/gorm"
)

type BillingHandler struct {
	db *gorm.DB
}

func NewBillingHandler(db *gorm.DB) *BillingHandler {
	return &BillingHandler{db: db}
}

func planToPriceID(plan string) string {
	switch plan {
	case "standard":
		return os.Getenv("STRIPE_STANDARD_PRICE_ID")
	case "pro":
		return os.Getenv("STRIPE_PRO_PRICE_ID")
	default:
		return ""
	}
}

func priceIDToPlan(priceID string) string {
	if priceID == os.Getenv("STRIPE_STANDARD_PRICE_ID") {
		return "standard"
	}
	if priceID == os.Getenv("STRIPE_PRO_PRICE_ID") {
		return "pro"
	}
	return "free"
}

type CheckoutRequest struct {
	Plan       string `json:"plan"        binding:"required"`
	SuccessURL string `json:"success_url" binding:"required"`
	CancelURL  string `json:"cancel_url"  binding:"required"`
}

type PortalRequest struct {
	ReturnURL string `json:"return_url" binding:"required"`
}

func (h *BillingHandler) HandleWebhook(c *gin.Context) {
	body, err := io.ReadAll(c.Request.Body)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "failed to read body"})
		return
	}

	sig := c.GetHeader("Stripe-Signature")
	secret := os.Getenv("STRIPE_WEBHOOK_SECRET")

	log.Printf("stripe webhook: body=%d bytes, sig_present=%v, secret_prefix=%.12s",
		len(body), sig != "", secret)

	event, err := webhook.ConstructEventWithOptions(body, sig, secret,
		webhook.ConstructEventOptions{IgnoreAPIVersionMismatch: true})
	if err != nil {
		log.Printf("stripe webhook signature error: %v", err)
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid webhook signature"})
		return
	}

	switch event.Type {
	case "checkout.session.completed":
		h.handleCheckoutCompleted(event)
	case "customer.subscription.updated":
		h.handleSubscriptionUpdated(event)
	case "customer.subscription.deleted":
		h.handleSubscriptionDeleted(event)
	}

	c.JSON(http.StatusOK, gin.H{})
}

func (h *BillingHandler) handleCheckoutCompleted(event stripelib.Event) {
	var s stripelib.CheckoutSession
	if err := json.Unmarshal(event.Data.Raw, &s); err != nil {
		log.Printf("stripe: failed to parse checkout.session.completed: %v", err)
		return
	}

	teamID := s.Metadata["team_id"]
	plan := s.Metadata["plan"]
	userID := s.Metadata["user_id"]
	if teamID == "" || plan == "" {
		return
	}

	updates := map[string]any{"plan": plan}
	if s.Subscription != nil {
		updates["stripe_subscription_id"] = s.Subscription.ID
	}
	h.db.Model(&models.Team{}).Where("id = ?", teamID).UpdateColumns(updates)

	if userID != "" && s.Customer != nil {
		h.db.Model(&models.User{}).Where("id = ?", userID).Update("stripe_customer_id", s.Customer.ID)
	}
	log.Printf("stripe: team %s upgraded to %s", teamID, plan)
}

func (h *BillingHandler) handleSubscriptionUpdated(event stripelib.Event) {
	var sub stripelib.Subscription
	if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
		log.Printf("stripe: failed to parse subscription.updated: %v", err)
		return
	}

	var team models.Team
	if h.db.Where("stripe_subscription_id = ?", sub.ID).First(&team).Error != nil {
		return
	}

	switch sub.Status {
	case stripelib.SubscriptionStatusActive, stripelib.SubscriptionStatusTrialing:
		if len(sub.Items.Data) > 0 {
			plan := priceIDToPlan(sub.Items.Data[0].Price.ID)
			h.db.Model(&team).Update("plan", plan)
			log.Printf("stripe: team %s plan synced to %s", team.ID, plan)
		}
	case stripelib.SubscriptionStatusCanceled, stripelib.SubscriptionStatusUnpaid:
		h.db.Model(&team).UpdateColumns(map[string]any{
			"plan":                   "free",
			"stripe_subscription_id": "",
		})
		log.Printf("stripe: team %s downgraded to free (status: %s)", team.ID, sub.Status)
	}
}

func (h *BillingHandler) handleSubscriptionDeleted(event stripelib.Event) {
	var sub stripelib.Subscription
	if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
		log.Printf("stripe: failed to parse subscription.deleted: %v", err)
		return
	}

	h.db.Model(&models.Team{}).
		Where("stripe_subscription_id = ?", sub.ID).
		UpdateColumns(map[string]any{
			"plan":                   "free",
			"stripe_subscription_id": "",
		})
	log.Printf("stripe: subscription %s deleted, team downgraded to free", sub.ID)
}
