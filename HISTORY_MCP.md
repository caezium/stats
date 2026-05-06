# Stats fork — History + Claude Code MCP

This branch (`henry/history-mcp`) extends [exelban/Stats](https://github.com/exelban/stats) with two things upstream doesn't have:

1. **Long-running time-series storage** for every reader — CPU, RAM, GPU, Disk, Network, Battery, Sensors, plus per-process readers — kept locally for up to 90 days.
2. **A localhost MCP server** that lets Claude Code (or any MCP client) query that history with natural-language tools like *"top processes by network last hour"* or *"find CPU spikes today"*.

The architecture is:

```
┌────────────────────┐                  ┌─────────────────────┐
│  Stats.app (Swift) │  writes JSON →   │  LevelDB time-series│
│  + Readers         │  every ~10s      │  ~/Library/.../lldb │
└──────────┬─────────┘                  └──────────┬──────────┘
           │                                       │ reads via
           │ in-process reads                      │ in-process API
           ▼                                       │
┌──────────────────────┐                           │
│  QueryServer.swift   │ ◄─────────────────────────┘
│  (NWListener,        │
│   127.0.0.1:9276)    │
└──────────┬───────────┘
           │ HTTP/JSON over loopback
           ▼
┌──────────────────────┐                  ┌──────────────┐
│  mcp-server/server.py│ ◄─── stdio MCP ──┤  Claude Code │
│  (FastMCP, httpx)    │                  └──────────────┘
└──────────────────────┘
```

## What changed in the Stats codebase

| File | Change |
|---|---|
| `Kit/lldb/lldb.h`, `Kit/lldb/lldb.m` | Added `findKeysAndValues:` for efficient key+value range scans. |
| `Kit/plugins/DB.swift` | TTL is now configurable (`history_retention_days` default 7), added `findTimeSeries` / `findLatestTimeSeries` / `listPrefixes` / `pruneExpired`, scheduled hourly background prune. |
| `Kit/plugins/QueryServer.swift` | **New.** Localhost-only HTTP/JSON server bound to `127.0.0.1`. |
| `Kit/module/reader.swift` | Reader's default `history` flag flipped to `true`. |
| `Kit/types.swift` | Added `HistoryRetentionOptions`. |
| `Stats/AppDelegate.swift` | Starts/stops `QueryServer` with the app lifecycle. |
| `Stats/Views/AppSettings.swift` | New "History" section in Settings → retention period + query server toggle. |

## QueryServer endpoints

All bound to `127.0.0.1:9276` (configurable via `history_query_port` default).

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/health` | `{"ok":true,...}` liveness check |
| `GET` | `/info` | retention, current time, list of available prefixes |
| `GET` | `/modules` | shorthand for the prefixes list |
| `GET` | `/metrics?prefix=…&since=…&until=…&bucket=…` | time-series rows |
| `GET` | `/latest?prefix=…` | most recent value for a prefix |

`prefix` is a `<module>@<reader>` string like `CPU@LoadReader` or `Network@ProcessReader`. `since`/`until` are unix seconds. `bucket` (optional) downsamples by `floor(ts / bucket)`.

Try it once Stats is running:

```bash
curl -s http://127.0.0.1:9276/info
curl -s 'http://127.0.0.1:9276/metrics?prefix=CPU@LoadReader' | jq '.[-1]'
curl -s 'http://127.0.0.1:9276/latest?prefix=Network@ProcessReader' | jq '.value[:5]'
```

## MCP server tools

Exposed by `mcp-server/server.py` (Python, FastMCP). Claude Code calls these via stdio MCP.

| Tool | What it does |
|---|---|
| `health` | Verify Stats is up; show retention + available prefixes. |
| `list_metrics` | List `<module>@<reader>` prefixes. |
| `query_metric(prefix, since_minutes_ago, until_minutes_ago, bucket_seconds, max_points)` | Raw or bucketed time-series for one metric. |
| `latest(prefix)` | Most recent value. |
| `top_processes(reader, since_minutes_ago, by, n, aggregator)` | Roll up `*@ProcessReader` samples to top apps by CPU / RAM / network bytes / etc. `aggregator` can be `max` (default), `mean`, `last`, or `delta` (useful for cumulative network counters). |
| `find_spikes(prefix, field, since_minutes_ago, threshold, threshold_stddevs, min_gap_seconds)` | Locate moments when a metric exceeded an absolute or statistical threshold. |
| `compare_periods(prefix, field, window_minutes, offset_hours)` | Compare e.g. "last hour" against "the same hour yesterday". |
| `summarize_period(since_minutes_ago, include_top_processes, top_n)` | One-shot snapshot across all aggregate readers + top apps per process reader. |

## Setup

### 1. Build & install the modified Stats

```bash
cd ~/Desktop/stats
xcodebuild -project Stats.xcodeproj -scheme Stats -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build_check \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

open build_check/Build/Products/Debug/Stats.app
```

(For a Release build, drop the `CODE_SIGN_*` overrides and use your own signing identity. The QueryServer needs no special entitlements — Stats already runs without sandbox.)

After launch, open **Settings → Application → History** to adjust retention or toggle the query server.

### 2. Install MCP server dependencies

```bash
cd ~/Desktop/stats/mcp-server
uv sync
```

### 3. Register with Claude Code

```bash
claude mcp add --scope user stats /Users/henry/.local/bin/uv -- \
    --directory /Users/henry/Desktop/stats/mcp-server run python server.py
```

Verify:

```bash
claude mcp list
# stats: /Users/henry/.local/bin/uv ... - ✓ Connected
```

### 4. Use it

In any Claude Code session:

> *What was eating my CPU between 2pm and 4pm today?*

> *Which apps used the most network in the last hour?*

> *Find any RAM spikes from the last 24 hours.*

> *Is my CPU usage right now unusual compared to this time yesterday?*

> *Give me a snapshot of the last 60 minutes.*

## Storage shape

LevelDB at `~/Library/Application Support/Stats/lldb/`. Keys are
`<module>@<reader>@<unix_seconds>`, values are JSON-encoded `Codable` payloads. Hourly prune deletes timestamped rows older than `history_retention_days * 24 * 60 * 60`.

Rough sizing: each reader writes a row roughly every `interval × 10` seconds (the existing `lastDBWrite` throttle). For default settings × 7 days × ~12 readers, expect tens of MB.

## Configuration knobs

All via `defaults` (or the new Settings UI):

```bash
defaults write eu.exelban.Stats history_retention_days -int 7    # 1–90
defaults write eu.exelban.Stats history_query_enabled -bool YES
defaults write eu.exelban.Stats history_query_port -int 9276
```

## Security model

- The query server is **localhost-only**. `NWParameters.requiredLocalEndpoint` pins the listener to `127.0.0.1`, and there's a defensive `isLoopback` check on incoming connections.
- No authentication — anyone with a process on this machine and the port can read system metrics. That's intentional given the data is already visible to any local process via `top`/`nettop`/IOKit. If you want to expose it off-host, put it behind something with auth.
- `Access-Control-Allow-Origin: *` is set so a browser tab on a `file://` page can probe it during dev. Remove if that bothers you.

## Differences from upstream

The fork keeps everything Stats already does — same UI, same modules, same widgets, same notifications. The only behavioral change to the existing app surface is that timestamped values are now actually being written (the hooks already existed; the default was off). If you don't want long-running history, set retention to 1 day or disable the query server in Settings → History.

## License

Same MIT license as upstream Stats.
