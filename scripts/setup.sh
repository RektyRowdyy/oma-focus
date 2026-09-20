#!/usr/bin/env bash
# One-time setup for oma-focus: install the privileged helper and grant this
# user permission to run it without a password.
#
#   ./scripts/setup.sh            install
#   ./scripts/setup.sh --remove   undo
#
# Why this exists: blocking a site means writing /etc/hosts and the Chromium
# managed-policy directory, both root-owned. Without this, every focus toggle
# would put a password prompt on screen. With it, the plugin can invoke exactly
# one root-owned program and nothing else.
#
# What you are agreeing to is written out in full by --remove's counterpart in
# the README's "Privilege boundary" section. The short version: any process
# running as you can then map hostnames of its choosing to 127.0.0.1 without a
# password. It cannot point them anywhere else, and it cannot write any other
# file, because the helper hardcodes both.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PLUGIN_SRC="$(dirname -- "$SCRIPT_DIR")"
SOURCE_HELPER="$PLUGIN_SRC/bin/oma-focus-block"

INSTALLED_HELPER=/usr/local/bin/oma-focus-block
SUDOERS_FILE=/etc/sudoers.d/oma-focus

die() {
  echo "oma-focus setup: $1" >&2
  exit 1
}

# The user to write the rule for — resolved before escalating, since $USER is
# root's once we are root.
TARGET_USER=${SUDO_USER:-${PKEXEC_UID:+$(id -un "$PKEXEC_UID")}}
TARGET_USER=${TARGET_USER:-$(id -un)}

ACTION=install
case ${1-} in
"") ;;
--remove | --uninstall) ACTION=remove ;;
-h | --help)
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
*) die "unknown option '$1' (expected --remove)" ;;
esac

require_root() {
  if ((EUID == 0)); then
    return
  fi
  echo "oma-focus setup needs root to install $INSTALLED_HELPER and $SUDOERS_FILE."
  if [[ -t 0 ]]; then
    exec sudo -- "$0" "$@"
  elif command -v pkexec >/dev/null 2>&1; then
    exec pkexec "$0" "$@"
  else
    die "no terminal and no pkexec available; re-run this from a terminal"
  fi
}

do_install() {
  [[ -f $SOURCE_HELPER ]] || die "cannot find $SOURCE_HELPER"

  # Installed root-owned and not writable by the user. This is the whole basis
  # of the sudoers rule being safe: a NOPASSWD grant on a script the user can
  # edit would be a one-line path to root.
  install -m 0755 -o root -g root -T "$SOURCE_HELPER" "$INSTALLED_HELPER"
  echo "Installed $INSTALLED_HELPER"

  id -u "$TARGET_USER" >/dev/null 2>&1 || die "no such user '$TARGET_USER'"
  # A username with whitespace or a comment character would corrupt the file.
  [[ $TARGET_USER =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "refusing to write a sudoers rule for the unusual username '$TARGET_USER'"

  local staged
  staged=$(mktemp) || die "could not create a temporary file"
  printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$INSTALLED_HELPER" >"$staged"

  # Never install a sudoers file without checking it first: a malformed one can
  # lock every user out of sudo on the machine.
  if ! visudo -cqf "$staged"; then
    rm -f -- "$staged"
    die "generated sudoers rule failed validation; nothing was installed"
  fi
  install -m 0440 -o root -g root -T "$staged" "$SUDOERS_FILE"
  rm -f -- "$staged"
  echo "Installed $SUDOERS_FILE (NOPASSWD for $TARGET_USER, that one program only)"
  echo
  echo "Done. Focus toggles are now silent."
}

do_remove() {
  # Clear any block still in place before removing the only tool that can.
  if [[ -x $INSTALLED_HELPER ]]; then
    "$INSTALLED_HELPER" off || echo "warning: could not clear the current block" >&2
  fi
  rm -f -- "$SUDOERS_FILE" && echo "Removed $SUDOERS_FILE"
  rm -f -- "$INSTALLED_HELPER" && echo "Removed $INSTALLED_HELPER"
  echo "Done. /etc/hosts and the browser policy directories are back to how they were."
}

require_root "$@"
case $ACTION in
install) do_install ;;
remove) do_remove ;;
esac
