# third_party/fff

Vendored FFF C library used by `internal/workspacesearch/fff`. The daemon
links `libfff_c.dylib` directly on macOS arm64; ordinary builds never touch
the network for this dependency.

`MANIFEST.json` is the source of truth for the pinned version and checksums.
`CHECKSUMS.sha256` duplicates the checksums in `shasum -c` format so
`make fff-verify` stays dependency-free.

## Updating FFF

1. Pick one exact release tag on https://github.com/dmtrKovalenko/fff.
   Never vendor a nightly or floating label.
2. Download the matching pair from that tag:
   - `c-lib-aarch64-apple-darwin.dylib` (release asset) → `lib/darwin-arm64/libfff_c.dylib`
   - `crates/fff-c/include/fff.h` (repository at the tag) → `include/fff.h`
3. Verify the release asset against its published `.sha256` file and record
   that value as `upstreamSha256`.
4. Normalize and re-sign the dylib (the upstream install name is a CI path):

   ```sh
   install_name_tool -id @rpath/libfff_c.dylib lib/darwin-arm64/libfff_c.dylib
   codesign --force --sign - lib/darwin-arm64/libfff_c.dylib
   ```

5. Update `MANIFEST.json` and `CHECKSUMS.sha256` with the new tag, URLs, and
   the post-normalization SHA-256 values (`shasum -a 256 <file>`).
6. Update `LICENSE` if the upstream license changed.
7. Run `make fff-verify`, then
   `go test ./internal/workspacesearch/...` on macOS arm64. If the header
   changed, confirm the functions used by
   `internal/workspacesearch/fff/finder_darwin.go` still exist with the same
   signatures and that `FFF_CREATE_OPTIONS_VERSION` is still accepted by the
   wrapper's create helper.
8. Keep the previous dylib/header pair available (previous commit) until the
   staged daemon and client acceptance checks pass; rolling back is reverting
   this directory.

Do not load FFF from Homebrew or any machine-global install, and do not add
an option for users to point at arbitrary FFF dylibs.
