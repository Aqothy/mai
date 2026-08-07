.DEFAULT_GOAL := build

CLIENT_GEN_STAMP := tools/client-gen/node_modules/.package-lock.json

# The daemon links a static libghostty-vt (terminal model for attach and
# agent detection). Building the library once needs cmake and zig
# (`brew install cmake zig`); the produced daemon binary is statically
# linked and needs nothing installed at runtime.
#
# Any direct `go build`/`go test` (including gopls) needs
# PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) in its environment.
GHOSTTY_VT_BUILD := build/ghostty-vt
GHOSTTY_VT_STAMP := $(GHOSTTY_VT_BUILD)/.built
GHOSTTY_VT_PKG_CONFIG := $(CURDIR)/$(GHOSTTY_VT_BUILD)/_deps/ghostty-src/zig-out/share/pkgconfig

.PHONY: client-gen-setup generate build run ghostty-vt test

client-gen-setup: $(CLIENT_GEN_STAMP)

$(CLIENT_GEN_STAMP): tools/client-gen/package.json tools/client-gen/package-lock.json
	npm --prefix tools/client-gen ci --ignore-scripts

generate: client-gen-setup ghostty-vt
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) go generate ./api/wire

build: ghostty-vt
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) go build ./...

run: ghostty-vt
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) go run ./cmd/maiD

test: ghostty-vt
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) go test ./...

ghostty-vt: $(GHOSTTY_VT_STAMP)

$(GHOSTTY_VT_STAMP): tools/ghostty-vt/CMakeLists.txt
	cmake -S tools/ghostty-vt -B $(GHOSTTY_VT_BUILD) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(GHOSTTY_VT_BUILD)
	# Go's build cache does not hash linked static-library contents. A Ghostty
	# pin change must force cgo packages to relink instead of reusing the old VT.
	go clean -cache
	@touch $(GHOSTTY_VT_STAMP)
