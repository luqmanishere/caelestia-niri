#!/usr/bin/env fish
#
# build-plugin.fish — Build the caelestia-niri compiled QML modules
# (Caelestia.* and M3Shapes) into a local prefix, and export QML2_IMPORT_PATH
# into your current fish shell so you can run `qs -p` yourself with hot-reload.
#
# IMPORTANT — this file is meant to be SOURCED from inside `nix develop`:
#
#     nix develop
#     source ./scripts/build-plugin.fish   # builds + exports QML2_IMPORT_PATH
#     qs -p (pwd)                          # then run the shell yourself
#
# Sourcing matters because a child process can't export env vars back to its
# parent. Run inside the devshell so cmake + the plugin build deps are on PATH.

set -l REPO_ROOT (realpath (dirname (status --current-filename))/..)
set -l BUILD_DIR "$REPO_ROOT/build-module"
set -l PREFIX "$REPO_ROOT/.plugin-prefix"
set -l VERSION (if set -q CAELESTIA_VERSION; echo $CAELESTIA_VERSION; else; echo 1.0.0; end)

# Run from inside a nix devshell. If not in one, warn (the build deps would be
# missing); we don't auto re-enter nix because exec-ing inside a source would
# replace the user's interactive shell.
if test -z "$IN_NIX_SHELL"
    echo "build-plugin: not in a nix devshell. Run 'nix develop' first." >&2
    return 1
end

cmake -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DVERSION="$VERSION" \
    -DGIT_REVISION=(git -C "$REPO_ROOT" rev-parse HEAD) \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DINSTALL_QMLDIR=lib/qt6/qml \
    '-DENABLE_MODULES=plugin;m3shapes'
or return 1

cmake --build "$BUILD_DIR"
or return 1

cmake --install "$BUILD_DIR"
or return 1

set -gx QML2_IMPORT_PATH "$PREFIX/lib/qt6/qml"

echo "Plugin built & QML2_IMPORT_PATH exported in this shell:"
echo "  QML2_IMPORT_PATH=$QML2_IMPORT_PATH"
echo "Run the shell yourself:"
echo "  qs -p \"$REPO_ROOT\""
