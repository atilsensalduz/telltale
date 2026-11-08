#!/bin/sh
# Build a release Telltale.app and copy it to ~/Applications.
# Run Telltale from there, and switch on "Open Telltale when you log in" in its Settings: macOS records the
# path of the app, so a login item pointing into a build folder breaks the next time you rebuild or clean.
set -e
cd "$(dirname "$0")/.."

Scripts/bundle.sh release
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Telltale.app"
cp -R build/Telltale.app "$HOME/Applications/Telltale.app"
echo "installed $HOME/Applications/Telltale.app"
