#!/bin/zsh
# 运行 DailyKit 的全部测试。
# 只装了 Command Line Tools 时，swift-testing 的宏插件要在编译器进程内加载，否则会报
# "plugin for module 'TestingMacros' not found"；装了 Xcode 后这个参数无害。
set -e
cd "$(dirname "$0")/../Packages/DailyKit"
PLUGINS="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host/plugins/testing"
swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
