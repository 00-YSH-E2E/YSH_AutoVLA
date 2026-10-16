#!/bin/bash
# Verify and re-download corrupted OpenScene v1.1 camera splits.
#
# Run AFTER download_trainval.sh / download_test.sh finish.
# Idempotent: re-running only retries splits that haven't passed verification yet
# (tracked via .ok stamp files in the cache dir).
#
# Usage:
#   bash fixup_openscene.sh trainval   # 200 camera splits
#   bash fixup_openscene.sh test       #  32 camera splits

set -uo pipefail

DEST="${OPENSCENE_DATA_ROOT:-/home/Humble/extra2}"
SPLIT="${1:-trainval}"

case "$SPLIT" in
    trainval)
        N_SPLITS=200
        URL_PREFIX="https://huggingface.co/datasets/OpenDriveLab/OpenScene/resolve/main/openscene-v1.1/openscene_sensor_trainval_camera/openscene_sensor_trainval_camera"
        FINAL_LOGS="$DEST/trainval_navsim_logs"
        FINAL_BLOBS="$DEST/trainval_sensor_blobs"
        ;;
    test)
        N_SPLITS=32
        URL_PREFIX="https://huggingface.co/datasets/OpenDriveLab/OpenScene/resolve/main/openscene-v1.1/openscene_sensor_test_camera/openscene_sensor_test_camera"
        FINAL_LOGS="$DEST/test_navsim_logs"
        FINAL_BLOBS="$DEST/test_sensor_blobs"
        ;;
    *)
        echo "usage: $0 [trainval|test]" >&2
        exit 2
        ;;
esac

CACHE="$DEST/_tgz_cache_${SPLIT}"
EXTRACT_TMP="$DEST/_extract_tmp_${SPLIT}"
mkdir -p "$CACHE" "$EXTRACT_TMP"

if [ ! -d "$FINAL_BLOBS" ]; then
    echo "ERROR: $FINAL_BLOBS not found. Run download_${SPLIT}.sh first." >&2
    exit 1
fi

verify_one() {
    local i="$1"
    local url="${URL_PREFIX}_${i}.tgz"
    local tgz="$CACHE/split_${i}.tgz"
    local stamp="$CACHE/split_${i}.ok"

    if [ -f "$stamp" ]; then
        echo "[$i] already verified, skipping"
        return 0
    fi

    for attempt in 1 2 3; do
        echo "[$i] attempt $attempt: download"
        if ! wget -c -q -O "$tgz" "$url"; then
            echo "[$i] wget failed (attempt $attempt)"
            rm -f "$tgz"
            continue
        fi

        echo "[$i] verify"
        if ! tar tzf "$tgz" > /dev/null 2>&1; then
            echo "[$i] tarball corrupted (attempt $attempt), retrying"
            rm -f "$tgz"
            continue
        fi

        echo "[$i] extract+merge"
        local stage="$EXTRACT_TMP/split_${i}"
        rm -rf "$stage"
        mkdir -p "$stage"
        if ! tar xzf "$tgz" -C "$stage"; then
            echo "[$i] extract failed"
            rm -rf "$stage"
            rm -f "$tgz"
            continue
        fi

        # Tarball layout: openscene-v1.1/sensor_blobs/<log>/...
        if [ -d "$stage/openscene-v1.1/sensor_blobs" ]; then
            cp -an "$stage/openscene-v1.1/sensor_blobs/." "$FINAL_BLOBS/" \
                || rsync -a "$stage/openscene-v1.1/sensor_blobs/" "$FINAL_BLOBS/"
        fi
        rm -rf "$stage"
        touch "$stamp"
        rm -f "$tgz"
        echo "[$i] OK"
        return 0
    done
    echo "[$i] FAILED after 3 attempts" >&2
    return 1
}

export -f verify_one
export CACHE EXTRACT_TMP URL_PREFIX FINAL_BLOBS

PARALLEL="${FIXUP_PARALLEL:-4}"
seq 0 $((N_SPLITS - 1)) | xargs -I {} -P "$PARALLEL" bash -c 'verify_one "$@"' _ {}

echo
echo "=== Summary ==="
ok=$(ls "$CACHE"/*.ok 2>/dev/null | wc -l)
echo "Verified splits: $ok / $N_SPLITS"
if [ "$ok" -eq "$N_SPLITS" ]; then
    echo "All splits OK. You can remove the cache: rm -rf '$CACHE' '$EXTRACT_TMP'"
else
    echo "Missing splits — re-run this script to retry."
fi
