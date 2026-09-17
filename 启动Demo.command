#!/bin/zsh
set -e
DEMO_DIR="${0:A:h}"
exec /Applications/Godot.app/Contents/MacOS/Godot --path "$DEMO_DIR"
