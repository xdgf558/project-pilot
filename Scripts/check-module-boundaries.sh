#!/bin/bash
# 模块边界检查(P0-02)
#
# SPM 在编译期强制的是「谁能 import 谁」。这个脚本补的是另一半:
# PilotCore 内部不许出现任何 IO 或 UI 符号 —— 那是 SPM 看不见的。
#
# 检查前会剥掉注释,否则 PilotCore.swift 里那段说明边界的文档注释
# 本身就会把自己判红。
#
# 已知限制:剥注释是按行处理的,字符串字面量里的 "//" 之后的内容会被
# 一并剥掉。这只会造成漏报,不会造成误报,可以接受。

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

strip_comments() {
    sed -e 's|/\*.*\*/||g' -e 's|//.*$||'
}

report() {
    # $1=文件 $2=行号 $3=内容 $4=原因
    printf '  \033[31m✗\033[0m %s:%s\n      %s\n      → %s\n' "$1" "$2" "$3" "$4"
    fail=1
}

# ── 检查 1:PilotCore 必须保持纯净 ─────────────────────────────────────
#
# 禁止的 import 与符号。PilotCore 要能在没有磁盘、没有网络、没有 Git 仓库
# 的情况下被完整测试 —— Phase 5 的决策表测试和属性测试全依赖这一点。

CORE_FORBIDDEN_IMPORTS='^[[:space:]]*(@[a-zA-Z]+[[:space:]]+)?import[[:space:]]+(AppKit|UIKit|SwiftUI|XPC|Network|ServiceManagement|PilotInfrastructure)\b'
CORE_FORBIDDEN_SYMBOLS='\b(Process|NSTask|FileManager|FileHandle|Pipe|URLSession|NSXPCConnection)\b'

echo "检查 PilotCore 纯净性…"
while IFS= read -r file; do
    while IFS=: read -r lineno content; do
        [ -z "${lineno:-}" ] && continue
        report "$file" "$lineno" "$(echo "$content" | sed 's/^[[:space:]]*//')" \
            "PilotCore 不得引入 IO / UI / XPC 依赖"
    done < <(strip_comments < "$file" | grep -nE "$CORE_FORBIDDEN_IMPORTS")

    while IFS=: read -r lineno content; do
        [ -z "${lineno:-}" ] && continue
        report "$file" "$lineno" "$(echo "$content" | sed 's/^[[:space:]]*//')" \
            "PilotCore 不得直接做 IO,把它挪到 PilotInfrastructure"
    done < <(strip_comments < "$file" | grep -nE "$CORE_FORBIDDEN_SYMBOLS")
done < <(find Sources/PilotCore -name '*.swift' 2>/dev/null)

# ── 检查 2:全代码库禁止拼接 shell 命令 ────────────────────────────────
#
# v0.2 §4.1 与 Phase 2 退出闸门:只使用 Process.executableURL 加参数数组。
# 这条从第一次提交就该成立 —— 一旦有人写了 shell 拼接,后面再拆很痛。

SHELL_FORBIDDEN='(/bin/(ba|z)?sh|/usr/bin/env[[:space:]]+(ba|z)?sh)'

echo "检查 shell 拼接…"
while IFS= read -r file; do
    while IFS=: read -r lineno content; do
        [ -z "${lineno:-}" ] && continue
        report "$file" "$lineno" "$(echo "$content" | sed 's/^[[:space:]]*//')" \
            "禁止通过 shell 执行外部命令,改用 Process.executableURL + 参数数组"
    done < <(strip_comments < "$file" | grep -nE "$SHELL_FORBIDDEN")
done < <(find Sources -name '*.swift' 2>/dev/null)

# ── 检查 3:Package.swift 的依赖声明未被反转 ───────────────────────────

echo "检查依赖方向声明…"
if grep -A3 'name: "PilotCore"' Package.swift | grep -q 'dependencies'; then
    printf '  \033[31m✗\033[0m Package.swift\n      → PilotCore 不应声明任何 target 依赖\n'
    fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m✓ 模块边界检查通过\033[0m\n'
else
    printf '\033[31m✗ 模块边界检查失败\033[0m\n'
fi
exit "$fail"
