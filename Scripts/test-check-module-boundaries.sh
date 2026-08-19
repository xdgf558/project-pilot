#!/bin/bash
# check-module-boundaries.sh 的测试(P0-02)
#
# 边界检查脚本是整个分层纪律的承重件,但它第一版带着两个真 bug 上线:
#   - @_exported import 能绕过 import 正则(漏报)
#   - 多行块注释被判成违规(误报)
# 手工冒烟没抓住。所以这个检查器本身必须有测试。
#
# 做法:往源码树临时投放 fixture,断言检查器的退出码,然后清理。
# 清理由 trap 保证,中途被杀也不会留下垃圾。

set -uo pipefail
cd "$(dirname "$0")/.."

CHECK="Scripts/check-module-boundaries.sh"
CORE_DIR="Sources/PilotCore"
INFRA_DIR="Sources/PilotInfrastructure"
FIXTURE=""
MANIFEST_BACKUP=""

cleanup() {
    [ -n "$FIXTURE" ] && rm -f "$FIXTURE"
    if [ -n "$MANIFEST_BACKUP" ] && [ -f "$MANIFEST_BACKUP" ]; then
        mv -f "$MANIFEST_BACKUP" Package.swift
    fi
}
trap cleanup EXIT INT TERM

pass=0
fail=0

# $1=用例名 $2=目标目录 $3=期望退出码 $4=文件内容
case_file() {
    local name="$1" dir="$2" want="$3" body="$4"
    FIXTURE="$dir/_fixture_$$.swift"
    printf '%s\n' "$body" > "$FIXTURE"
    "$CHECK" >/dev/null 2>&1
    local got=$?
    rm -f "$FIXTURE"; FIXTURE=""
    if [ "$got" -eq "$want" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  \033[31m✗\033[0m %s  (期望退出码 %s,实际 %s)\n' "$name" "$want" "$got"
        fail=$((fail + 1))
    fi
}

echo "基线"
"$CHECK" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    printf '  \033[32m✓\033[0m 干净代码树通过\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m 干净代码树应通过但失败了\n'; fail=$((fail + 1))
fi

echo
echo "应当抓到(违规)"
case_file "裸 import SwiftUI"            "$CORE_DIR"  1 'import SwiftUI'
case_file "@_exported 绕过"              "$CORE_DIR"  1 '@_exported import AppKit'
case_file "@_implementationOnly 绕过"    "$CORE_DIR"  1 '@_implementationOnly import Network'
case_file "多个 attribute 叠加"          "$CORE_DIR"  1 '@preconcurrency @_exported import SwiftUI'
case_file "缩进后的 import"              "$CORE_DIR"  1 '    import ServiceManagement'
case_file "Core 里用 FileManager"        "$CORE_DIR"  1 'import Foundation
public let x = FileManager.default'
case_file "Core 里用 Process"            "$CORE_DIR"  1 'import Foundation
public func f() -> Process { Process() }'
case_file "Infrastructure 里拼 shell"    "$INFRA_DIR" 1 'public let shell = "/bin/sh"'
case_file "env bash 变体"                "$INFRA_DIR" 1 'public let shell = "/usr/bin/env bash"'

echo
echo "不应误报(合法)"
case_file "行注释提到 import SwiftUI"    "$CORE_DIR"  0 '// import SwiftUI'
case_file "文档注释提到 FileManager"     "$CORE_DIR"  0 '/// 本模块禁止 FileManager 与 Process。'
case_file "多行块注释包住违规"           "$CORE_DIR"  0 '/*
import SwiftUI
let x = FileManager.default
*/
public let ok = 1'
case_file "块注释与代码同行"             "$CORE_DIR"  0 'public let ok = 1 /* FileManager */'
case_file "允许 import Foundation"       "$CORE_DIR"  0 'import Foundation
public let now = Date()'

echo
echo "依赖方向声明(检查 3)"
MANIFEST_BACKUP="Package.swift.testbak"
cp Package.swift "$MANIFEST_BACKUP"
# 给 PilotCore 硬塞一个依赖,断言检查器能发现
python3 - <<'PY'
import io
s = io.open('Package.swift', encoding='utf-8').read()
old = '''        .target(
            name: "PilotCore",
            swiftSettings: strictSettings
        ),'''
new = '''        .target(
            name: "PilotCore",
            dependencies: ["PilotInfrastructure"],
            swiftSettings: strictSettings
        ),'''
assert old in s, "anchor not found"
io.open('Package.swift', 'w', encoding='utf-8').write(s.replace(old, new))
PY
"$CHECK" >/dev/null 2>&1
got=$?
mv -f "$MANIFEST_BACKUP" Package.swift; MANIFEST_BACKUP=""
if [ "$got" -eq 1 ]; then
    printf '  \033[32m✓\033[0m PilotCore 声明依赖时被拒\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m PilotCore 声明依赖应被拒(期望 1,实际 %s)\n' "$got"; fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m✓ %s 个用例全部通过\033[0m\n' "$pass"
    exit 0
else
    printf '\033[31m✗ %s 通过,%s 失败\033[0m\n' "$pass" "$fail"
    exit 1
fi
