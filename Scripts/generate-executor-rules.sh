#!/bin/bash
# 从 Docs/EXECUTOR_RULES.md 生成 AGENTS.md 与 CLAUDE.md(P0-08)
#
# 为什么要生成而不是维护两份:两个执行器读不同的文件,但规则 95% 是共享的。
# 分开维护的结果是有一天只改了一边 —— 于是同一个工作包派给 Codex 和派给 Claude
# 会得到不同的行为,而且没有任何东西会报错。这种漂移是静默的。
#
# 用法:
#   generate-executor-rules.sh          生成
#   generate-executor-rules.sh --check  只校验,有漂移则退出码 1(CI 用)

set -uo pipefail
cd "$(dirname "$0")/.."

CANONICAL="Docs/EXECUTOR_RULES.md"
declare -a TARGETS=("codex:AGENTS.md" "claude:CLAUDE.md")

if [ ! -f "$CANONICAL" ]; then
    printf '\033[31m✗\033[0m 找不到权威源 %s\n' "$CANONICAL"
    exit 1
fi

# 剥掉不属于本目标的 only 块,并去掉权威源顶部那段「怎么改这个文件」的说明 ——
# 那是给维护者看的,不该出现在执行器读的文件里。
render() {
    local target="$1"
    awk -v target="$target" '
    BEGIN { skip = 0; started = 0 }
    # 权威源开头的说明块以第一条水平线结束
    !started { if ($0 ~ /^---$/) { started = 1 }; next }
    /^<!--only:/ {
        match($0, /only:[a-z]+/)
        skip = (substr($0, RSTART + 5, RLENGTH - 5) == target) ? 0 : 1
        next
    }
    /^<!--\/only-->/ { skip = 0; next }
    { if (!skip) print }
    ' "$CANONICAL"
}

banner() {
    cat <<HEADER
<!--
  本文件由 Scripts/generate-executor-rules.sh 从 Docs/EXECUTOR_RULES.md 生成。
  不要直接编辑 —— 改动会在下次生成时丢失,CI 的漂移检查也会拦下。
  要改规则,改 Docs/EXECUTOR_RULES.md。
-->
HEADER
}

check_mode=0
[ "${1:-}" = "--check" ] && check_mode=1

fail=0
for entry in "${TARGETS[@]}"; do
    target="${entry%%:*}"
    output="${entry##*:}"

    rendered=$(banner; render "$target")

    if [ "$check_mode" -eq 1 ]; then
        if [ ! -f "$output" ]; then
            printf '  \033[31m✗\033[0m %s 不存在\n' "$output"
            fail=1
            continue
        fi
        if ! diff -q <(printf '%s\n' "$rendered") "$output" >/dev/null 2>&1; then
            printf '  \033[31m✗\033[0m %s 与 %s 不一致\n' "$output" "$CANONICAL"
            printf '      → 有人直接改了生成物,或改了权威源却忘了重新生成\n'
            printf '      → 修复:运行 Scripts/generate-executor-rules.sh\n'
            printf '      → 差异:\n'
            diff <(printf '%s\n' "$rendered") "$output" | sed 's/^/        /' | head -20
            fail=1
        else
            printf '  \033[32m✓\033[0m %s 与权威源一致\n' "$output"
        fi
    else
        printf '%s\n' "$rendered" > "$output"
        printf '  \033[32m✓\033[0m 已生成 %s(%s 行)\n' "$output" "$(wc -l < "$output" | tr -d ' ')"
    fi
done

if [ "$fail" -ne 0 ]; then
    printf '\033[31m✗ 执行器规则存在漂移\033[0m\n'
    exit 1
fi
exit 0
