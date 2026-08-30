#!/bin/bash
# mutation-probe.sh 的测试
#
# 探针是用来判断「测试有没有拦住改动」的工具。它自己判断错了,
# 得到的是一个方向相反的结论 —— 比没有探针更坏。
#
# 构建与测试命令通过环境变量注入,所以这里用打桩的方式覆盖各种输出组合,
# 不必每个用例都真跑一遍 swift build(那要几分钟)。
# 末尾另有一条端到端用例,用真实命令跑一次。

set -uo pipefail
cd "$(dirname "$0")/.."

PROBE="Scripts/mutation-probe.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

pass=0
fail=0

# 打桩:$1=退出码 $2=输出
make_stub() {
    local path="$1" code="$2" output="$3"
    printf '#!/bin/bash\ncat <<'\''OUT'\''\n%s\nOUT\nexit %s\n' "$output" "$code" > "$path"
    chmod +x "$path"
}

TARGET="$WORK/target.txt"
PRISTINE="$WORK/pristine.txt"

reset_target() {
    printf 'alpha\nbravo\ncharlie\n' > "$TARGET"
    cp "$TARGET" "$PRISTINE"
}

# $1=用例名 $2=期望退出码 $3.. = 传给探针的参数
run_case() {
    local name="$1" want="$2"; shift 2
    reset_target
    "$PROBE" "$@" >/dev/null 2>&1
    local got=$?
    local restored="是"
    cmp -s "$TARGET" "$PRISTINE" || restored="否"

    if [ "$got" -eq "$want" ] && [ "$restored" = "是" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  \033[31m✗\033[0m %s  (期望退出码 %s 实际 %s;文件已还原:%s)\n' \
            "$name" "$want" "$got" "$restored"
        fail=$((fail + 1))
    fi
}

BUILD_OK="$WORK/build-ok";     make_stub "$BUILD_OK" 0 "Build complete!"
BUILD_BAD="$WORK/build-bad";   make_stub "$BUILD_BAD" 1 "Sources/X.swift:3:5: error: 用不了"
TEST_PASS="$WORK/test-pass";   make_stub "$TEST_PASS" 0 "✔ Test run with 10 tests in 2 suites passed"
TEST_FAIL="$WORK/test-fail";   make_stub "$TEST_FAIL" 1 '✘ Test "某条断言" recorded an issue at X.swift:1:1
✘ Test "某条断言" failed after 0.001 seconds with 1 issue.
✘ Test run with 10 tests in 2 suites failed'
TEST_ABORT="$WORK/test-abort"; make_stub "$TEST_ABORT" 134 "Precondition failed: 只支持 github.com"
TEST_WEIRD="$WORK/test-weird"; make_stub "$TEST_WEIRD" 7 "something went sideways"

export MUTATION_PROBE_SKIP_BASELINE=1

echo "探针本身跑不成(退出码 2)"
export MUTATION_PROBE_BUILD="$BUILD_OK" MUTATION_PROBE_TEST="$TEST_FAIL"
run_case "锚点一处都没命中"   2 "$TARGET" "不存在的文本" "x" "案例"
run_case "文件不存在"         2 "$WORK/nope.txt" "alpha" "x" "案例"

reset_target; printf 'dup\ndup\n' > "$TARGET"; cp "$TARGET" "$PRISTINE"
"$PROBE" "$TARGET" "dup" "x" "案例" >/dev/null 2>&1
got=$?; cmp -s "$TARGET" "$PRISTINE" && restored=是 || restored=否
if [ "$got" -eq 2 ] && [ "$restored" = "是" ]; then
    printf '  \033[32m✓\033[0m 锚点命中多处时拒绝\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m 锚点命中多处时拒绝 (退出码 %s,还原 %s)\n' "$got" "$restored"; fail=$((fail + 1))
fi

reset_target; printf 'dup\ndup\n' > "$TARGET"; cp "$TARGET" "$PRISTINE"
MUTATION_PROBE_OCCURRENCE=2 "$PROBE" "$TARGET" "dup" "x" "案例" >/dev/null 2>&1
got=$?; cmp -s "$TARGET" "$PRISTINE" && restored=是 || restored=否
if [ "$got" -eq 0 ] && [ "$restored" = "是" ]; then
    printf '  \033[32m✓\033[0m 指定第几处后可继续\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m 指定第几处后可继续 (退出码 %s,还原 %s)\n' "$got" "$restored"; fail=$((fail + 1))
fi

reset_target
MUTATION_PROBE_OCCURRENCE=0 "$PROBE" "$TARGET" "alpha" "x" "案例" >/dev/null 2>&1
got=$?; cmp -s "$TARGET" "$PRISTINE" && restored=是 || restored=否
if [ "$got" -eq 2 ] && [ "$restored" = "是" ]; then
    printf '  \033[32m✓\033[0m 指定第 0 处时拒绝\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m 指定第 0 处时拒绝 (退出码 %s,还原 %s)\n' "$got" "$restored"; fail=$((fail + 1))
fi

reset_target; printf 'dup\ndup\n' > "$TARGET"; cp "$TARGET" "$PRISTINE"
MUTATION_PROBE_OCCURRENCE=3 "$PROBE" "$TARGET" "dup" "x" "案例" >/dev/null 2>&1
got=$?; cmp -s "$TARGET" "$PRISTINE" && restored=是 || restored=否
if [ "$got" -eq 2 ] && [ "$restored" = "是" ]; then
    printf '  \033[32m✓\033[0m 指定的处数越界时拒绝\n'; pass=$((pass + 1))
else
    # 越界时若不拦,python 抛异常、替换根本没发生,脚本却拿着**没改过的**
    # 文件跑完并报「没有任何东西拦下」—— 一个方向相反的假阴性。
    printf '  \033[31m✗\033[0m 指定的处数越界时拒绝 (退出码 %s,还原 %s)\n' "$got" "$restored"; fail=$((fail + 1))
fi

reset_target
stderr_lines=$(MUTATION_PROBE_OCCURRENCE=abc "$PROBE" "$TARGET" "alpha" "x" "案例" 2>&1 >/dev/null | wc -l | tr -d ' ')
MUTATION_PROBE_OCCURRENCE=abc "$PROBE" "$TARGET" "alpha" "x" "案例" >/dev/null 2>&1
got=$?
if [ "$got" -eq 2 ] && [ "$stderr_lines" -eq 0 ]; then
    printf '  \033[32m✓\033[0m 非数字的处数:拒绝且 stderr 干净\n'; pass=$((pass + 1))
else
    # 直接拿非数字去做 [ -lt ] 比较会漏一行「integer expression expected」——
    # 退出码虽然对,用户看到的却是 shell 在抱怨,不是探针在解释。
    printf '  \033[31m✗\033[0m 非数字的处数 (退出码 %s,stderr %s 行)\n' "$got" "$stderr_lines"; fail=$((fail + 1))
fi

echo
echo "改动被拦下(退出码 0)—— 三种拦法都要认得"
export MUTATION_PROBE_BUILD="$BUILD_BAD" MUTATION_PROBE_TEST="$TEST_PASS"
run_case "构建失败也算拦下"   0 "$TARGET" "alpha" "x" "案例"
export MUTATION_PROBE_BUILD="$BUILD_OK" MUTATION_PROBE_TEST="$TEST_ABORT"
run_case "进程中止也算拦下"   0 "$TARGET" "alpha" "x" "案例"
export MUTATION_PROBE_TEST="$TEST_FAIL"
run_case "测试失败算拦下"     0 "$TARGET" "alpha" "x" "案例"

echo
echo "改动没被拦下(退出码 1)"
export MUTATION_PROBE_TEST="$TEST_PASS"
run_case "测试全过 = 有缺口"  1 "$TARGET" "alpha" "x" "案例"

echo
echo "判不了的情况不能假装有结论(退出码 2)"
export MUTATION_PROBE_TEST="$TEST_WEIRD"
run_case "非零退出但无失败测试" 2 "$TARGET" "alpha" "x" "案例"

echo
echo "基线检查"
unset MUTATION_PROBE_SKIP_BASELINE
export MUTATION_PROBE_BUILD="$BUILD_OK" MUTATION_PROBE_TEST="$TEST_FAIL"
run_case "基线本来就红时拒绝"  2 "$TARGET" "alpha" "x" "案例"
export MUTATION_PROBE_SKIP_BASELINE=1

echo
echo "计数口径"
TEST_SAMENAME="$WORK/test-samename"
make_stub "$TEST_SAMENAME" 1 '✘ Test "往返相等" recorded an issue at /x/ProjectTests.swift:12:5: 断言失败
✘ Test "往返相等" recorded an issue at /x/BlockerTests.swift:20:5: 断言失败
✘ Test run with 10 tests in 2 suites failed'
export MUTATION_PROBE_BUILD="$BUILD_OK" MUTATION_PROBE_TEST="$TEST_SAMENAME"
reset_target
output=$("$PROBE" "$TARGET" "alpha" "x" "同名测试" 2>&1)
# 本仓库有四个套件都有叫「往返相等」的测试。只按名字去重会把它们算成一个,
# 让「这个变异打红了多少地方」显著低估。
if printf '%s' "$output" | grep -q "2 个函数红"; then
    printf '  \033[32m✓\033[0m 同名测试跨套件不合并计数\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m 同名测试跨套件不合并计数:%s\n' "$(printf '%s' "$output" | grep 测试 | head -1)"; fail=$((fail + 1))
fi

echo
echo "不能改坏文件权限"
EXEC_TARGET="$WORK/executable.sh"
printf '#!/bin/bash\necho hi\n' > "$EXEC_TARGET"
chmod +x "$EXEC_TARGET"
before_mode=$(stat -f '%p' "$EXEC_TARGET")
export MUTATION_PROBE_BUILD="$BUILD_OK" MUTATION_PROBE_TEST="$TEST_FAIL"
"$PROBE" "$EXEC_TARGET" "hi" "bye" "权限" >/dev/null 2>&1
after_mode=$(stat -f '%p' "$EXEC_TARGET")
if [ "$before_mode" = "$after_mode" ] && [ -x "$EXEC_TARGET" ]; then
    printf '  \033[32m✓\033[0m 探测可执行文件后权限位不变\n'; pass=$((pass + 1))
else
    # 变异走的是「写临时文件 + os.replace」,而临时文件带的是默认权限。
    # 不把原权限带过去,脚本探完就不能执行了 —— 下游看到的是「退出码 126」
    # 这种和被测内容毫无关系的失败,极难往权限上想。
    printf '  \033[31m✗\033[0m 权限被改坏:%s → %s\n' "$before_mode" "$after_mode"; fail=$((fail + 1))
fi

echo
echo "被中断时不能损坏源文件"
SLOW_BUILD="$WORK/slow-build"; printf '#!/bin/bash\nsleep 30\n' > "$SLOW_BUILD"; chmod +x "$SLOW_BUILD"
export MUTATION_PROBE_BUILD="$SLOW_BUILD" MUTATION_PROBE_TEST="$TEST_PASS"
damaged=0
for _ in 1 2 3 4 5; do
    reset_target
    "$PROBE" "$TARGET" "alpha" "x" "会被中断" >"$WORK/interrupted.log" 2>&1 &
    probe_pid=$!
    ( while ! grep -q "锚点" "$WORK/interrupted.log" 2>/dev/null; do :; done
      kill -TERM $probe_pid 2>/dev/null )
    wait $probe_pid
    cmp -s "$TARGET" "$PRISTINE" || damaged=$((damaged + 1))
done
leaked=$(ls "${TMPDIR:-/tmp}"/mutation-probe-* 2>/dev/null | wc -l | tr -d ' ')
if [ "$leaked" -eq 0 ]; then
    printf '  \033[32m✓\033[0m 5 次中断后无暂存文件泄漏\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m 5 次中断泄漏了 %s 个暂存文件\n' "$leaked"; fail=$((fail + 1))
fi
if [ "$damaged" -eq 0 ]; then
    printf '  \033[32m✓\033[0m 5 次中断后源文件完好\n'; pass=$((pass + 1))
else
    # 这条防的是两个真实存在过的窗口:mktemp 建出空文件后、拷贝完成前被中断,
    # 还原会把空文件盖到目标上;以及就地写入被中断留下截断的文件。
    printf '  \033[31m✗\033[0m 5 次中断有 %s 次损坏源文件\n' "$damaged"; fail=$((fail + 1))
fi
export MUTATION_PROBE_BUILD="$BUILD_OK" MUTATION_PROBE_TEST="$TEST_PASS"

echo
echo "端到端(真实 swift 命令)"
unset MUTATION_PROBE_BUILD MUTATION_PROBE_TEST
before=$(git status --porcelain Sources/ | wc -l | tr -d ' ')
"$PROBE" Sources/PilotCore/DataFormat/Checksum.swift \
    "0x0000_0100_0000_01B3" "0x0000_0100_0000_01B5" "改掉 FNV prime" >/dev/null 2>&1
got=$?
after=$(git status --porcelain Sources/ | wc -l | tr -d ' ')
if [ "$got" -eq 0 ] && [ "$before" = "$after" ]; then
    printf '  \033[32m✓\033[0m 真实工程里能拦下 FNV prime 改动,且源码已还原\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m 端到端 (退出码 %s;改动前 %s 后 %s)\n' "$got" "$before" "$after"; fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m✓ %s 个用例全部通过\033[0m\n' "$pass"; exit 0
else
    printf '\033[31m✗ %s 通过,%s 失败\033[0m\n' "$pass" "$fail"; exit 1
fi
