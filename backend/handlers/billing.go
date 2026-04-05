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
	checkoutsession "github.com/stripe/stripe-go/v76/checkout/session"
	portalsession "github.com/stripe/stripe-go/v76/billingportal/session"
	"github.com/stripe/stripe-go/v76/webhook"
	"gorm.io/gorm"
)

type BillingHandler struct {
	db *gorm.DB
}

func NewBillingHandler(db *gorm.DB) *BillingHandler {
	stripelib.Key = os.Getenv("STRIPE_SECRET_KEY")
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

func (h *BillingHandler) CreateCheckoutSession(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	groupSlug := c.Param("id")

	var req CheckoutRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if req.Plan != "standard" && req.Plan != "pro" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid plan"})
		return
	}

	priceID := planToPriceID(req.Plan)
	if priceID == "" {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "price not configured — set STRIPE_STANDARD_PRICE_ID / STRIPE_PRO_PRICE_ID"})
		return
	}

	var group models.Group
	if err := h.db.Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}
	if group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the group owner can change the plan"})
		return
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}

	params := &stripelib.CheckoutSessionParams{
		Mode: stripelib.String("subscription"),
		LineItems: []*stripelib.CheckoutSessionLineItemParams{
			{Price: stripelib.String(priceID), Quantity: stripelib.Int64(1)},
		},
		SuccessURL: stripelib.String(req.SuccessURL),
		CancelURL:  stripelib.String(req.CancelURL),
		Metadata: map[string]string{
			"group_id": group.ID,
			"plan":     req.Plan,
			"user_id":  userID,
		},
	}
	if user.StripeCustomerID != "" {
		params.Customer = stripelib.String(user.StripeCustomerID)
	} else {
		params.CustomerEmail = stripelib.String(user.Email)
	}

	s, err := checkoutsession.New(params)
	if err != nil {
		log.Printf("stripe checkout error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create checkout session"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"url": s.URL})
}

type PortalRequest struct {
	ReturnURL string `json:"return_url" binding:"required"`
}

func (h *BillingHandler) CreatePortalSession(c *gin.Context) {
	userID := c.MustGet("userID").(string)
	groupSlug := c.Param("id")

	var req PortalRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	var group models.Group
	if err := h.db.Where("slug = ?", groupSlug).First(&group).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "group not found"})
		return
	}
	if group.OwnerID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "only the group owner can manage billing"})
		return
	}

	var user models.User
	if err := h.db.Where("id = ?", userID).First(&user).Error; err != nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
		return
	}
	if user.StripeCustomerID == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "no billing account found for this group"})
		return
	}

	params := &stripelib.BillingPortalSessionParams{
		Customer:  stripelib.String(user.StripeCustomerID),
		ReturnURL: stripelib.String(req.ReturnURL),
	}
	s, err := portalsession.New(params)
	if err != nil {
		log.Printf("stripe portal error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "failed to create portal session"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"url": s.URL})
}

func (h *BillingHandler) HandleWebhook(c *gin.Context) {
	body, err := io.ReadAll(c.Request.Body)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "failed to read body"})
		return
	}

	sig := c.GetHeader("Stripe-Signature")
	event, err := webhook.ConstructEvent(body, sig, os.Getenv("STRIPE_WEBHOOK_SECRET"))
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

	groupID := s.Metadata["group_id"]
	plan := s.Metadata["plan"]
	userID := s.Metadata["user_id"]
	if groupID == "" || plan == "" {
		return
	}

	updates := map[string]any{"plan": plan}
	if s.Subscription != nil {
		updates["stripe_subscription_id"] = s.Subscription.ID
	}
	h.db.Model(&models.Group{}).Where("id = ?", groupID).UpdateColumns(updates)

	if userID != "" && s.Customer != nil {
		h.db.Model(&models.User{}).Where("id = ?", userID).Update("stripe_customer_id", s.Customer.ID)
	}
	log.Printf("stripe: group %s upgraded to %s", groupID, plan)
}

func (h *BillingHandler) handleSubscriptionUpdated(event stripelib.Event) {
	var sub stripelib.Subscription
	if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
		log.Printf("stripe: failed to parse subscription.updated: %v", err)
		return
	}

	var group models.Group
	if h.db.Where("stripe_subscription_id = ?", sub.ID).First(&group).Error != nil {
		return
	}

	switch sub.Status {
	case stripelib.SubscriptionStatusActive, stripelib.SubscriptionStatusTrialing:
		if len(sub.Items.Data) > 0 {
			plan := priceIDToPlan(sub.Items.Data[0].Price.ID)
			h.db.Model(&group).Update("plan", plan)
			log.Printf("stripe: group %s plan synced to %s", group.ID, plan)
		}
	case stripelib.SubscriptionStatusCanceled, stripelib.SubscriptionStatusUnpaid:
		h.db.Model(&group).UpdateColumns(map[string]any{
			"plan":                   "free",
			"stripe_subscription_id": "",
		})
		log.Printf("stripe: group %s downgraded to free (status: %s)", group.ID, sub.Status)
	}
}

func (h *BillingHandler) handleSubscriptionDeleted(event stripelib.Event) {
	var sub stripelib.Subscription
	if err := json.Unmarshal(event.Data.Raw, &sub); err != nil {
		log.Printf("stripe: failed to parse subscription.deleted: %v", err)
		return
	}

	h.db.Model(&models.Group{}).
		Where("stripe_subscription_id = ?", sub.ID).
		UpdateColumns(map[string]any{
			"plan":                   "free",
			"stripe_subscription_id": "",
		})
	log.Printf("stripe: subscription %s deleted, group downgraded to free", sub.ID)
}
