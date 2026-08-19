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
    echo "::error::$CONFIGURATION 配置未生成任何 xunit XML。上游行为可能已变更,见 ADR-0003。"
    exit 1
fi

total=0
for file in "${xml[@]}"; do
    count=$(sed -n 's/.*<testsuite [^>]*tests="\([0-9]*\)".*/\1/p' "$file" | head -1)
    echo "  $file  tests=${count:-0}"
    total=$((total + ${count:-0}))
done

if [ "$total" -eq 0 ]; then
    echo "::error::$CONFIGURATION 配置的 xunit XML 存在但记录了 0 个测试。见 ADR-0003。"
    exit 1
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "## 测试($CONFIGURATION)"
        echo "xunit 记录 **$total** 个测试"
    } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$status"
