# Variables
local_bin_path := env_var_or_default("LOCAL_BIN_PATH", "$HOME/.local/bin")

# List available commands
default:
    @just --list

# Run the application
run *ARGS:
    ./.build/debug/kopya {{ARGS}}

# Generate version information from git tag or commit SHA
version:
    #!/usr/bin/env bash
    set -e
    # Get version from git tag or commit hash
    if git describe --tags --exact-match 2>/dev/null; then
        VERSION=$(git describe --tags 2>/dev/null)
    else
        COMMIT=$(git rev-parse --short HEAD 2>/dev/null)
        if [ -n "$COMMIT" ]; then
            VERSION="$COMMIT"
        else
            VERSION="unknown"
        fi
    fi

    echo "Generating version: $VERSION"

    # Create Swift file with version definition
    echo "// Generated file - Do not edit manually" > Sources/Version.swift
    echo "// Generated on $(date)" >> Sources/Version.swift
    echo "import Foundation" >> Sources/Version.swift
    echo "" >> Sources/Version.swift
    echo "enum Version {" >> Sources/Version.swift
    echo "    static let version = \"$VERSION\"" >> Sources/Version.swift
    echo "}" >> Sources/Version.swift

# Build in debug mode
debug:
    swift build -Xswiftc -parse-as-library --product kopya

# Build in release mode
release:
    swift build -c release -Xswiftc -parse-as-library --product kopya

# Run tests
test:
    swift test -v -Xswiftc -parse-as-library

# Clean build artifacts
clean:
    swift package clean
    rm -rf .build

# Install the application
install:
    mkdir -p {{local_bin_path}}
    cp ./.build/release/kopya {{local_bin_path}}/kopya
    echo "Installed Kopya to {{local_bin_path}}/kopya"
