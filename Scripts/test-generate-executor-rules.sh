#!/bin/bash
# generate-executor-rules.sh --check 的测试(P0-08)
#
# 漂移检查的全部价值在于它会红。这里把三种真实会发生的漂移各造一遍:
# 有人直接改了生成物、有人改了权威源忘了重新生成、生成物被删掉。

set -uo pipefail
cd "$(dirname "$0")/.."

GEN="Scripts/generate-executor-rules.sh"
CANONICAL="Docs/EXECUTOR_RULES.md"
BACKUP_DIR=""

cleanup() {
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        cp -f "$BACKUP_DIR/EXECUTOR_RULES.md" "$CANONICAL" 2>/dev/null
        cp -f "$BACKUP_DIR/AGENTS.md" AGENTS.md 2>/dev/null
        cp -f "$BACKUP_DIR/CLAUDE.md" CLAUDE.md 2>/dev/null
        rm -rf "$BACKUP_DIR"
    fi
}
trap cleanup EXIT INT TERM

BACKUP_DIR=$(mktemp -d)
cp "$CANONICAL" "$BACKUP_DIR/EXECUTOR_RULES.md"
cp AGENTS.md "$BACKUP_DIR/AGENTS.md"
cp CLAUDE.md "$BACKUP_DIR/CLAUDE.md"

pass=0
fail=0

# $1=用例名 $2=造漂移的函数 $3=期望退出码
run_case() {
    local name="$1" mutate="$2" want="$3"
    "$mutate"
    "$GEN" --check >/dev/null 2>&1
    local got=$?
    cleanup_to_backup
    if [ "$got" -eq "$want" ]; then
        printf '  \033[32m✓\033[0m %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  \033[31m✗\033[0m %s  (期望退出码 %s,实际 %s)\n' "$name" "$want" "$got"
        fail=$((fail + 1))
    fi
}

cleanup_to_backup() {
    cp -f "$BACKUP_DIR/EXECUTOR_RULES.md" "$CANONICAL"
    cp -f "$BACKUP_DIR/AGENTS.md" AGENTS.md
    cp -f "$BACKUP_DIR/CLAUDE.md" CLAUDE.md
}

noop() { :; }
edit_generated_file() { printf '\n偷偷加的一行\n' >> AGENTS.md; }
edit_canonical_only() { printf '\n## 新规则\n\n忘了重新生成。\n' >> "$CANONICAL"; }
delete_generated_file() { rm -f CLAUDE.md; }

echo "漂移检查"
run_case "无漂移时通过"                  noop                  0
run_case "直接改了生成物 → 拒绝"          edit_generated_file   1
run_case "改了权威源没重新生成 → 拒绝"    edit_canonical_only   1
run_case "生成物被删 → 拒绝"              delete_generated_file 1

echo
echo "生成的正确性"

# 专用小节必须各进各家,不能串门
if grep -q "Codex 专用" AGENTS.md && ! grep -q "Codex 专用" CLAUDE.md; then
    printf '  \033[32m✓\033[0m Codex 专用小节只在 AGENTS.md\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m Codex 专用小节串门了\n'; fail=$((fail + 1))
fi

if grep -q "Claude Code 专用" CLAUDE.md && ! grep -q "Claude Code 专用" AGENTS.md; then
    printf '  \033[32m✓\033[0m Claude 专用小节只在 CLAUDE.md\n'; pass=$((pass + 1))
else
    printf '  \033[31m✗\033[0m Claude 专用小节串门了\n'; fail=$((fail + 1))
fi

# 生成物里不该残留标记,也不该带上「怎么改这个文件」那段维护者说明
for f in AGENTS.md CLAUDE.md; do
    if grep -q "only:" "$f"; then
        printf '  \033[31m✗\033[0m %s 残留了 only 标记\n' "$f"; fail=$((fail + 1))
    else
        printf '  \033[32m✓\033[0m %s 无残留标记\n' "$f"; pass=$((pass + 1))
    fi
    if grep -q "这是 \`AGENTS.md\` 与 \`CLAUDE.md\` 的唯一来源" "$f"; then
        printf '  \033[31m✗\033[0m %s 混入了维护者说明\n' "$f"; fail=$((fail + 1))
    else
        printf '  \033[32m✓\033[0m %s 未混入维护者说明\n' "$f"; pass=$((pass + 1))
    fi
    if ! head -3 "$f" | grep -q "由 Scripts/generate-executor-rules.sh"; then
        printf '  \033[31m✗\033[0m %s 缺少「勿直接编辑」抬头\n' "$f"; fail=$((fail + 1))
    else
        printf '  \033[32m✓\033[0m %s 带有「勿直接编辑」抬头\n' "$f"; pass=$((pass + 1))
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    printf '\033[32m✓ %s 个用例全部通过\033[0m\n' "$pass"
    exit 0
else
    printf '\033[31m✗ %s 通过,%s 失败\033[0m\n' "$pass" "$fail"
    exit 1
fi
