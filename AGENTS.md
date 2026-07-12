# AGENTS.md

## 构建

**APK(arm64, debug):**

```
flutter build apk --debug --flavor normal --target-platform android-arm64 --no-tree-shake-icons
```

**APK(arm64, release):**

```
flutter build apk --release --flavor normal --target-platform android-arm64 --no-tree-shake-icons && cp build/app/outputs/apk/normal/release/Android-DIY-Sandbox-*.apk build/app/outputs/flutter-apk/ && APK=$(ls build/app/outputs/flutter-apk/Android-DIY-Sandbox-*.apk | head -1) && sha1sum "$APK" | cut -d' ' -f1 > "${APK}.sha1"
```

Gradle 已配置 `outputFileName`,产物在 `android/app/outputs/apk/` 下自动命名为
`Android-DIY-Sandbox-v{versionName}-{buildType}.apk`。
Flutter 工具会额外复制一份到 `build/app/outputs/flutter-apk/` (默认名 `app-normal-{buildType}.apk`)。
上方的构建命令会将 Gradle 目录下的重命名产物连同 SHA 校验文件同步到 `flutter-apk/`。

**必须带 `--no-tree-shake-icons`**:Lua 层 UI 允许用任意图标名/codepoint 在运行时动态构造 `IconData`
(见 `lib/ui/lua/lua_view.dart` 的 `luaIconFor` 与 `lib/ui/lua/material_icons_map.g.dart`)。
不加该 flag 时 Flutter 会摇树裁掉未静态引用的图标,导致 Lua 指定的图标显示为方框。

真机:XT2507-5,包名 `com.diysandbox.android.debug`。

## Lua UI 图标映射

`lib/ui/lua/material_icons_map.g.dart` 是**生成文件**,来自 Flutter SDK 的
`packages/flutter/lib/src/material/icons.dart`。升级 Flutter 后如需刷新,重跑生成脚本
(解析 `static const IconData NAME = IconData(0xXXXX ...)` → 名称/codepoint/RTL 映射)。
