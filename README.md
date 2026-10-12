# CapitalBar

macOS menu bar tracker for a Capital.com account: live P&L in the menu bar,
open/close positions from the menu. Native Swift + AppKit, no dependencies.

## Install / update

```bash
./install.sh
```

Builds, bundles `~/Applications/CapitalBar.app`, restarts it. `LSUIElement`
means menu bar only — no Dock icon, no window.

To have it start at login: System Settings → General → Login Items → add
`~/Applications/CapitalBar.app`.

## Credentials

Read from the first of these that exists and contains `CAPITAL_API_KEY`:

1. `~/.config/capitalbar/env`  ← the one in use, mode 600
2. `~/.capitalbar.env`

Keys: `CAPITAL_API_KEY`, `CAPITAL_IDENTIFIER`, `CAPITAL_PASSWORD`,
`CAPITAL_ENVIRONMENT` (`live` | `demo`). Capital.com can issue a separate key
per environment; if yours differ, set `CAPITAL_LIVE_API_KEY` and
`CAPITAL_DEMO_API_KEY` instead of the shared `CAPITAL_API_KEY`.

## Logo

Three rising candlesticks, drawn in code in
[Logo.swift](Sources/CapitalBar/Logo.swift) on a 100×100 grid — no image assets.
The same path renders the menu bar glyph (a template image, so macOS tints it
for light/dark) and the app icon (mint on a dark navy→green squircle).
`install.sh` regenerates `AppIcon.icns` on every build via
`CapitalBar --export-icons <dir>` + `iconutil`, so the icon can't drift from the
glyph. Edit the `candles` array to change both at once.

## Menu bar title

- `▮▮▮ ● +12.40 · 3` — candlestick mark, red dot for the live account (absent on
  demo), then net unrealised P&L and open position count. Green up, red down.
- `▮▮▮ 586.41 · flat` — no open positions, shows balance.
- `▮▮▮ ⚠` — auth or network failure; the reason is in the menu. A single ⚠ right
  after a restart is usually the old session being replaced — it clears itself
  on the next poll.

Polls every 10s and on menu open.

## Watchlist

Live bid/offer mid price and day % change for each favourite, refreshed on the
same 10s poll (one batched `/markets?epics=…` call). Defaults:

| Instrument | Epic |
| --- | --- |
| Gold | `GOLD` |
| Brent Oil Spot | `OIL_BRENT` |
| SpaceX | `SPCX` |
| Alphabet Inc – A | `GOOGL` |
| Tesla Inc | `TSLA` |

Green when up, red when down, grey when the market is closed. Each row's
submenu has bid/offer, day high/low, status, *Trade …* (disabled when closed)
and *Remove from watchlist*. *Add to Watchlist…* searches and appends; the list
persists in UserDefaults, so edits survive a rebuild — delete it with
`defaults delete com.jamahl.capitalbar favourites` to get the defaults back.

## Trading

- **Close**: hover a position → submenu → *Close position* → confirm. The row
  itself does nothing, so a stray click can't fire an order.
- **Open**: *New Trade…* → search markets → pick instrument, size, optional
  stop/limit **price levels** (absolute, not distances) → Buy or Sell → confirm.
- Every order is behind two clicks and a confirmation dialog. Switching to Live
  asks first. Nothing trades on a timer — this app never acts on its own.

## Caveat: one API key, one session

Capital.com invalidates the previous session when the same API key logs in
elsewhere. If you run other tools against the same environment with this key,
both sides will re-login in a loop. Generate a second API key for CapitalBar if
you hit that.
