APP_NAME := Wispr Flow Switch
EXECUTABLE := wispr-flow-switch
TARGET_EXECUTABLE := WisprFlowSwitch
BUILD_DIR := .build/release
APP_DIR := dist/$(APP_NAME).app

.PHONY: build app run clean check

build:
	swift build -c release

app: build
	rm -rf "dist"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	if [ -f "$(BUILD_DIR)/$(EXECUTABLE)" ]; then \
		cp "$(BUILD_DIR)/$(EXECUTABLE)" "$(APP_DIR)/Contents/MacOS/$(EXECUTABLE)"; \
	else \
		cp "$(BUILD_DIR)/$(TARGET_EXECUTABLE)" "$(APP_DIR)/Contents/MacOS/$(EXECUTABLE)"; \
	fi

run: app
	open "$(APP_DIR)"

check:
	swift build

clean:
	rm -rf .build dist
