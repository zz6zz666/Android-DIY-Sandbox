# 🧩 Android DIY Sandbox

**Android DIY Sandbox** 是一个运行在安卓上的 **Lua 声明式沙盒运行时**。

App 本身是一个**空壳运行时**:导航栏、每个页面的内容、主页顶栏按钮、对话框、乃至内嵌的
love2d 小游戏,**全部由一份 Lua 脚本目录声明式定义**。改脚本即改 App,无需重新编译。

> 一句话:把手机变成一个可以用纯 Lua 快速搭 UI、跑游戏、连网络、读写文件、
> 并内置 AI coding agent 的可编程沙盒。

---

## ✨ 核心能力

- **声明式 Lua UI** — `card / row / column / grid / list / tabs / textfield / slider …`
  一整套组件,写 Lua 表即得原生 Flutter 界面;`state` / `reactive` 两级响应式状态。
- **love2d 画布** — `love{}` 把标准 love2d 工程当成普通 UI 组件嵌入页面,支持挂起 / 冻结 /
  销毁三态生命周期,UI ↔ 游戏双向消息通信。
- **网络** — `host.http`(含 SSE 流式、multipart 上传)、`host.websocket`、系统状态栏通知,
  可做"后台监听 → 通知提醒"类应用。
- **文件与存储** — 完整文件 API、原生共享存储(自动申请权限)、键值持久化、内置 SQLite。
- **AI Agent(opencode)** — 内置 Ubuntu 容器 + [opencode](https://opencode.ai) coding agent,
  可在容器里让 AI 直接编辑本沙盒的 Lua 脚本,并用 `bash agent/app-reload` 热重载生效。
- **容器终端** — 内嵌 Ubuntu(proot)终端,`host.spawn` 把容器命令绑到按钮、流式输出。
- **工具箱** — Base64 / Hex / URL 编码、MD5/SHA/HMAC、UUID、定时器、设备信息等原生能力。

脚本目录内的 `AGENTS.md` 是完整的 Lua API 开发文档。

---

## 🚀 构建

仅打包 arm64-v8a,minSdk 26。

```sh
flutter build apk --debug --flavor normal --target-platform android-arm64 --no-tree-shake-icons
```

> **必须带 `--no-tree-shake-icons`**:Lua 层允许在运行时用任意图标名/codepoint 动态构造
> `IconData`,不加该 flag 会被摇树裁掉,导致图标显示为方框。

包名:`com.diysandbox.android`(debug 为 `com.diysandbox.android.debug`)。

---

## 📂 脚本目录结构

首次启动后,默认脚本释放到 App 的脚本目录(设置页可导入/导出整包 zip):

```
scripts/
  main.lua          用户主脚本 (入口: 导航 / 页面 / 组件, 自由定制)
  agent/main.lua    Agent 入口 (受保护, 独立加载; 改崩 main.lua 也不影响)
  agent/app-reload  命令行工具: 改完脚本触发 App 重载
  AGENTS.md         完整 Lua API 文档
  games/            love2d 小游戏 (每个子目录一个 main.lua)
  apps/ widgets/    动态加载示例模块
```

默认皮肤演示了:组件画廊、网络能力、文件与存储、love2d 游戏,以及 opencode 环境入口。

---

## 🙏 致谢

- [**Code LFA**](https://github.com/nightmare-space/code_lfa):安卓端 Ubuntu 容器环境方案
- [**opencode**](https://opencode.ai):终端 AI coding agent
- [**LÖVE (love2d)**](https://love2d.org):Lua 游戏框架
- 本项目在 [AstrBot-Android-App](https://github.com/zz6zz666/AstrBot-Android-App) 的容器/终端基础设施上重构而来

---

## 📜 许可证

本项目采用 **BSD-3-Clause 许可证**,尊重根基项目 Code LFA 的开源协议。

---

## 💬 反馈

使用中遇到问题或有功能建议,欢迎提交 Issues 参与讨论。

> (注:本文档部分内容可能由 AI 生成)
