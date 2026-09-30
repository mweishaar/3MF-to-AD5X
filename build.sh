#!/bin/bash
# Build a Linux build of 3MF To AD5X.
#
#   ./build.sh               build for this machine
#
# This needs Python 3.8+ with Tk (Tcl/Tk 8.6+). On Debian/Ubuntu that means
# installing the "python3-tk" system package:
#
#     sudo apt install python3-tk        # Debian / Ubuntu / Mint / Pop!_OS
#     sudo dnf install python3-tkinter   # Fedora / RHEL
#     sudo pacman -S tk                  # Arch / Manjaro
#
# The build is NOT signed (there is no signing on Linux), and it produces a
# single-folder app at dist/3MF-To-AD5X/ that you can keep, zip, or share.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd -P)"

APP_SLUG="3MF-To-AD5X"
APP_NAME="3MF To AD5X"
VENV="$ROOT/.venv-build"

die() { printf '\n\033[31merror:\033[0m %s\n\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $arg" ;;
    esac
done

# The Python used to build (override with PYTHON=/path/to/python3).
PYTHON="${PYTHON:-python3}"

# ---------------------------------------------------------------- prerequisites
case "$(uname -s)" in
    Linux) ;;
    Darwin) die "this script builds a Linux app; on macOS use build_mac.sh (on Windows, build_exe.bat)." ;;
    *) die "unsupported OS: $(uname -s)" ;;
esac

step "Checking tools"
command -v "$PYTHON" >/dev/null 2>&1 || die "'$PYTHON' not found. Install Python 3.8+, then run this again."
PY_BIN="$(command -v "$PYTHON")"
note "python  : $PY_BIN ($("$PY_BIN" -V 2>&1))"

[ -f "$ROOT/ad5x_template.json" ] || die "ad5x_template.json is missing from $ROOT - cannot build."

# ---------------------------------------------------------------- python + Tk
step "Checking Python / Tk"

if ! "$PY_BIN" -c "import tkinter" >/dev/null 2>&1; then
    cat >&2 <<EOF

$(printf '\033[31m')error:$(printf '\033[0m') this Python has no tkinter - the GUI needs Tcl/Tk.
    python  : $PY_BIN

  Install the system package, depending on your distro:
        Debian / Ubuntu / Mint / Pop!_OS :  sudo apt install python3-tk
        Fedora / RHEL                    :  sudo dnf install python3-tkinter
        Arch / Manjaro                   :  sudo pacman -S tk
        openSUSE                         :  sudo zypper install python3-tk
  then run this script again.

EOF
    exit 1
fi
TK_VER="$("$PY_BIN" -c 'import tkinter; print(tkinter.TkVersion)')"

# Distros ship Tcl/Tk 8.6+; anything older (8.5) can't render PNG icons at all.
if printf '%s\n' "$TK_VER" | awk -F. '$1 < 8 || ($1 == 8 && $2 < 6) {exit 1}'; then
    : # Tk 8.6 / 9.x - good
else
    die "this Python uses Tcl/Tk $TK_VER; Tcl/Tk 8.6 or newer is required (install a newer Python / Tk)."
fi
note "Tk $TK_VER - ok"

# ---------------------------------------------------------------- pyinstaller
step "Setting up the build environment"
if [ ! -x "$VENV/bin/python" ]; then
    "$PY_BIN" -m venv "$VENV" || die "could not create a virtualenv at $VENV"
fi
VPY="$VENV/bin/python"
"$VPY" -m pip install --quiet --upgrade pip >/dev/null
"$VPY" -c "import PyInstaller" >/dev/null 2>&1 || "$VPY" -m pip install --quiet --upgrade pyinstaller
note "pyinstaller $("$VPY" -m PyInstaller --version 2>/dev/null | tail -1) in $VENV"

EXTRA=()
"$VPY" -c "import tkinterdnd2" >/dev/null 2>&1 && EXTRA+=(--collect-all tkinterdnd2) && note "including drag & drop (tkinterdnd2)"
"$VPY" -c "import PIL.ImageTk" >/dev/null 2>&1 && EXTRA+=(--hidden-import PIL.ImageTk) && note "including Pillow (smooth previews)"

# The app icon is optional (the GUI finds it at runtime when present); some
# older checkouts don't ship assets/appicon.png, so only bundle it if it exists.
ICON_ARGS=()
[ -f "$ROOT/assets/appicon.png" ] && ICON_ARGS+=(--add-data "$ROOT/assets/appicon.png:assets") && note "including app icon"

# ---------------------------------------------------------------- build
step "Building $APP_SLUG (a minute or two)"
rm -rf "$ROOT/build" "$ROOT/dist" "$ROOT/$APP_SLUG.spec"

set -x
"$VPY" -m PyInstaller \
    --noconfirm --clean --onedir \
    --name "$APP_SLUG" \
    --add-data "$ROOT/ad5x_template.json:." \
    ${ICON_ARGS[@]+"${ICON_ARGS[@]}"} \
    ${EXTRA[@]+"${EXTRA[@]}"} \
    "$ROOT/bambu2ad5x_gui.py"
set +x

APP="$ROOT/dist/$APP_SLUG"
[ -d "$APP" ] || die "PyInstaller did not produce $APP"
EXE="$APP/$APP_SLUG"
[ -x "$EXE" ] || die "no executable at $EXE"

# ---------------------------------------------------------------- verify
step "Verifying"
"$VENV/bin/python" - "$APP" <<'PY'
import os, sys
# the template has to travel inside the bundle or the app cannot convert anything
found = []
for root, _, files in os.walk(sys.argv[1]):
    if "ad5x_template.json" in files:
        found.append(os.path.join(root, "ad5x_template.json"))
print("    ad5x_template.json bundled: %s" % (found[0] if found else "MISSING"))
sys.exit(0 if found else 1)
PY

# The smoke test opens a window, so it needs a display. On a headless build
# machine skip it - the folder is still fine to copy to a desktop.
step "Smoke-testing the app"
if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    SELFTEST_OUT="$("$EXE" --selftest 2>&1)" && SELFTEST_RC=0 || SELFTEST_RC=$?
    printf '    %s\n' "$SELFTEST_OUT"
    [ "$SELFTEST_RC" = 0 ] || die "the packaged app failed its self-test (exit $SELFTEST_RC)"

    # also confirm the real GUI stays up, not just that --selftest returns
    "$EXE" &
    APP_PID=$!
    sleep 6
    if kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        note "the GUI launched and stayed running."
    else
        wait "$APP_PID" 2>/dev/null || true
        die "the GUI exited immediately. Run it from a terminal to see why:  '$EXE'"
    fi
else
    note "no display here - skipping the window smoke test. Try the app on a desktop."
fi

# ---------------------------------------------------------------- done
rm -rf "$ROOT/build" "$ROOT/$APP_SLUG.spec"
rm -rf "$VENV"          # keep the repo clean; rebuilds recreate it

cat <<EOF

$(printf '\033[1;32mDone!\033[0m')  $APP/

    Test it:      "$EXE"                 (or double-click it in a file manager)
    Keep it:      copy the whole '$APP' folder anywhere / zip it

    On GNOME you may want an app icon; the window already shows one at runtime.

EOF