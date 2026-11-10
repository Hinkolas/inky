PROJECT := Inky.xcodeproj
SCHEME  := Inky
BUILD   := build
XCODE   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD)

.PHONY: build release run test clean

build: ## Debug build
	$(XCODE) -configuration Debug build

release: ## Optimized build
	$(XCODE) -configuration Release build

run: build ## Build and launch
	open $(BUILD)/Build/Products/Debug/Inky.app

test: ## Run the InkyCore tests
	swift test --package-path InkyCore

clean:
	rm -rf $(BUILD) InkyCore/.build
