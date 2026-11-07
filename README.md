<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

<h1 align="center">Portifo Bar</h1>

<p align="center">Live stock prices in the macOS menu bar.</p>

<p align="center">
  <img src="docs/screenshot.png" width="768" alt="Apple and Bitcoin with their moves in the menu bar, and below them the popover: Apple's price after hours, its chart for the day, and a watchlist of six symbols">
</p>

Portifo Bar keeps the prices you follow in the menu bar: stocks, indexes,
crypto, currencies and futures, each with its move on the day, kept within
about half a minute of the market, after hours and overnight included. Click
it for a chart of any of them and the rest of your watchlist.

It reads the same Yahoo Finance data that powers
[Portifo](https://github.com/meysius/portifo). It's free, needs no account or
API key, and is a native Swift app with no dependencies.

## Install

Requires macOS 14 Sonoma or later, on Apple silicon or Intel. In Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/meysius/portifo-bar/main/install.sh | sh
```

This puts the latest release in `/Applications` and opens it. Run it again to
update.

The app isn't notarized by Apple, so macOS blocks it if it's downloaded in a
browser. The script downloads it with `curl` instead, which macOS doesn't
block, so you don't need to do anything else.

<details>
<summary>Installing by hand instead</summary>

Download `PortifoBar.zip` from the
[latest release](https://github.com/meysius/portifo-bar/releases/latest), unzip
it, and move **Portifo Bar** to Applications. macOS will refuse to open it,
saying it can't check it for malicious software. Remove the browser's
quarantine flag to fix this:

```bash
xattr -dr com.apple.quarantine "/Applications/Portifo Bar.app"
```

Or open it once, then go to System Settings → Privacy & Security and click
**Open Anyway**.
</details>
