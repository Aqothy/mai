package wire

// Regenerate the canonical schema and all checked-in client models.
// Run from anywhere with: go generate ./api/wire
//go:generate go run ../../cmd/generate-wire-schema -out ../generated/client-api.schema.json -methods-out ../generated/rpc-methods.json
//go:generate npm --prefix ../../tools/client-gen run generate
