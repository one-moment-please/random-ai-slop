#!/usr/bin/env bash

###############################################################################
# Jellyfin Hardware Transcoding Diagnostic
#
# Tests:
#   - Intel Quick Sync (QSV)
#   - NVIDIA NVENC/NVDEC
#   - VA-API (Intel / AMD)
#
# The script is diagnostic-only. It does NOT:
#   - modify groups
#   - modify permissions
#   - install packages
#   - restart Jellyfin
#   - modify Jellyfin configuration
#
# Usage:
#
#   sudo ./jellyfin-hw-transcode-check.sh
#
# Optional:
#
#   sudo ./jellyfin-hw-transcode-check.sh /path/to/media
#
###############################################################################

set -u
set -o pipefail

###############################################################################
# Configuration
###############################################################################

MEDIA_PATH="${1:-}"
TRANSCODE_PATH="${TRANSCODE_PATH:-}"

PASS=0
WARN=0
FAIL=0
INFO_COUNT=0

JELLYFIN_SERVICE=""
JELLYFIN_USER=""
JELLYFIN_GROUP=""

FFMPEG=""
VAINFO=""

###############################################################################
# Colors
###############################################################################

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    RESET=''
fi

###############################################################################
# Output helpers
###############################################################################

section()
{
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

pass()
{
    echo -e "  ${GREEN}[PASS]${RESET} $*"
    ((PASS++))
}

warn()
{
    echo -e "  ${YELLOW}[WARN]${RESET} $*"
    ((WARN++))
}

fail()
{
    echo -e "  ${RED}[FAIL]${RESET} $*"
    ((FAIL++))
}

info()
{
    echo -e "  ${BLUE}[INFO]${RESET} $*"
    ((INFO_COUNT++))
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

###############################################################################
# Basic information
###############################################################################

section "System"

info "Hostname: $(hostname 2>/dev/null || echo unknown)"
info "Kernel:   $(uname -sr 2>/dev/null || echo unknown)"
info "Arch:     $(uname -m 2>/dev/null || echo unknown)"

if [[ "$EUID" -eq 0 ]]; then
    pass "Running as root"
else
    warn "Not running as root"
    warn "Run this script with sudo for the most complete results."
fi

if command_exists systemctl; then
    pass "systemd detected"
else
    warn "systemctl not found"
fi

###############################################################################
# Locate Jellyfin
###############################################################################

section "Jellyfin service"

if command_exists systemctl; then

    for svc in jellyfin.service jellyfin; do
        if systemctl cat "$svc" >/dev/null 2>&1; then
            JELLYFIN_SERVICE="$svc"
            break
        fi
    done

fi

if [[ -z "$JELLYFIN_SERVICE" ]]; then
    fail "Could not find a systemd Jellyfin service"
    info "This may be a Docker/Podman/LXC installation."
else

    pass "Found Jellyfin service: $JELLYFIN_SERVICE"

    if systemctl is-active --quiet "$JELLYFIN_SERVICE"; then
        pass "Jellyfin service is running"
    else
        fail "Jellyfin service is NOT running"
    fi

fi

###############################################################################
# Determine Jellyfin user
###############################################################################

section "Jellyfin user"

if [[ -n "$JELLYFIN_SERVICE" ]]; then

    JELLYFIN_USER="$(
        systemctl show "$JELLYFIN_SERVICE" \
            -p User \
            --value \
            2>/dev/null
    )"

    JELLYFIN_GROUP="$(
        systemctl show "$JELLYFIN_SERVICE" \
            -p Group \
            --value \
            2>/dev/null
    )"

fi

# Default Debian/Ubuntu installation
if [[ -z "$JELLYFIN_USER" ]]; then
    if id jellyfin >/dev/null 2>&1; then
        JELLYFIN_USER="jellyfin"
        info "Using jellyfin account because systemd User= was not explicitly set."
    fi
fi

if [[ -z "$JELLYFIN_USER" ]]; then

    fail "Could not determine Jellyfin user"

else

    pass "Jellyfin runs as: $JELLYFIN_USER"

    if id "$JELLYFIN_USER" >/dev/null 2>&1; then

        info "Identity:"
        id "$JELLYFIN_USER" | sed 's/^/         /'

        info "Groups:"
        id -nG "$JELLYFIN_USER" |
            tr ' ' '\n' |
            sed 's/^/         /'

        JELLYFIN_UID="$(id -u "$JELLYFIN_USER")"
        JELLYFIN_GID="$(id -g "$JELLYFIN_USER")"

        info "UID: $JELLYFIN_UID"
        info "GID: $JELLYFIN_GID"

    else

        fail "Jellyfin user does not exist: $JELLYFIN_USER"

    fi

fi

###############################################################################
# Systemd restrictions
###############################################################################

section "Jellyfin systemd restrictions"

if [[ -n "$JELLYFIN_SERVICE" ]]; then

    for property in \
        User \
        Group \
        SupplementaryGroups \
        PrivateDevices \
        DevicePolicy \
        DeviceAllow \
        ProtectSystem \
        ProtectHome \
        NoNewPrivileges \
        RestrictAddressFamilies
    do

        VALUE="$(
            systemctl show "$JELLYFIN_SERVICE" \
                -p "$property" \
                --value \
                2>/dev/null
        )"

        printf "  %-24s %s\n" "$property:" "${VALUE:-<not set>}"

    done

    PRIVATE_DEVICES="$(
        systemctl show "$JELLYFIN_SERVICE" \
            -p PrivateDevices \
            --value \
            2>/dev/null
    )"

    if [[ "$PRIVATE_DEVICES" == "yes" ]]; then
        fail "PrivateDevices=yes may block GPU device access"
    else
        pass "PrivateDevices is not blocking GPU devices"
    fi

fi

###############################################################################
# GPU discovery
###############################################################################

section "GPU detection"

HAS_INTEL=0
HAS_NVIDIA=0
HAS_AMD=0

if command_exists lspci; then

    GPU_LIST="$(lspci 2>/dev/null | grep -Ei \
        'VGA compatible controller|3D controller|Display controller' || true)"

    if [[ -n "$GPU_LIST" ]]; then

        echo "$GPU_LIST" | sed 's/^/  /'

        if echo "$GPU_LIST" | grep -qi intel; then
            HAS_INTEL=1
            pass "Intel GPU detected"
        fi

        if echo "$GPU_LIST" | grep -qi nvidia; then
            HAS_NVIDIA=1
            pass "NVIDIA GPU detected"
        fi

        if echo "$GPU_LIST" | grep -qi amd; then
            HAS_AMD=1
            pass "AMD GPU detected"
        fi

    else

        warn "No GPU detected through lspci"

    fi

else

    warn "lspci not installed; GPU detection is limited"

fi

###############################################################################
# DRI devices
###############################################################################

section "DRI devices"

DRI_DEVICES=()

if [[ -d /dev/dri ]]; then

    pass "/dev/dri exists"

    for device in /dev/dri/renderD*; do

        [[ -e "$device" ]] || continue

        DRI_DEVICES+=("$device")

        echo
        info "Device: $device"

        ls -l "$device" | sed 's/^/         /'

        OWNER_GROUP="$(stat -c '%U:%G' "$device" 2>/dev/null || true)"
        MODE="$(stat -c '%A (%a)' "$device" 2>/dev/null || true)"

        info "Owner/group: $OWNER_GROUP"
        info "Permissions: $MODE"

        if [[ -n "$JELLYFIN_USER" ]]; then

            if sudo -u "$JELLYFIN_USER" test -r "$device"; then
                pass "$JELLYFIN_USER can read $device"
            else
                fail "$JELLYFIN_USER cannot read $device"
            fi

            if sudo -u "$JELLYFIN_USER" test -w "$device"; then
                pass "$JELLYFIN_USER can write $device"
            else
                warn "$JELLYFIN_USER cannot write $device"
            fi

        fi

    done

    if [[ "${#DRI_DEVICES[@]}" -eq 0 ]]; then
        warn "/dev/dri exists but no renderD* devices were found"
    fi

else

    warn "/dev/dri does not exist"

    if [[ "$HAS_INTEL" -eq 1 || "$HAS_AMD" -eq 1 ]]; then
        fail "Intel/AMD GPU detected but /dev/dri is missing"
    fi

fi

###############################################################################
# GPU group permissions
###############################################################################

section "GPU group permissions"

if [[ -n "$JELLYFIN_USER" ]]; then

    USER_GROUPS="$(id -nG "$JELLYFIN_USER" 2>/dev/null || true)"

    if getent group render >/dev/null 2>&1; then

        RENDER_GID="$(getent group render | cut -d: -f3)"

        info "render group GID: $RENDER_GID"

        if echo " $USER_GROUPS " | grep -q " render "; then
            pass "$JELLYFIN_USER belongs to render"
        else
            warn "$JELLYFIN_USER is NOT a member of render"
        fi

    else

        info "No render group exists"

    fi

    if getent group video >/dev/null 2>&1; then

        VIDEO_GID="$(getent group video | cut -d: -f3)"

        info "video group GID: $VIDEO_GID"

        if echo " $USER_GROUPS " | grep -q " video "; then
            pass "$JELLYFIN_USER belongs to video"
        else
            warn "$JELLYFIN_USER is NOT a member of video"
        fi

    fi

fi

###############################################################################
# Locate FFmpeg
###############################################################################

section "Jellyfin FFmpeg"

FFMPEG_CANDIDATES=(
    "/usr/lib/jellyfin-ffmpeg/ffmpeg"
    "/usr/lib/jellyfin-ffmpeg7/ffmpeg"
    "/usr/lib/jellyfin-ffmpeg6/ffmpeg"
    "/usr/lib/jellyfin-ffmpeg5/ffmpeg"
    "/usr/bin/ffmpeg"
    "/usr/local/bin/ffmpeg"
)

for candidate in "${FFMPEG_CANDIDATES[@]}"; do

    if [[ -x "$candidate" ]]; then
        FFMPEG="$candidate"
        break
    fi

done

if [[ -z "$FFMPEG" ]] && command_exists ffmpeg; then
    FFMPEG="$(command -v ffmpeg)"
fi

if [[ -n "$FFMPEG" ]]; then

    pass "FFmpeg found: $FFMPEG"

    VERSION="$(
        "$FFMPEG" -version 2>/dev/null |
        head -n 1
    )"

    info "$VERSION"

    if echo "$VERSION" | grep -qi jellyfin; then
        pass "Using Jellyfin FFmpeg"
    else
        warn "This does not appear to be jellyfin-ffmpeg"
        info "Jellyfin recommends its modified jellyfin-ffmpeg build."
    fi

else

    fail "Could not locate FFmpeg"

fi

###############################################################################
# FFmpeg encoder helper
###############################################################################

has_encoder()
{
    local encoder="$1"

    [[ -n "$FFMPEG" ]] || return 1

    "$FFMPEG" -hide_banner -encoders 2>/dev/null |
        awk '{print $2}' |
        grep -qx "$encoder"
}

###############################################################################
# Intel QSV
###############################################################################

section "Intel Quick Sync (QSV)"

if [[ "$HAS_INTEL" -eq 0 ]]; then

    info "No Intel GPU detected; skipping QSV."

else

    QSV_AVAILABLE=1

    if [[ -z "$FFMPEG" ]]; then
        QSV_AVAILABLE=0
        fail "Cannot test QSV because FFmpeg was not found"
    fi

    if has_encoder h264_qsv; then
        pass "FFmpeg has h264_qsv encoder"
    else
        QSV_AVAILABLE=0
        fail "FFmpeg does NOT contain h264_qsv"
    fi

    if has_encoder hevc_qsv; then
        pass "FFmpeg has hevc_qsv encoder"
    else
        warn "FFmpeg does not contain hevc_qsv"
    fi

    if [[ "${#DRI_DEVICES[@]}" -eq 0 ]]; then
        QSV_AVAILABLE=0
        fail "No DRI render device available for QSV"
    fi

    if command_exists vainfo; then
        VAINFO="$(command -v vainfo)"
    elif [[ -x "/usr/lib/jellyfin-ffmpeg/vainfo" ]]; then
        VAINFO="/usr/lib/jellyfin-ffmpeg/vainfo"
    fi

    if [[ -n "$VAINFO" && "${#DRI_DEVICES[@]}" -gt 0 ]]; then

        for device in "${DRI_DEVICES[@]}"; do

            echo
            info "Testing VA-API/QSV device: $device"

            if sudo -u "$JELLYFIN_USER" \
                "$VAINFO" \
                --display drm \
                --device "$device" \
                >/tmp/jellyfin-vainfo.$$ 2>&1
            then

                pass "$JELLYFIN_USER can initialize VA-API on $device"

                DRIVER="$(
                    grep -Ei \
                        'Driver version|iHD|i965' \
                        /tmp/jellyfin-vainfo.$$ |
                    head -n 3
                )"

                if [[ -n "$DRIVER" ]]; then
                    echo "$DRIVER" |
                        sed 's/^/         /'
                fi

            else

                warn "$JELLYFIN_USER could not initialize VA-API on $device"

                sed 's/^/         /' \
                    /tmp/jellyfin-vainfo.$$ |
                    tail -n 20

            fi

        done

        rm -f /tmp/jellyfin-vainfo.$$

    else

        warn "vainfo unavailable; cannot inspect Intel VA-API driver"

    fi

    ###########################################################################
    # Actual QSV encode
    ###########################################################################

    if [[ "$QSV_AVAILABLE" -eq 1 ]]; then

        info "Running actual QSV encode as $JELLYFIN_USER..."

        QSV_LOG="/tmp/jellyfin-qsv-test-$$.log"

        sudo -u "$JELLYFIN_USER" \
            "$FFMPEG" \
            -hide_banner \
            -loglevel error \
            -f lavfi \
            -i "testsrc2=size=320x240:rate=30" \
            -vf "format=nv12,hwupload=extra_hw_frames=64" \
            -frames:v 30 \
            -c:v h264_qsv \
            -f null - \
            >"$QSV_LOG" 2>&1

        QSV_STATUS=$?

        if [[ "$QSV_STATUS" -eq 0 ]]; then
            pass "QSV hardware encode succeeded"
        else
            fail "QSV hardware encode FAILED"

            sed 's/^/         /' "$QSV_LOG"
        fi

        rm -f "$QSV_LOG"

    fi

fi

###############################################################################
# VA-API
###############################################################################

section "VA-API"

if [[ "$HAS_INTEL" -eq 0 && "$HAS_AMD" -eq 0 ]]; then

    info "No Intel or AMD GPU detected; skipping VA-API."

else

    VAAPI_AVAILABLE=1

    if [[ -z "$FFMPEG" ]]; then
        VAAPI_AVAILABLE=0
        fail "Cannot test VA-API because FFmpeg was not found"
    fi

    if has_encoder h264_vaapi; then
        pass "FFmpeg has h264_vaapi encoder"
    else
        VAAPI_AVAILABLE=0
        fail "FFmpeg does NOT contain h264_vaapi"
    fi

    if has_encoder hevc_vaapi; then
        pass "FFmpeg has hevc_vaapi encoder"
    else
        warn "FFmpeg does not contain hevc_vaapi"
    fi

    if [[ "${#DRI_DEVICES[@]}" -eq 0 ]]; then
        VAAPI_AVAILABLE=0
        fail "No /dev/dri/renderD* device available"
    fi

    if [[ "$VAAPI_AVAILABLE" -eq 1 ]]; then

        for device in "${DRI_DEVICES[@]}"; do

            echo
            info "Testing VA-API encode on $device..."

            VAAPI_LOG="/tmp/jellyfin-vaapi-test-$$.log"

            sudo -u "$JELLYFIN_USER" \
                "$FFMPEG" \
                -hide_banner \
                -loglevel error \
                -vaapi_device "$device" \
                -f lavfi \
                -i "testsrc2=size=320x240:rate=30" \
                -vf "format=nv12,hwupload" \
                -frames:v 30 \
                -c:v h264_vaapi \
                -f null - \
                >"$VAAPI_LOG" 2>&1

            VAAPI_STATUS=$?

            if [[ "$VAAPI_STATUS" -eq 0 ]]; then

                pass "VA-API hardware encode succeeded on $device"

            else

                warn "VA-API encode failed on $device"

                sed 's/^/         /' "$VAAPI_LOG"

            fi

            rm -f "$VAAPI_LOG"

        done

    fi

fi

###############################################################################
# NVIDIA
###############################################################################

section "NVIDIA NVENC"

if [[ "$HAS_NVIDIA" -eq 0 ]]; then

    info "No NVIDIA GPU detected; skipping NVENC."

else

    NVENC_AVAILABLE=1

    ###########################################################################
    # NVIDIA driver
    ###########################################################################

    if command_exists nvidia-smi; then

        pass "nvidia-smi found"

        echo
        nvidia-smi \
            --query-gpu=name,driver_version \
            --format=csv,noheader 2>&1 |
            sed 's/^/  /'

        if nvidia-smi >/dev/null 2>&1; then
            pass "NVIDIA driver is responding"
        else
            fail "nvidia-smi failed to communicate with the NVIDIA driver"
            NVENC_AVAILABLE=0
        fi

    else

        fail "nvidia-smi not found"
        fail "NVIDIA driver/tools may not be installed"
        NVENC_AVAILABLE=0

    fi

    ###########################################################################
    # FFmpeg encoders
    ###########################################################################

    if [[ -z "$FFMPEG" ]]; then

        NVENC_AVAILABLE=0
        fail "Cannot test NVENC because FFmpeg was not found"

    else

        if has_encoder h264_nvenc; then
            pass "FFmpeg has h264_nvenc encoder"
        else
            fail "FFmpeg does NOT contain h264_nvenc"
            NVENC_AVAILABLE=0
        fi

        if has_encoder hevc_nvenc; then
            pass "FFmpeg has hevc_nvenc encoder"
        else
            warn "FFmpeg does not contain hevc_nvenc"
        fi

    fi

    ###########################################################################
    # Jellyfin user GPU access
    ###########################################################################

    if command_exists nvidia-smi; then

        info "Testing NVIDIA access as $JELLYFIN_USER..."

        if sudo -u "$JELLYFIN_USER" nvidia-smi >/dev/null 2>&1; then
            pass "$JELLYFIN_USER can access NVIDIA GPU"
        else
            fail "$JELLYFIN_USER cannot access NVIDIA GPU through nvidia-smi"
            NVENC_AVAILABLE=0
        fi

    fi

    ###########################################################################
    # Actual NVENC encode
    ###########################################################################

    if [[ "$NVENC_AVAILABLE" -eq 1 ]]; then

        info "Running actual NVENC encode as $JELLYFIN_USER..."

        NVENC_LOG="/tmp/jellyfin-nvenc-test-$$.log"

        sudo -u "$JELLYFIN_USER" \
            "$FFMPEG" \
            -hide_banner \
            -loglevel error \
            -f lavfi \
            -i "testsrc2=size=320x240:rate=30" \
            -vf "format=nv12,hwupload_cuda" \
            -frames:v 30 \
            -c:v h264_nvenc \
            -f null - \
            >"$NVENC_LOG" 2>&1

        NVENC_STATUS=$?

        if [[ "$NVENC_STATUS" -eq 0 ]]; then

            pass "NVENC hardware encode succeeded"

        else

            fail "NVENC hardware encode FAILED"

            sed 's/^/         /' "$NVENC_LOG"

        fi

        rm -f "$NVENC_LOG"

    fi

fi

###############################################################################
# Media permissions
###############################################################################

section "Media permissions"

if [[ -z "$MEDIA_PATH" ]]; then

    info "No media directory supplied."
    info "Pass one as an argument to test it."

else

    if [[ ! -d "$MEDIA_PATH" ]]; then

        fail "Media directory does not exist: $MEDIA_PATH"

    else

        pass "Media directory exists: $MEDIA_PATH"

        stat -c \
            '  Permissions: %A (%a)  Owner: %U:%G' \
            "$MEDIA_PATH" 2>/dev/null

        if sudo -u "$JELLYFIN_USER" test -r "$MEDIA_PATH"; then
            pass "Jellyfin user can read media directory"
        else
            fail "Jellyfin user cannot read media directory"
        fi

        if sudo -u "$JELLYFIN_USER" test -x "$MEDIA_PATH"; then
            pass "Jellyfin user can traverse media directory"
        else
            fail "Jellyfin user cannot traverse media directory"
        fi

        # Check every parent directory.
        CURRENT="$MEDIA_PATH"

        while [[ "$CURRENT" != "/" ]]; do

            if sudo -u "$JELLYFIN_USER" test -x "$CURRENT"; then
                pass "Can traverse $CURRENT"
            else
                fail "Cannot traverse $CURRENT"
            fi

            CURRENT="$(dirname "$CURRENT")"

        done

    fi

fi

###############################################################################
# Transcode directory
###############################################################################

section "Transcode/cache directory"

if [[ -z "$TRANSCODE_PATH" ]]; then

    for candidate in \
        "/var/cache/jellyfin" \
        "/var/lib/jellyfin/transcodes" \
        "/var/lib/jellyfin/cache"
    do

        if [[ -d "$candidate" ]]; then
            TRANSCODE_PATH="$candidate"
            break
        fi

    done

fi

if [[ -z "$TRANSCODE_PATH" ]]; then

    warn "Could not determine Jellyfin transcode directory"
    info "Set TRANSCODE_PATH=/path/to/transcodes if needed."

else

    info "Transcode path: $TRANSCODE_PATH"

    if [[ -d "$TRANSCODE_PATH" ]]; then

        pass "Transcode directory exists"

        stat -c \
            '  Permissions: %A (%a)  Owner: %U:%G' \
            "$TRANSCODE_PATH" 2>/dev/null

        if sudo -u "$JELLYFIN_USER" test -r "$TRANSCODE_PATH"; then
            pass "Jellyfin user can read transcode directory"
        else
            fail "Jellyfin user cannot read transcode directory"
        fi

        if sudo -u "$JELLYFIN_USER" test -w "$TRANSCODE_PATH"; then
            pass "Jellyfin user can write to transcode directory"
        else
            fail "Jellyfin user cannot write to transcode directory"
        fi

        TEST_FILE="$TRANSCODE_PATH/.jellyfin-hw-test-$$"

        if sudo -u "$JELLYFIN_USER" touch "$TEST_FILE" 2>/dev/null; then
            rm -f "$TEST_FILE"
            pass "Jellyfin user can create files there"
        else
            fail "Jellyfin user cannot create files there"
        fi

    else

        fail "Transcode directory does not exist"

    fi

fi

###############################################################################
# SELinux
###############################################################################

section "SELinux / AppArmor"

if command_exists getenforce; then

    SELINUX="$(getenforce 2>/dev/null || true)"

    case "$SELINUX" in

        Enforcing)
            warn "SELinux is enforcing"
            info "SELinux policy could restrict Jellyfin GPU/media access."
            ;;

        Permissive)
            warn "SELinux is permissive"
            ;;

        Disabled)
            pass "SELinux is disabled"
            ;;

        *)
            info "Could not determine SELinux state"
            ;;

    esac

else

    info "SELinux tools not installed"

fi

if command_exists aa-status; then

    if aa-status --enabled >/dev/null 2>&1; then

        warn "AppArmor is enabled"

        if aa-status 2>/dev/null | grep -qi jellyfin; then
            warn "An AppArmor profile mentioning Jellyfin was detected"
        fi

    else

        pass "AppArmor is not enabled"

    fi

else

    info "AppArmor tools not installed"

fi

###############################################################################
# Recent Jellyfin logs
###############################################################################

section "Recent Jellyfin transcoding errors"

if [[ -n "$JELLYFIN_SERVICE" ]]; then

    LOGS="$(
        journalctl \
            -u "$JELLYFIN_SERVICE" \
            --no-pager \
            -n 300 \
            2>/dev/null |
        grep -Ei \
            'ffmpeg|transcod|nvenc|cuda|qsv|vaapi|permission denied|access denied|dri|renderD' |
        tail -n 40
    )"

    if [[ -n "$LOGS" ]]; then

        warn "Relevant recent log messages were found:"

        echo "$LOGS" |
            sed 's/^/         /'

    else

        pass "No obvious recent hardware-transcoding errors found"

    fi

fi

###############################################################################
# Final summary
###############################################################################

section "RESULT"

echo
echo "  PASS : $PASS"
echo "  WARN : $WARN"
echo "  FAIL : $FAIL"
echo

if [[ "$HAS_INTEL" -eq 1 ]]; then
    echo "  Intel GPU detected: YES"
else
    echo "  Intel GPU detected: NO"
fi

if [[ "$HAS_NVIDIA" -eq 1 ]]; then
    echo "  NVIDIA GPU detected: YES"
else
    echo "  NVIDIA GPU detected: NO"
fi

if [[ "$HAS_AMD" -eq 1 ]]; then
    echo "  AMD GPU detected: YES"
else
    echo "  AMD GPU detected: NO"
fi

echo

if [[ "$FAIL" -eq 0 ]]; then

    if [[ "$WARN" -eq 0 ]]; then
        echo -e "  ${GREEN}OVERALL: Hardware transcoding prerequisites look good.${RESET}"
    else
        echo -e "  ${YELLOW}OVERALL: No hard failures, but review the warnings.${RESET}"
    fi

else

    echo -e "  ${RED}OVERALL: One or more hardware transcoding checks failed.${RESET}"
    echo
    echo "  The failures above should be investigated before"
    echo "  troubleshooting Jellyfin transcoding itself."

fi

echo
echo "  NOTE: A successful FFmpeg hardware test means the"
echo "  Jellyfin service user can actually access the accelerator."
echo "  Jellyfin still needs the corresponding HWA method enabled"
echo "  in Dashboard -> Playback -> Transcoding."

echo

###############################################################################
# Exit status
###############################################################################

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
else
    exit 0
fi
