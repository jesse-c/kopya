# Variables
local_bin_path := env_var_or_default("LOCAL_BIN_PATH", "$HOME/.local/bin")

# List available commands
default:
    @just --list

# Run the CLI
run-cli *ARGS:
    ./.build/debug/kopya {{ARGS}}

# Generate version information from Git tag or commit SHA, or use provided version argument
# Example: just version v1.2.3
version VERSION="":
    #!/usr/bin/env bash
    set -e
    # Use provided VERSION if it exists, otherwise get from git
    if [ -n "{{VERSION}}" ]; then
        VERSION="{{VERSION}}"
    elif git describe --tags --exact-match 2>/dev/null; then
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

# Run tests
test:
    swift test -v -Xswiftc -parse-as-library

# Run linting
lint:
    swiftlint --config .swiftlint.yml

# Run formating
format:
    swiftformat .

# Clean build artifacts
clean:
    swift package clean
    rm -rf .build

# Build in debug mode
build-cli-debug:
    swift build -Xswiftc -parse-as-library --product kopya

# Build CLI binary in release mode
build-cli:
    swift build -c release -Xswiftc -parse-as-library --product kopya

# Build .app bundle
build-app:
    @./Scripts/build-app.sh

# Install CLI binary to ~/.local/bin
install-cli: build-cli
    mkdir -p {{local_bin_path}}
    cp ./.build/release/kopya {{local_bin_path}}/kopya
    echo "Installed Kopya to {{local_bin_path}}/kopya"

# Install .app to /Applications
install-app: build-app
    rm -rf /Applications/Kopya.app
    cp -r build/Kopya.app /Applications/Kopya.app
    @echo "✓ Installed to /Applications/Kopya.app"

# Create symlink for CLI access
link-cli:
    @ln -sf /Applications/Kopya.app/Contents/MacOS/kopya {{local_bin_path}}/kopya
    @echo "✓ Symlinked to {{local_bin_path}}/kopya"
