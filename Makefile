PROJECT := Inky.xcodeproj
SCHEME  := Inky
BUILD   := build
XCODE   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD)

PLACES  := InkyCore/Sources/InkyCore/Resources/places.tsv

.PHONY: build release run test places clean

build: ## Debug build
	$(XCODE) -configuration Debug build

release: ## Optimized build
	$(XCODE) -configuration Release build

run: build ## Build and launch, replacing a running Inky
	-pkill -x Inky && sleep 0.5
	open $(BUILD)/Build/Products/Debug/Inky.app

test: ## Run the InkyCore tests
	swift test --package-path InkyCore

places: ## Rebuild the list of cities and their time zones from GeoNames
	rm -rf $(BUILD)/geonames && mkdir -p $(BUILD)/geonames
	curl -fsS -o $(BUILD)/geonames/cities15000.zip https://download.geonames.org/export/dump/cities15000.zip
	unzip -q -o $(BUILD)/geonames/cities15000.zip -d $(BUILD)/geonames
	swift Scripts/places.swift $(BUILD)/geonames/cities15000.txt > $(PLACES)

clean:
	rm -rf $(BUILD) InkyCore/.build
