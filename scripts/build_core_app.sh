#!/bin/zsh
# 兼容旧构建命令；当前剪坊统一由 build_release_app.sh 构建。
set -euo pipefail
root="${0:A:h:h}"
exec "$root/scripts/build_release_app.sh" \
  --app "${1:-$root/dist/剪坊.app}" \
  --log-dir "${2:-$root/build-logs/release}"
