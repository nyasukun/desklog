#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Desklog: 記録開始（画面のみ）
# @raycast.mode silent

# Optional parameters:
# @raycast.packageName Desklog

set -euo pipefail
/usr/bin/open -g 'desklog://record/start'
