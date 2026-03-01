SCHEME = Synchro
BUILD_DIR = .build/xcode
APP = $(BUILD_DIR)/Build/Products/Release/$(SCHEME).app
INSTALL_DIR = /Applications

.PHONY: generate build run clean install uninstall

generate:
	xcodegen generate

build: generate
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath $(BUILD_DIR) build

run: generate
	xcodebuild -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR) build
	open $(BUILD_DIR)/Build/Products/Debug/$(SCHEME).app

clean:
	rm -rf $(BUILD_DIR)
	rm -rf *.xcodeproj

install: build
	cp -R $(APP) $(INSTALL_DIR)/$(SCHEME).app

uninstall:
	rm -rf $(INSTALL_DIR)/$(SCHEME).app
