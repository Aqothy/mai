.DEFAULT_GOAL := build

CLIENT_GEN_STAMP := tools/client-gen/node_modules/.package-lock.json

.PHONY: client-gen-setup generate build fff-verify

client-gen-setup: $(CLIENT_GEN_STAMP)

$(CLIENT_GEN_STAMP): tools/client-gen/package.json tools/client-gen/package-lock.json
	npm --prefix tools/client-gen ci --ignore-scripts

generate: client-gen-setup
	go generate ./api/wire

build:
	go build ./...

# Deterministic vendored-FFF integrity checks: manifest checksums, arm64
# architecture, relocatable install name, and staged @loader_path loading.
# Never touches the network, Cargo, Zig, or npm.
fff-verify:
	cd third_party/fff && shasum -a 256 -c CHECKSUMS.sha256
	lipo -archs third_party/fff/lib/darwin-arm64/libfff_c.dylib | grep -qw arm64
	otool -D third_party/fff/lib/darwin-arm64/libfff_c.dylib | tail -1 | grep -qx '@rpath/libfff_c.dylib'
	sh tools/fff-smoke/verify_staged.sh
