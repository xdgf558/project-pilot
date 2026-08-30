#!/bin/bash
# 跑单元测试并断言测试结果产物真的产生了(P0-04 / P0-05)
#
# 用法:run-tests.sh [debug|release]
#
# 抽成脚本而不是写在 CI 的 YAML 里,有两个理由:同一段逻辑要给两种配置各跑一次,
# 以及 YAML 里的 shell 没法在本地复现 —— 出问题只能靠推一次 CI 来看。

set -uo pipefail
shopt -s nullglob
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) printf '\033[31m✗\033[0m 未知配置 "%s",只接受 debug 或 release\n' "$CONFIGURATION"; exit 2 ;;
esac

PREFIX="test-results-$CONFIGURATION"
rm -f "$PREFIX"*.xml

swift test -c "$CONFIGURATION" --xunit-output "$PREFIX.xml" 2>&1 | tee "test-$CONFIGURATION.log"
status=${PIPESTATUS[0]}

# SwiftPM 不把 Swift Testing 的结果写进你指定的文件名,而是写到
# <去掉扩展名>-swift-testing.xml。指定路径本身只在 --parallel 下生成,
# 且只含 XCTest 结果。详见 Docs/DECISIONS.md 的 ADR-0003。
#
# 所以这里用 glob 而不是写死后缀:上游改命名 glob 仍能捕获,
# 彻底不产出则断言会红。两种变化都可见。
xml=("$PREFIX"*.xml)
if [ ${#xml[@]} -eq 0 ]; then
    # 「没有产物」有两种原因,报错时必须分清 —— 指着错误的方向排查最费时间。
    if [ "$status" -ne 0 ]; then
        echo "::error::$CONFIGURATION 配置的 swift test 失败(退出码 $status),因此没有测试结果产物。具体原因见上方日志,多半是编译没过。"
    else
        echo "::error::$CONFIGURATION 配置的 swift test 成功了,却没有生成任何 xunit XML。这是上游行为变更的信号,见 ADR-0003。"
    fi
    exit 1
fi

# 数 <testcase> 元素,不是读 <testsuite> 的 tests= 属性。
#
# 原来的写法是 `sed …tests="…"… | head -1`,只取**第一个** testsuite 的计数。
# Swift 6.3.3 下一个文件只有一个 testsuite,恰好对;Swift 6.4 改成每个
# test target 一个 testsuite —— 于是 185 个测试被报成 30 个,而断言
# 只查 `> 0`,静默放过。
#
# 数 testcase 不依赖 tests= 属性存不存在、对不对,是更根本的事实。
total=0
for file in "${xml[@]}"; do
    count=$(grep -c '<testcase' "$file")
    suites=$(grep -c '<testsuite ' "$file")
    echo "  $file  testcase=$count(分布在 $suites 个 testsuite)"
    total=$((total + count))
done

if [ "$total" -eq 0 ]; then
    echo "::error::$CONFIGURATION 配置的 xunit XML 存在但记录了 0 个测试。见 ADR-0003。"
    exit 1
fi

# 交叉核对:运行器自己报了多少个测试,XML 里就该有多少条。
#
# 上面那个 bug 能溜过去,正是因为断言只查 `> 0` —— 少报 155 个也算「有」。
# 拿运行器的输出当第二个信源,两边对不上就说明产出不完整。
# Swift 6.4 会打多行 "Test run with N tests"(每个 target 一行),所以要加总。
reported=$(grep -oE 'Test run with [0-9]+ test' "test-$CONFIGURATION.log" \
    | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
if [ -n "$reported" ] && [ "$reported" -gt 0 ] && [ "$reported" -ne "$total" ]; then
    echo "::error::$CONFIGURATION 配置的测试结果不完整:运行器报告 $reported 个测试,xunit XML 只记录了 $total 个。上游产出格式可能已变更,见 ADR-0003。"
    exit 1
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## 测试($CONFIGURATION)"
        echo "xunit 记录 **$total** 个测试"
    } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$status"
