#!/bin/bash
# 变异探针(工具)
#
# 规则第 4 节要求「一个从没红过的测试等于没验证过」:写完检查之后要故意
# 破坏它一次,确认它真的会失败。手工做这件事出错率很高 —— 本仓库里
# 已经发生过四种不同的失效,而且**每一种都把「没拦住」误报成了结论**:
#
#   锚点没命中        正则写坏,替换根本没发生 → 看起来「测试没红」
#   锚点命中错的位置  文档散文里有同样的字样,替换打在了散文上
#   构建失败          穷尽 switch 被破坏 → 编译错误,grep 到 0 条失败
#   进程中止          precondition 触发 → 进程 abort,同样 grep 到 0 条
#
# 这四种的共同点是把「没拦住」和「拦住了,只是不长成测试失败的样子」
# 混为一谈,而这两个结论方向相反。
#
# 用法:
#   Scripts/mutation-probe.sh <文件> <原文> <替换文> [描述]
#
# 退出码:
#   0  改动被拦下了(构建、进程中止或测试任一阶段)—— 这是期望结果
#   1  改动没有被任何东西拦下 —— 测试有缺口
#   2  探针本身没跑成(锚点没命中、命中多处、基线本来就是红的)
#
# 选项(环境变量):
#   MUTATION_PROBE_OCCURRENCE  锚点命中多处时指定用第几处(从 1 起)
#   MUTATION_PROBE_SKIP_BASELINE=1  跳过基线检查(连续跑多个探针时用)
#   MUTATION_PROBE_BUILD / MUTATION_PROBE_TEST  覆盖构建与测试命令(给自测用)

set -uo pipefail
cd "$(dirname "$0")/.."

BUILD_COMMAND="${MUTATION_PROBE_BUILD:-swift build --build-tests}"
TEST_COMMAND="${MUTATION_PROBE_TEST:-swift test}"

if [ "$#" -lt 3 ]; then
    printf '用法:%s <文件> <原文> <替换文> [描述]\n' "$0"
    exit 2
fi

TARGET="$1"
ORIGINAL="$2"
REPLACEMENT="$3"
LABEL="${4:-$TARGET}"
BACKUP=""

restore() {
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        cp -f "$BACKUP" "$TARGET"
        rm -f "$BACKUP"
        BACKUP=""
    fi
}
trap restore EXIT INT TERM

say()  { printf '  %-10s %s\n' "$1" "$2"; }
good() { printf '  %-10s \033[32m%s\033[0m\n' "$1" "$2"; }
bad()  { printf '  %-10s \033[31m%s\033[0m\n' "$1" "$2"; }
warn() { printf '  %-10s \033[33m%s\033[0m\n' "$1" "$2"; }

printf '\n探针:%s\n' "$LABEL"
say "文件" "$TARGET"

if [ ! -f "$TARGET" ]; then
    bad "文件" "不存在"
    exit 2
fi

# ── 1. 锚点必须命中,且默认必须唯一 ────────────────────────────────────
#
# 命中 0 处最危险:替换没发生,后面一路绿,看起来像「测试没拦住」。
# 命中多处同样危险:可能打在文档、注释或另一个同名的地方 —— 踩过。
occurrences=$(ORIGINAL="$ORIGINAL" python3 -c '
import io, os, sys
text = io.open(sys.argv[1], encoding="utf-8").read()
print(text.count(os.environ["ORIGINAL"]))
' "$TARGET")

wanted="${MUTATION_PROBE_OCCURRENCE:-}"
if [ "$occurrences" -eq 0 ]; then
    bad "锚点" "一处都没命中 —— 探针没跑成,不能据此得出任何结论"
    exit 2
elif [ "$occurrences" -gt 1 ] && [ -z "$wanted" ]; then
    bad "锚点" "命中 $occurrences 处,不知道该改哪一处"
    say "" "用 MUTATION_PROBE_OCCURRENCE=N 指定(从 1 起),或把原文写得更长"
    exit 2
else
    say "锚点" "命中 $occurrences 处${wanted:+,使用第 $wanted 处}"
fi

# ── 2. 基线必须是绿的,否则探针结果无意义 ──────────────────────────────
if [ "${MUTATION_PROBE_SKIP_BASELINE:-0}" != "1" ]; then
    if ! $BUILD_COMMAND >/dev/null 2>&1 || ! $TEST_COMMAND >/dev/null 2>&1; then
        bad "基线" "改动之前就是红的 —— 先修好再来探"
        exit 2
    fi
    say "基线" "绿"
fi

# ── 3. 施加变异 ───────────────────────────────────────────────────────
BACKUP=$(mktemp)
cp "$TARGET" "$BACKUP"
ORIGINAL="$ORIGINAL" REPLACEMENT="$REPLACEMENT" python3 -c '
import io, os, sys
path = sys.argv[1]
old, new = os.environ["ORIGINAL"], os.environ["REPLACEMENT"]
nth = int(sys.argv[2]) if sys.argv[2] else 1
text = io.open(path, encoding="utf-8").read()
index = -1
for _ in range(nth):
    index = text.index(old, index + 1)
io.open(path, "w", encoding="utf-8").write(text[:index] + new + text[index + len(old):])
' "$TARGET" "$wanted"

# ── 4. 分阶段判定,不把不同的失败方式混为一谈 ──────────────────────────
if ! build_output=$($BUILD_COMMAND 2>&1); then
    good "构建" "失败 —— 编译器拦下了"
    say "" "$(printf '%s' "$build_output" | grep -m1 'error:' | cut -c1-72)"
    good "结论" "✓ 被拦下(构建阶段)"
    exit 0
fi
say "构建" "通过"

test_output=$($TEST_COMMAND 2>&1)
test_status=$?

if printf '%s' "$test_output" | grep -qE 'Fatal error|Precondition failed|Assertion failed'; then
    good "测试" "进程中止"
    say "" "$(printf '%s' "$test_output" | grep -moE '(Fatal error|Precondition failed|Assertion failed)[^"]*' | head -1 | cut -c1-72)"
    good "结论" "✓ 被拦下(运行期不变量)"
    exit 0
fi

failed_functions=$(printf '%s' "$test_output" | grep -oE '✘ Test "[^"]+"' | sort -u | wc -l | tr -d ' ')
failed_cases=$(printf '%s' "$test_output" | grep -c 'recorded an issue')

if [ "$failed_functions" -gt 0 ]; then
    good "测试" "$failed_functions 个函数红 / $failed_cases 个用例"
    say "" "$(printf '%s' "$test_output" | grep -oE '✘ Test "[^"]+"' | sort -u | head -1 | sed 's/✘ Test //')"
    good "结论" "✓ 被拦下(测试阶段)"
    exit 0
fi

if [ "$test_status" -ne 0 ]; then
    warn "测试" "退出码 $test_status,但没有可识别的失败测试"
    say "" "$(printf '%s' "$test_output" | tail -2 | head -1 | cut -c1-72)"
    warn "结论" "? 探针无法判定 —— 请人工看上面的输出"
    exit 2
fi

bad "测试" "全部通过"
bad "结论" "✗ 没有任何东西拦下这个改动"
exit 1
