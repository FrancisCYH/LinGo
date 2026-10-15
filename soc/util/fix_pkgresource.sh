#!/usr/bin/env bash
set -euo pipefail

# 默认在当前目录查找，也支持传入项目根目录
ROOT="${1:-.}"

shopt -s nullglob

REGGEN_DIRS=(
    "$ROOT"/.bender/git/checkouts/register_interface-*/vendor/lowrisc_opentitan/util/reggen
)

if [ ${#REGGEN_DIRS[@]} -eq 0 ]; then
    echo "Error: reggen directory not found"
    exit 1
fi

for REGGEN in "${REGGEN_DIRS[@]}"; do
    echo "Patching: $REGGEN"

    for file in "$REGGEN"/*.py; do
        [ -f "$file" ] || continue

        if ! grep -qE 'pkg_resources|resource_filename' "$file"; then
            continue
        fi

        # 备份原文件
        cp -n "$file" "$file.bak"

        # 替换导入
        sed -i \
            's/from pkg_resources import resource_filename/from pathlib import Path/' \
            "$file"

        # 替换资源文件路径
        sed -i -E \
            "s/resource_filename\('reggen', '([^']+)'\)/str(Path(__file__).resolve().parent \/ '\1')/g" \
            "$file"

        # 替换版本查询
        sed -i \
            's/^import pkg_resources.*$/from importlib.metadata import version/' \
            "$file"

        sed -i \
            's/pkg_resources.require(p)\[0\].version/version(p)/g' \
            "$file"

        echo "  Patched: $(basename "$file")"
    done

    # 检查剩余引用
    echo "Checking remaining references..."
    if grep -nE 'pkg_resources|resource_filename' "$REGGEN"/*.py; then
        echo "WARNING: Some references remain."
    else
        echo "SUCCESS: All known pkg_resources references removed."
    fi
done