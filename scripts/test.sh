#!/bin/zsh
# SelfRecord 测试统一入口（CLT 6.4 环境适配，环境事实见 docs/design.md §12.4）
#
# 本机（无完整 Xcode，仅命令行工具）跑 Swift Testing 的环境事实：
#  1. libTestingMacros.dylib 位于 CLT 的 plugins/testing/ 子目录，swift build
#     不自动加载 → 裸 swift test 报
#     "external macro implementation type 'TestingMacros…' could not be found"。
#     解法 = -Xswiftc -plugin-path 指向该目录（插件搜索目录参数会随每个派生
#     frontend 进程继承；-load-resolved-plugin 方案在 swift-driver 批量模式
#     派生子任务时会丢失，实测不可用）。
#  2. 防御性兜底：首跑失败 → 重试 → 仍失败清 .build 全量重跑。
#
# 实测（2026-10-06）：干净全量 / 增量 / swift build 后首跑 / touch 后 共 5 类
# 状态连跑全绿，30 tests。
# ⚠ 换机器 / 安装完整 Xcode / 未来 CLT 修复后，本脚本可简化为裸 `swift test`。

set -o pipefail

PLUGIN_ARGS=(
  -Xswiftc -plugin-path
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
)

swift test "${PLUGIN_ARGS[@]}"
exit_code=$?

if [ $exit_code -ne 0 ]; then
  echo ""
  echo "==> 首跑失败（见脚本头注释），重试一次…"
  swift test "${PLUGIN_ARGS[@]}"
  exit_code=$?
fi

if [ $exit_code -ne 0 ]; then
  echo ""
  echo "==> 重试仍失败，清 .build 走干净全量构建…"
  rm -rf .build
  swift test "${PLUGIN_ARGS[@]}"
  exit_code=$?
fi

exit $exit_code
