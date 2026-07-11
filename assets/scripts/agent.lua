-- agent.lua · opencode 引擎模块 (独立于界面, 可热更新)
-- 职责: opencode 二进制的安装/升级, 以及用 `opencode web` 一键启动 (自带 WebUI/自动免密/本机),
-- 就绪后在 WebView 标签打开其地址。界面编排在 main.lua; 本模块只暴露纯逻辑函数。
-- API 详见 docs/lua_api.md

local M = {}

-- 与 opencode 二进制安装保持一致的版本 (仅用于安装/升级下载)
local OPENCODE_VERSION = "1.17.18"
M.version = OPENCODE_VERSION

local function bin_host() return host.ubuntu_path() .. "/root/.local/bin/opencode" end

-- 是否已安装 opencode 二进制
function M.installed() return host.exists(bin_host()) end

-- ==================== 安装 / 升级 ====================
-- 下载 opencode-linux-arm64 二进制到容器 ~/.local/bin (复用环境管理的 GitHub 代理设置)。
local SH_OPENCODE = [==[
ensure_tools(){
  for c in curl tar; do
    if ! command -v "$c" >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get -o Acquire::ForceIPv4=true update >/dev/null 2>&1 || true
      apt-get -o Acquire::ForceIPv4=true install -y curl tar >/dev/null 2>&1 || true
      break
    fi
  done
}
resolve_proxy(){
  TARGET=""
  if [ "$OPENCODE_GH_PROXY" = "direct" ]; then return; fi
  if [ -n "$OPENCODE_GH_PROXY" ] && [ "$OPENCODE_GH_PROXY" != "auto" ]; then TARGET="$OPENCODE_GH_PROXY"; return; fi
  local check="https://raw.githubusercontent.com/anomalyco/opencode/dev/README.md"
  for p in "https://ghfast.top" "https://gh.wuliya.xin" "https://gh-proxy.com" "https://github.moeyy.xyz"; do
    echo "测试代理: $p"
    code=$(curl -k -L --connect-timeout 8 --max-time 16 -o /dev/null -s -w "%{http_code}" "${p}/${check}")
    if [ "$code" = "200" ]; then TARGET="$p"; echo "使用代理: $p"; return; fi
  done
  echo "未找到可用代理, 尝试直连"
}
install_opencode(){
  INSTALL_DIR="$HOME/.local/bin"
  mkdir -p "$INSTALL_DIR"
  ensure_tools
  resolve_proxy
  FILE="opencode-linux-arm64.tar.gz"
  URL="${TARGET:+${TARGET}/}https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${FILE}"
  echo "下载 opencode v${OPENCODE_VERSION} ..."
  TMP=$(mktemp -d 2>/dev/null || mktemp -t 'octmp.XXXXXX')
  if ! curl -fL "$URL" -o "$TMP/$FILE"; then echo "下载失败: $URL"; rm -rf "$TMP"; exit 1; fi
  echo "解压 ..."
  if ! tar -xzf "$TMP/$FILE" -C "$TMP"; then echo "解压失败"; rm -rf "$TMP"; exit 1; fi
  if [ ! -f "$TMP/opencode" ]; then echo "包内未找到 opencode 二进制"; rm -rf "$TMP"; exit 1; fi
  mv "$TMP/opencode" "$INSTALL_DIR/opencode"
  chmod 755 "$INSTALL_DIR/opencode"
  grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH=$HOME/.local/bin:$PATH' >> "$HOME/.bashrc"
  rm -rf "$TMP"
  echo "opencode 安装完成: $("$INSTALL_DIR/opencode" --version 2>/dev/null || echo '(版本未知)')"
}
]==]

-- reinstall: 是否覆盖重装 (升级同样走此路径)
function M.install(reinstall)
  local pre = table.concat({
    'export TMPDIR="' .. host.tmp_path() .. '"',
    'export OPENCODE_VERSION="' .. OPENCODE_VERSION .. '"',
    'export OPENCODE_GH_PROXY="' .. (host.get("environment_github_proxy") or "direct") .. '"',
  }, "\n")
  local body = "\ninstall_opencode\n"
  if reinstall then
    body = '\nrm -f "$HOME/.local/bin/opencode"\ninstall_opencode\n'
  end
  host.spawn(pre .. "\n" .. SH_OPENCODE .. body, "opencode 安装", "opencode_install")
end

-- ==================== 运行 / 启动 ====================
-- `opencode web` 自带 WebUI, 本机免密。它本身没有 --directory 参数(工作目录取自 cwd),
-- 但 WebUI 支持用 URL 路径 /<base64url(dir)> 深链到某工作目录。我们据此直接把 WebView
-- 打开到指定工作目录, 既绑定了工作目录, 又避开 opencode 文件选择器拒绝 home/根目录的限制。
local S = { port = nil, running = false }

M.running = function() return S.running == true end

-- 工作目录 (容器内绝对路径); 可用设置 opencode_workdir 覆盖, 默认 /root。
local function workdir()
  local w = host.get("opencode_workdir")
  if not w or w == "" then return "/root" end
  return w
end

-- base64url (与 opencode core 的 base64Encode 一致: +→- /→_ 去掉 =)
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64url(data)
  local r = ((data:gsub('.', function(x)
    local b = x:byte(); local s = ''
    for i = 8, 1, -1 do s = s .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
    return s
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
    return B64:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
  return (r:gsub('%+', '-'):gsub('/', '_'):gsub('=', ''))
end

local function open_webui(target_dir, tab_name)
  local dir = target_dir or workdir()
  host.webview_open("http://127.0.0.1:" .. S.port .. "/" .. b64url(dir), tab_name or "opencode")
end

local function wait_ready(tries, target_dir, tab_name)
  if not S.running or not S.port then return end
  if tries > 60 then host.toast("opencode 启动超时, 可在终端查看日志"); return end
  host.http({
    url = "http://127.0.0.1:" .. S.port .. "/",
    timeout = 4,
    on_done = function(res)
      if res and res.status == 200 then
        open_webui(target_dir, tab_name)
      else
        host.delay(1000, function() wait_ready(tries + 1, target_dir, tab_name) end)
      end
    end,
    on_error = function() host.delay(1000, function() wait_ready(tries + 1, target_dir, tab_name) end) end,
  })
end

-- 启动 (幂等): 未装 -> 引导安装; 已运行 -> 直接开界面; 否则起 `opencode web` 并就绪后开 WebView。
-- target_dir: 要打开的深链工作目录, 省略则用默认 (/root)
-- tab_name: WebView 标签页名称, 默认 "opencode"
function M.launch(target_dir, tab_name)
  if not M.installed() then
    host.confirm("opencode 引擎尚未安装。是否前往「环境管理」查看安装步骤?", function(yes)
      if yes then host.nav.go(0) end
    end, { title = "未安装 opencode", ok_text = "前往安装", cancel_text = "取消" })
    return
  end
  if S.running and S.port then open_webui(target_dir, tab_name); return end
  host.toast("正在启动 opencode…")
  host.free_port(41000, 45000, {}, function(p)
    if not p then host.toast("无可用端口"); return end
    S.port = p
    local wd = target_dir or workdir()
    local cmd = table.concat({
      'export PATH="$HOME/.local/bin:$PATH"',
      'mkdir -p "' .. wd .. '"',
      -- opencode 启动后会尝试用 xdg-open 自动开浏览器; 容器内无桌面, 放个空桩避免报错
      'mkdir -p "$HOME/.local/bin"',
      'printf "#!/bin/sh\\nexit 0\\n" > "$HOME/.local/bin/xdg-open" && chmod +x "$HOME/.local/bin/xdg-open"',
      "echo 'opencode 引擎启动 (127.0.0.1:" .. p .. "), 工作目录 " .. wd .. "'",
      "opencode web --hostname 127.0.0.1 --port " .. p,
    }, "\n")
    host.spawn(cmd, "opencode 引擎", "opencode_web", function()
      S.running = false
    end)
    S.running = true
    wait_ready(0, target_dir, tab_name)
  end)
end

-- 停止引擎
function M.stop()
  host.stop("opencode_web")
  S.running = false
end

return M
