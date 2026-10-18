# Silk — common tasks. `make app` builds build/Silk.app; `make install` puts it into /Applications.

APP := build/Silk.app
DEBUG_APP := build/Silk Debug.app
INSTALL_APP := /Applications/Silk.app
CLI_IN_APP := $(INSTALL_APP)/Contents/Resources/bin/silk
# Quits the installed Silk if it is running (by bundle id, so "Silk Debug" is left alone; never launches it).
QUIT_SILK := if osascript -e 'application id "dev.jensderond.silk" is running' 2>/dev/null | grep -q true; then \
	osascript -e 'tell application id "dev.jensderond.silk" to quit'; fi
# The CLI symlink goes to Homebrew's bin when it is writable, else ~/.local/bin.
CLI_LINK := $(shell if [ -w /opt/homebrew/bin ]; then echo /opt/homebrew/bin/silk; else echo $$HOME/.local/bin/silk; fi)

.PHONY: build test app debug-app install uninstall clean run icon

build:
	swift build

test:
	swift test

app:
	scripts/build-app.sh

debug-app:
	scripts/build-app.sh --debug

## Regenerates Resources/AppIcon.icns and the README's Resources/AppIcon.png (committed; builds don't need this).
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns
	sips -s format png -Z 512 Resources/AppIcon.icns --out Resources/AppIcon.png

install: app
	@$(QUIT_SILK)
	rm -rf "$(INSTALL_APP)"
	ditto "$(APP)" "$(INSTALL_APP)"
	mkdir -p "$(dir $(CLI_LINK))"
	ln -sfn "$(CLI_IN_APP)" "$(CLI_LINK)"
	@echo "Installed $(INSTALL_APP); CLI linked at $(CLI_LINK)"

uninstall:
	@$(QUIT_SILK)
	@for link in /opt/homebrew/bin/silk $$HOME/.local/bin/silk; do \
		if [ -L "$$link" ] && [ "$$(readlink "$$link")" = "$(CLI_IN_APP)" ]; then rm -f "$$link" && echo "Removed $$link"; fi; \
	done
	rm -rf "$(INSTALL_APP)"

clean:
	rm -rf build
	swift package clean

run: debug-app
	open "$(DEBUG_APP)"
