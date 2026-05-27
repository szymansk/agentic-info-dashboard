#!/usr/bin/env python3
"""
Fetch recent videos from curated AI/Agentic-AI YouTube channels via RSS,
write a single data.json that the youtube dashboard renders.

No API key required, no third-party libraries (stdlib only).

Output:
    dashboards/youtube/data.json
"""

import json
import random
import sys
import time
import urllib.request
import urllib.error
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_PATH = ROOT / "dashboards" / "youtube" / "data.json"

# Wenn weniger als dieser Anteil der Channels erfolgreich war, gilt der
# Run als "Outage" und data.json wird NICHT überschrieben.
MIN_SUCCESS_RATIO = 0.5

# Throttle zwischen sequenziellen Channel-Requests, um YouTube-Rate-Limit
# (15/16 404er bei 06:03 UTC am 2026-05-21) zu vermeiden.
INTER_REQUEST_DELAY_SEC = 0.6

# Retry-Konfiguration bei 404/429/Timeout
MAX_RETRIES = 2
RETRY_BACKOFF_SEC = 30

# ─── Channels ──────────────────────────────────────────────────────────
# tier 1 = automatisch ins "Featured" beim Skript-Lauf, sofern aktuell

CHANNELS = [
    # Solo-Researcher / Educators
    {"id": "UCPk8m_r6fkUSYmvgCBwq-sw", "name": "Andrej Karpathy",          "category": "researcher", "tier": 1, "color": "#7aa2f7"},
    {"id": "UCYO_jab_esuFRV4b17AJtAw", "name": "3Blue1Brown",              "category": "researcher", "tier": 2, "color": "#7aa2f7"},
    {"id": "UCbfYPyITQ-7l4upoX8nvctg", "name": "Two Minute Papers",        "category": "researcher", "tier": 2, "color": "#7aa2f7"},
    {"id": "UCZHmQk67mSJgfCCTn7xBfew", "name": "Yannic Kilcher",           "category": "researcher", "tier": 2, "color": "#7aa2f7"},
    {"id": "UC9-y-6csu5WGm29I7JiwpnA", "name": "Computerphile",            "category": "researcher", "tier": 3, "color": "#7aa2f7"},

    # News / Analysis
    {"id": "UCNJ1Ymd5yFuUPtn21xtRbbw", "name": "AI Explained",             "category": "news",       "tier": 1, "color": "#e0a857"},
    {"id": "UCawZsQWqfGSbCI5yjkdVkTA", "name": "Matthew Berman",           "category": "news",       "tier": 2, "color": "#e0a857"},

    # Podcasts / Interviews
    {"id": "UCSHZKyawb77ixDdsGog4iWA", "name": "Lex Fridman",              "category": "podcast",    "tier": 1, "color": "#b04bd1"},
    {"id": "UCMLtBahI5DMrt0NPvDSoIRQ", "name": "Machine Learning Street Talk", "category": "podcast","tier": 2, "color": "#b04bd1"},

    # Official Labs
    {"id": "UCrDwWp7EBBv4NwvScIpBDOA", "name": "Anthropic",                "category": "lab",        "tier": 1, "color": "#c39a4a"},
    {"id": "UCXZCJLdBC09xxGZ6gcdrc6A", "name": "OpenAI",                   "category": "lab",        "tier": 1, "color": "#6ec38b"},
    {"id": "UCP7jMXSY2xbc3KCAE0MHQ-A", "name": "Google DeepMind",          "category": "lab",        "tier": 1, "color": "#6ec38b"},
    {"id": "UCHlNU7kIZhRgSbhHvFoy72w", "name": "Hugging Face",             "category": "lab",        "tier": 3, "color": "#c39a4a"},

    # Industry / Talks
    {"id": "UC9cn0TuPq4dnbTY-CBsm8XA", "name": "a16z",                     "category": "industry",   "tier": 3, "color": "#e15a5a"},
    {"id": "UCcIXc5mJsHVYTZR1maL5l9w", "name": "DeepLearningAI",           "category": "industry",   "tier": 3, "color": "#e15a5a"},

    # Practitioner / Bite-Size
    {"id": "UCsBjURrPoezykLs9EqgamOA", "name": "Fireship",                 "category": "practitioner", "tier": 3, "color": "#6ec38b"},
]

# Optional: kuratorische Notizen pro video_id, werden in "featured" eingeblendet.
# Wird über Tage hinweg angereichert; das Skript überschreibt sie nicht.
CURATED_NOTES: dict[str, str] = {
    # "VIDEO_ID": "Warum man das anschauen sollte (Lese-Hinweis)",
}

# Filter
RECENT_DAYS = 14
MAX_VIDEOS_PER_CHANNEL = 5
MAX_FEATURED = 6

NS = {
    "atom":  "http://www.w3.org/2005/Atom",
    "yt":    "http://www.youtube.com/xml/schemas/2015",
    "media": "http://search.yahoo.com/mrss/",
}

# Mehrere User-Agents rotieren, damit YouTube uns nicht als einzelnen Bot brandmarkt.
USER_AGENTS = [
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/124.0",
]


def fetch_feed(channel_id: str, attempt: int = 1) -> bytes | None:
    """Holt einen Channel-Feed mit Retry-Backoff bei 404/429/Timeout."""
    url = f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"
    ua = random.choice(USER_AGENTS)
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": ua,
            "Accept": "application/atom+xml, application/xml;q=0.9",
            "Accept-Language": "en-US,en;q=0.5",
        })
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        # 404 + 429 sind "vorübergehende" Codes von YouTube-Rate-Limit
        if e.code in (404, 429) and attempt <= MAX_RETRIES:
            wait = RETRY_BACKOFF_SEC * attempt
            print(f"  ↻ {channel_id}: HTTP {e.code} (Versuch {attempt}/{MAX_RETRIES}), warte {wait}s", file=sys.stderr)
            time.sleep(wait)
            return fetch_feed(channel_id, attempt + 1)
        print(f"  ⚠ {channel_id}: HTTP {e.code}", file=sys.stderr)
        return None
    except (urllib.error.URLError, TimeoutError) as e:
        if attempt <= MAX_RETRIES:
            wait = RETRY_BACKOFF_SEC * attempt
            print(f"  ↻ {channel_id}: {e} (Versuch {attempt}/{MAX_RETRIES}), warte {wait}s", file=sys.stderr)
            time.sleep(wait)
            return fetch_feed(channel_id, attempt + 1)
        print(f"  ⚠ {channel_id}: {e}", file=sys.stderr)
        return None


def parse_feed(xml_bytes: bytes, channel: dict) -> list[dict]:
    try:
        root = ET.fromstring(xml_bytes)
    except ET.ParseError as e:
        print(f"  ⚠ {channel['id']}: XML parse error: {e}", file=sys.stderr)
        return []

    videos = []
    for entry in root.findall("atom:entry", NS):
        video_id_el = entry.find("yt:videoId", NS)
        title_el    = entry.find("atom:title", NS)
        published_el = entry.find("atom:published", NS)
        link_el     = entry.find("atom:link[@rel='alternate']", NS)
        media_group = entry.find("media:group", NS)
        desc_el     = media_group.find("media:description", NS) if media_group is not None else None

        if video_id_el is None or title_el is None or published_el is None:
            continue

        vid = video_id_el.text or ""
        title = (title_el.text or "").strip()
        published = published_el.text or ""
        url = link_el.get("href") if link_el is not None else f"https://www.youtube.com/watch?v={vid}"
        description = (desc_el.text or "").strip() if desc_el is not None else ""

        videos.append({
            "video_id": vid,
            "title": title,
            "channel_id": channel["id"],
            "channel_name": channel["name"],
            "category": channel["category"],
            "color": channel["color"],
            "published": published,
            "url": url,
            "thumbnail": f"https://img.youtube.com/vi/{vid}/mqdefault.jpg",
            "description": description[:240],
        })
    return videos


def is_recent(iso_ts: str, days: int) -> bool:
    try:
        dt = datetime.fromisoformat(iso_ts.replace("Z", "+00:00"))
    except ValueError:
        return False
    return datetime.now(timezone.utc) - dt <= timedelta(days=days)


def pick_featured(recent: list[dict], channels_by_id: dict) -> list[dict]:
    """One most-recent video per Tier-1 channel, capped at MAX_FEATURED."""
    seen_channels = set()
    out = []
    for v in recent:
        ch = channels_by_id.get(v["channel_id"])
        if not ch or ch["tier"] != 1 or v["channel_id"] in seen_channels:
            continue
        seen_channels.add(v["channel_id"])
        item = dict(v)
        item["why"] = CURATED_NOTES.get(v["video_id"], "")
        out.append(item)
        if len(out) >= MAX_FEATURED:
            break
    return out


def main():
    channels_by_id = {c["id"]: c for c in CHANNELS}
    all_videos: list[dict] = []
    failures: list[str] = []

    print(f"Fetching {len(CHANNELS)} channels (mit {INTER_REQUEST_DELAY_SEC}s throttle) …")
    for i, ch in enumerate(CHANNELS):
        if i > 0:
            # Throttle: vermeidet YouTube-Rate-Limit (404er bei Burst)
            time.sleep(INTER_REQUEST_DELAY_SEC)
        xml = fetch_feed(ch["id"])
        if xml is None:
            failures.append(ch["name"])
            continue
        videos = parse_feed(xml, ch)
        kept = [v for v in videos if is_recent(v["published"], RECENT_DAYS)]
        kept = kept[:MAX_VIDEOS_PER_CHANNEL]
        all_videos.extend(kept)
        print(f"  · {ch['name']:<32} {len(kept)} recent of {len(videos)}")

    # Safety-Net: wenn zu viele Channels fehlgeschlagen sind, NICHT überschreiben
    success_count = len(CHANNELS) - len(failures)
    success_ratio = success_count / len(CHANNELS) if CHANNELS else 0
    if success_ratio < MIN_SUCCESS_RATIO:
        print(
            f"\n⚠ Erfolgsquote {success_count}/{len(CHANNELS)} = {success_ratio:.0%} "
            f"unter Schwelle {MIN_SUCCESS_RATIO:.0%}. data.json wird NICHT überschrieben.",
            file=sys.stderr,
        )
        print(f"  Failures: {', '.join(failures)}", file=sys.stderr)
        sys.exit(2)

    # Sortiere alle Videos nach Datum absteigend
    all_videos.sort(key=lambda v: v["published"], reverse=True)

    featured = pick_featured(all_videos, channels_by_id)
    print(f"\n→ {len(all_videos)} recent videos · {len(featured)} featured · {success_count}/{len(CHANNELS)} channels OK")

    data = {
        "last_updated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "channels": CHANNELS,
        "featured": featured,
        "recent": all_videos,
        "stats": {
            "total_videos": len(all_videos),
            "total_channels": len(CHANNELS),
            "successful_channels": success_count,
            "failed_channels": failures,
            "window_days": RECENT_DAYS,
        }
    }

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\nWrote {OUT_PATH} ({OUT_PATH.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
