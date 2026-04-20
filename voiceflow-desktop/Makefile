.PHONY: generate build clean open

# Generate Xcode project from project.yml
generate:
	xcodegen generate

# Open Xcode project after generating
open: generate
	open VoiceflowDesktop.xcodeproj

# Clean derived data
clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceflowDesktop-*
	rm -rf VoiceflowDesktop.xcodeproj

# Regenerate and open (typical dev workflow)
dev: generate open

# Build from command line (requires code signing to be set up)
build:
	xcodebuild -project VoiceflowDesktop.xcodeproj \
		-scheme VoiceflowDesktop \
		-configuration Debug \
		-derivedDataPath .build \
		build

# Install dependencies note — KeyboardShortcuts is fetched by Xcode SPM
deps:
	@echo "SPM packages are resolved automatically when you open the Xcode project."
	@echo "Run 'make open' to generate the project and open Xcode."
