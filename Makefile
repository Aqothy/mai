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

# File search links FFF's C library (internal/workspacesearch/fff): the
# aarch64-apple-darwin dylib from the pinned release, checked against the
# SHA-256 the release publishes beside it, and fff.h from the same tag, which
# GitHub serves without a checksum, so its SHA-256 is pinned here. The dylib's
# install name is upstream's CI path, so it is renamed to @rpath and re-signed.
# The daemon loads it at run time from $(FFF_DIR)/lib (the binary's rpath).
# The tag is the version in finder_darwin.go's cgo paths. To move the pin,
# take a release tag (never a nightly), change it there and both checksums
# below, and check that the functions finder_darwin.go calls kept their
# signatures.
FFF_TAG := $(shell sed -n 's|^\#cgo CFLAGS: .*/build/fff/\([^/]*\)/include$$|\1|p' internal/workspacesearch/fff/finder_darwin.go)
FFF_DYLIB_SHA256 := d052aae92b8d89f4734399aa53f80a327c4931f1b5dea0a7d96f9c488229ba43
FFF_HEADER_SHA256 := a74f5051edf60b4209aad2ded20e67bba85c72e0c1d3bc8e1ad0818e8e8ad6fb
FFF_DIR := build/fff/$(FFF_TAG)
FFF_STAMP := $(FFF_DIR)/.$(FFF_TAG)

.PHONY: client-gen-setup generate build run ghostty-vt fff test fff-verify

client-gen-setup: $(CLIENT_GEN_STAMP)

$(CLIENT_GEN_STAMP): tools/client-gen/package.json tools/client-gen/package-lock.json
	npm --prefix tools/client-gen ci --ignore-scripts

generate: client-gen-setup ghostty-vt fff
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) go generate ./api/wire

build: ghostty-vt fff
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) go build ./...

run: ghostty-vt fff
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) go run ./cmd/maiD

test: ghostty-vt fff
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

fff: $(FFF_STAMP)

$(FFF_STAMP):
	@test -n "$(FFF_TAG)" || { echo "no FFF version in finder_darwin.go's cgo paths" >&2; exit 1; }
	rm -rf build/fff
	mkdir -p $(FFF_DIR)/include $(FFF_DIR)/lib
	curl -fsSL -o $(FFF_DIR)/lib/libfff_c.dylib \
		https://github.com/dmtrKovalenko/fff/releases/download/$(FFF_TAG)/c-lib-aarch64-apple-darwin.dylib
	curl -fsSL -o $(FFF_DIR)/include/fff.h \
		https://raw.githubusercontent.com/dmtrKovalenko/fff/$(FFF_TAG)/crates/fff-c/include/fff.h
	echo '$(FFF_DYLIB_SHA256)  $(FFF_DIR)/lib/libfff_c.dylib' | shasum -a 256 -c
	echo '$(FFF_HEADER_SHA256)  $(FFF_DIR)/include/fff.h' | shasum -a 256 -c
	install_name_tool -id @rpath/libfff_c.dylib $(FFF_DIR)/lib/libfff_c.dylib
	codesign --force --sign - $(FFF_DIR)/lib/libfff_c.dylib
	@touch $(FFF_STAMP)

# Proves the FFF dylib loads relocatably via @loader_path, the way a packaged
# daemon would load it.
fff-verify: ghostty-vt fff
	PKG_CONFIG_PATH=$(GHOSTTY_VT_PKG_CONFIG) sh tools/fff-smoke/verify_staged.sh $(FFF_DIR)/lib
