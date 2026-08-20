# Client contract generation

The daemon uses JSON-RPC 2.0 over WebSocket. Go is the source of truth for every
client-visible payload and method:

- `api/wire/wire.go` lists shared DTOs and owns RPC parameter/result DTOs.
- `api/wire/methods.go` is the canonical method and notification registry.
- `api/generated/client-api.schema.json` is the generated JSON Schema.
- `api/generated/rpc-methods.json` is the generated method manifest.
- `clients/swift/mai/Generated/` contains generated Swift `Codable` models and
  RPC method constants. Xcode's synchronized source group compiles these files
  automatically.
- `tools/client-gen/` contains the pinned Swift generator tooling.

Do not edit generated files directly.

## Workflow

After changing a client-visible Go type or JSON-RPC method:

```sh
make generate
```

`make generate` installs the pinned Swift generator dependencies when they are
missing or when its package files change. To install them explicitly, run:

```sh
make client-gen-setup
```

The underlying Go command skips dependency installation and therefore expects
`client-gen-setup` (or `npm ci` in `tools/client-gen`) to have run already. It
regenerates the schema and Swift client:

```sh
go generate ./api/wire
```

## Adding an RPC method

1. Add its method constant and parameter/result DTOs to `api/wire`.
2. Add one `MethodDefinition` to `wire.Methods`.
3. For a server notification, add a `NotificationDefinition`.
4. Implement the handler using the wire constant and DTO.
5. Run `make generate`.

The Swift WebSocket/JSON-RPC runtime remains handwritten and small; it decodes
results and notifications with the generated models and uses
`MaidRPCMethod` constants.

## Optional-field envelopes

Commands and stream items are broad Go structs with optional fields. The
`jsonschema` reflector mirrors that shape; it cannot infer rules such as
"message is required when type is thread.turn.start" from pointers and string
constants alone. The daemon remains the authority and validates those rules at
runtime.

If compile-time tagged unions become valuable later, model them explicitly in
the canonical Go wire layer. Until then, avoiding a second custom union schema
keeps generation simple and prevents Go, schema, and Swift definitions from
drifting.

## Internal versus wire types

Provider adapter runtime events, process generations, resume cursors, and ACP
native protocol DTOs are internal and must not be added merely because they
have JSON tags. Add only values crossing the client WebSocket boundary.

Some fields intentionally contain arbitrary JSON (`config`, non-tool item
payloads, approval args). They generate as `JSONAny` in Swift.
Provider-native tool input/output stays adapter-private;
tool presentation uses only the typed `toolCall` fields.
