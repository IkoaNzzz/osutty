#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, Ghostty-iOS, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    # Xcode enables coverage for scheme builds that include test plans, even
    # when the requested action is only "build". Keep coverage for tests, but
    # never ship an instrumented Debug or Release application.
    let coverage_settings = if $action == "test" {
        []
    } else {
        [
            "ENABLE_CODE_COVERAGE=NO"
            "CLANG_COVERAGE_MAPPING=NO"
            "GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO"
            "GCC_GENERATE_TEST_COVERAGE_FILES=NO"
        ]
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$skip_testing
        ...$coverage_settings
        $action)
}
