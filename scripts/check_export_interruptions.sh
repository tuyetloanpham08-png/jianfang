#!/bin/zsh
# 故障注入只使用独立目录、日志和临时磁盘映像；不清理用户已有缓存。
# 可选 JF_TEST_BINARY 指向已经构建的待验收 App 可执行文件。
set -euo pipefail
project_root="${0:A:h:h}"
exec python3 "$project_root/scripts/check_export_interruptions.py" "$@"
