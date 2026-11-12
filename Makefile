PROJECT := Inky.xcodeproj
SCHEME  := Inky
BUILD   := build
XCODE   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD)

PLACES  := InkyCore/Sources/InkyCore/Resources/places.tsv

TLDS    := InkyCore/Sources/InkyCore/Resources/tlds.txt

.PHONY: build release run test places tlds clean

build: ## Debug build
	$(XCODE) -configuration Debug build

release: ## Optimized build
	$(XCODE) -configuration Release build

DEBUG_APP := $(BUILD)/Build/Products/Debug/Inky (Debug).app

run: build ## Build and launch Inky (Debug), replacing a running one; an installed Inky keeps running
	-pkill -x "Inky (Debug)" && sleep 0.5
	open "$(DEBUG_APP)"

test: ## Run the InkyCore tests
	swift test --package-path InkyCore

places: ## Rebuild the list of cities and their time zones from GeoNames
	rm -rf $(BUILD)/geonames && mkdir -p $(BUILD)/geonames
	curl -fsS -o $(BUILD)/geonames/cities15000.zip https://download.geonames.org/export/dump/cities15000.zip
	unzip -q -o $(BUILD)/geonames/cities15000.zip -d $(BUILD)/geonames
	swift Scripts/places.swift $(BUILD)/geonames/cities15000.txt > $(BUILD)/geonames/places.tsv
	test -s $(BUILD)/geonames/places.tsv
	mv $(BUILD)/geonames/places.tsv $(PLACES)

tlds: ## Fetch the current list of top-level domains from IANA
	mkdir -p $(BUILD)
	curl -fsS -o $(BUILD)/tlds.txt https://data.iana.org/TLD/tlds-alpha-by-domain.txt
	test -s $(BUILD)/tlds.txt
	mv $(BUILD)/tlds.txt $(TLDS)

clean:
	rm -rf $(BUILD) InkyCore/.build
