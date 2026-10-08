.PHONY: app run install icon clean

# Build build/EchoWave.app
app:
	@scripts/build-app.sh

# Build, quit any running copy, and launch
run: app
	@pkill -x EchoWave 2>/dev/null || true
	@open build/EchoWave.app

# Build, copy to /Applications and launch
install: app
	@pkill -x EchoWave 2>/dev/null || true
	@rm -rf /Applications/EchoWave.app
	@cp -R build/EchoWave.app /Applications/
	@echo "✓ Installed /Applications/EchoWave.app"
	@open /Applications/EchoWave.app

# Regenerate Resources/AppIcon.icns
icon:
	@swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	@rm -rf .build build
