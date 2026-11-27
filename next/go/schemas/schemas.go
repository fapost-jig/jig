// Package schemas embeds the committed JSON Schemas of Jig's shapes. They are
// generated from the Go structs of internal/schema by that package's tests
// (`go test ./internal/schema -update` rewrites them); nothing here is written
// by hand.
package schemas

import "embed"

// FS holds the *.schema.json files.
//
//go:embed *.schema.json
var FS embed.FS
