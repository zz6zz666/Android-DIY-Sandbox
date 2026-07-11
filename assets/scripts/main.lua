-- Android DIY Sandbox · 默认演示皮肤 (main.lua)
--
-- 本 App 是一个"空壳 Lua 运行时": 导航栏、每个页面、主页顶栏按钮、对话框、内嵌小游戏,
-- 全部由本目录下的 Lua 脚本声明式定义。改脚本即改 App, 无需重新编译。
-- 完整 API 见同目录 AGENTS.md。改完 → 主页顶栏刷新键 或 `bash agent/sandbox reload` 生效。
--
-- 这套默认皮肤演示沙盒的核心能力:
--   · UI 组件画廊   (画廊)
--   · 网络 HTTP/WS  (网络)
--   · 文件与存储     (文件)
--   · love2d 游戏    (游戏)
-- 另含 opencode (沙盒自带 AI Agent 能力) 的环境安装入口, 顶栏右侧 (设置齿轮左边)
-- 两枚按钮来自受保护的 agent/main.lua (改崩 main.lua 也不影响)。

local agent = require("agent")   -- opencode 引擎: 安装 / 启动 / WebUI 托管

-- 导航页索引 (host.nav.go 用)
local TAB = { home = 0, gallery = 1, network = 2, files = 3, games = 4, webui = 5, terminal = 6 }

nav.tabs({
  { title = "主页",  icon = "home_outlined",          page = "home" },
  { title = "画廊",  icon = "widgets_outlined",        page = "gallery" },
  { title = "网络",  icon = "cloud_outlined",          page = "network" },
  { title = "文件",  icon = "folder_open_outlined",    page = "files" },
  { title = "游戏",  icon = "sports_esports_outlined", page = "games" },
  { title = "WebUI", icon = "language",                page = webview() },
  { title = "终端",  icon = "terminal",                page = terminal() },
})

-- ============================================================
-- opencode / Ubuntu 环境安装 (沙盒自带 Agent 能力所需)
-- 三步: 基础命令 (sudo/git/curl) / uv / opencode
-- ============================================================
local GH_PROXIES = {
  { label = "直连 (GitHub 原始)", value = "direct" },
  { label = "Ghfast",     value = "https://ghfast.top" },
  { label = "Gh-Proxy",   value = "https://gh-proxy.com" },
  { label = "GhProxyNet", value = "https://ghproxy.net" },
  { label = "GhProxyCc",  value = "https://ghproxy.cc" },
  { label = "Dpik",       value = "https://gh.dpik.top" },
  { label = "Monlor",     value = "https://gh.monlor.com" },
  { label = "Chjina",     value = "https://gh.chjina.com" },
  { label = "BokiMoe",    value = "https://github.boki.moe" },
  { label = "JasonZeng",  value = "https://gh.jasonzeng.dev" },
  { label = "GeekerTao",  value = "https://gh.geekertao.top" },
  { label = "Nxnow",      value = "https://gh.nxnow.top" },
  { label = "Npee",       value = "https://down.npee.cn" },
}
local function gh_proxy() return host.get("environment_github_proxy") or "direct" end
local function gh_proxy_label(v)
  for _, p in ipairs(GH_PROXIES) do if p.value == v then return p.label end end
  return v
end

-- 镜像测速 (纯 Lua 端): value -> { ms=数字 | err=字符串 | testing=true }
local gh_speed = {}
local GH_TEST_PATH = "/https://raw.githubusercontent.com/astral-sh/uv/main/README.md"
local function gh_test_all()
  local rev = state("gh.speed.rev", 0)
  for _, p in ipairs(GH_PROXIES) do
    if p.value ~= "direct" then
      gh_speed[p.value] = { testing = true }
      local t0 = host.now_ms()
      host.http({
        url = p.value .. GH_TEST_PATH, method = "GET", timeout = 10,
        on_done = function(res)
          if res and res.ok then
            gh_speed[p.value] = { ms = host.now_ms() - t0 }
          else
            gh_speed[p.value] = { err = "HTTP " .. tostring(res and res.status or "?") }
          end
          rev.set(rev.get() + 1)
        end,
        on_error = function() gh_speed[p.value] = { err = "失败" }; rev.set(rev.get() + 1) end,
      })
    end
  end
  rev.set(rev.get() + 1)
end
-- 直连置顶, 其余按延迟升序 (未测/失败沉底)
local function gh_sorted()
  local list = {}
  for _, p in ipairs(GH_PROXIES) do list[#list + 1] = p end
  table.sort(list, function(a, b)
    if a.value == "direct" then return true end
    if b.value == "direct" then return false end
    local sa, sb = gh_speed[a.value], gh_speed[b.value]
    local ma = (sa and sa.ms) or math.huge
    local mb = (sb and sb.ms) or math.huge
    if ma ~= mb then return ma < mb end
    return a.label < b.label
  end)
  return list
end
local function gh_status_widget(p)
  if p.value == "direct" then return text("默认", { size = 12, color = "grey" }) end
  local s = gh_speed[p.value]
  if not s or s.testing then
    return row({ spinner({ size = 14 }), spacer(6), text("测速中", { size = 12, color = "grey" }) }, { cross = "center" })
  elseif s.ms then
    local col = s.ms < 800 and "green" or (s.ms < 2000 and "orange" or "grey")
    return text(s.ms .. " ms", { size = 12, color = col, weight = "bold" })
  else
    return text(s.err or "失败", { size = 12, color = "red" })
  end
end
local function open_gh_dialog()
  gh_test_all()
  host.dialog({
    title = "GitHub 代理测速",
    build = function()
      local rows = {
        row({
          expanded(text("点选一个镜像作为下载代理", { size = 12, color = "grey" })),
          button("重新测速", gh_test_all, { variant = "text", icon = "refresh" }),
        }, { cross = "center" }),
        divider(),
      }
      for _, p in ipairs(gh_sorted()) do
        local sel = gh_proxy() == p.value
        rows[#rows + 1] = tile(p.label, {
          icon = sel and "radio_button_checked" or "radio_button_unchecked",
          trailing = gh_status_widget(p),
          onTap = function()
            host.set("environment_github_proxy", p.value)
            host.close_dialog()
            host.toast("已选择: " .. p.label)
          end,
        })
      end
      return box({ height = 400, child = scroll({ column(rows) }) })
    end,
    actions = { { label = "关闭", variant = "text" } },
  })
end

-- 选中代理时给下载 URL 加前缀 (direct 则直接 github.com)
local function gh_prefix(url)
  local p = gh_proxy()
  if p == "direct" or p == "auto" then return url end
  return p .. "/" .. url
end

local function env_pre()
  return table.concat({
    'export TMPDIR="' .. host.tmp_path() .. '"',
    'export SANDBOX_GITHUB_PROXY="' .. gh_proxy() .. '"',
    'export L_NOT_INSTALLED=未安装',
    'export L_INSTALLING=安装中',
    'export L_INSTALLED=已安装',
    'export UV_LINK_MODE=copy',
    'export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"',
    'export UV_PYTHON_INSTALL_MIRROR="' ..
      gh_prefix("https://github.com/astral-sh/python-build-standalone/releases/download") .. '"',
  }, "\n")
end

local SH_HELPERS = [==[
progress_echo(){ echo -e "\033[31m- $@\033[0m"; echo "$@" > "$TMPDIR/progress_des"; }
]==]

local SH_NET = [==[
network_test() {
  target_proxy=""
  case "$SANDBOX_GITHUB_PROXY" in
    ""|direct|auto) echo "Github 直连"; return 0 ;;
    *) target_proxy="$SANDBOX_GITHUB_PROXY"; echo "使用代理: $target_proxy"; return 0 ;;
  esac
}
]==]

local SH_BASE = [==[
install_sudo_curl_git(){
  missing=()
  for cmd in sudo git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then missing+=("$cmd"); fi
  done
  if [ ${#missing[@]} -eq 0 ]; then progress_echo "基础命令已安装"; return 0; fi
  progress_echo "基础命令缺失: ${missing[*]}, 开始安装..."
  export DEBIAN_FRONTEND=noninteractive
  apt_opts="-o Acquire::ForceIPv4=true"
  apt-get $apt_opts update || echo "apt-get update 失败, 继续尝试..."
  if ! apt-get $apt_opts install -y sudo git curl; then echo "基础命令安装失败"; return 1; fi
  progress_echo "基础命令安装完成"
}
]==]

local SH_UV = [==[
install_uv(){
  INSTALL_DIR="$HOME/.local/bin"
  ARCHIVE_FILE="uv-aarch64-unknown-linux-gnu.tar.gz"
  mkdir -p "$INSTALL_DIR"
  network_test

  # 探测最新版本: 走 releases/latest 的 302 重定向, 取最终 URL 末段 tag (无需 api.github.com)
  progress_echo "检测 uv 最新版本..."
  LATEST_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${target_proxy:+${target_proxy}/}https://github.com/astral-sh/uv/releases/latest" 2>/dev/null)
  APP_VERSION="${LATEST_URL##*/}"
  case "$APP_VERSION" in
    ""|*latest*) APP_VERSION="0.9.9"; echo "无法获取最新版本, 回退到 $APP_VERSION" ;;
    *) echo "最新 uv 版本: $APP_VERSION" ;;
  esac

  # 未强制重装, 且已安装同版本 -> 跳过
  if [ "${UV_REINSTALL:-}" != "1" ] && [ -x "$INSTALL_DIR/uv" ]; then
    CUR=$("$INSTALL_DIR/uv" --version 2>/dev/null | awk '{print $2}')
    if [ -n "$CUR" ] && [ "$CUR" = "$APP_VERSION" ]; then
      progress_echo "uv 已是最新 ($CUR)"
      return 0
    fi
    echo "当前 uv ${CUR:-未知}, 将更新到 $APP_VERSION..."
  fi
  [ "${UV_REINSTALL:-}" = "1" ] && { echo "强制重装 uv..."; rm -f "$INSTALL_DIR/uv" "$INSTALL_DIR/uvx"; }

  progress_echo "uv $L_INSTALLING ($APP_VERSION)..."
  DOWNLOAD_URL="${target_proxy:+${target_proxy}/}https://github.com/astral-sh/uv/releases/download/${APP_VERSION}/${ARCHIVE_FILE}"
  TMP_DIR=$(mktemp -d)
  echo "正在下载 uv $APP_VERSION..."
  if ! curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/$ARCHIVE_FILE"; then echo "下载失败"; rm -rf "$TMP_DIR"; exit 1; fi
  if ! tar -C "$TMP_DIR" -xf "$TMP_DIR/$ARCHIVE_FILE" --strip-components 1; then echo "解压失败"; rm -rf "$TMP_DIR"; exit 1; fi
  cp "$TMP_DIR/uv" "$TMP_DIR/uvx" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/uv" "$INSTALL_DIR/uvx"
  grep -q "$INSTALL_DIR" "$HOME/.bashrc" 2>/dev/null || echo "export PATH=$INSTALL_DIR:\$PATH" >> "$HOME/.bashrc"
  rm -rf "$TMP_DIR"
  progress_echo "uv 安装完成 ($APP_VERSION)"
}
]==]

local function env_installed(step)
  local ub = host.ubuntu_path()
  if step == "base" then
    return host.exists(ub .. "/usr/bin/git") and host.exists(ub .. "/usr/bin/curl") and host.exists(ub .. "/usr/bin/sudo")
  elseif step == "uv" then
    return host.exists(ub .. "/root/.local/bin/uv")
  elseif step == "opencode" then
    return agent.installed()
  end
  return false
end

local function install_base(_)
  host.spawn(env_pre() .. "\n" .. SH_HELPERS .. SH_BASE .. "\ninstall_sudo_curl_git\n", "基础命令")
end
local function install_uv(reinstall)
  local pre = env_pre()
  if reinstall then pre = pre .. "\nexport UV_REINSTALL=1" end
  host.spawn(pre .. "\n" .. SH_HELPERS .. SH_NET .. SH_BASE .. SH_UV .. "\ninstall_sudo_curl_git\ninstall_uv\n", "uv")
end

local ENV_STEPS = {
  { id = "base",     title = "基础命令", sub = "sudo / git / curl", run = install_base },
  { id = "uv",       title = "uv",       sub = "Python 依赖管理工具 (自动装最新版)", run = install_uv },
  { id = "opencode", title = "opencode", sub = "AI coding agent (沙盒自带)", run = function(reinstall) agent.install(reinstall) end },
}

-- ============================================================
-- 小工具
-- ============================================================
local function chip_status(ok)
  return chip(ok and "已安装" or "未安装", { color = ok and "green" or "grey" })
end

local function feature_card(iconName, title, sub, tabIndex, color)
  return inkwell(
    card({
      row({
        box({ width = 46, height = 46, child = center(icon(iconName, { size = 26, color = color or "primary" })),
          style = { bg = (color or "primary"), radius = 12, opacity = 0.14 } }),
        spacer(12),
        expanded(column({
          text(title, { weight = "bold", size = 15 }),
          text(sub, { size = 12, color = "grey" }),
        }, { gap = 2 })),
        icon("chevron_right", { color = "grey" }),
      }, { cross = "center" }),
    }),
    { onTap = function() host.nav.go(tabIndex) end }
  )
end

-- ============================================================
-- 动态加载槽位: 按需 loadlua 一个独立模块, 用完卸载 (不常驻/不污染主脚本)
-- 模块级 upvalue, 跨页面重建持久; 生命周期靠 lifecycle 的 onHide/onShow 接到模块 pause/resume
-- ============================================================
local DYN_APPS = {
  { label = "时钟",       icon = "schedule",      path = SCRIPTS .. "/apps/clock.lua" },
  { label = "调色板",     icon = "palette",       path = SCRIPTS .. "/apps/palette.lua" },
  { label = "算力·切走停", icon = "layers_clear",  path = SCRIPTS .. "/apps/compute.lua" },
  { label = "算力·后台续", icon = "bolt",          path = SCRIPTS .. "/apps/compute_bg.lua" },
}
local dyn_current, dyn_paused = nil, false

local function dyn_unload()
  if dyn_current and dyn_current.dispose then pcall(dyn_current.dispose) end
  dyn_current, dyn_paused = nil, false
end
local function dyn_load(path)
  dyn_unload()
  dyn_current = loadlua(path)
end
local function dyn_hide()   -- 不可见: 仅 unload="hidden" 的模块暂停; "back" 的继续跑
  if dyn_current and dyn_current.unload == "hidden" and dyn_current.pause and not dyn_paused then
    pcall(dyn_current.pause); dyn_paused = true
  end
end
local function dyn_show()   -- 回到可见: 恢复被暂停的模块
  if dyn_current and dyn_paused and dyn_current.resume then
    pcall(dyn_current.resume); dyn_paused = false
  end
end

-- 动态贴图 (widgets/): 主页上用 loadlua 切换不同样式的贴图
local STICKERS = {
  { name = "极光", path = SCRIPTS .. "/widgets/aurora.lua" },
  { name = "极简", path = SCRIPTS .. "/widgets/mono.lua" },
  { name = "霓虹", path = SCRIPTS .. "/widgets/neon.lua" },
}

-- 文件查看器: .md 渲染为 Markdown, 其它按纯文本; 完整内容 (超大才截断), 可滚动。
local function open_file_viewer(name, path)
  local body = host.read_file(path)
  if not body then host.toast("无法读取 (可能是二进制文件)"); return end
  if #body > 100000 then body = body:sub(1, 100000) .. "\n\n…(文件过大, 已截断)" end
  local is_md = tostring(name):lower():match("%.md$") ~= nil
  host.dialog({
    title = tostring(name),
    build = function()
      return box({ height = 460, child = scroll({
        is_md and markdown(body) or text(body, { size = 12 }),
      }) })
    end,
    actions = { { label = "关闭", variant = "text" } },
  })
end

-- 顶栏按钮说明: 图标 + 功能文字 (row 里长文本用 expanded 防溢出)
local function btn_desc(iconName, desc)
  return row({
    icon(iconName, { size = 24, color = "primary" }),
    spacer(12),
    expanded(text(desc, { size = 13 })),
  }, { cross = "center" })
end

-- ============================================================
-- 主页 home
-- ============================================================
app.page("home", function(ctx)
  local dev = host.device_info() or {}
  return {
    -- Hero: 动态 love 贴图 + 标题
    card({
      clip(love{ id = 3, game = SCRIPTS .. "/games/demo", height = 150, freeze = true }, { radius = 14 }),
      spacer(12),
      text("Android DIY Sandbox", { size = 22, weight = "bold" }),
      text("一个用 Lua 声明式定义的空壳运行时 · v" .. tostring(dev.appVersion or "0.2.0"),
        { size = 12, color = "grey" }),
    }),

    section("探索能力", {
      column({
        feature_card("widgets_outlined",        "组件画廊", "按钮 / 表单 / 布局 / 反馈", TAB.gallery,  "indigo"),
        feature_card("cloud_outlined",           "网络能力", "HTTP / WebSocket / 通知",   TAB.network,  "teal"),
        feature_card("folder_open_outlined",     "文件存储", "读写 / 目录 / SQLite",      TAB.files,    "orange"),
        feature_card("sports_esports_outlined",  "love2d",  "小游戏 · 生命周期演示",     TAB.games,    "pink"),
      }, { gap = 10 }),
    }),

    -- 动态贴图: 用 loadlua 切换 widgets/ 里的样式模块 (按需加载、用完即弃)
    section("动态贴图 (loadlua)", {
      (function()
        local sel = state("home.sticker", 1)
        local mod = loadlua(STICKERS[sel.get()].path)
        local btns = {}
        for i, s in ipairs(STICKERS) do
          btns[#btns + 1] = button(s.name, function() sel.set(i) end,
            { variant = (i == sel.get()) and "filled" or "tonal" })
        end
        return card({
          (mod and mod.build) and mod.build() or text("(加载失败)", { color = "grey" }),
          spacer(12),
          row(btns, { gap = 8 }),
        })
      end)(),
    }),

    -- opencode / 环境
    section("Agent 环境 (opencode)", {
      card({
        text("沙盒的 AI Agent 能力基于 Ubuntu 容器内的 opencode。顶栏右侧 (设置齿轮左边) 两枚按钮即入口。",
          { size = 13, color = "grey" }),
        spacer(10),
        tile("GitHub 代理", {
          subtitle = "当前: " .. gh_proxy_label(gh_proxy()) .. " · 点击测速并选择镜像",
          icon = "swap_horiz",
          onTap = open_gh_dialog,
        }),
        spacer(6),
        column((function()
          local rows = {}
          for _, s in ipairs(ENV_STEPS) do
            local ok = env_installed(s.id)
            rows[#rows + 1] = tile(s.title, {
              subtitle = s.sub,
              icon = ok and "check_circle" or "radio_button_unchecked",
              trailing = row({
                chip_status(ok),
                spacer(8),
                button(ok and "重装" or "安装", function() s.run(ok) end, { variant = ok and "text" or "tonal" }),
              }, { cross = "center" }),
            })
          end
          return rows
        end)(), { gap = 2 }),
      }),
    }),

    section("关于", {
      card("主页顶栏按钮", {
        btn_desc("refresh", "重新加载 Lua 脚本"),
        spacer(12),
        btn_desc("construction", "Lua 脚本 DIY 开发。脚本目录挂载至 Ubuntu 的 /app-lua-runtime, 用 opencode 定制"),
        spacer(12),
        btn_desc("smart_toy_outlined", "在容器中使用 opencode (/root 目录)"),
        spacer(12),
        btn_desc("settings", "应用设置"),
      }),
      spacer(10),
      card("设置页顶栏按钮", {
        btn_desc("file_download_outlined", "从外部加载并替换 Lua 脚本 (ZIP 打包整个 lua 目录, 注意不要嵌套文件夹)"),
        spacer(12),
        btn_desc("file_upload_outlined", "将 lua 目录备份至系统下载目录"),
        spacer(12),
        btn_desc("article_outlined", "查看 Lua 脚本运行日志"),
      }),
      spacer(10),
      card({
        tile("查看文档", { subtitle = "AGENTS.md · 完整 Lua API", icon = "menu_book_outlined",
          onTap = function() open_file_viewer("AGENTS.md", SCRIPTS .. "/AGENTS.md") end }),
        tile("设备", { subtitle = tostring(dev.brand or "?") .. " " .. tostring(dev.model or "") ..
          "  ·  Android " .. tostring(dev.osVersion or "?"), icon = "smartphone" }),
      }),
    }),
  }
end)

-- ============================================================
-- 画廊 gallery: UI 组件展示 (页内多标签)
-- ============================================================
-- 打字机: UTF-8 逐字循环输出 (reactive 刷新, 只重绘这一个文本, 不重建整页)
local TYPER_LINES = {
  "欢迎来到 Android DIY Sandbox",
  "用纯 Lua 声明式定义界面",
  "reactive 让文本逐字刷新, 不重建整页",
}
local function utf8_chars(s)
  local t = {}
  for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do t[#t + 1] = c end
  return t
end
local typer_timer, typer_line, typer_n = nil, 1, 0
local function typer_tick()
  local chars = utf8_chars(TYPER_LINES[typer_line])
  typer_n = typer_n + 1
  if typer_n > #chars + 8 then          -- 打完停留几拍 → 切下一句
    typer_n = 0
    typer_line = typer_line % #TYPER_LINES + 1
    return
  end
  local k = math.min(typer_n, #chars)
  reactive("gallery.typer").set(table.concat(chars, "", 1, k) .. (typer_n <= #chars and " ▌" or ""))
end
local function typer_start() if not typer_timer then typer_timer = host.interval(130, typer_tick) end end
local function typer_stop() if typer_timer then host.clear_interval(typer_timer); typer_timer = nil end end

local function swatch(name, color)
  return column({
    box({ width = 50, height = 50, child = center(icon(name, { size = 24, color = "white" })),
      style = { bg = color, radius = 15, shadow = { color = "#33000000", blur = 8, dy = 3 } } }),
    spacer(5),
    text(name, { size = 10, color = "grey" }),
  }, { cross = "center" })
end

local function gallery_basic()
  reactive("gallery.typer", "")
  typer_start()
  return column({
    card("打字机 · reactive 逐字刷新", {
      box({ height = 32, child = align(text("", { bind = "gallery.typer", size = 18, weight = "bold", color = "primary" }), "centerLeft") }),
      text("host.interval + reactive 循环输出, 只重绘这一行文本。", { size = 12, color = "grey" }),
    }),
    card("排版层级", {
      text("Display 大标题", { size = 30, weight = "bold" }),
      spacer(4),
      text("Section · 小节标题", { size = 18, weight = "bold", color = "primary" }),
      spacer(8),
      text("正文段落:界面就是组件树,每个组件是一个普通 Lua 表,可自由拼接、按条件生成。",
        { size = 14 }),
      spacer(6),
      text("Caption · 辅助说明文字", { size = 12, color = "grey" }),
    }),
    card("富文本混排", {
      richtext({
        { text = "同一行内支持 " },
        { text = "加粗", weight = "bold" },
        { text = "、" },
        { text = "彩色", color = "primary", weight = "bold" },
        { text = "、" },
        { text = "下划线", underline = true },
        { text = "、" },
        { text = "斜体", italic = true, color = "teal" },
        { text = " 自由组合。" },
      }),
    }),
    card("图标", {
      wrap({
        swatch("favorite", "red"),
        swatch("bolt", "amber"),
        swatch("rocket_launch", "indigo"),
        swatch("eco", "green"),
        swatch("cloud", "teal"),
        swatch("palette", "purple"),
      }, { spacing = 16, runSpacing = 14 }),
    }),
    card("头像 / 标签 / 角标", {
      row({
        avatar({ icon = "person", color = "indigo" }),
        spacer(10),
        avatar({ text = "AI", color = "teal" }),
        spacer(16),
        badge(icon("notifications_outlined", { size = 28 }), { label = "9", color = "red" }),
        spacer(16),
        chip("标签", { color = "primary" }),
        spacer(8),
        chip("完成", { color = "green" }),
      }, { cross = "center" }),
    }),
    card("进度", {
      row({ spinner({ size = 22 }), spacer(12), expanded(text("环形加载(不确定)")) }, { cross = "center" }),
      spacer(14),
      row({ expanded(text("下载", { size = 13 })), text("35%", { size = 13, color = "grey" }) }),
      spacer(5),
      progress(0.35),
      spacer(12),
      row({ expanded(text("完成", { size = 13 })), text("70%", { size = 13, color = "grey" }) }),
      spacer(5),
      progress(0.7, { color = "green" }),
    }),
  }, { gap = 12 })
end

local function gallery_interactive()
  local sw    = state("g.switch", true)
  local ck    = state("g.check", false)
  local sld   = state("g.slider", 40)
  local seg   = state("g.seg", "b")
  local sel   = state("g.select", "cn")
  local rad   = state("g.radio", "a")
  local echo  = state("g.text", "")
  return column({
    card("按钮", {
      wrap({
        button("Filled", function() host.toast("filled") end),
        button("Tonal", function() host.toast("tonal") end, { variant = "tonal" }),
        button("Outlined", function() host.toast("outlined") end, { variant = "outlined" }),
        button("Text", function() host.toast("text") end, { variant = "text" }),
      }, { spacing = 8, runSpacing = 8 }),
      spacer(8),
      row({
        button("发送", function() host.toast("发送") end, { icon = "send" }),
        spacer(8),
        button("删除", function() host.toast("删除") end, { icon = "delete", danger = true }),
        spacer(8),
        iconbutton("thumb_up", function() host.toast("赞") end, { tooltip = "点赞" }),
      }, { cross = "center" }),
    }),
    card("开关 / 复选 / 单选", {
      toggle({ title = "启用通知", value = sw.get(), onChanged = function(v) sw.set(v) end }),
      checkbox({ title = "记住我", value = ck.get(), onChanged = function(v) ck.set(v) end }),
      radio({ title = "主题", value = rad.get(), axis = "row",
        options = { { label = "浅色", value = "a" }, { label = "深色", value = "b" }, { label = "跟随", value = "c" } },
        onChanged = function(v) rad.set(v) end }),
    }),
    card("滑块 / 分段 / 下拉", {
      text("音量: " .. tostring(math.floor(sld.get()))),
      slider({ value = sld.get(), min = 0, max = 100, onChanged = function(v) sld.set(v) end }),
      spacer(6),
      segmented({ value = seg.get(),
        options = { { label = "日", value = "a" }, { label = "周", value = "b" }, { label = "月", value = "c" } },
        onChanged = function(v) seg.set(v) end }),
      spacer(10),
      select({ title = "语言", value = sel.get(),
        options = { { label = "简体中文", value = "cn" }, { label = "English", value = "en" }, { label = "日本語", value = "jp" } },
        onChanged = function(v) sel.set(v) end }),
    }),
    card("输入框", {
      textfield({ label = "说点什么", hint = "输入后回显", value = echo.get(),
        onChanged = function(v) echo.set(v) end }),
      spacer(6),
      text(echo.get() == "" and "(尚未输入)" or ("你输入了: " .. echo.get()), { color = "grey" }),
    }),
  }, { gap = 12 })
end

local function gallery_layout()
  local boxes = {}
  local palette = { "red", "orange", "amber", "green", "teal", "blue", "indigo", "purple" }
  for i, c in ipairs(palette) do
    boxes[i] = box({ height = 54, child = center(text(c, { color = "white", size = 11 })),
      style = { bg = c, radius = 10 } })
  end
  return column({
    card("网格 grid", {
      grid(boxes, { columns = 4, gap = 8, ratio = 1.2 }),
    }),
    card("流式 wrap", {
      wrap((function()
        local t = {}
        for _, s in ipairs({ "Lua", "Flutter", "love2d", "SQLite", "HTTP", "WebSocket", "Agent", "Sandbox" }) do
          t[#t + 1] = chip(s, { color = "primary" })
        end
        return t
      end)(), { spacing = 8, runSpacing = 8 }),
    }),
    expansion("可展开面板 expansion", {
      text("expansion 里可以放任意内容,点标题展开/收起。"),
      spacer(6),
      tile("子项 A", { icon = "circle", subtitle = "说明" }),
      tile("子项 B", { icon = "circle", subtitle = "说明" }),
    }, { icon = "expand_more" }),
    card("数据表 datatable", {
      datatable({
        headers = { "组件", "用途" },
        rows = {
          { "card", "毛玻璃卡片" },
          { "grid", "网格布局" },
          { "list", "虚拟化列表" },
          { "tabs", "页内多标签" },
        },
      }),
    }),
  }, { gap = 12 })
end

local function gallery_feedback()
  return column({
    card("轻提示 / 对话框", {
      wrap({
        button("Toast", function() host.toast("这是一条 toast") end, { variant = "tonal" }),
        button("确认框", function()
          host.confirm("确定执行该操作?", function(yes) host.toast(yes and "已确认" or "已取消") end,
            { title = "请确认", ok_text = "执行" })
        end, { variant = "tonal" }),
        button("输入框", function()
          host.input({ title = "输入名称", hint = "在此输入", default = "" },
            function(t) if t then host.toast("你输入: " .. t) end end)
        end, { variant = "tonal" }),
      }, { spacing = 8, runSpacing = 8 }),
    }),
    card("自定义对话框 / 底部菜单", {
      wrap({
        button("Dialog", function()
          host.dialog({
            title = "自定义对话框",
            build = function() return column({ text("对话框内容可放任意组件:"), spacer(6), progress(0.6) }) end,
            actions = {
              { label = "取消", variant = "text" },
              { label = "好的", variant = "filled", onTap = function() host.toast("ok") end },
            },
          })
        end, { variant = "tonal" }),
        button("Sheet", function()
          host.sheet({ title = "更多操作", items = {
            { label = "分享", icon = "share", onTap = function() host.toast("分享") end },
            { label = "编辑", icon = "edit", onTap = function() host.toast("编辑") end },
            { label = "删除", icon = "delete", danger = true, onTap = function() host.toast("删除") end },
          } })
        end, { variant = "tonal" }),
      }, { spacing = 8, runSpacing = 8 }),
    }),
    card("系统通知", {
      text("推送到状态栏, 点击可拉起 App。", { size = 13, color = "grey" }),
      spacer(8),
      button("发送通知", function()
        host.notify{ title = "Android DIY Sandbox", body = "这是一条来自 Lua 的通知 · " .. os.date("%H:%M:%S") }
        host.toast("已发送到状态栏")
      end, { icon = "notifications_active_outlined" }),
    }),
  }, { gap = 12 })
end

app.page("gallery", function()
  local t = state("gallery.tab", 1)
  local dynrev = state("gallery.dynrev", 0)   -- 触发动态槽位重建
  local function refresh() dynrev.set(dynrev.get() + 1) end

  local dyn_content
  if dyn_current and dyn_current.build then
    dyn_content = column({
      row({
        button("返回", function() dyn_unload(); refresh() end, { variant = "text", icon = "arrow_back" }),
        spacer(8),
        expanded(text(dyn_current.title or "动态应用", { weight = "bold" })),
        chip(dyn_current.unload == "back" and "后台续跑" or "切走即停",
          { color = dyn_current.unload == "back" and "secondary" or "primary" }),
      }, { cross = "center" }),
      divider(),
      box({ height = 300, child = dyn_current.build() }),
    }, { gap = 8 })
  else
    local tiles = {}
    for _, a in ipairs(DYN_APPS) do
      tiles[#tiles + 1] = tile(a.label, {
        icon = a.icon, subtitle = a.path:match("[^/]+$"),
        trailing = icon("chevron_right", { color = "grey" }),
        onTap = function() dyn_load(a.path); refresh() end,
      })
    end
    dyn_content = column({
      card({
        text("动态加载 loadlua", { weight = "bold" }),
        text("按需加载独立 .lua 模块, 用完卸载: 不常驻内存、不污染主脚本。切走标签会依模块声明暂停或续跑。",
          { size = 12, color = "grey" }),
      }),
      card(tiles),
    }, { gap = 12 })
  end

  return tabs({
    active = t.get(),
    onSelect = function(i) t.set(i) end,
    items = {
      { title = "基础", icon = "text_fields",
        content = lifecycle({ child = gallery_basic(), onShow = typer_start, onHide = typer_stop }) },
      { title = "交互", icon = "touch_app",       content = gallery_interactive() },
      { title = "布局", icon = "dashboard",       content = gallery_layout() },
      { title = "反馈", icon = "notifications",   content = gallery_feedback() },
      { title = "动态", icon = "dashboard_customize_outlined",
        content = lifecycle({ child = dyn_content, onHide = dyn_hide, onShow = dyn_show }) },
    },
  })
end)

-- ============================================================
-- 网络 network: HTTP / WebSocket / 通知 / 工具箱
-- ============================================================
local ws_handle = nil

app.page("network", function()
  local url = state("net.url", "https://www.baidu.com")
  local wsurl = state("net.wsurl", host.ws_echo_url() or "wss://echo.websocket.events")
  local wsin = state("net.wsin", "hello sandbox")
  local tin  = state("net.toolin", "sandbox")

  reactive("net.http", "点「发送」发起 GET 请求")
  reactive("net.ws", "(未连接)")
  reactive("net.wsstate", "未连接")

  local function do_http()
    reactive("net.http").set("请求中…")
    host.http{
      url = url.get(), method = "GET", timeout = 20,
      on_done = function(res)
        local b = tostring(res.body or "")
        if #b > 600 then b = b:sub(1, 600) .. "\n…(已截断)" end
        reactive("net.http").set("HTTP " .. tostring(res.status) .. "\n" .. b)
      end,
      on_error = function(err) reactive("net.http").set("错误: " .. tostring(err)) end,
    }
  end

  local function ws_connect()
    if ws_handle then pcall(function() ws_handle:close() end); ws_handle = nil end
    reactive("net.ws").set("")
    reactive("net.wsstate").set("连接中…")
    ws_handle = host.websocket{
      url = wsurl.get(),
      on_open = function() reactive("net.wsstate").set("已连接") end,
      on_message = function(data) reactive("net.ws").set(tostring(data)) end,
      on_close = function() reactive("net.wsstate").set("已关闭") end,
      on_error = function(e) reactive("net.wsstate").set("错误: " .. tostring(e)) end,
    }
  end

  local tool = tin.get()
  return {
    section("HTTP 请求", {
      card({
        textfield({ label = "URL", value = url.get(), onChanged = function(v) url.set(v) end }),
        spacer(8),
        row({
          button("发送 GET", do_http, { icon = "download" }),
          spacer(8),
          button("清空", function() reactive("net.http").set("") end, { variant = "text" }),
        }),
        spacer(10),
        box({ height = 180, child = scroll({ text("", { bind = "net.http", size = 12 }) }),
          style = { bg = "#11000000", radius = 10, padding = 10 } }),
      }),
    }),
    section("WebSocket (echo 回声)", {
      card({
        row({ icon("bolt", { color = "teal" }), spacer(6),
          expanded(text("", { bind = "net.wsstate", color = "grey" })) }, { cross = "center" }),
        spacer(8),
        textfield({ label = "服务地址 (wss://)", value = wsurl.get(), onChanged = function(v) wsurl.set(v) end }),
        spacer(8),
        textfield({ label = "发送内容", value = wsin.get(), onChanged = function(v) wsin.set(v) end }),
        spacer(8),
        wrap({
          button("连接", ws_connect, { variant = "tonal", icon = "link" }),
          button("发送", function()
            if ws_handle then ws_handle:send(wsin.get()) else host.toast("请先连接") end
          end, { icon = "send" }),
          button("断开", function()
            if ws_handle then ws_handle:close(); ws_handle = nil end
          end, { variant = "text" }),
        }, { spacing = 8, runSpacing = 8 }),
        spacer(10),
        text("收到: ", { size = 12, color = "grey" }),
        text("", { bind = "net.ws" }),
        spacer(6),
        text("默认已指向 App 内置的本地回声服务器 (ws://127.0.0.1), 无需外网即可连通。",
          { size = 11, color = "grey" }),
      }),
    }),
    section("工具箱 (哈希 / 编码)", {
      card({
        textfield({ label = "输入文本", value = tool, onChanged = function(v) tin.set(v) end }),
        spacer(8),
        datatable({
          headers = { "算法", "结果" },
          rows = {
            { "md5",    host.md5(tool) },
            { "sha256", (host.sha256(tool)):sub(1, 32) .. "…" },
            { "base64", host.base64_encode(tool) },
            { "uuid",   host.uuid() },
          },
        }),
      }),
    }),
  }
end)

-- ============================================================
-- 文件 files: 浏览 / 读写 / 持久化 / SQLite / 共享存储
-- ============================================================
local todo_db = store.open("demo_todo")
todo_db.exec[[CREATE TABLE IF NOT EXISTS todo(
  id INTEGER PRIMARY KEY AUTOINCREMENT, text TEXT NOT NULL, done INT DEFAULT 0, ts INT)]]

app.page("files", function()
  local cwd  = state("files.cwd", SCRIPTS)
  local note = state("files.note", host.read_file(host.home_path() .. "/sandbox_demo.txt") or "")

  -- 文件浏览器
  local entries = host.list_dir(cwd.get()) or {}
  table.sort(entries, function(a, b)
    if a.isDir ~= b.isDir then return a.isDir end
    return tostring(a.name) < tostring(b.name)
  end)
  local rows = {}
  if cwd.get() ~= SCRIPTS then
    rows[#rows + 1] = tile("..", { icon = "arrow_upward", onTap = function()
      cwd.set((cwd.get()):gsub("/[^/]+$", ""))
    end })
  end
  for _, e in ipairs(entries) do
    rows[#rows + 1] = tile(tostring(e.name), {
      icon = e.isDir and "folder" or "insert_drive_file_outlined",
      subtitle = e.isDir and "目录" or nil,
      onTap = function()
        if e.isDir then
          cwd.set(e.path)
        else
          open_file_viewer(e.name, e.path)
        end
      end,
    })
  end

  -- 持久化计数器
  local cnt = tonumber(host.get("demo.counter")) or 0

  -- SQLite 待办
  local todos = todo_db.query("SELECT * FROM todo ORDER BY id DESC")
  local todo_rows = {}
  for _, r in ipairs(todos) do
    local done = tostring(r.done) == "1"
    todo_rows[#todo_rows + 1] = tile(tostring(r.text), {
      icon = done and "check_box" or "check_box_outline_blank",
      trailing = iconbutton("delete_outline", function()
        todo_db.run("DELETE FROM todo WHERE id=?", { r.id })
        host.toast("已删除")
      end),
      onTap = function()
        todo_db.run("UPDATE todo SET done=? WHERE id=?", { done and 0 or 1, r.id })
      end,
    })
  end

  return {
    section("脚本目录浏览器", {
      card({
        text(cwd.get(), { size = 11, color = "grey", maxLines = 2, ellipsis = true }),
        divider(),
        box({ height = 240, child = list(rows, { scroll = true }) }),
      }),
    }),
    section("读写文本文件", {
      card({
        text("落盘到 " .. host.home_path() .. "/sandbox_demo.txt", { size = 11, color = "grey" }),
        spacer(6),
        textfield({ label = "内容", value = note.get(), onChanged = function(v) note.set(v) end }),
        spacer(8),
        row({
          button("保存", function()
            host.write_file(host.home_path() .. "/sandbox_demo.txt", note.get())
            host.toast("已保存")
          end, { icon = "save_outlined" }),
          spacer(8),
          button("读取", function()
            local p = host.home_path() .. "/sandbox_demo.txt"
            local body = host.read_file(p)
            if not body then host.toast("文件不存在, 请先保存"); return end
            note.set(body)
            host.dialog({
              title = "读取内容",
              build = function()
                return box({ height = 300, child = scroll({
                  text(#body > 0 and body or "(空文件)", { size = 13 }),
                }) })
              end,
              actions = { { label = "关闭", variant = "text" } },
            })
          end, { variant = "tonal" }),
        }),
      }),
    }),
    section("持久化键值 (重启仍在)", {
      card({
        row({
          expanded(text("计数器: " .. cnt, { size = 18, weight = "bold" })),
          iconbutton("remove", function() host.set("demo.counter", cnt - 1) end),
          iconbutton("add", function() host.set("demo.counter", cnt + 1) end),
        }, { cross = "center" }),
        text("host.set/get · 存于原生设置", { size = 11, color = "grey" }),
      }),
    }),
    section("SQLite 待办", {
      card({
        row({
          expanded(text("共 " .. #todos .. " 条", { color = "grey" })),
          button("添加", function()
            host.input({ title = "新待办", hint = "要做什么?" }, function(t)
              if t and t ~= "" then
                todo_db.run("INSERT INTO todo(text,ts) VALUES(?,?)", { t, os.time() })
                host.toast("已添加")
              end
            end)
          end, { icon = "add", variant = "tonal" }),
        }, { cross = "center" }),
        divider(),
        (#todo_rows > 0) and column(todo_rows, { gap = 2 }) or text("(点「添加」新建)", { color = "grey" }),
      }),
    }),
    section("原生共享存储", {
      card({
        text("根目录: " .. tostring(host.storage_path()), { size = 12, color = "grey" }),
        spacer(8),
        button("写入 Download/sandbox_hello.txt", function()
          local p = host.storage_path() .. "/Download/sandbox_hello.txt"
          host.write_file(p, "Hello from Android DIY Sandbox · " .. os.date())
          host.toast("已写入 (首次会弹权限申请)")
        end, { icon = "sd_storage_outlined", variant = "tonal" }),
      }),
    }),
  }
end)

-- ============================================================
-- 游戏 games: love2d 画布 + 生命周期演示
-- ============================================================
app.page("games", function()
  local t = state("games.tab", 1)
  reactive("game.score", "0")
  return tabs({
    active = t.get(),
    keepalive = false,   -- 切走标签即卸载子树: 配合 love{keepalive=false} 真正销毁进程
    onSelect = function(i) t.set(i) end,
    items = {
      {
        title = "动画", icon = "auto_awesome",
        content = column({
          card({ text("旋转多边形 · freeze=true", { weight = "bold" }),
            text("切走导航页 → 冻结, 回来从快照继续 (时钟不跳变)。", { size = 12, color = "grey" }) }),
          love{ id = 0, game = SCRIPTS .. "/games/demo", height = 320, freeze = true },
        }, { gap = 10 }),
      },
      {
        title = "跑酷", icon = "directions_run",
        content = column({
          card({
            row({
              expanded(column({
                text("点击屏幕跳跃 · keepalive=false", { weight = "bold" }),
                text("切到「动画」标签 → 进程销毁, 回来全新开始。", { size = 12, color = "grey" }),
              })),
              text("得分", { size = 13, color = "grey" }),
              spacer(6),
              text("", { bind = "game.score", size = 22, weight = "bold", color = "primary" }),
            }, { cross = "center" }),
          }),
          love{
            id = 1, game = SCRIPTS .. "/games/runner", height = 320, keepalive = false,
            onEvent = function(msg)
              if type(msg) == "table" then
                local v = (msg.data and msg.data.value) or msg.value or (msg.data and msg.data.score) or msg.score
                if type(v) == "number" then reactive("game.score").set(tostring(math.floor(v))) end
              end
            end,
          },
          button("重开", function() love.send(1, "reset") end, { icon = "refresh", variant = "tonal" }),
        }, { gap = 10 }),
      },
    },
  })
end)
