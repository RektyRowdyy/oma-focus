#!/usr/bin/env bash
# Dev-install oma-focus into the live Omarchy shell.
#
# Always a copy, never a symlink: omarchy-plugin-validate rejects any symlink
# under the plugin folder, and `find` does not dereference a symlink given as
# its own path argument — so a symlinked plugin root reports itself as -type l
# and can never validate. Re-run this after every edit.
#
# Note that a rescan does not reliably re-instantiate Loader-hosted components
# (Panel.qml) or a keepLoaded service (Service.qml); the shell will happily go
# on running the previous build with no warning. Restart the shell before
# judging any change.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PLUGIN_SRC="$(dirname -- "$SCRIPT_DIR")"
PLUGIN_ID="io.github.rektyrowdyy.focus"
PLUGIN_DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

if [[ -e $PLUGIN_DEST || -L $PLUGIN_DEST ]]; then
  echo "Removing existing $PLUGIN_DEST"
  rm -rf -- "$PLUGIN_DEST"
fi

mkdir -p "$(dirname -- "$PLUGIN_DEST")"
cp -r "$PLUGIN_SRC" "$PLUGIN_DEST"
# The live plugin directory is a deployment, not a checkout.
rm -rf -- "$PLUGIN_DEST/.git" "$PLUGIN_DEST/tests" "$PLUGIN_DEST/node_modules"

omarchy-plugin-validate "$PLUGIN_DEST"
echo "Copied to: $PLUGIN_DEST"

omarchy-shell -q shell rescanPlugins || true
echo
echo "Now restart the shell so the service and panel are rebuilt:"
echo "  omarchy-restart-shell"
echo "Then enable it with:"
echo "  omarchy plugin enable $PLUGIN_ID --section right"
