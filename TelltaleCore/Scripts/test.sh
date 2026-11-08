#!/bin/sh
# Run TelltaleCore tests. With full Xcode installed this is just `swift test`.
# With only the Command Line Tools, Swift Testing needs explicit framework, rpath and plugin paths.
cd "$(dirname "$0")/.." || exit 1
D=/Library/Developer/CommandLineTools/Library/Developer
if xcodebuild -version >/dev/null 2>&1; then
  exec swift test "$@"
fi
exec swift test \
  -Xswiftc -F"$D/Frameworks" -Xlinker -F"$D/Frameworks" \
  -Xlinker -rpath -Xlinker "$D/Frameworks" -Xlinker -rpath -Xlinker "$D/usr/lib" \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing \
  "$@"
