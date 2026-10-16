#!/bin/bash
# Robust navtrain (NAVSIM filtered training subset) downloader using aria2c.
#
# AutoVLA training scripts use train_test_split=navtrain (NOT trainval), which
# only requires the trainval *logs* (~14GB) plus a curated 445GB sensor subset
# (300GB without history).  This script downloads both with verification and
# multi-connection parallelism.
#
# Source endpoints:
#   - logs:       huggingface.co  (CloudFront, US-East)
#   - sensors:    s3.eu-central-1.amazonaws.com  (direct S3, Frankfurt)
#
# Usage:
#   bash download_navtrain_aria.sh             # current + history (~445GB)
#   bash download_navtrain_aria.sh nohistory   # current only     (~300GB)
#
# Env knobs:
#   OPENSCENE_DATA_ROOT   destination root (default /home/Humble/extra2)
#   ARIA_FILES_PARALLEL   concurrent .tgz files (default 2)
#   ARIA_CONN_PER_FILE    connections per file (default 16)

set -uo pipefail

DEST="${OPENSCENE_DATA_ROOT:-/home/Humble/extra2}"
MODE="${1:-full}"   # full | nohistory
PARALLEL="${ARIA_FILES_PARALLEL:-2}"
CONN="${ARIA_CONN_PER_FILE:-16}"

command -v aria2c >/dev/null || { echo "aria2c not found"; exit 1; }
command -v rsync  >/dev/null || { echo "rsync not found"; exit 1; }

CACHE="$DEST/_aria_cache_navtrain"
LOGS_DIR="$DEST/navsim_logs/trainval"
BLOBS_DIR="$DEST/sensor_blobs/trainval"
mkdir -p "$CACHE" "$LOGS_DIR" "$BLOBS_DIR"

# Official MD5s from navsim/docs/splits.md
MD5_FILE="$CACHE/.md5_sums"
cat > "$MD5_FILE" <<'EOF'
current_1 6f92f38d5f03ed852da7872a7122bdd2
current_2 7a72f0a758b5df6cbe4c565920a4869f
current_3 b083fce1428308abb5682a1a150cc1af
current_4 68354ac2c993aa1ebbfac59547fdb840
history_1 dc46ed34d92d5ab9cc1464d67b72fbf6
history_2 fab177bdb79c0c9536da1566d13e5995
history_3 71ed9a2387edc3849921861d7873c7f0
history_4 2cc13aced2f458e50fe4cc2f26d18e07
EOF

# --- Step 1: trainval metadata (logs) ---
META_URL="https://huggingface.co/datasets/OpenDriveLab/OpenScene/resolve/main/openscene-v1.1/openscene_metadata_trainval.tgz"
META_STAMP="$CACHE/metadata.ok"

# Reuse metadata.tgz from a prior download_openscene_aria.sh trainval run.
PREEXISTING_META="$DEST/_aria_cache_trainval/metadata.tgz"
if [ ! -f "$META_STAMP" ] && [ -f "$PREEXISTING_META" ]; then
    echo "[meta] reusing $PREEXISTING_META"
    cp -n "$PREEXISTING_META" "$CACHE/metadata.tgz"
fi

if [ ! -f "$META_STAMP" ]; then
    if [ ! -f "$CACHE/metadata.tgz" ] || ! tar tzf "$CACHE/metadata.tgz" > /dev/null 2>&1; then
        echo "[meta] downloading"
        rm -f "$CACHE/metadata.tgz"
        aria2c -x "$CONN" -s "$CONN" --max-tries=5 --retry-wait=10 \
            --continue=true --auto-file-renaming=false \
            --console-log-level=warn --summary-interval=30 \
            --file-allocation=none \
            -d "$CACHE" -o "metadata.tgz" "$META_URL" \
            || { echo "[meta] download failed"; exit 1; }
    fi
    if ! tar tzf "$CACHE/metadata.tgz" > /dev/null 2>&1; then
        echo "[meta] verification failed"; exit 1
    fi
    stage="$CACHE/_meta_stage"; rm -rf "$stage"; mkdir -p "$stage"
    tar xzf "$CACHE/metadata.tgz" -C "$stage" || { echo "[meta] extract failed"; exit 1; }
    rsync -a "$stage/openscene-v1.1/meta_datas/" "$LOGS_DIR/"
    rm -rf "$stage" "$CACHE/metadata.tgz"
    touch "$META_STAMP"
    echo "[meta] OK"
else
    echo "[meta] already done"
fi

# --- Step 2: navtrain sensor tarballs ---
S3_BASE="https://s3.eu-central-1.amazonaws.com/avg-projects-2/navsim"

process_navtrain_part() {
    local part="$1"   # e.g. current_1
    local url="${S3_BASE}/navtrain_${part}.tgz"
    local tgz="$CACHE/navtrain_${part}.tgz"
    local stamp="$CACHE/navtrain_${part}.ok"
    local expected_md5
    expected_md5=$(awk -v k="$part" '$1==k {print $2}' "$MD5_FILE")

    if [ -f "$stamp" ]; then
        echo "[$part] already done"; return 0
    fi

    for attempt in 1 2 3; do
        echo "[$part] download (try $attempt)"
        if ! aria2c \
                -x "$CONN" -s "$CONN" \
                --max-tries=5 --retry-wait=10 \
                --continue=true --auto-file-renaming=false \
                --console-log-level=warn --summary-interval=30 \
                --file-allocation=none \
                -d "$CACHE" -o "navtrain_${part}.tgz" "$url"; then
            echo "[$part] aria2c failed"; rm -f "$tgz"; continue
        fi

        if [ -n "$expected_md5" ]; then
            local got
            got=$(md5sum "$tgz" | awk '{print $1}')
            if [ "$got" != "$expected_md5" ]; then
                echo "[$part] md5 mismatch ($got vs $expected_md5)"
                rm -f "$tgz"; continue
            fi
            echo "[$part] md5 OK"
        elif ! tar tzf "$tgz" > /dev/null 2>&1; then
            echo "[$part] tarball corrupted"; rm -f "$tgz"; continue
        fi

        local stage="$CACHE/_stage_${part}"; rm -rf "$stage"; mkdir -p "$stage"
        if ! tar xzf "$tgz" -C "$stage"; then
            echo "[$part] extract failed"; rm -rf "$stage"; rm -f "$tgz"; continue
        fi
        # tarballs unpack to <prefix>_split_<n>/<log>/...
        local subdir
        subdir=$(ls -d "$stage"/*/ 2>/dev/null | head -1)
        if [ -n "$subdir" ]; then
            rsync -a "$subdir" "$BLOBS_DIR/"
        fi
        rm -rf "$stage" "$tgz"
        touch "$stamp"
        echo "[$part] OK"
        return 0
    done
    echo "[$part] FAILED" >&2; return 1
}
export -f process_navtrain_part
export CACHE S3_BASE BLOBS_DIR CONN MD5_FILE

PARTS="current_1 current_2 current_3 current_4"
if [ "$MODE" != "nohistory" ]; then
    PARTS="$PARTS history_1 history_2 history_3 history_4"
fi

printf "%s\n" $PARTS | xargs -I {} -P "$PARALLEL" bash -c 'process_navtrain_part "$@"' _ {}

echo
ok=$(ls "$CACHE"/navtrain_*.ok 2>/dev/null | wc -l)
total=$(echo "$PARTS" | wc -w)
echo "=== Summary ==="
echo "Verified: $ok / $total"
if [ "$ok" -eq "$total" ] && [ -f "$META_STAMP" ]; then
    echo "All done. Cache can be removed: rm -rf '$CACHE'"
else
    echo "Re-run the same command to retry."
fi
