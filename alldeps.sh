#!/usr/bin/env bash
# alldeps.sh - fast SBOM scan of the host + running containers -> Dependency-Track
#
# Env overrides: DT_URL, DT_API_KEY, DT_PROJECT (compose project name),
#                MAX_JOBS (parallel image scans), SCAN_HOST=0 to skip the host scan
set -uo pipefail

PROJECT="${DT_PROJECT:-dependencytrack}"
MAX_JOBS="${MAX_JOBS:-4}"
SCAN_HOST="${SCAN_HOST:-1}"

command -v syft   >/dev/null 2>&1 || { echo "ERROR: syft not found"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }

if docker info >/dev/null 2>&1; then DOCKER="docker"; else DOCKER="sudo docker"; fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 1. API URL
discover_url() {
    local id port
    id=$($DOCKER ps -q \
            --filter "label=com.docker.compose.project=$PROJECT" \
            --filter "label=com.docker.compose.service=apiserver" | head -n1)
    [ -z "$id" ] && id=$($DOCKER ps -q --filter "ancestor=dependencytrack/apiserver" | head -n1)
    [ -z "$id" ] && return 1
    port=$($DOCKER port "$id" 8080/tcp 2>/dev/null | head -n1 | sed 's/.*://')
    [ -z "$port" ] && return 1
    echo "http://localhost:$port"
}

if [ -z "${DT_URL:-}" ]; then
    DT_URL=$(discover_url) || {
        echo "ERROR: no running apiserver container found for project '$PROJECT'."
        echo "       Run 'make up' first, or set DT_URL=http://host:port"
        exit 1
    }
fi
DT_URL="${DT_URL%/}"
echo "=== API server: $DT_URL ==="
curl -fsS "$DT_URL/api/version" >/dev/null || { echo "ERROR: $DT_URL/api/version unreachable"; exit 1; }

# ---------------------------------------------------------------- 2. API key
if [ -z "${DT_API_KEY:-}" ]; then
    read -rs -p "Dependency-Track API key: " DT_API_KEY
    echo
fi
[ -n "$DT_API_KEY" ] || { echo "ERROR: no API key given"; exit 1; }

# key goes via stdin config so it never appears in the process list
dt_curl() { printf 'header = "X-Api-Key: %s"\n' "$DT_API_KEY" | curl -K - "$@"; }

code=$(dt_curl -s -o /dev/null -w '%{http_code}' "$DT_URL/api/v1/team/self")
case "$code" in
    401|403) echo "ERROR: API key rejected (HTTP $code)"; exit 1 ;;
esac

upload() {   # $1 project name, $2 version, $3 sbom file
    local c
    c=$(dt_curl -s -o /dev/null -w '%{http_code}' "$DT_URL/api/v1/bom" \
        -F "projectName=$1" -F "projectVersion=$2" \
        -F "autoCreate=true" -F "bom=@$3")
    [ "$c" = "200" ]
}

scan_image() {
    local image="$1" repo="$1" tag="latest" file
    if [[ "$image" == *:* && "${image##*:}" != */* ]]; then
        repo="${image%:*}"; tag="${image##*:}"
    fi
    file="$WORK/$(echo "$image" | tr '/:@' '___').json"
    if syft "docker:$image" -q -o "cyclonedx-json=$file" && upload "Docker-$repo" "$tag" "$file"; then
        echo "[✓] $image"
    else
        echo "[✗] FAILED: $image"
    fi
}

# ---------------------------------------------------------------- 3. host scan
if [ "$SCAN_HOST" = "1" ]; then
    echo "=== Host scan (needs sudo) ==="
    sudo -v || { echo "ERROR: sudo required for host scan (or SCAN_HOST=0)"; exit 1; }
    sudo syft dir:/ -q \
        --exclude './proc/**' --exclude './sys/**' --exclude './dev/**' \
        --exclude './var/cache/**' --exclude './var/log/**' --exclude './tmp/**' \
        -o "cyclonedx-json=$WORK/host.json" &
fi

# ---------------------------------------------------------------- 4. containers
echo "=== Containers (max $MAX_JOBS parallel) ==="
images=$($DOCKER ps --format '{{.Image}}' | sort -u)
if [ -z "$images" ]; then
    echo "No running containers."
else
    while read -r image; do
        [ -z "$image" ] && continue
        while [ "$(jobs -rp | wc -l)" -ge "$MAX_JOBS" ]; do sleep 0.5; done
        echo "[+] $image"
        scan_image "$image" &
    done <<< "$images"
fi

echo "=== Waiting for scans ==="
wait

# ---------------------------------------------------------------- 5. host upload
if [ "$SCAN_HOST" = "1" ]; then
    if [ -s "$WORK/host.json" ] && upload "Host-$(hostname -s)" "latest" "$WORK/host.json"; then
        echo "[✓] host: Host-$(hostname -s)"
    else
        echo "[✗] FAILED: host scan/upload"
    fi
fi

echo "Done. Check the Dependency-Track UI."
