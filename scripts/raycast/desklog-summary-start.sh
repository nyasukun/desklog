#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Desklog: 要約開始
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Desklog

set -euo pipefail
/usr/bin/open -g 'desklog://summary/start'
