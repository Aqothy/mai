.DEFAULT_GOAL := build

CLIENT_GEN_STAMP := tools/client-gen/node_modules/.package-lock.json

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

.PHONY: client-gen-setup generate build run fff test fff-verify

client-gen-setup: $(CLIENT_GEN_STAMP)

$(CLIENT_GEN_STAMP): tools/client-gen/package.json tools/client-gen/package-lock.json
	npm --prefix tools/client-gen ci --ignore-scripts

generate: client-gen-setup fff
	go generate ./api/wire

build: fff
	go build ./...

run: fff
	go run ./cmd/maiD

test: fff
	go test ./...

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
fff-verify: fff
	sh tools/fff-smoke/verify_staged.sh $(FFF_DIR)/lib
