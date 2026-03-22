package utils

import (
	"fmt"
	"regexp"
	"strings"
)

var nonAlphanumRegex = regexp.MustCompile(`[^a-z0-9]+`)

func Slugify(name string) string {
	s := strings.ToLower(name)
	s = nonAlphanumRegex.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	if s == "" {
		s = "unnamed"
	}
	return s
}

// UniqueSlug returns a slug unique within the given table+column using the
// provided exists function to check for collisions.
func UniqueSlug(base string, exists func(slug string) bool) string {
	slug := base
	for i := 2; exists(slug); i++ {
		slug = fmt.Sprintf("%s-%d", base, i)
	}
	return slug
}
