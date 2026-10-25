#!/bin/bash
# Launch Autodesk Fusion 360 from the fusion-box wineprefix.

set -euo pipefail

PREFIX="${WINEPREFIX_FUSION:-$HOME/.wine-fusion}"
export WINEPREFIX="$PREFIX"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:-fixme-all,err-winediag}"

# End a prior session in THIS prefix — Fusion refuses to run a second instance,
# and WebView2/CER children survive a plain wineserver -k in a detached tree.
#
# Only Wine processes whose WINEPREFIX is this prefix are touched. Fusion
# instances in other prefixes keep running: the container shares the host's
# PID namespace, so a `pkill -f Fusion360.exe` here would also end, e.g.,
# sandboxed instances that overlay this prefix at another path (cx-reloaded's
# test pool). A running Fusion360.exe may hold unsaved work, so it is ended only
# after the user agrees; leftovers of a session whose Fusion is gone are not.

# PIDs of Wine processes (wine-preloader, wine64, wineserver, …) in this prefix.
prefix_wine_pids() {
    local env pid exe
    for env in /proc/[0-9]*/environ; do
        pid=${env#/proc/}
        pid=${pid%/environ}
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        case "${exe##*/}" in wine*) ;; *) continue ;; esac
        tr '\0' '\n' <"$env" 2>/dev/null | grep -qxF "WINEPREFIX=$PREFIX" && echo "$pid"
    done
}

# Ask a yes/no question: a desktop dialog (the host's zenity, through
# distrobox-host-exec inside the container), else the terminal. Without
# either, the answer is no: nothing is killed unasked.
confirm() {
    local zenity=()
    if command -v zenity >/dev/null; then
        zenity=(zenity)
    elif command -v distrobox-host-exec >/dev/null \
            && distrobox-host-exec sh -c 'command -v zenity' >/dev/null 2>&1; then
        zenity=(distrobox-host-exec zenity)
    fi
    if [ ${#zenity[@]} -gt 0 ]; then
        "${zenity[@]}" --question --title="Fusion is already running" --text="$1" \
            --ok-label="End it and restart" --cancel-label="Keep it" 2>/dev/null
        return
    fi
    if [ -t 0 ]; then
        local answer
        read -r -p "$1 [y/N] " answer
        [[ "$answer" == [yY]* ]]
        return
    fi
    echo "$1 — no dialog or terminal to ask; leaving it running." >&2
    return 1
}

mapfile -t STALE < <(prefix_wine_pids)
if [ ${#STALE[@]} -gt 0 ]; then
    for pid in "${STALE[@]}"; do
        if [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = Fusion360.exe ]; then
            confirm "Fusion is already running from $PREFIX. End it (unsaved work is lost) and start a new session?" \
                || exit 0
            break
        fi
    done
    echo "[$(date +%H:%M:%S)] ending ${#STALE[@]} Wine process(es) of the prior session in $PREFIX"
    kill -9 "${STALE[@]}" 2>/dev/null || true
    # WINEPREFIX is exported above, so each -k ends only this prefix's wineserver.
    wineserver -k 2>/dev/null || true
    for ws in "$HOME"/wine-versions/*/bin/wineserver "$HOME"/wine-versions/*/usr/bin/wineserver; do
        [ -x "$ws" ] && "$ws" -k 2>/dev/null || true
    done
    sleep 2
fi

# WINEDLLOVERRIDES:
#   bcp47langs=       — IDM's GetUserLanguages import is unimplemented; without
#                       this override wine aborts before IDM inits.
#   winewayland.drv=b — native Wayland driver (XWayland renders Qt6 as black).
#                       FUSION_FORCE_X11=1 falls back for diagnostics.
#   winemenubuilder.exe= — no host .desktop/MIME/icon entries; they would run
#                       host wine on this prefix, outside the container.
DRIVER_OVERRIDE='winewayland.drv=b;winex11.drv='
if [ "${FUSION_FORCE_X11:-0}" = 1 ]; then
    DRIVER_OVERRIDE='winewayland.drv=;winex11.drv=b'
fi
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:+$WINEDLLOVERRIDES;}${DRIVER_OVERRIDE:+$DRIVER_OVERRIDE;}bcp47langs=;winemenubuilder.exe="

# Wine binary: $WINE_BIN > patched build from build-wine.sh > system wine.
PATCHED_WINE="$HOME/wine-versions/wine-11.10-fusion/bin/wine"
if [ -n "${WINE_BIN:-}" ]; then
    :
elif [ -x "$PATCHED_WINE" ]; then
    WINE_BIN="$PATCHED_WINE"
else
    WINE_BIN="wine"
fi

# winebrowser needs $BROWSER set — its default /usr/bin/<browser> paths don't
# exist in this image, so IDM's OAuth redirect silently fails without this.
export BROWSER=/usr/local/bin/xdg-open

# Force Qt6 to 1:1 pixel scale. Wine's multi-monitor DPI handling breaks
# Qt's hover-driven cursor-shape updates when auto-scaling per screen.
export QT_ENABLE_HIGHDPI_SCALING=0
export QT_AUTO_SCREEN_SCALE_FACTOR=0
export QT_SCALE_FACTOR=1

# Disable Qt's 4ms paint-coalescing idle. On a secondary monitor Fusion
# quiesces after ~6 parent commits — with the default idle, patch 0006's
# vsub can miss the toolbar merge and stay black. See navbar-black-secondary-monitor.
export QT_QPA_UPDATE_IDLE_TIME=0

# FUSION_QTWE_SINGLE_PROCESS=1: diagnostic — collapse Qt6WebEngine into one
# process so patch 0006's cross-process HWND lookup succeeds (Data Panel).
if [ "${FUSION_QTWE_SINGLE_PROCESS:-0}" = 1 ]; then
    export QTWEBENGINE_CHROMIUM_FLAGS="${QTWEBENGINE_CHROMIUM_FLAGS:-} --single-process"
fi

# WebView2 fallbacks (kept for historical Data Panel investigation — see
# project_data_panel_investigation memory. Not needed since the fresh-prefix fix).
if [ "${FUSION_WEBVIEW2_DISABLE_DCOMP:-0}" = 1 ]; then
    export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:-} --disable-direct-composition"
fi
if [ "${FUSION_WEBVIEW2_FORCE_SW:-0}" = 1 ]; then
    export WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="${WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS:-} --disable-direct-composition --disable-gpu --disable-gpu-compositing --use-gl=swiftshader"
fi

# Most-recent Fusion360.exe (auto-update lands versions as sibling hash dirs).
FUSION_EXE=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production" \
    -name Fusion360.exe -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-)

if [ -z "$FUSION_EXE" ]; then
    echo "ERROR: Fusion360.exe not found under $PREFIX/drive_c/Program Files/Autodesk/webdeploy/production"
    echo "Run install-fusion.sh first."
    exit 1
fi

# Follow the desktop's light/dark preference. Fusion's default "Match OS" UI theme reads
# the Windows AppsUseLightTheme value; color-scheme.exe (built here from color-scheme.c)
# sets it and broadcasts the change, so a running Fusion switches live. The desktop side
# is the freedesktop portal setting org.freedesktop.appearance color-scheme
# (1 = prefer dark, 0/2 = light), which GNOME and KDE both provide.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLOR_SCHEME_EXE="$HOME/.cache/fusion-box/color-scheme.exe"
if [ "$SCRIPT_DIR/color-scheme.c" -nt "$COLOR_SCHEME_EXE" ]; then
    mkdir -p "$(dirname "$COLOR_SCHEME_EXE")"
    x86_64-w64-mingw32-gcc -O2 -o "$COLOR_SCHEME_EXE" "$SCRIPT_DIR/color-scheme.c" \
        || echo "WARN: could not build color-scheme.exe; Fusion won't follow the desktop theme"
fi

sync_color_scheme() {
    local scheme=light
    [ -f "$COLOR_SCHEME_EXE" ] || return 0
    case "$(gdbus call --session --dest org.freedesktop.portal.Desktop \
                --object-path /org/freedesktop/portal/desktop \
                --method org.freedesktop.portal.Settings.Read \
                org.freedesktop.appearance color-scheme 2>/dev/null)" in
        *"uint32 1"*) scheme=dark ;;
        "") return 0 ;;  # portal unreachable: leave the prefix as it is
    esac
    "$WINE_BIN" "$COLOR_SCHEME_EXE" "$scheme" >/dev/null 2>&1 || true
}

watch_color_scheme() {
    gdbus monitor --session --dest org.freedesktop.portal.Desktop \
        --object-path /org/freedesktop/portal/desktop 2>/dev/null |
    while read -r line; do
        case "$line" in *"'org.freedesktop.appearance', 'color-scheme'"*) sync_color_scheme ;; esac
    done
}

sync_color_scheme

# Pre-warm IDSDK. Wine's CreateProcess cold-start (~15s) races against
# Fusion's 15s SSO-readiness timeout; losing gives error 3213. Polling
# the IDM log lets a fast start not waste time. Opt out: FUSION_PREWARM_IDM=0.
if [ "${FUSION_PREWARM_IDM:-1}" = 1 ]; then
    IDM_EXE=$(find "$PREFIX/drive_c/Program Files/Autodesk/webdeploy/production" \
        -name AdskIdentityManager.exe -print -quit 2>/dev/null)
    if [ -n "$IDM_EXE" ]; then
        IDM_LOG="$PREFIX/drive_c/users/$USER/AppData/Local/Autodesk/Identity Services/Log/IdServices.log"
        : >"$IDM_LOG" 2>/dev/null || true

        echo "[$(date +%H:%M:%S)] pre-launching IDSDK..."
        PREWARM_T0=$(date +%s.%N)
        "$WINE_BIN" "$IDM_EXE" \
            --process_name Autodesk.IDSDK.DefaultProcess-v2 \
            --server_name Autodesk.IDSDK.DefaultServer-v2 \
            >/dev/null 2>&1 &

        # Marker matches the same "IPC listening" line Fusion's SDK waits on. Cap 45s.
        READY=0
        for i in $(seq 1 90); do
            if [ -s "$IDM_LOG" ] && grep -aq "Starting async call to listen for new connection" "$IDM_LOG" 2>/dev/null; then
                READY=1
                break
            fi
            sleep 0.5
        done

        PREWARM_T1=$(date +%s.%N)
        PREWARM_ELAPSED=$(awk "BEGIN{printf \"%.2f\", $PREWARM_T1 - $PREWARM_T0}")
        if [ "$READY" = 1 ]; then
            echo "[$(date +%H:%M:%S)] IDSDK ready in ${PREWARM_ELAPSED}s; launching Fusion..."
        else
            echo "[$(date +%H:%M:%S)] IDSDK readiness not observed after ${PREWARM_ELAPSED}s - launching anyway"
        fi
    fi
fi

# Qt text engine — Qt 6.8's DirectWrite default breaks under wine's dwrite;
# freetype is least-broken. gdi drops capital I ("Insert" → "nsert").
# Values: freetype (default) | gdi | directwrite (diagnostic).
FUSION_QT_TEXT_ENGINE="${FUSION_QT_TEXT_ENGINE:-freetype}"
case "$FUSION_QT_TEXT_ENGINE" in
    freetype)    QT_PLATFORM_ARG="windows:fontengine=freetype" ;;
    gdi)         QT_PLATFORM_ARG="windows:nodirectwrite" ;;
    directwrite) QT_PLATFORM_ARG="" ;;
    *)           echo "WARN: unknown FUSION_QT_TEXT_ENGINE=$FUSION_QT_TEXT_ENGINE, using default freetype"
                 QT_PLATFORM_ARG="windows:fontengine=freetype" ;;
esac

# Fusion's output goes to a file, not the inherited podman-exec pipe: wine reports those
# pipes as Windows pipes that Node.js can't open (Error: open EBADF), which kills Fusion's
# bundled FremontJs service ("FremontJs is not healthy" in Fusion's log).
FUSION_LOG="$HOME/.cache/fusion-box/fusion.log"
mkdir -p "$(dirname "$FUSION_LOG")"
echo "[$(date +%H:%M:%S)] launching Fusion; output goes to $FUSION_LOG"

watch_color_scheme &
WATCHER=$!
trap 'pkill -P "$WATCHER" 2>/dev/null || true' EXIT

cd "$(dirname "$FUSION_EXE")"
"$WINE_BIN" Fusion360.exe ${QT_PLATFORM_ARG:+-platform "$QT_PLATFORM_ARG"} "$@" \
    >"$FUSION_LOG" 2>&1 </dev/null
