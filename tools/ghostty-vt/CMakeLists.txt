cmake_minimum_required(VERSION 3.19)
project(maid-ghostty-vt LANGUAGES C)

include(FetchContent)
FetchContent_Declare(ghostty
    GIT_REPOSITORY https://github.com/ghostty-org/ghostty.git
    # Includes upstream formatter cursor/tabstop ordering fix 7a9c369cf.
    GIT_TAG 7a9c369cf5da72d41946f683c48b0466a210cb7e
)
FetchContent_MakeAvailable(ghostty)
