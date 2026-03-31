# ABOUTME: Makefile for building and code-signing the riff-bridge Swift binary.
# ABOUTME: Targets: build, sign, all (default), install (deploy + restart LaunchAgent), clean.

BINARY = riff-bridge
SOURCE = riff_bridge.swift
IDENTITY = Apple Development
PLIST = co.remotehumans.riff-bridge.plist
AGENT_LABEL = co.remotehumans.riff-bridge
AGENT_DIR = $(HOME)/Library/LaunchAgents

.PHONY: all build sign install clean

all: build sign

build:
	swiftc $(SOURCE) -o $(BINARY) -framework CoreGraphics -framework IOKit

sign:
	codesign --sign "$(IDENTITY)" --options runtime $(BINARY) || echo "WARNING: Signing failed — run 'security unlock-keychain' if keychain is locked"

install: all
	mkdir -p $(AGENT_DIR)
	sed 's|__INSTALL_DIR__|$(CURDIR)|g' $(PLIST) > $(AGENT_DIR)/$(PLIST)
	-launchctl bootout gui/$$(id -u) $(AGENT_DIR)/$(PLIST) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT_DIR)/$(PLIST)

clean:
	rm -f $(BINARY)
