#!/bin/bash
# 模块边界检查(P0-02)
#
# SPM 在编译期强制的是「谁能 import 谁」。这个脚本补的是另一半:
# PilotCore 内部不许出现任何 IO 或 UI 符号 —— 那是 SPM 看不见的。
#
# ── 关于剥注释 ──
# 检查前必须剥掉注释,否则 PilotCore.swift 里那段说明边界的文档注释
# 本身就会把自己判红。剥注释用 awk 状态机,能正确处理跨行块注释,
# 并保留行号(整行内容清空但不删行)。
#
# 已知限制:不识别字符串字面量。字符串里出现 "//" 或 "/*" 会被当成
# 注释起点,后续内容被误剥。这个方向是**漏报**(少检查),不是误报。
# 反方向的误报需要字符串里恰好有 "*/" 把块注释提前闭合 —— 构造得出来,
# 实践中不会发生。真要杜绝就得上真正的 Swift parser,当前不值这个成本。

set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

# 剥掉行注释与块注释(含跨行),保留行数以维持行号准确。
strip_comments() {
    awk '
    BEGIN { inblock = 0 }
    {
        line = $0; out = ""; i = 1; n = length(line)
        while (i <= n) {
            if (inblock) {
                p = index(substr(line, i), "*/")
                if (p > 0) { i = i + p + 1; inblock = 0 } else { i = n + 1 }
            } else {
                rest = substr(line, i)
                a = index(rest, "//")
                b = index(rest, "/*")
                if (a > 0 && (b == 0 || a < b)) {
                    out = out substr(line, i, a - 1); i = n + 1
                } else if (b > 0) {
                    out = out substr(line, i, b - 1); i = i + b + 1; inblock = 1
                } else {
                    out = out rest; i = n + 1
                }
            }
        }
        print out
    }'
}

report() {
    # $1=文件 $2=行号 $3=内容 $4=原因
    printf '  \033[31m✗\033[0m %s:%s\n      %s\n      → %s\n' "$1" "$2" "$3" "$4"
    fail=1
}

scan() {
    # $1=文件 $2=正则 $3=原因
    while IFS=: read -r lineno content; do
        [ -z "${lineno:-}" ] && continue
        report "$1" "$lineno" "$(echo "$content" | sed 's/^[[:space:]]*//')" "$3"
    done < <(strip_comments < "$1" | grep -nE "$2")
}

# ── 检查 1:PilotCore 必须保持纯净 ─────────────────────────────────────
#
# PilotCore 要能在没有磁盘、没有网络、没有 Git 仓库的情况下被完整测试 ——
# Phase 5 的决策表测试和属性测试全依赖这一点。
#
# import 前缀允许零个或多个 attribute,且 attribute 名可含下划线。
# @_exported / @_implementationOnly 是真实存在的重导出手段,
# 用 [a-zA-Z]+ 会被它们绕过。

CORE_FORBIDDEN_IMPORTS='^[[:space:]]*(@[_a-zA-Z]+[[:space:]]+)*import[[:space:]]+(AppKit|UIKit|SwiftUI|XPC|Network|ServiceManagement|PilotInfrastructure)\b'
CORE_FORBIDDEN_SYMBOLS='\b(Process|NSTask|FileManager|FileHandle|Pipe|URLSession|NSXPCConnection)\b'

echo "检查 PilotCore 纯净性…"
while IFS= read -r file; do
    scan "$file" "$CORE_FORBIDDEN_IMPORTS" "PilotCore 不得引入 IO / UI / XPC 依赖"
    scan "$file" "$CORE_FORBIDDEN_SYMBOLS" "PilotCore 不得直接做 IO,把它挪到 PilotInfrastructure"
done < <(find Sources/PilotCore -name '*.swift' 2>/dev/null)

# ── 检查 2:全代码库禁止拼接 shell 命令 ────────────────────────────────
#
# v0.2 §4.1 与 Phase 2 退出闸门:只使用 Process.executableURL 加参数数组。
# 这条从第一次提交就该成立 —— 一旦有人写了 shell 拼接,后面再拆很痛。

SHELL_FORBIDDEN='(/bin/(ba|z)?sh|/usr/bin/env[[:space:]]+(ba|z)?sh)'

echo "检查 shell 拼接…"
while IFS= read -r file; do
    scan "$file" "$SHELL_FORBIDDEN" "禁止通过 shell 执行外部命令,改用 Process.executableURL + 参数数组"
done < <(find Sources -name '*.swift' 2>/dev/null)

# ── 检查 2.5:生命周期状态字段必须收口到唯一写入口 ─────────────────────
#
# P1-03 把 TaskStage / JobStatus 的合法转换做成了边表校验,但校验器
# 只有在字段不可绕过时才是领域不变量。PilotTask.stage 与 Job.status
# 必须 private(set) —— 唯一的写入口是类型上的 transition(to:source:)。
#
# 单元测试无法断言「这行代码不该编译」,所以这条落在边界检查里:
# 让绕过变成 CI 红灯,而不是靠审查者的眼睛。
#
# 只盯这两个生命周期字段:PullRequestSnapshot / StatusCheck 里的
# state / status 是快照镜像字段(整份快照一起替换),不归边表管。
# 检查是「含 var stage/status 但不含 private(set) 就报」——
# init 参数与自赋值不带 var,不会误伤。

echo "检查生命周期状态字段收口…"
for f in Sources/PilotCore/Domain/PilotTask.swift Sources/PilotCore/Domain/Job.swift; do
    if [ ! -f "$f" ]; then
        printf '  \033[31m✗\033[0m %s\n      → 文件不存在,检查 2.5 无法执行\n' "$f"
        fail=1
        continue
    fi
    bad_lines=$(strip_comments < "$f" | grep -nE 'var[[:space:]]+(stage|status)\b' | grep -v 'private(set)' || true)
    if [ -n "$bad_lines" ]; then
        while IFS=: read -r lineno content; do
            [ -z "${lineno:-}" ] && continue
            report "$f" "$lineno" "$(echo "$content" | sed 's/^[[:space:]]*//')" \
                "生命周期状态字段必须 private(set),唯一写入口是 transition(to:source:)"
        done <<< "$bad_lines"
        fail=1
    fi
done

# ── 检查 3:PilotCore 未声明任何 target 依赖 ───────────────────────────
#
# 解析 SPM 真实清单,而不是 grep Package.swift 的文本 ——
# 文本窗口会被 path:/exclude: 之类的新增行挤破。

echo "检查依赖方向声明…"
if ! command -v jq >/dev/null 2>&1; then
    printf '  \033[33m!\033[0m 未找到 jq,跳过依赖声明检查\n'
else
    manifest=$(swift package dump-package 2>/dev/null)
    if [ -z "$manifest" ]; then
        printf '  \033[31m✗\033[0m 无法解析 Package.swift(swift package dump-package 失败)\n'
        fail=1
    else
        core_deps=$(printf '%s' "$manifest" \
            | jq -r '[.targets[] | select(.name == "PilotCore") | .dependencies[]?] | length')
        if [ "${core_deps:-0}" != "0" ]; then
            printf '  \033[31m✗\033[0m Package.swift\n      → PilotCore 声明了 %s 个 target 依赖,应为 0\n' "$core_deps"
            fail=1
        fi

        # ── 检查 4:测试替身不得进入产品 ───────────────────────────────
        #
        # PilotTestSupport 里有 FakeClock、InMemoryFileSystem 这些东西。
        # 它们跟着产品二进制发出去不只是死重量 —— 一个能注入「磁盘满」的
        # 文件系统出现在正式构建里是负债。
        #
        # 两个方向都要挡:非测试 target 不得依赖它,也不得把它做成 product
        # 暴露给外部消费者。
        leaked_targets=$(printf '%s' "$manifest" | jq -r '
            [ .targets[]
              | select(.type != "test")
              | select(.name != "PilotTestSupport")
              | select([.dependencies[]?.byName[0]?] | index("PilotTestSupport"))
              | .name
            ] | join(", ")')
        if [ -n "$leaked_targets" ]; then
            printf '  \033[31m✗\033[0m Package.swift\n      → 产品 target 依赖了 PilotTestSupport:%s\n      → 测试替身只能被 test target 依赖\n' "$leaked_targets"
            fail=1
        fi

        leaked_products=$(printf '%s' "$manifest" | jq -r '
            [ .products[]
              | select([.targets[]?] | index("PilotTestSupport"))
              | .name
            ] | join(", ")')
        if [ -n "$leaked_products" ]; then
            printf '  \033[31m✗\033[0m Package.swift\n      → product 暴露了 PilotTestSupport:%s\n      → 测试替身不应作为 product 发布\n' "$leaked_products"
            fail=1
        fi
    fi
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m✓ 模块边界检查通过\033[0m\n'
else
    printf '\033[31m✗ 模块边界检查失败\033[0m\n'
fi
exit "$fail"
