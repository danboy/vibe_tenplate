package mail

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
)

// SendPasswordResetEmail sends a password reset link to toEmail via Mailgun.
// Reads MAILGUN_API_KEY/MAILGUN_URL/MAILGUN_FROM lazily (not cached at
// startup), matching middleware.JWTSecret()'s style.
func SendPasswordResetEmail(toEmail, resetLink string) error {
	apiKey := os.Getenv("MAILGUN_API_KEY")
	domain := os.Getenv("MAILGUN_URL")
	from := os.Getenv("MAILGUN_FROM")

	form := url.Values{
		"from":    {from},
		"to":      {toEmail},
		"subject": {"Reset your 10plate password"},
		"text": {fmt.Sprintf(
			"We received a request to reset your 10plate password.\n\n"+
				"Reset it here (expires in 30 minutes):\n%s\n\n"+
				"If you didn't request this, you can ignore this email.",
			resetLink,
		)},
	}

	endpoint := fmt.Sprintf("https://api.mailgun.net/v3/%s/messages", domain)
	req, err := http.NewRequest(http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.SetBasicAuth("api", apiKey)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("mailgun send failed (%d): %s", resp.StatusCode, string(body))
	}
	return nil
}
