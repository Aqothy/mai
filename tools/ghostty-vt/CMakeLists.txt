cmake_minimum_required(VERSION 3.19)
project(maid-ghostty-vt LANGUAGES C)

# The commit go.mitchellh.com/libghostty pins (go.mod). The Swift client's
# libghostty-vt must be built from the same commit, because snapshots are only
# compatible within one commit.
set(GHOSTTY_COMMIT 81598385d608dda4946093d6d6a234d204a2f225)

# libghostty-vt reports its lib version, not git, as build info
# (ghostty build.zig `lib_version`), so the commit is stamped in explicitly:
# the daemon derives its snapshot format from GHOSTTY_BUILD_INFO_VERSION_BUILD.
# Set as a cache entry so Ghostty's own CACHE default doesn't replace it.
set(GHOSTTY_ZIG_BUILD_FLAGS
    "-Dlib-version-string=0.1.0-dev+${GHOSTTY_COMMIT};-Demit-xcframework=false"
    CACHE STRING "Flags for Ghostty's zig build" FORCE)

include(FetchContent)
FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    GIT_TAG ${GHOSTTY_COMMIT}
)
FetchContent_MakeAvailable(ghostty)
