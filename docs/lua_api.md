# AstrBot 泡泡版 · Lua 脚本 API

App 本体是一个"空壳运行时"：导航栏、主页内容、从旧设置迁出的操作项等**全部由 Lua 脚本声明式定义**。
修改脚本无需重新编译——改完在「设置 → Lua 热更新」重载即可生效。

- 脚本位置：`{configPath}/scripts/main.lua`（首次运行从内置默认释放）
- 引擎：LuaJIT 2.1（真机验证 `jit=true`），通过 dart:ffi 双向桥接
- 内置 `prelude`（`lib/core/lua/lua_prelude.dart`）在用户脚本前执行，提供下述全部 API

---

## 1. 核心概念

全 App 的操作只有两类：
1. **原生层操作**：剪贴板、文件、对话框、导航、设置存储、退出……（`host.*`）
2. **容器交互**：传入命令 → 取回结果（`host.exec` / `host.container`）

UI 用**声明式组件**描述：`组件 = 类型 + 属性(props) + 子节点`。每个页面是一个 `build(ctx)` 函数，
返回组件树；App 状态变化时自动重建。

---

## 2. 页面与导航注册

```lua
-- 导航栏 tab 列表。page 可为: "home"(特殊内置) / "terminal"(特殊内置) /
-- webview(url)(普通页) / 任意已注册的 Lua 页面名(普通页, 可做游戏等)
nav.tabs({
  { title = "主页",  icon = "home",     page = "home" },
  { title = "WebUI", icon = "language", page = webview("http://127.0.0.1:6185") },
  { title = "终端",  icon = "terminal", page = terminal() },
})

-- 注册一个页面的 build 函数。ctx 为实时状态快照 (见下)
app.page("home", function(ctx)
  return { card("标题", { text("你好") }) }   -- 返回组件或组件数组
end)
```

> 特殊内置页：`home`（唯一带固定齿轮设置入口）、`terminal`。其余（含 webview、游戏）均为普通页。

### ctx 实时状态快照
```lua
ctx.astrbot.running / starting / stopping   -- bool
ctx.ports.dashboard / onebot / napcat       -- int
```

---

## 3. host —— 宿主能力

### 交互
| API | 说明 |
|-----|------|
| `host.toast(msg)` | 顶部提示条 |
| `host.log(msg)` | 写入 logcat (`[Lua] ...`) |
| `host.confirm(msg, cb)` | 确认框; `cb(yes:boolean)` |
| `host.input(opts, cb)` | 输入框; `opts={title,hint,default}`; `cb(text\|nil)` |
| `host.dialog(spec)` | 自定义组件对话框; `spec={title, build=function() return <组件> end}`, 随 state 重建 |
| `host.close_dialog()` | 关闭当前对话框 |
| `host.exit_app()` | 退出应用 |

### 设置存储 / 路径 / 端口
| API | 说明 |
|-----|------|
| `host.get(key)` / `host.set(key, val)` | 读写持久化设置 (set 会触发重建) |
| `host.ubuntu_path()` | 容器 rootfs 路径 |
| `host.home_path()` | App home 路径 |
| `host.port(name)` | `"dashboard"`/`"onebot"`/`"napcat"` 端口 |

### 文件 / 目录
| API | 说明 |
|-----|------|
| `host.read_file(p)` → string\|nil | 读文件 |
| `host.write_file(p, content)` → bool | 写文件 |
| `host.exists(p)` → bool | 文件或目录是否存在 |
| `host.delete_dir(p)` / `host.delete_file(p)` | 删除 |
| `host.list_dir(p)` → `{ {name,path,isDir}, ... }` | 列目录 |

### 容器交互（核心通用积木）
| API | 说明 |
|-----|------|
| `host.exec(cmd, cb)` | 在容器执行命令并**取回输出**; `cb({code=int, output=string})` |
| `host.container(cmd, cb)` | 执行命令(不取输出); `cb()` 完成回调 |
| `host.run(program, args, cb)` | **宿主层**进程执行 (非容器, 如 busybox tar); `cb({code,stdout,stderr})` |
| `host.astrbot.start()/stop()/toggle()` | AstrBot 启停 |
| `host.run_env_step(step, title, reinstall, cb)` | 运行环境安装步骤 (base/uv/napcat/astrbot) |
| `host.bin_path()` | 原生二进制目录 (bash/busybox/proot 等) |
| `host.backup_dir()` | 备份目录 (/storage/emulated/0/Download/AstrBotBubble) |
| `host.mkdirs(p)` | 递归创建目录 |

### NapCat 账号操作
| API | 说明 |
|-----|------|
| `host.napcat.add(port, cb)` | 新增账号 (port 可 nil 自动分配) |
| `host.napcat.start(id, cb)` / `stop(id, cb)` | 启停实例 |
| `host.napcat.open(id)` | 打开该账号 WebUI 并切到 webview tab |
| `host.napcat.url(id)` | 返回 WebUI 完整链接 |
| `host.napcat.edit(id, name, port, cb)` | 修改名称/端口 |
| `host.napcat.logout(id, cb)` / `delete(id, cb)` | 退出登录 / 删除 |
| `host.napcat.binding(id, cb)` | 取绑定数据 `cb({state,clients,adapters,selectedClient,selectedAdapter})` |
| `host.napcat.bind_ws(id, name, cb)` | 绑定 websocket client |
| `host.napcat.bind_adapter(id, adapterId, cb)` | 绑定 AstrBot 适配器 (含换绑/覆盖确认) |
| `host.napcat.repair(id, cb)` | 修复绑定 |
| `host.napcat.create_adapter(id, name, cb)` | 新建 AstrBot 适配器 |

> `ctx.napcat` = 账号列表, 每项含 `{id,name,qq,webUiPort,token,running,...}`。

> 提示：AstrBot / NapCat 的复杂操作 = `host.exec` 跑命令 + `json` 读写配置 + 组件拼 UI，
> 全部可在 Lua 内组合实现，无需原生特例。

### 其它原生
| API | 说明 |
|-----|------|
| `host.clipboard.copy(s)` / `host.clipboard.paste()` | 剪贴板 |
| `host.nav.go(tabIndex)` | 切换到第 N 个导航 tab (0 起) |
| `host.open_webview(url)` | 切换到 webview tab |
| `host.open_url(url)` | 用系统浏览器打开外链 |

---

## 4. 反应式状态

```lua
local expanded = state("home.expanded", false)  -- (key, default)
expanded.get()          -- 读
expanded.set(true)      -- 写, 触发本页重建
```

---

## 5. 组件积木

所有组件都接受可选 `style`（见第 6 节）。

### 布局
| 构造 | 说明 |
|------|------|
| `column(children, {main,cross,gap,expand})` | 纵向排列 |
| `row(children, {main,cross,gap,expand})` | 横向排列 |
| `stack(children)` | 层叠 |
| `wrap(children, {spacing,runSpacing})` | 自动换行 |
| `padding(child, pad)` | 内边距 (pad 见 edge 格式) |
| `align(child, alignName)` | 对齐 |
| `center(child)` | 居中 |
| `expanded(child, flex)` | 在 row/column 中占据剩余空间 |
| `spacer(size?)` | 间隔 (省略 size 则弹性) |
| `box({width,height,child})` | 定尺寸盒子 |
| `scroll(children, {axis})` | 滚动容器 |

### 内容
| 构造 | 说明 |
|------|------|
| `text(s, {size,weight,color,align,maxLines,ellipsis})` | 文本 |
| `icon(name, {size,color})` | 图标 (名称见图标表) |
| `image(path, {width,height})` | 本地/网络图片 |
| `spinner({size})` | 环形加载 |
| `progress(value, ...)` | 线形进度 (value 0..1, nil 为不确定) |
| `chip(label, {color})` | 标签 |
| `badge(child, {label})` | 角标 |
| `divider()` | 分隔线 |

### 交互
| 构造 | 说明 |
|------|------|
| `button(label, onTap, {variant,icon,color,danger})` | 按钮 (variant: filled/tonal/outlined/text) |
| `iconbutton(name, onTap, {tooltip,color})` | 图标按钮 |
| `menu(iconName, items)` | 弹出菜单; items: `{{label, onTap, enabled}, ...}` |
| `tile(title, {subtitle,icon,iconColor,trailing,onTap})` | 列表项 (trailing 可为组件) |
| `toggle({title,subtitle,value,onChanged})` | 开关 |
| `slider({label,value,min,max,onChanged})` | 滑块 |
| `select({title,value,options,onChanged})` | 下拉 (options: `{{label,value},...}`) |
| `textfield({label,hint,value,onChanged})` | 输入框 |
| `checkbox({title,value,onChanged})` | 复选 |

### 容器
| 构造 | 说明 |
|------|------|
| `card(title, children)` 或 `card(children)` | 毛玻璃卡片 |
| `section(title, children)` | 带标题的分组 |
| `expansion(title, children, {icon})` | 可展开面板 |

---

## 6. 样式系统 (style)

任意组件可传 `style = { ... }`：

| 属性 | 取值 |
|------|------|
| `bg` / `border` / `color` | 颜色: `"#RRGGBB"` 或语义名 `primary/secondary/error/surface/white/black/red/green/orange/blue/grey` |
| `radius` | 圆角半径 (数字) |
| `width` / `height` | 尺寸 |
| `padding` / `margin` | 见 edge 格式 |
| `opacity` | 0..1 |
| `align` | `topLeft/topCenter/.../center/.../bottomRight` |

文本另支持 `size` / `weight`(`bold/w600/500/normal` 或数字) / `color`。

**edge 格式**：`8`（四边）/ `{h, v}`（水平,垂直）/ `{l, t, r, b}` / `{left=,top=,right=,bottom=}`

---

## 7. JSON

纯 Lua 实现，用于读写容器内配置文件（如 `cmd_config.json`）：
```lua
local t = json.decode(host.read_file(path))
t.dashboard.port = 6185
host.write_file(path, json.encode(t))
```

---

## 8. 图标名

`home dashboard language terminal lan settings_ethernet refresh delete restart_alt backup
restore build science folder code battery exit info image layers blur privacy settings play
play_circle pause_circle stop link download upload edit add more star bug extension construction
pets check_circle error lock copy logout qr warning`

（需要新图标时在 `lib/ui/lua/lua_view.dart` 的 `_kIcons` 表中补充。）
