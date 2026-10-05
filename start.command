#!/bin/sh
# macOS: double-click in Finder. Closing the window stops the server.
cd "$(dirname "$0")" && exec /bin/sh ./start.sh "$@"
