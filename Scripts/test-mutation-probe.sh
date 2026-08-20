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
