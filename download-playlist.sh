#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load shared config ---
CONFIG_FILE="$SCRIPT_DIR/config.env"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config.env not found at $CONFIG_FILE" >&2
    exit 1
fi

while IFS='=' read -r key value; do
    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | xargs)"
    [[ -z "$key" || "$key" == \#* ]] && continue
    declare "$key=$value"
done < "$CONFIG_FILE"

# --- Defaults (can be overridden by config.env) ---
OUTPUT_DIR="${OUTPUT_DIR:-$HOME/Downloads/yt-dlp_playlist}"
AUDIO_ONLY=false
AUDIO_FORMAT="${DEFAULT_AUDIO_FORMAT:-mp3}"
COOKIE_BROWSER=""
NO_SPONSORBLOCK=false
MAX_DOWNLOADS=""
CRT=false
EPHEMERAL=false
PLAYLIST_URL=""

# --- Parse arguments ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] PLAYLIST_URL

Download a playlist using yt-dlp with auto-downloaded tools.

Options:
  -o DIR          Output directory (default: ~/Downloads/yt-dlp_playlist)
  -a              Audio-only mode
  -f FORMAT       Audio format (default: mp3)
  -c [BROWSER]    Extract cookies from browser (opt-in, defaults to config value)
  -n NUM          Max downloads (for testing)
  --crt           Crop video to 4:3 for CRT displays
  --ephemeral     Store tools in /tmp (cleaned on reboot)
  --no-sponsorblock  Skip SponsorBlock segment removal
  -h, --help      Show this help message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)     OUTPUT_DIR="$2"; shift 2 ;;
        -a)     AUDIO_ONLY=true; shift ;;
        -f)     AUDIO_FORMAT="$2"; shift 2 ;;
        -c)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                COOKIE_BROWSER="${DEFAULT_BROWSER:-firefox}"
                shift
            else
                COOKIE_BROWSER="$2"; shift 2
            fi ;;
        -n)     MAX_DOWNLOADS="$2"; shift 2 ;;
        --crt)  CRT=true; shift ;;
        --ephemeral) EPHEMERAL=true; shift ;;
        --no-sponsorblock) NO_SPONSORBLOCK=true; shift ;;
        -h|--help) usage ;;
        -*)     echo "Unknown option: $1" >&2; exit 1 ;;
        *)      PLAYLIST_URL="$1"; shift ;;
    esac
done

if [[ -z "$PLAYLIST_URL" ]]; then
    echo "Error: PLAYLIST_URL is required." >&2
    echo "Run '$(basename "$0") --help' for usage." >&2
    exit 1
fi

# --- Tools directory ---
if $EPHEMERAL; then
    EXISTING_EPHEMERAL="$(find /tmp -maxdepth 1 -type d -name 'jellyfin-dl-tools.*' 2>/dev/null | head -1)"
    if [[ -n "$EXISTING_EPHEMERAL" && -d "$EXISTING_EPHEMERAL/bin" ]]; then
        TOOLS_DIR="$EXISTING_EPHEMERAL"
        echo "Ephemeral mode: reusing existing tools in $TOOLS_DIR"
    else
        TOOLS_DIR="$(mktemp -d /tmp/jellyfin-dl-tools.XXXXXX)"
        echo "Ephemeral mode: tools in $TOOLS_DIR (cleaned on reboot)"
    fi
else
    TOOLS_DIR="$HOME/.local/share/jellyfin-dl-tools"
fi

BIN_DIR="$TOOLS_DIR/bin"
ARCHIVE_FILE="$TOOLS_DIR/$ARCHIVE_FILENAME"
mkdir -p "$BIN_DIR"

# --- Check for required system tools ---
for cmd in curl tar unzip; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: $cmd is required but not found in PATH." >&2
        exit 1
    fi
done

# --- Helper: download file with progress ---
download() {
    local url="$1" dest="$2"
    echo "Downloading $(basename "$dest")..."
    curl -L --progress-bar -o "$dest" "$url"
}

# --- Ensure yt-dlp ---
YT_DLP_PATH=""
if command -v yt-dlp &>/dev/null; then
    YT_DLP_PATH="$(command -v yt-dlp)"
    echo "yt-dlp found at: $YT_DLP_PATH — attempting self-update..."
    "$YT_DLP_PATH" -U 2>/dev/null || true
elif [[ -x "$BIN_DIR/yt-dlp" ]]; then
    YT_DLP_PATH="$BIN_DIR/yt-dlp"
    echo "yt-dlp exists — attempting self-update..."
    "$YT_DLP_PATH" -U 2>/dev/null || true
else
    download "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" "$BIN_DIR/yt-dlp"
    chmod +x "$BIN_DIR/yt-dlp"
    YT_DLP_PATH="$BIN_DIR/yt-dlp"
    echo "yt-dlp installed to: $YT_DLP_PATH"
fi

# --- Ensure ffmpeg ---
FFMPEG_DIR=""
if command -v ffmpeg &>/dev/null; then
    echo "ffmpeg found at: $(command -v ffmpeg)"
else
    FFMPEG_DIR="$TOOLS_DIR/ffmpeg"
    FFMPEG_BIN="$FFMPEG_DIR/ffmpeg"
    if [[ ! -x "$FFMPEG_BIN" ]]; then
        FFMPEG_TAR="$TOOLS_DIR/ffmpeg-release-amd64-static.tar.xz"
        download "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" "$FFMPEG_TAR"
        echo "Extracting ffmpeg..."
        tar -xf "$FFMPEG_TAR" -C "$TOOLS_DIR"
        mv "$TOOLS_DIR"/ffmpeg-*-static "$FFMPEG_DIR" 2>/dev/null || true
        rm -f "$FFMPEG_TAR"
        echo "ffmpeg extracted to: $FFMPEG_DIR"
    else
        echo "ffmpeg already present."
    fi
    FFMPEG_DIR="$FFMPEG_DIR"
fi

# --- Ensure Deno ---
DENO_PATH=""
if command -v deno &>/dev/null; then
    DENO_PATH="$(command -v deno)"
    echo "deno found at: $DENO_PATH"
elif [[ -x "$BIN_DIR/deno" ]]; then
    DENO_PATH="$BIN_DIR/deno"
    echo "deno found at: $DENO_PATH"
else
    echo "Downloading deno..."
    DENO_ZIP="$TOOLS_DIR/deno.zip"
    DENO_URL="$(curl -fsSL --connect-timeout 10 --max-time 30 "https://api.github.com/repos/denoland/deno/releases/latest" | grep -o '"browser_download_url": "[^"]*deno-linux-x64.zip"' | cut -d'"' -f4)"
    if [[ -z "$DENO_URL" ]]; then
        echo "Warning: could not determine latest deno release URL." >&2
        echo "deno may not work correctly for YouTube bot challenges." >&2
    else
        download "$DENO_URL" "$DENO_ZIP"
        unzip -qo "$DENO_ZIP" -d "$BIN_DIR"
        chmod +x "$BIN_DIR/deno"
        rm -f "$DENO_ZIP"
        DENO_PATH="$BIN_DIR/deno"
        echo "deno installed to: $DENO_PATH"
    fi
fi

# --- Add tools to PATH for this session ---
export PATH="$BIN_DIR:$PATH"

# --- Output template (forward slashes work on both platforms in yt-dlp) ---
OUTPUT_TEMPLATE="${OUTPUT_TEMPLATE:-%(playlist_title)s/%(playlist_index)s - %(title)s.%(ext)s}"

# --- Build yt-dlp args ---
args=(
    "-vU"
    "--yes-playlist"
    "--ignore-errors"
    "--no-warnings"
    "--newline"
    "--download-archive" "$ARCHIVE_FILE"
)

# Deno for YouTube bot challenges
if [[ -n "$DENO_PATH" && -x "$DENO_PATH" ]]; then
    args+=("--js-runtimes" "deno:$BIN_DIR")
fi

# SponsorBlock
if ! $NO_SPONSORBLOCK; then
    args+=("--sponsorblock-remove" "${SPONSORBLOCK_CATEGORIES:-all}")
fi

# Cookies (opt-in via -c)
if [[ -n "$COOKIE_BROWSER" ]]; then
    args+=("--cookies-from-browser" "$COOKIE_BROWSER")
fi

# Max downloads
if [[ -n "$MAX_DOWNLOADS" ]]; then
    args+=("--max-downloads" "$MAX_DOWNLOADS")
fi

# ffmpeg location
if [[ -n "$FFMPEG_DIR" && -d "$FFMPEG_DIR" ]]; then
    args+=("--ffmpeg-location" "$FFMPEG_DIR")
fi

# Audio-only vs video mode
if $AUDIO_ONLY; then
    args+=("-x" "--audio-format" "$AUDIO_FORMAT" "--audio-quality" "$AUDIO_QUALITY")
    pp_args="-af loudnorm=I=${LOUDNORM_I_AUDIO:--16}:TP=${LOUDNORM_TP_AUDIO:--1.5}:LRA=${LOUDNORM_LRA:-11}"
    args+=("--postprocessor-args" "$pp_args")
else
    args+=("-f" "bv[height<=${MAX_HEIGHT:-1080}]+bestaudio/best[height<=${MAX_HEIGHT:-1080}]")
    pp_args="-af loudnorm=I=${LOUDNORM_I_VIDEO:--14}:TP=${LOUDNORM_TP_VIDEO:--1.0}:LRA=${LOUDNORM_LRA:-11} -c:v copy -c:a libopus"
    if $CRT; then
        pp_args="$pp_args -vf scale=-2:ih,crop=ih*4/3:ih"
    fi
    args+=("--postprocessor-args" "ffmpeg:$pp_args")
fi

# Output template and URL
args+=("--output" "$OUTPUT_TEMPLATE")
args+=("$PLAYLIST_URL")

# --- Execute ---
echo "Starting yt-dlp..."
"$YT_DLP_PATH" "${args[@]}"

echo "Finished. Files saved under: $OUTPUT_DIR"

# --- Cleanup ephemeral tools ---
if $EPHEMERAL; then
    echo "Cleaning up ephemeral tools: $TOOLS_DIR"
    rm -rf "$TOOLS_DIR"
fi
