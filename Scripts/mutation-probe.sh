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

STAGING=""

restore() {
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        # -p 保留备份的权限位。不加 -p 的话,cp 写进一个已存在的文件时
        # 保留的是**目标**当前的权限 —— 而那正是可能已经被改坏的那个。
        cp -pf "$BACKUP" "$TARGET"
        rm -f "$BACKUP"
        BACKUP=""
    fi
    # 暂存文件单独清。信号若落在 mktemp 与 cp 之间,BACKUP 还没被赋值
    # (那是有意的,见下面),但 mktemp 已经建了文件 —— 不清就会在
    # TMPDIR 里留下一个空文件。源码无损,但泄漏会累积。
    if [ -n "$STAGING" ]; then
        rm -f "$STAGING"
        STAGING=""
    fi
}
# EXIT 只负责还原文件。INT/TERM 必须**额外退出** ——
# bash 的 trap 跑完会继续执行下一条语句,于是 Ctrl-C 打断构建时:
# 子进程被信号杀死 → trap 还原 → 脚本继续 → `if ! build` 看到非零
# → 打印「✓ 被拦下(构建阶段)」并 exit 0。
# 用户只是中断,结论却是「拦下了」,批量跑时这就是假证据。
trap restore EXIT
trap 'restore; exit 130' INT TERM

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
elif [ -n "$wanted" ] && ! printf '%s' "$wanted" | grep -qE '^[0-9]+$'; then
    # 先判是不是数字。直接拿去做 [ -lt ] 比较会漏一行
    # 「integer expression expected」的 shell 内部报错 —— 退出码虽然对,
    # 但用户看到的是 shell 在抱怨,不是探针在解释。
    bad "锚点" "MUTATION_PROBE_OCCURRENCE 必须是正整数,收到:$wanted"
    exit 2
elif [ -n "$wanted" ] && { [ "$wanted" -lt 1 ] || [ "$wanted" -gt "$occurrences" ]; }; then
    bad "锚点" "指定了第 $wanted 处,但只命中 $occurrences 处"
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
# 先备份到暂存位置,**拷完之后**才让 restore 认它。
#
# 直接写 BACKUP=$(mktemp) 会开一个致命窗口:mktemp 建的是**空文件**,
# 信号若落在 mktemp 与 cp 之间,restore 就把那个空文件盖到目标上,
# 把源码清空。实测 8 次中断有 7 次踩中 —— 这个窗口比看上去宽得多。
# 路径先定,文件后建 —— 顺序反过来就还有一个窗口:mktemp 已经建出文件、
# 变量还没被赋值时被中断,trap 无从得知要清哪个,文件就泄漏在 TMPDIR 里。
# 先赋值的代价只是 trap 可能去 rm 一个不存在的文件,那是无害的。
STAGING="${TMPDIR:-/tmp}/mutation-probe-$$-$(date +%s)"
cp "$TARGET" "$STAGING"
BACKUP="$STAGING"
STAGING=""   # 已经交给 BACKUP 管,不再重复清
# 变异必须确认施加成功。不查这一步,python 抛异常时脚本会拿着**没改过的**
# 文件跑完,然后报「没有任何东西拦下」—— 一个方向相反的假阴性。
# 这正是本工具要防的那个坑,只是发生在工具自己身上。
if ! ORIGINAL="$ORIGINAL" REPLACEMENT="$REPLACEMENT" python3 -c '
import io, os, sys
path = sys.argv[1]
old, new = os.environ["ORIGINAL"], os.environ["REPLACEMENT"]
nth = int(sys.argv[2]) if sys.argv[2] else 1
text = io.open(path, encoding="utf-8").read()
index = -1
for _ in range(nth):
    index = text.index(old, index + 1)
# 原子写:先写同目录临时文件,再 os.replace 换过去。
# 直接就地写会留下一个截断窗口 —— 实测中断落在这个窗口里时,
# 目标文件被清空,而 trap 的还原已经跑过了。
# 这和 P0-06 里 SystemFileSystem.replaceItem 要解决的是同一个问题。
temporary = path + ".mutation-probe-tmp"
io.open(temporary, "w", encoding="utf-8").write(text[:index] + new + text[index + len(old):])
# 把原文件的权限位带过去。os.replace 换的是**新建的**临时文件,
# 它带的是默认权限 —— 直接替换会把可执行位丢掉。
# 探针探脚本时这一点是致命的:内容对了,文件却不能执行了,
# 而下游看到的是「退出码 126」这种和被测内容毫无关系的失败。
os.chmod(temporary, os.stat(path).st_mode)
os.replace(temporary, path)
' "$TARGET" "$wanted"; then
    bad "变异" "施加失败 —— 探针没跑成,不能据此得出任何结论"
    exit 2
fi

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

# 按「测试名 + 源文件」去重,不能只按名字 —— 本仓库有四个套件都有
# 叫「往返相等」的测试,只按名字去重会把它们算成一个。
failed_functions=$(printf '%s' "$test_output" | python3 -c '
import re, sys
seen = set()
for line in sys.stdin:
    match = re.search(r"✘ Test \"([^\"]+)\".*? at ([^:]+):", line)
    if match:
        seen.add((match.group(1), match.group(2).rsplit("/", 1)[-1]))
print(len(seen))
')
failed_cases=$(printf '%s' "$test_output" | grep -c 'recorded an issue')

if [ "$failed_functions" -gt 0 ]; then
    good "测试" "$failed_functions 个函数红 / $failed_cases 个用例"
    say "" "$(printf '%s' "$test_output" | grep -oE '✘ Test "[^"]+"' | head -1 | sed 's/✘ Test //')"
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
