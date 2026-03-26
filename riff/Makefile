# ABOUTME: Makefile for installing and managing the Riff voice narrator daemon.
# ABOUTME: Targets: install (deps + LaunchAgent + symlinks), clean, uninstall, restart, logs.

AGENT_DIR = $(HOME)/Library/LaunchAgents
PLIST = co.remotehumans.riff.plist
LABEL = co.remotehumans.riff
CONFIG_DIR = $(HOME)/.config/riff
HOOK_DIR = $(HOME)/.claude/hooks

.PHONY: all install clean uninstall restart logs

all:
	uv sync

install: all
	mkdir -p $(CONFIG_DIR)
	@test -f $(CONFIG_DIR)/config.json || cp config.default.json $(CONFIG_DIR)/config.json
	mkdir -p $(AGENT_DIR)
	cp $(PLIST) $(AGENT_DIR)/$(PLIST)
	-launchctl bootout gui/$$(id -u) $(AGENT_DIR)/$(PLIST) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT_DIR)/$(PLIST)
	mkdir -p $(HOME)/.local/bin
	ln -sf "$(CURDIR)/.venv/bin/riff-say" "$(HOME)/.local/bin/riff-say"
	ln -sf "$(CURDIR)/.venv/bin/riff-ctl" "$(HOME)/.local/bin/riff-ctl"
	mkdir -p $(HOOK_DIR)
	cp riff-hook.sh $(HOOK_DIR)/riff-hook.sh
	chmod +x $(HOOK_DIR)/riff-hook.sh

clean:
	rm -rf .venv/

uninstall:
	-launchctl bootout gui/$$(id -u) $(AGENT_DIR)/$(PLIST) 2>/dev/null
	rm -f $(AGENT_DIR)/$(PLIST)
	rm -f $(HOME)/.local/bin/riff-say
	rm -f $(HOME)/.local/bin/riff-ctl
	rm -f $(HOOK_DIR)/riff-hook.sh

restart:
	-launchctl bootout gui/$$(id -u) $(AGENT_DIR)/$(PLIST) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT_DIR)/$(PLIST)

logs:
	tail -f /tmp/riff.log
