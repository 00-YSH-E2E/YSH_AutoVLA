#!/bin/bash
# Robust OpenScene v1.1 downloader using aria2c (multi-connection per file).
#
# Differences vs. original wget-pipe-tar approach:
#   - Each .tgz lands on disk first, verified via `tar tzf` BEFORE extraction.
#   - aria2c uses 16 parallel chunks per file -> typically 5-10x faster on HF.
#   - Idempotent: stamp files in cache dir mark verified splits, re-run skips them.
#   - Extracts directly into navsim canonical layout:
#       $DEST/navsim_logs/<split>/   $DEST/sensor_blobs/<split>/
#   - Pre-existing partial data (e.g. from a killed wget run) is overlayed via
#     rsync, so completed files are kept and incomplete ones get overwritten.
#
# Usage:
#   bash download_openscene_aria.sh trainval     # 200 camera splits
#   bash download_openscene_aria.sh test         #  32 camera splits
#
# Env knobs:
#   OPENSCENE_DATA_ROOT  destination root (default /home/Humble/extra2)
#   ARIA_FILES_PARALLEL  how many .tgz to fetch concurrently (default 2)
#   ARIA_CONN_PER_FILE   aria2c -x / -s value (default 16)

set -uo pipefail

DEST="${OPENSCENE_DATA_ROOT:-/home/Humble/extra2}"
SPLIT="${1:-trainval}"
PARALLEL="${ARIA_FILES_PARALLEL:-2}"
CONN="${ARIA_CONN_PER_FILE:-16}"

case "$SPLIT" in
    trainval)
        N_SPLITS=200
        URL_PREFIX="https://huggingface.co/datasets/OpenDriveLab/OpenScene/resolve/main/openscene-v1.1/openscene_sensor_trainval_camera/openscene_sensor_trainval_camera"
        META_URL="https://huggingface.co/datasets/OpenDriveLab/OpenScene/resolve/main/openscene-v1.1/openscene_metadata_trainval.tgz"
        ;;
    test)
        N_SPLITS=32
        URL_PREFIX="https://huggingface.co/datasets/OpenDriveLab/OpenScene/resolve/main/openscene-v1.1/openscene_sensor_test_camera/openscene_sensor_test_camera"
        META_URL="https://huggingface.co/datasets/OpenDriveLab/OpenScene/resolve/main/openscene-v1.1/openscene_metadata_test.tgz"
        ;;
    *) echo "usage: $0 [trainval|test]" >&2; exit 2 ;;
esac

command -v aria2c >/dev/null || { echo "aria2c not found"; exit 1; }
command -v rsync  >/dev/null || { echo "rsync not found"; exit 1; }

CACHE="$DEST/_aria_cache_${SPLIT}"
LOGS_DIR="$DEST/navsim_logs/${SPLIT}"
BLOBS_DIR="$DEST/sensor_blobs/${SPLIT}"
mkdir -p "$CACHE" "$LOGS_DIR" "$BLOBS_DIR"

aria_get() {
    # $1 = url, $2 = output filename (relative to CACHE)
    aria2c \
        -x "$CONN" -s "$CONN" \
        --max-tries=5 --retry-wait=10 \
        --continue=true --auto-file-renaming=false \
        --console-log-level=warn --summary-interval=30 \
        --file-allocation=none \
        -d "$CACHE" -o "$2" "$1"
}

# --- Step 1: metadata (small, ~14GB for trainval, ~1GB for test) ---
META_STAMP="$CACHE/metadata.ok"
if [ ! -f "$META_STAMP" ]; then
    echo "[meta] downloading"
    rm -f "$CACHE/metadata.tgz"
    if ! aria_get "$META_URL" "metadata.tgz"; then
        echo "[meta] download failed" >&2; exit 1
    fi
    if ! tar tzf "$CACHE/metadata.tgz" > /dev/null 2>&1; then
        echo "[meta] tar verify failed" >&2; exit 1
    fi
    stage="$CACHE/_meta_stage"; rm -rf "$stage"; mkdir -p "$stage"
    tar xzf "$CACHE/metadata.tgz" -C "$stage" || { echo "[meta] extract failed"; exit 1; }
    # tarball: openscene-v1.1/meta_datas/...
    rsync -a "$stage/openscene-v1.1/meta_datas/" "$LOGS_DIR/"
    rm -rf "$stage" "$CACHE/metadata.tgz"
    touch "$META_STAMP"
    echo "[meta] OK"
else
    echo "[meta] already done"
fi

# --- Step 2: per-split sensor tarballs ---
process_split() {
    local i="$1"
    local url="${URL_PREFIX}_${i}.tgz"
    local tgz="$CACHE/split_${i}.tgz"
    local stamp="$CACHE/split_${i}.ok"

    if [ -f "$stamp" ]; then
        echo "[$i] already done"
        return 0
    fi

    for attempt in 1 2 3; do
        echo "[$i] download (try $attempt)"
        if ! aria2c \
                -x "$CONN" -s "$CONN" \
                --max-tries=5 --retry-wait=10 \
                --continue=true --auto-file-renaming=false \
                --console-log-level=warn --summary-interval=0 \
                --file-allocation=none \
                -d "$CACHE" -o "split_${i}.tgz" "$url"; then
            echo "[$i] aria2c failed (try $attempt)"
            rm -f "$tgz"
            continue
        fi

        if ! tar tzf "$tgz" > /dev/null 2>&1; then
            echo "[$i] tarball corrupted (try $attempt)"
            rm -f "$tgz"
            continue
        fi

        local stage="$CACHE/_stage_${i}"
        rm -rf "$stage"; mkdir -p "$stage"
        if ! tar xzf "$tgz" -C "$stage"; then
            echo "[$i] extract failed (try $attempt)"
            rm -rf "$stage"; rm -f "$tgz"
            continue
        fi

        if [ -d "$stage/openscene-v1.1/sensor_blobs" ]; then
            rsync -a "$stage/openscene-v1.1/sensor_blobs/" "$BLOBS_DIR/"
        fi
        rm -rf "$stage" "$tgz"
        touch "$stamp"
        echo "[$i] OK"
        return 0
    done
    echo "[$i] FAILED after 3 attempts" >&2
    return 1
}
export -f process_split aria_get
export CACHE URL_PREFIX BLOBS_DIR CONN

seq 0 $((N_SPLITS - 1)) | xargs -I {} -P "$PARALLEL" bash -c 'process_split "$@"' _ {}

echo
ok=$(ls "$CACHE"/split_*.ok 2>/dev/null | wc -l)
echo "=== Summary ==="
echo "Verified: $ok / $N_SPLITS"
if [ "$ok" -eq "$N_SPLITS" ] && [ -f "$META_STAMP" ]; then
    echo "All done. Safe to remove cache: rm -rf '$CACHE'"
else
    echo "Re-run the same command to retry remaining splits."
fi
