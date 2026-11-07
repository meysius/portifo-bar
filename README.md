<p align="center"><img src="docs/icon.png" width="128" alt=""></p>

<h1 align="center">Portifo Bar</h1>

<p align="center">Live stock prices in the macOS menu bar.</p>

<p align="center">
  <img src="docs/screenshot-day.png" width="400" alt="NVIDIA's price in the menu bar, and below it the popover: NVIDIA's price after hours, its chart for the day from pre-market to after hours, and a watchlist of NVIDIA and QQQ">
  <img src="docs/screenshot-year.png" width="400" alt="The same popover with NVIDIA's chart over a year, its 200-day moving average dashed inside bands 5, 10 and 15% either side, the price 8.8% from the average">
</p>

A live, near real-time stream of stock prices in your menu bar, with simple
charts for keeping track of the stocks you follow. Prices stream from Yahoo
Finance's WebSocket.

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
