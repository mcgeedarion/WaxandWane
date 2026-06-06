SWIFT_DIR := swift
PREFIX ?= $(HOME)/.local/bin
CONFIG_DIR ?= $(HOME)/.config/wax-and-wane
LAUNCH_AGENT := $(HOME)/Library/LaunchAgents/com.user.waxandwane.plist
BINARY := $(PREFIX)/wax-and-wane
CONFIG := $(CONFIG_DIR)/config.json
PLIST_TEMPLATE := com.user.waxandwane.plist

.PHONY: build test install uninstall launchagent-install launchagent-uninstall doctor

build:
	cd $(SWIFT_DIR) && swift build -c release

test:
	python3 -m pytest -q python/Tests
	cd $(SWIFT_DIR) && swift test

install: build
	mkdir -p $(PREFIX) $(CONFIG_DIR)
	cp $(SWIFT_DIR)/.build/release/WaxAndWane $(BINARY)
	@if [ ! -f $(CONFIG) ]; then cp examples/config.json $(CONFIG); fi
	@echo "Installed $(BINARY) and config $(CONFIG)"

uninstall: launchagent-uninstall
	rm -f $(BINARY)
	@echo "Removed $(BINARY); kept $(CONFIG_DIR)"

launchagent-install: install
	mkdir -p $(HOME)/Library/LaunchAgents $(HOME)/Library/Logs
	sed -e "s#__WAX_AND_WANE_BINARY__#$(BINARY)#g" \
	    -e "s#__WAX_AND_WANE_CONFIG__#$(CONFIG)#g" \
	    -e "s#__WAX_AND_WANE_LOG_DIR__#$(HOME)/Library/Logs#g" \
	    $(PLIST_TEMPLATE) > $(LAUNCH_AGENT)
	launchctl unload $(LAUNCH_AGENT) >/dev/null 2>&1 || true
	launchctl load $(LAUNCH_AGENT)
	@echo "Loaded $(LAUNCH_AGENT)"

launchagent-uninstall:
	@if [ -f $(LAUNCH_AGENT) ]; then launchctl unload $(LAUNCH_AGENT) >/dev/null 2>&1 || true; rm -f $(LAUNCH_AGENT); fi

doctor:
	$(BINARY) doctor || cd $(SWIFT_DIR) && swift run WaxAndWane doctor
