#!/bin/sh
# Startovací skript: stáhne hlavní skript a spustí ho s výchozími volbami.
#   Linux: wget -qO- https://raw.githubusercontent.com/slezacek/Sand-/w11/i|sudo bash
#   macOS: curl -fsSL https://raw.githubusercontent.com/slezacek/Sand-/w11/i|bash
# Další volby: ... |sudo bash -s -- --help
set -e
U=https://raw.githubusercontent.com/slezacek/Sand-/w11/win11-t14/build-win11-t14.sh
F=${TMPDIR:-/tmp}/w11.sh
if command -v curl >/dev/null 2>&1; then curl -fsSL "$U" -o "$F"; else wget -qO "$F" "$U"; fi
if [ $# -eq 0 ]; then
  case $(uname -s) in
    Linux) set -- --usb auto --reboot ;;
    *) set -- --usb auto ;;
  esac
fi
# Skript čte potvrzení z terminálu; stdin je tady rouře po stažení tohoto souboru.
if (: </dev/tty) 2>/dev/null; then exec bash "$F" "$@" </dev/tty; fi
exec bash "$F" "$@"
