"""MCP server exposing Stats time-series data to Claude Code.

Architecture:
    Claude Code <-stdio-> server.py <-HTTP-> Stats QueryServer (127.0.0.1:9276)

Stats stores its time-series readings in a LevelDB database that only one
process can open at a time, so this MCP server doesn't read the DB directly.
Instead it speaks to the QueryServer that the modified Stats app exposes on
loopback.

Tools exposed:
    health                — verify Stats is running and reachable
    list_metrics          — show available <module>@<reader> prefixes
    query_metric          — raw or bucketed time series for one metric
    latest                — most recent value for one metric
    top_processes         — aggregate ProcessReader output across a window
    summarize_period      — one-shot snapshot across all aggregate readers
"""

from __future__ import annotations

import collections
import json
import os
import time
from typing import Any, Optional

import httpx
from mcp.server.fastmcp import FastMCP


STATS_HOST = os.environ.get("STATS_HOST", "127.0.0.1")
STATS_PORT = int(os.environ.get("STATS_PORT", "9276"))
BASE_URL = f"http://{STATS_HOST}:{STATS_PORT}"

# Process-bearing readers and the field on each entry that represents
# "how much was used". These power top_processes / summarize_period.
PROCESS_READERS: dict[str, dict[str, Any]] = {
    "CPU@ProcessReader": {
        "metric": "usage",          # percent CPU
        "unit": "percent",
        "key_fields": ("name", "pid"),
    },
    "RAM@ProcessReader": {
        "metric": "usage",          # bytes
        "unit": "bytes",
        "key_fields": ("name", "pid"),
    },
    "Network@ProcessReader": {
        "metric": "download",       # cumulative bytes; we'll handle separately
        "unit": "bytes",
        "key_fields": ("name", "pid"),
        "extra_metrics": ("upload",),
    },
    "Disk@ProcessReader": {
        # Disk_process schema varies by macOS version; pass through whatever
        # is present and pick the largest numeric field at query time.
        "metric": None,
        "unit": "bytes",
        "key_fields": ("name", "pid"),
    },
    "Battery@ProcessReader": {
        "metric": "usage",
        "unit": "percent",
        "key_fields": ("name", "pid"),
    },
}

# Aggregate (system-wide) readers we surface in summarize_period.
AGGREGATE_READERS = (
    "CPU@LoadReader",
    "CPU@AverageLoadReader",
    "CPU@TemperatureReader",
    "CPU@FrequencyReader",
    "RAM@UsageReader",
    "Disk@CapacityReader",
    "Disk@ActivityReader",
    "Network@UsageReader",
    "Network@ConnectivityReader",
    "Battery@UsageReader",
)


mcp = FastMCP("stats")
_client: Optional[httpx.Client] = None


def _http() -> httpx.Client:
    global _client
    if _client is None:
        _client = httpx.Client(base_url=BASE_URL, timeout=10.0)
    return _client


def _get(path: str, **params: Any) -> Any:
    """GET <path>?... returning parsed JSON, or raise a readable error."""
    cleaned = {k: v for k, v in params.items() if v is not None}
    try:
        resp = _http().get(path, params=cleaned)
        resp.raise_for_status()
        return resp.json()
    except httpx.ConnectError as exc:
        raise RuntimeError(
            f"Cannot reach Stats QueryServer at {BASE_URL}. "
            "Is the modified Stats app running? "
            f"({exc.__class__.__name__}: {exc})"
        ) from exc


def _resolve_window(
    since_minutes_ago: Optional[float],
    until_minutes_ago: Optional[float],
    since_unix: Optional[int],
    until_unix: Optional[int],
) -> tuple[Optional[int], Optional[int]]:
    """Convert flexible time inputs to absolute unix seconds.

    Either *_minutes_ago or *_unix may be supplied. _minutes_ago wins if both
    are passed (more natural in chat). When everything is None, returns
    (None, None) — the QueryServer treats that as "all retained data".
    """
    now = int(time.time())
    since = since_unix
    until = until_unix
    if since_minutes_ago is not None:
        since = now - int(since_minutes_ago * 60)
    if until_minutes_ago is not None:
        until = now - int(until_minutes_ago * 60)
    return since, until


def _format_ts(ts: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))


# ---------------------------------------------------------------------------
# MCP tools
# ---------------------------------------------------------------------------


@mcp.tool()
def health() -> dict[str, Any]:
    """Check that the Stats QueryServer is reachable and report basic info.

    Returns retention window, current time, and the list of metric prefixes
    that have data. Use this first if other tools start failing.
    """
    info = _get("/info")
    info["base_url"] = BASE_URL
    info["now_human"] = _format_ts(info.get("now", int(time.time())))
    return info


@mcp.tool()
def list_metrics() -> list[str]:
    """List every `<module>@<reader>` prefix that currently has time-series data.

    Use these as the `prefix` argument to `query_metric` and `latest`.
    """
    return list(_get("/modules").get("modules", []))


@mcp.tool()
def query_metric(
    prefix: str,
    since_minutes_ago: Optional[float] = None,
    until_minutes_ago: Optional[float] = None,
    bucket_seconds: Optional[int] = None,
    since_unix: Optional[int] = None,
    until_unix: Optional[int] = None,
    max_points: int = 500,
) -> dict[str, Any]:
    """Return a time-series for a single metric prefix.

    Args:
        prefix: A `<module>@<reader>` string, e.g. "CPU@LoadReader".
                Use `list_metrics` to see available prefixes.
        since_minutes_ago: How far back to look (e.g. 60 for last hour).
        until_minutes_ago: Upper bound (default = now). Set to 30 with
                           since_minutes_ago=60 for the window 30–60min ago.
        bucket_seconds: If set, downsample by floor(ts / bucket); one row per
                        bucket carrying the last raw value.
        since_unix / until_unix: Absolute alternative to *_minutes_ago.
        max_points: Soft cap on returned rows. The full series is fetched
                    from Stats; we just thin the output for chat readability.

    Returns dict with `points` (list of `{ts, ts_human, value}`) and
    metadata describing the range/bucket.
    """
    since, until = _resolve_window(
        since_minutes_ago, until_minutes_ago, since_unix, until_unix
    )
    series = _get(
        "/metrics",
        prefix=prefix,
        since=since,
        until=until,
        bucket=bucket_seconds,
    )
    if not isinstance(series, list):
        return {"prefix": prefix, "error": "unexpected response", "raw": series}

    total = len(series)
    if total > max_points:
        # Even thinning by stride keeps endpoints visible.
        stride = max(1, total // max_points)
        series = series[::stride]

    return {
        "prefix": prefix,
        "since": since,
        "until": until,
        "bucket_seconds": bucket_seconds,
        "total_points": total,
        "returned_points": len(series),
        "points": [
            {"ts": p["ts"], "ts_human": _format_ts(p["ts"]), "value": p["value"]}
            for p in series
        ],
    }


@mcp.tool()
def latest(prefix: str) -> dict[str, Any]:
    """Return the most recent value for a `<module>@<reader>` prefix."""
    payload = _get("/latest", prefix=prefix)
    ts = payload.get("ts")
    return {
        "prefix": prefix,
        "ts": ts,
        "ts_human": _format_ts(ts) if isinstance(ts, int) else None,
        "value": payload.get("value"),
    }


@mcp.tool()
def top_processes(
    reader: str,
    since_minutes_ago: float = 5.0,
    by: Optional[str] = None,
    n: int = 10,
    aggregator: str = "max",
) -> dict[str, Any]:
    """Aggregate a ProcessReader's samples across a window and return top N apps.

    Args:
        reader: One of "CPU", "RAM", "Network", "Disk", "Battery" — or the
                full prefix like "Network@ProcessReader".
        since_minutes_ago: Window length, default 5 minutes.
        by: Field to rank by (e.g. "usage", "download", "upload"). If None,
            picks a sensible default per reader.
        n: How many to return.
        aggregator: "max" (peak observed), "mean" (average across window),
                    "last" (final value seen). For Network the cumulative
                    download/upload counters are best read with "last - first"
                    semantics — in that case pass aggregator="delta".

    Returns the top processes by `name` (rolled up across pids).
    """
    prefix = reader if "@" in reader else f"{reader}@ProcessReader"
    cfg = PROCESS_READERS.get(prefix)
    if cfg is None:
        return {
            "error": f"unknown reader '{reader}'. Try one of: "
            + ", ".join(sorted(PROCESS_READERS))
        }
    metric_field = by or cfg.get("metric")
    if metric_field is None:
        # Disk: pick the largest numeric field at runtime.
        metric_field = "auto"

    since, _ = _resolve_window(since_minutes_ago, None, None, None)
    series = _get("/metrics", prefix=prefix, since=since)

    if not isinstance(series, list) or not series:
        return {
            "prefix": prefix,
            "metric": metric_field,
            "since_minutes_ago": since_minutes_ago,
            "total_points": 0,
            "top": [],
            "note": "no samples in window",
        }

    # Roll values up by process name. Each "value" is a list of process dicts.
    bucket: dict[str, list[float]] = collections.defaultdict(list)
    extra_field = None
    if cfg.get("extra_metrics"):
        extra_field = cfg["extra_metrics"][0]
    extra_bucket: dict[str, list[float]] = collections.defaultdict(list)

    for sample in series:
        entries = sample.get("value")
        if not isinstance(entries, list):
            continue
        for entry in entries:
            name = entry.get("name") or "<unknown>"
            if metric_field == "auto":
                # Disk_process: pick the max numeric field on the entry.
                val = max(
                    (v for v in entry.values() if isinstance(v, (int, float))),
                    default=None,
                )
            else:
                val = entry.get(metric_field)
            if isinstance(val, (int, float)):
                bucket[name].append(float(val))
            if extra_field is not None:
                ev = entry.get(extra_field)
                if isinstance(ev, (int, float)):
                    extra_bucket[name].append(float(ev))

    def reduce(values: list[float]) -> float:
        if not values:
            return 0.0
        if aggregator == "mean":
            return sum(values) / len(values)
        if aggregator == "last":
            return values[-1]
        if aggregator == "delta":
            return max(values) - min(values)
        return max(values)  # default "max"

    ranked = sorted(
        (
            {
                "name": name,
                metric_field: reduce(values),
                **(
                    {extra_field: reduce(extra_bucket[name])}
                    if extra_field
                    else {}
                ),
                "samples": len(values),
            }
            for name, values in bucket.items()
        ),
        key=lambda d: d.get(metric_field, 0.0),
        reverse=True,
    )

    return {
        "prefix": prefix,
        "metric": metric_field,
        "extra_metric": extra_field,
        "aggregator": aggregator,
        "since_minutes_ago": since_minutes_ago,
        "unit": cfg.get("unit"),
        "total_points": len(series),
        "top": ranked[:n],
    }


@mcp.tool()
def find_spikes(
    prefix: str,
    field: Optional[str] = None,
    since_minutes_ago: float = 60.0,
    threshold: Optional[float] = None,
    threshold_stddevs: float = 2.0,
    min_gap_seconds: int = 30,
    max_results: int = 20,
) -> dict[str, Any]:
    """Locate moments when a metric exceeded a threshold.

    Args:
        prefix: A `<module>@<reader>` like "CPU@LoadReader".
        field: When the value is a dict, the numeric field to inspect
               (e.g. "totalUsage" for CPU@LoadReader). If None we pick
               the first plausible numeric field.
        since_minutes_ago: How far back to scan (default 60).
        threshold: Absolute cutoff. If None we use mean + threshold_stddevs * stddev.
        threshold_stddevs: Used only when `threshold` is None.
        min_gap_seconds: Coalesce consecutive spike samples within this gap
                         into a single event (avoids reporting 100 rows for
                         one busy minute).
        max_results: Cap on returned events.

    Returns events with start/end timestamps and the peak value seen.
    """
    since, _ = _resolve_window(since_minutes_ago, None, None, None)
    series = _get("/metrics", prefix=prefix, since=since)
    if not isinstance(series, list) or not series:
        return {"prefix": prefix, "events": [], "note": "no samples"}

    # Pull the numeric value out of each sample.
    samples: list[tuple[int, float]] = []
    chosen_field = field
    for sample in series:
        ts = sample.get("ts")
        v = sample.get("value")
        if isinstance(v, (int, float)):
            samples.append((ts, float(v)))
            continue
        if isinstance(v, dict):
            if chosen_field is None:
                for cand in (
                    "totalUsage",
                    "used",          # RAM/Disk used bytes
                    "level",
                    "temperature",
                    "load",
                    "frequency",
                    "download",
                    "value",
                ):
                    if isinstance(v.get(cand), (int, float)):
                        chosen_field = cand
                        break
            if chosen_field and isinstance(v.get(chosen_field), (int, float)):
                samples.append((ts, float(v[chosen_field])))

    if not samples:
        return {"prefix": prefix, "events": [], "note": "no numeric values"}

    values = [v for _, v in samples]
    mean = sum(values) / len(values)
    if len(values) > 1:
        variance = sum((v - mean) ** 2 for v in values) / (len(values) - 1)
        stddev = variance ** 0.5
    else:
        stddev = 0.0

    cutoff = threshold if threshold is not None else mean + threshold_stddevs * stddev

    events: list[dict[str, Any]] = []
    current: Optional[dict[str, Any]] = None
    for ts, v in samples:
        if v >= cutoff:
            if current is None:
                current = {
                    "start": ts,
                    "end": ts,
                    "peak": v,
                    "peak_ts": ts,
                    "samples": 1,
                }
            else:
                if ts - current["end"] > min_gap_seconds:
                    events.append(current)
                    current = {
                        "start": ts,
                        "end": ts,
                        "peak": v,
                        "peak_ts": ts,
                        "samples": 1,
                    }
                else:
                    current["end"] = ts
                    current["samples"] += 1
                    if v > current["peak"]:
                        current["peak"] = v
                        current["peak_ts"] = ts
    if current is not None:
        events.append(current)

    for ev in events:
        ev["start_human"] = _format_ts(ev["start"])
        ev["end_human"] = _format_ts(ev["end"])
        ev["peak_ts_human"] = _format_ts(ev["peak_ts"])
        ev["duration_seconds"] = ev["end"] - ev["start"]

    events.sort(key=lambda e: e["peak"], reverse=True)
    return {
        "prefix": prefix,
        "field": chosen_field,
        "since_minutes_ago": since_minutes_ago,
        "stats": {
            "samples": len(values),
            "mean": mean,
            "stddev": stddev,
            "cutoff": cutoff,
        },
        "events": events[:max_results],
    }


@mcp.tool()
def compare_periods(
    prefix: str,
    field: Optional[str] = None,
    window_minutes: float = 60.0,
    offset_hours: float = 24.0,
) -> dict[str, Any]:
    """Compare a recent window against the same window N hours earlier.

    Useful for "is right now unusual?" — e.g. last hour vs the same hour
    yesterday.

    Args:
        prefix: A `<module>@<reader>` like "CPU@LoadReader".
        field: Same semantics as in find_spikes.
        window_minutes: Width of each window (default 60).
        offset_hours: How far back the comparison window starts (default 24).
    """
    now = int(time.time())
    win = int(window_minutes * 60)
    off = int(offset_hours * 3600)

    recent = _get("/metrics", prefix=prefix, since=now - win, until=now)
    prior = _get(
        "/metrics", prefix=prefix, since=now - off - win, until=now - off
    )

    def stats(series: list[Any]) -> dict[str, Any]:
        nums: list[float] = []
        chosen = field
        for sample in series or []:
            v = sample.get("value")
            if isinstance(v, (int, float)):
                nums.append(float(v))
            elif isinstance(v, dict):
                if chosen is None:
                    for cand in ("totalUsage", "load", "level", "temperature"):
                        if isinstance(v.get(cand), (int, float)):
                            chosen = cand
                            break
                if chosen and isinstance(v.get(chosen), (int, float)):
                    nums.append(float(v[chosen]))
        if not nums:
            return {"samples": 0}
        nums.sort()
        n = len(nums)
        mid = nums[n // 2] if n % 2 else (nums[n // 2 - 1] + nums[n // 2]) / 2
        return {
            "samples": n,
            "min": nums[0],
            "max": nums[-1],
            "mean": sum(nums) / n,
            "median": mid,
            "field": chosen,
        }

    return {
        "prefix": prefix,
        "window_minutes": window_minutes,
        "offset_hours": offset_hours,
        "recent": stats(recent if isinstance(recent, list) else []),
        "prior": stats(prior if isinstance(prior, list) else []),
    }


@mcp.tool()
def summarize_period(
    since_minutes_ago: float = 60.0,
    include_top_processes: bool = True,
    top_n: int = 5,
) -> dict[str, Any]:
    """Cross-reader snapshot covering the last N minutes.

    For each aggregate reader, returns the latest value plus min/avg/max of
    the primary numeric field over the window. For each ProcessReader,
    returns the top N apps by their default metric.
    """
    since, _ = _resolve_window(since_minutes_ago, None, None, None)
    out: dict[str, Any] = {
        "since_minutes_ago": since_minutes_ago,
        "since": since,
        "now": int(time.time()),
        "aggregates": {},
        "top_processes": {},
    }

    available = set(_get("/modules").get("modules", []))

    for prefix in AGGREGATE_READERS:
        if prefix not in available:
            continue
        try:
            series = _get("/metrics", prefix=prefix, since=since)
        except RuntimeError as exc:
            out["aggregates"][prefix] = {"error": str(exc)}
            continue
        latest_val = series[-1] if series else None
        primary_values: list[float] = []
        for sample in series:
            v = sample.get("value")
            if isinstance(v, (int, float)):
                primary_values.append(float(v))
            elif isinstance(v, dict):
                # Pick the first plausible numeric primary field.
                for field in (
                    "totalUsage",
                    "level",
                    "load",
                    "value",
                    "temperature",
                    "frequency",
                ):
                    if field in v and isinstance(v[field], (int, float)):
                        primary_values.append(float(v[field]))
                        break
        summary: dict[str, Any] = {
            "samples": len(series),
            "latest": latest_val,
        }
        if primary_values:
            summary["min"] = min(primary_values)
            summary["max"] = max(primary_values)
            summary["mean"] = sum(primary_values) / len(primary_values)
        out["aggregates"][prefix] = summary

    if include_top_processes:
        for prefix in PROCESS_READERS:
            if prefix not in available:
                continue
            try:
                tp = top_processes(
                    reader=prefix,
                    since_minutes_ago=since_minutes_ago,
                    n=top_n,
                )
            except Exception as exc:  # noqa: BLE001
                tp = {"error": str(exc)}
            out["top_processes"][prefix] = tp

    return out


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
