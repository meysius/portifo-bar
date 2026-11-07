APP := build/Portifo Bar.app

.PHONY: app zip run install test tail clean

# The .app bundle, in build/.
app:
	./scripts/bundle.sh

# What a release ships: the app, zipped with its signature intact.
zip: app
	cd build && rm -f PortifoBar.zip && ditto -c -k --keepParent "Portifo Bar.app" PortifoBar.zip

# Build, quit any running copy, and launch.
run: app
	-pkill -x PortifoBar
	open "$(APP)"

# Copy into /Applications, where Launch at Login expects it.
install: app
	-pkill -x PortifoBar
	rm -rf "/Applications/Portifo Bar.app"
	cp -R "$(APP)" /Applications/
	open "/Applications/Portifo Bar.app"

test:
	swift test

# The feed in the terminal: make tail SYMBOLS=AAPL,^GSPC,BTC-USD
SYMBOLS ?= AAPL,^GSPC,BTC-USD
tail:
	swift run PortifoBar --tail "$(SYMBOLS)"

clean:
	rm -rf .build build
