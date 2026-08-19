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

# 允许的 only 目标。新增执行器时同时改这里和 TARGETS。
VALID_TARGETS="codex claude"

# 剥掉不属于本目标的 only 块,并去掉权威源顶部那段「怎么改这个文件」的说明 ——
# 那是给维护者看的,不该出现在执行器读的文件里。
#
# 标记必须严格校验,不能「不认识就当普通文本」。原因是这类错误的后果是
# **静默丢内容**,而漂移检查抓不到 —— 它比对的是权威源和生成物,
# 拼错之后重新生成,两边一起变,CI 照样绿:
#
#   only:claud     目标名拼错  → Claude 专用小节整节消失(含提示注入防护)
#   <!--/onlyy-->  结束标记拼错 → 若是最后一个块,其后所有通用内容
#                                 从另一个目标的生成物里全部消失
#
# 所以任何无法识别的标记、未闭合的块、多余的结束标记,一律硬失败。
render() {
    local target="$1"
    awk -v target="$target" -v valid="$VALID_TARGETS" '
    function fatal(msg) {
        printf("  ✗ %s(%s 第 %d 行)\n", msg, FILENAME, FNR) > "/dev/stderr"
        failed = 1
        exit 3
    }
    BEGIN {
        skip = 0; started = 0; open = 0; failed = 0
        n = split(valid, list, " ")
        for (i = 1; i <= n; i++) allowed[list[i]] = 1
    }
    # 权威源开头的说明块以第一条水平线结束
    !started { if ($0 ~ /^---$/) { started = 1 }; next }

    /^<!--only:[a-zA-Z]+-->$/ {
        if (open) fatal("上一个 only 块还没闭合就开了新块")
        match($0, /only:[a-zA-Z]+/)
        t = substr($0, RSTART + 5, RLENGTH - 5)
        if (!(t in allowed)) fatal("未知的 only 目标 \"" t "\",可用的是:" valid)
        skip = (t == target) ? 0 : 1
        open = 1
        next
    }
    /^<!--\/only-->$/ {
        if (!open) fatal("多余的 only 结束标记")
        skip = 0; open = 0; next
    }
    # 长得像标记但对不上任何一种形式 —— 多半是拼错,不能当普通文本放过
    /^<!--.*only.*-->/ { fatal("无法识别的 only 标记:" $0) }

    { if (!skip) print }
    END { if (!failed && open) { printf("  ✗ only 块未闭合(%s)\n", FILENAME) > "/dev/stderr"; exit 3 } }
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

    if ! rendered=$(banner; render "$target"); then
        printf '\033[31m✗\033[0m 权威源 %s 的 only 标记有问题,已中止\n' "$CANONICAL"
        exit 1
    fi

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
