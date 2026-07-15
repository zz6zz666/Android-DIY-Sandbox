# AGENTS.md

## 构建

**normal (系统 WebView):**

```
flutter build apk --debug --flavor normal --target-platform android-arm64 --no-tree-shake-icons
```

```
flutter build apk --release --flavor normal --target-platform android-arm64 --no-tree-shake-icons && cp build/app/outputs/apk/normal/release/Android-DIY-Sandbox-*.apk build/app/outputs/flutter-apk/ && APK=$(ls build/app/outputs/flutter-apk/Android-DIY-Sandbox-*.apk | head -1) && sha1sum "$APK" | cut -d' ' -f1 > "${APK}.sha1"
```

**chromium (内置 Chromium 内核):**

```
flutter build apk --debug --flavor chromium --target-platform android-arm64 --no-tree-shake-icons
```

```
flutter build apk --release --flavor chromium --target-platform android-arm64 --no-tree-shake-icons && cp build/app/outputs/apk/chromium/release/Android-DIY-Sandbox-*.apk build/app/outputs/flutter-apk/ && APK=$(ls build/app/outputs/flutter-apk/Android-DIY-Sandbox-*.apk | head -1) && sha1sum "$APK" | cut -d' ' -f1 > "${APK}.sha1"
```

Gradle 已配置 `outputFileName`,产物在 `android/app/outputs/apk/` 下自动命名为
`Android-DIY-Sandbox-v{versionName}-{flavor}-{buildType}.apk` (normal 和 chromium 均带显式 flavor 标记)。
Flutter 工具会额外复制一份到 `build/app/outputs/flutter-apk/` (默认名 `app-{flavor}-{buildType}.apk`)。
上方的构建命令会将 Gradle 目录下的重命名产物连同 SHA 校验文件同步到 `flutter-apk/`。

**必须带 `--no-tree-shake-icons`**:Lua 层 UI 允许用任意图标名/codepoint 在运行时动态构造 `IconData`
(见 `lib/ui/lua/lua_view.dart` 的 `luaIconFor` 与 `lib/ui/lua/material_icons_map.g.dart`)。
不加该 flag 时 Flutter 会摇树裁掉未静态引用的图标,导致 Lua 指定的图标显示为方框。

真机:XT2507-5,包名 `com.diysandbox.android.debug`。

## Lua UI 图标映射

`lib/ui/lua/material_icons_map.g.dart` 是**生成文件**,来自 Flutter SDK 的
`packages/flutter/lib/src/material/icons.dart`。升级 Flutter 后如需刷新,重跑生成脚本
(解析 `static const IconData NAME = IconData(0xXXXX ...)` → 名称/codepoint/RTL 映射)。

## 皮肤打包

**默认皮肤** (`assets/scripts/` 全量无嵌套 zip):
```
( cd assets/scripts && zip -r ../../build/Sandbox_Default_Demo_Skin-v$(grep '^version: ' ../../pubspec.yaml | sed 's/.*: //' | cut -d+ -f1).zip . )
```

**空皮肤** (仅保留 agent/ sandbox/ agent.lua AGENTS.md):
```
( cd assets/scripts && zip -r ../../build/Sandbox_Empty_Skin-v$(grep '^version: ' ../../pubspec.yaml | sed 's/.*: //' | cut -d+ -f1).zip agent/ sandbox/ agent.lua AGENTS.md )
```

## 发布

1. 构建 normal + chromium release APK (含 SHA1)
2. 打包默认皮肤 + 空皮肤 zip
3. 先上传 normal APK/SHA1 到 GitHub Release (老客户端取第一个 .apk)
4. 再上传 chromium APK/SHA1 和两个 skin zip
5. 检查更新匹配逻辑: `-normal-` / `-chromium-` 显式标记
