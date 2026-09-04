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

echo "生命周期状态字段收口(检查 2.5)"
# 检查 2.5 是文件定向的(只盯 PilotTask.swift / Job.swift),
# fixture 投放式用例不适用,改用「备份-注入-还原」:
# 在真实文件末尾追加一行可绕过的字段声明,断言检查器变红。
state_field_case() {
    local name="$1" file="$2" line="$3"
    cp "$file" "$file.bak"
    printf '\n%s\n' "$line" >> "$file"
    "$CHECK" >/dev/null 2>&1
    local got=$?
    mv -f "$file.bak" "$file"
    if [ "$got" -eq 1 ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  \033[31m✗\033[0m %s  (期望退出码 1,实际 %s)\n' "$name" "$got"
        fail=$((fail + 1))
    fi
}
state_field_case "PilotTask.stage 改回 public var 被拦下" \
    "$CORE_DIR/Domain/PilotTask.swift" "public var stage: TaskStage = .backlog"
state_field_case "Job.status 改回 public var 被拦下" \
    "$CORE_DIR/Domain/Job.swift" "public var status: JobStatus = .queued"

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
echo "Package.swift 层面的检查(检查 3、4)"

# 每个用例:备份清单 → 变换 → 跑检查 → 还原 → 比对退出码
run_manifest_case() {
    local name="$1" mutate="$2" want="$3"
    MANIFEST_BACKUP="Package.swift.testbak"
    cp Package.swift "$MANIFEST_BACKUP"
    "$mutate"
    "$CHECK" >/dev/null 2>&1
    local got=$?
    mv -f "$MANIFEST_BACKUP" Package.swift; MANIFEST_BACKUP=""
    if [ "$got" -eq "$want" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  \033[31m✗\033[0m %s  (期望退出码 %s,实际 %s)\n' "$name" "$want" "$got"
        fail=$((fail + 1))
    fi
}

# 变换用 sed 而非 python:这些锚点都是单行,sed 够用且没有嵌套引号的坑。
mutate_core_gains_dependency() {
    sed -i '' 's|            name: "PilotCore",|            name: "PilotCore",\
            dependencies: ["PilotInfrastructure"],|' Package.swift
}

mutate_product_target_uses_test_support() {
    # pilotctl 的依赖行是唯一同时含三者的位置,直接定位它
    python3 -c "
import io
s = io.open('Package.swift', encoding='utf-8').read()
i = s.index('name: \"pilotctl\",')
j = s.index('dependencies: [', i)
k = s.index(']', j)
s = s[:j] + 'dependencies: [\"PilotCore\", \"PilotInfrastructure\", \"PilotTestSupport\"' + s[k:]
io.open('Package.swift', 'w', encoding='utf-8').write(s)
"
}

mutate_test_support_becomes_product() {
    python3 -c "
import io
s = io.open('Package.swift', encoding='utf-8').read()
anchor = '.executable(name: \"pilotctl\", targets: [\"pilotctl\"]),'
assert anchor in s
s = s.replace(anchor, anchor + '\n        .library(name: \"PilotTestSupport\", targets: [\"PilotTestSupport\"]),')
io.open('Package.swift', 'w', encoding='utf-8').write(s)
"
}

run_manifest_case "PilotCore 声明依赖时被拒"        mutate_core_gains_dependency            1
run_manifest_case "产品 target 依赖替身时被拒"      mutate_product_target_uses_test_support 1
run_manifest_case "替身被暴露为 product 时被拒"     mutate_test_support_becomes_product     1

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m✓ %s 个用例全部通过\033[0m\n' "$pass"
    exit 0
else
    printf '\033[31m✗ %s 通过,%s 失败\033[0m\n' "$pass" "$fail"
    exit 1
fi
