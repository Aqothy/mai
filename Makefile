.DEFAULT_GOAL := build

CLIENT_GEN_STAMP := tools/client-gen/node_modules/.package-lock.json

# The daemon links a static libghostty-vt (each terminal run's model: it
# answers the program's queries and exports attach snapshots): the macOS
# slice of Ghostty's own ghostty-vt.xcframework.zip for the pinned commit, the
# same file ghost-swiftly pins for the app. The commit is `ghosttyCommit` in
# internal/terminal/vtscreen and must be the one the Go binding builds
# against; the zip's SHA-256 is below. To move the pin, run ghost-swiftly's
# Script/bump-ghostty.sh <commit> (it checks Ghostty's signature), copy its
# commit and checksum to both places, and update go.mitchellh.com/libghostty
# to a version that builds against that commit. The produced daemon binary is
# statically linked and needs nothing installed at runtime.
#
# Any direct `go build`/`go test` (including gopls) needs
# PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) in its environment.
GHOSTTY_VT_COMMIT := $(shell sed -n 's/^const ghosttyCommit = "\(.*\)"$$/\1/p' internal/terminal/vtscreen/vtscreen_ghostty.go)
GHOSTTY_VT_SHA256 := e70bb38e45b831a4fd28c6e3be40f3a4d0cf62eeced9c0f1fd255a0e19606379
GHOSTTY_VT_DIR := build/ghostty-vt
GHOSTTY_VT_STAMP := $(GHOSTTY_VT_DIR)/.$(GHOSTTY_VT_COMMIT)
GHOSTTY_VT_PKG_CONFIG := $(CURDIR)/$(GHOSTTY_VT_DIR)/pkgconfig
GHOSTTY_VT_SLICE := $(CURDIR)/$(GHOSTTY_VT_DIR)/ghostty-vt.xcframework/macos-arm64_x86_64

.PHONY: client-gen-setup generate build run ghostty-vt test fff-verify

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

$(GHOSTTY_VT_STAMP):
	@go mod download go.mitchellh.com/libghostty
	@binding="$$(go list -m -f '{{.Dir}}' go.mitchellh.com/libghostty)/CMakeLists.txt"; \
	grep -q 'GIT_TAG $(GHOSTTY_VT_COMMIT)$$' "$$binding" || { \
		echo "go.mitchellh.com/libghostty doesn't build against Ghostty $(GHOSTTY_VT_COMMIT) ($$binding)" >&2; exit 1; }
	rm -rf $(GHOSTTY_VT_DIR)
	mkdir -p $(GHOSTTY_VT_DIR)/pkgconfig
	curl -fsSL -o $(GHOSTTY_VT_DIR)/ghostty-vt.xcframework.zip \
		https://tip.files.ghostty.org/$(GHOSTTY_VT_COMMIT)/ghostty-vt.xcframework.zip
	echo '$(GHOSTTY_VT_SHA256)  $(GHOSTTY_VT_DIR)/ghostty-vt.xcframework.zip' | shasum -a 256 -c
	unzip -q $(GHOSTTY_VT_DIR)/ghostty-vt.xcframework.zip -d $(GHOSTTY_VT_DIR)
	printf '%s\n' 'Name: libghostty-vt-static' 'Description: Ghostty VT library' 'Version: $(GHOSTTY_VT_COMMIT)' \
		'Cflags: -I$(GHOSTTY_VT_SLICE)/Headers' 'Libs: $(GHOSTTY_VT_SLICE)/libghostty-vt.a' \
		> $(GHOSTTY_VT_DIR)/pkgconfig/libghostty-vt-static.pc
	# Go's build cache does not hash linked static-library contents. A Ghostty
	# pin change must force cgo packages to relink instead of reusing the old VT.
	go clean -cache
	@touch $(GHOSTTY_VT_STAMP)

# Deterministic vendored-FFF integrity checks: manifest checksums, arm64
# architecture, relocatable install name, and staged @loader_path loading.
# Never touches the network, Cargo, Zig, or npm.
fff-verify:
	cd third_party/fff && shasum -a 256 -c CHECKSUMS.sha256
	lipo -archs third_party/fff/lib/darwin-arm64/libfff_c.dylib | grep -qw arm64
	otool -D third_party/fff/lib/darwin-arm64/libfff_c.dylib | tail -1 | grep -qx '@rpath/libfff_c.dylib'
	sh tools/fff-smoke/verify_staged.sh
