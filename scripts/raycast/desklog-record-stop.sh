#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Desklog: 記録停止
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Desklog

set -euo pipefail
/usr/bin/open -g 'desklog://record/stop'
