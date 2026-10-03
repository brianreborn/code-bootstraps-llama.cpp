#!/bin/bash
# macOS: double-click in Finder to run start.sh in Terminal.
# Closing the Terminal window sends SIGHUP to start.sh -> serve.sh, which stops the server.
# Runs start.sh through bash, so it works even if a ZIP extraction dropped the execute bit.
cd "$(dirname "$0")" && exec /bin/bash ./start.sh "$@"
