# AGENTS.md

## 构建

APK(arm64, debug):

```
flutter build apk --debug --flavor normal --target-platform android-arm64 --no-tree-shake-icons
```

**必须带 `--no-tree-shake-icons`**:Lua 层 UI 允许用任意图标名/codepoint 在运行时动态构造 `IconData`
(见 `lib/ui/lua/lua_view.dart` 的 `luaIconFor` 与 `lib/ui/lua/material_icons_map.g.dart`)。
不加该 flag 时 Flutter 会摇树裁掉未静态引用的图标,导致 Lua 指定的图标显示为方框。

真机:XT2507-5,包名 `com.astrbot.astrbot_bubble.debug`。

## Lua UI 图标映射

`lib/ui/lua/material_icons_map.g.dart` 是**生成文件**,来自 Flutter SDK 的
`packages/flutter/lib/src/material/icons.dart`。升级 Flutter 后如需刷新,重跑生成脚本
(解析 `static const IconData NAME = IconData(0xXXXX ...)` → 名称/codepoint/RTL 映射)。
