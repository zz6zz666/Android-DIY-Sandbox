-- AstrBot 泡泡版 · 默认脚本 (位于 {configPath}/scripts/main.lua, 可直接编辑, 设置页"Lua 热更新"重载)
-- API 详见 docs/lua_api.md

-- 独立 agent 模块 (opencode 引擎: 安装/启动/WebUI 托管), 界面在本文件编排
local agent = require("agent")

-- 端口管理: 纯 Lua, 基于通用设置存储 host.get/set (无 Dart 特定端口逻辑)
local ports = {
  key = { dashboard = "astrbot_dashboard_port", onebot = "astrbot_onebot_ws_port", napcat = "napcat_webui_port" },
  def = { dashboard = 6185, onebot = 6199, napcat = 6099 },
}
function ports.get(name)
  local v = tonumber(host.get(ports.key[name]))
  if v and v >= 1024 and v <= 65535 then return v end
  return ports.def[name]
end
function ports.set(name, v) host.set(ports.key[name], v) end

nav.tabs({
  { title = "主页",  icon = "home",     page = "home" },
  { title = "WebUI", icon = "language", page = webview("http://127.0.0.1:" .. ports.get("dashboard")) },
  { title = "终端",  icon = "terminal", page = terminal() },
})

-- GitHub 代理选项
local PROXIES = {
  { label = "自动测试",     value = "auto" },
  { label = "直连 GitHub",  value = "direct" },
  { label = "Ghfast",       value = "https://ghfast.top" },
  { label = "Wuliya",       value = "https://gh.wuliya.xin" },
  { label = "GH Proxy",     value = "https://gh-proxy.com" },
  { label = "Moeyy",        value = "https://github.moeyy.xyz" },
}

-- 环境安装状态: 用通用积木 host.exists 在 Lua 侧判断
local function env_installed(step)
  local ub = host.ubuntu_path()
  if step == "base" then
    return host.exists(ub .. "/usr/bin/git") and host.exists(ub .. "/usr/bin/curl") and host.exists(ub .. "/usr/bin/sudo")
  elseif step == "uv" then
    return host.exists(ub .. "/root/.local/bin/uv")
  elseif step == "napcat" then
    return host.exists(ub .. "/root/launcher.sh") and host.exists(ub .. "/root/napcat")
  elseif step == "astrbot" then
    return host.exists(ub .. "/root/AstrBot/main.py") and host.exists(ub .. "/root/AstrBot/.venv")
  elseif step == "opencode" then
    return agent.installed()
  end
  return false
end

local ENV_STEPS = {
  { id = "base",    title = "基础命令", sub = "sudo / git / curl" },
  { id = "uv",      title = "uv",       sub = "Python 依赖管理工具" },
  { id = "napcat",  title = "NapCat",   sub = "安装或修复 NapCatQQ" },
  { id = "astrbot", title = "AstrBot",  sub = "克隆 AstrBot 并同步依赖" },
  { id = "opencode", title = "opencode", sub = "AI 编程助手引擎 (v" .. agent.version .. ")" },
}

-- ============================================================
-- 安装命令: 每个按钮直接下发自己那一步的命令 (无中央分发器)。
-- 共享的辅助函数 (progress/network/各 install_*) 作为 verbatim 常量复用,
-- 每个步骤按钮显式列出自己要执行的调用序列。
-- ============================================================

-- 进容器执行时需要的环境变量前缀
local function env_pre(force)
  return table.concat({
    'export TMPDIR="' .. host.tmp_path() .. '"',
    'export ASTRBOT_DASHBOARD_PORT=' .. tostring(ports.get("dashboard")),
    'export ASTRBOT_ONEBOT_WS_PORT=' .. tostring(ports.get("onebot")),
    'export ASTRBOT_GITHUB_PROXY="' .. (host.get("environment_github_proxy") or "auto") .. '"',
    'export ASTRBOT_FORCE_REINSTALL_STEP="' .. (force or "") .. '"',
    'export L_NOT_INSTALLED=未安装',
    'export L_INSTALLING=安装中',
    'export L_INSTALLED=已安装',
    'export UV_LINK_MODE=copy',
    'export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"',
    'export UV_PYTHON_INSTALL_MIRROR="https://ghfast.top/https://github.com/astral-sh/python-build-standalone/releases/download"',
  }, "\n")
end

-- 共享辅助 (verbatim)
local SH_HELPERS = [==[
progress_echo(){
  echo -e "\033[31m- $@\033[0m"
  echo "$@" > "$TMPDIR/progress_des"
}
prepare_reinstall_step(){
  case "$1" in
    uv)
      progress_echo "uv 重装准备中"
      rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
      ;;
    napcat)
      progress_echo "NapCat 重装准备中"
      if [ -d "$HOME/napcat/config" ]; then
        rm -rf "$HOME/napcat_config_backup"
        cp -r "$HOME/napcat/config" "$HOME/napcat_config_backup"
      fi
      pkill -f 'qq --no-sandbox' 2>/dev/null || true
      pkill -f 'NapCat' 2>/dev/null || true
      pkill -f 'napcat' 2>/dev/null || true
      rm -rf "$HOME/napcat" "$HOME/napcat.sh" "$HOME/launcher.sh"
      ;;
    astrbot)
      progress_echo "AstrBot 重装准备中"
      killall uv 2>/dev/null || true
      rm -rf "$HOME/AstrBot_data_reinstall_backup"
      if [ -d "$HOME/AstrBot/data" ]; then
        cp -r "$HOME/AstrBot/data" "$HOME/AstrBot_data_reinstall_backup"
      fi
      rm -rf "$HOME/AstrBot" "$HOME/AstrBot_tmp"
      ;;
  esac
}
maybe_prepare_reinstall(){
  if [ "$ASTRBOT_FORCE_REINSTALL_STEP" = "$1" ]; then
    prepare_reinstall_step "$1"
  fi
}
]==]

local SH_NET = [==[
network_test() {
    local timeout=10
    local status=0
    local found=0
    target_proxy=""
    echo "开始网络测试: Github..."
    if [ "$ASTRBOT_GITHUB_PROXY" = "direct" ]; then
        echo "已选择 Github 直连"; target_proxy=""; return 0
    fi
    if [ -n "$ASTRBOT_GITHUB_PROXY" ] && [ "$ASTRBOT_GITHUB_PROXY" != "auto" ]; then
        target_proxy="$ASTRBOT_GITHUB_PROXY"; echo "已选择 Github 代理: $target_proxy"; return 0
    fi
    proxy_arr=("https://ghfast.top" "https://gh.wuliya.xin" "https://gh-proxy.com" "https://github.moeyy.xyz")
    check_url="https://raw.githubusercontent.com/NapNeko/NapCatQQ/main/package.json"
    for proxy in "${proxy_arr[@]}"; do
        echo "测试代理: ${proxy}"
        status=$(curl -k -L --connect-timeout ${timeout} --max-time $((timeout*2)) -o /dev/null -s -w "%{http_code}" "${proxy}/${check_url}")
        if [ $? -ne 0 ]; then echo "代理 ${proxy} 测试失败或超时"; continue; fi
        if [ "${status}" = "200" ]; then found=1; target_proxy="${proxy}"; echo "将使用Github代理: ${proxy}"; break; fi
    done
    if [ ${found} -eq 0 ]; then
        echo "警告: 无法找到可用的Github代理，将尝试直连..."
        status=$(curl -k --connect-timeout ${timeout} --max-time $((timeout*2)) -o /dev/null -s -w "%{http_code}" "${check_url}")
        if [ $? -eq 0 ] && [ "${status}" = "200" ]; then echo "直连Github成功"; target_proxy=""; else echo "警告: 无法连接 Github，将继续尝试安装。"; fi
    fi
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
  if ! apt-get $apt_opts update; then echo "apt-get update 失败，继续尝试安装..."; fi
  if ! apt-get $apt_opts install -y sudo git curl; then echo "基础命令安装失败"; return 1; fi
  for cmd in sudo git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then echo "基础命令安装后仍缺少: $cmd"; return 1; fi
  done
  progress_echo "基础命令安装完成"
}
]==]

local SH_UV = [==[
install_uv(){
  INSTALL_DIR="$HOME/.local/bin"
  if [ ! -x "$INSTALL_DIR/uv" ]; then
    progress_echo "uv $L_NOT_INSTALLED，$L_INSTALLING..."
    network_test
    APP_NAME="uv"
    APP_VERSION="0.9.9"
    ARCHIVE_FILE="uv-aarch64-unknown-linux-gnu.tar.gz"
    DOWNLOAD_URL="${target_proxy:+${target_proxy}/}https://github.com/astral-sh/uv/releases/download/${APP_VERSION}/${ARCHIVE_FILE}"
    for cmd in tar mkdir cp chmod mktemp rm curl; do
      if ! command -v $cmd >/dev/null 2>&1; then echo "错误：缺少必要命令 $cmd"; exit 1; fi
    done
    mkdir -p $INSTALL_DIR
    TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -t 'uvtmp.XXXXXX')
    if [ -z "$TMP_DIR" ]; then echo "创建临时目录失败"; exit 1; fi
    mkdir -p "$TMP_DIR"
    TMP_ARCHIVE="$TMP_DIR/$ARCHIVE_FILE"
    echo "正在下载 $APP_NAME $APP_VERSION..."
    if ! curl -fL $DOWNLOAD_URL -o $TMP_ARCHIVE; then echo "下载失败"; rm -rf $TMP_DIR; exit 1; fi
    echo "正在解压 $APP_NAME..."
    if ! tar -C "$TMP_DIR" -xf "$TMP_ARCHIVE" --strip-components 1; then echo "解压失败"; rm -rf $TMP_DIR; exit 1; fi
    cp $TMP_DIR/uv $TMP_DIR/uvx $INSTALL_DIR/
    chmod +x $INSTALL_DIR/uv $INSTALL_DIR/uvx
    if ! grep -q "$INSTALL_DIR" $HOME/.bashrc; then
      echo "export PATH=$INSTALL_DIR:\$PATH" >> $HOME/.bashrc
      source $HOME/.bashrc
      echo "已自动配置 $APP_NAME 路径到环境变量"
    fi
    rm -rf $TMP_DIR
  else
    progress_echo "uv $L_INSTALLED"
  fi
}
]==]

local SH_NAPCAT = [==[
configure_napcat_token_ttl(){
  if [ -f "$HOME/napcat/napcat.mjs" ]; then
    sed -i -E "s#static MAX_CREDENTIAL_VALID_SECONDS = [0-9]+#static MAX_CREDENTIAL_VALID_SECONDS = 604800#g" "$HOME/napcat/napcat.mjs"
    sed -i -E 's#Rp\.set\(`revoked:\$\{r\}`, !0, [0-9]+\)#Rp.set(`revoked:${r}`, !0, 604800)#g' "$HOME/napcat/napcat.mjs"
  fi
}
install_napcat(){
  if [ ! -f "$HOME/launcher.sh" ]; then
    progress_echo "Napcat $L_NOT_INSTALLED，$L_INSTALLING..."
    apt --fix-broken install -y
    if [ -d "$HOME/napcat/config" ]; then
      echo "备份 NapCat 配置目录..."
      cp -r "$HOME/napcat/config" "$HOME/napcat_config_backup"
    fi
    rm -rf $HOME/napcat
    cd $HOME
    curl -o napcat.sh https://raw.githubusercontent.com/NapNeko/napcat-linux-installer/refs/heads/main/install.sh
    if ! chmod +x napcat.sh; then echo "设置 napcat.sh 执行权限失败"; exit 1; fi
    bash napcat.sh
    pkill -f 'qq --no-sandbox' 2>/dev/null || true
    pkill -f 'NapCat' 2>/dev/null || true
    pkill -f 'napcat' 2>/dev/null || true
    if [ -d "$HOME/napcat_config_backup" ]; then
      echo "恢复 NapCat 配置目录..."
      mkdir -p "$HOME/napcat/config"
      cp -r "$HOME/napcat_config_backup"/* "$HOME/napcat/config/"
      rm -rf "$HOME/napcat_config_backup"
    fi
  if [ ! -f "$HOME/napcat/config/onebot11.json" ]; then
    echo "写入 onebot11.json 默认配置文件"
    cat > "$HOME/napcat/config/onebot11.json" <<EOF
{
  "network": {
    "httpServers": [],
    "httpClients": [],
    "websocketServers": [],
    "websocketClients": [
      {
        "name": "WsClient",
        "enable": true,
        "url": "ws://localhost:${ASTRBOT_ONEBOT_WS_PORT:-6199}/ws",
        "messagePostFormat": "array",
        "reportSelfMessage": false,
        "reconnectInterval": 5000,
        "token": "kasdkfljsadhlskdjhasdlkfshdlafksjdhf",
        "debug": false,
        "heartInterval": 30000
      }
    ]
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
EOF
  fi
fi
  configure_napcat_token_ttl
  progress_echo "Napcat $L_INSTALLED"
}
]==]

local SH_ASTRBOT = [==[
install_astrbot(){
  local INSTALL_DIR="$HOME/AstrBot"
  local CLONE_TEMP_DIR="$HOME/AstrBot_tmp"
  local BACKUP_DIR="/sdcard/Download/AstrBotBubble"
  rm -rf "$CLONE_TEMP_DIR"
  killall uv 2>/dev/null
  if [ -d "$INSTALL_DIR" ] && { [ ! -f "$INSTALL_DIR/pyproject.toml" ] || [ ! -f "$INSTALL_DIR/main.py" ]; }; then
    echo "AstrBot 安装目录不完整，准备重新安装..."
    rm -rf "$HOME/AstrBot_data_reinstall_backup"
    if [ -d "$INSTALL_DIR/data" ]; then cp -r "$INSTALL_DIR/data" "$HOME/AstrBot_data_reinstall_backup"; fi
    rm -rf "$INSTALL_DIR"
  fi
  if [ ! -d "$INSTALL_DIR" ]; then
    cd $HOME
    progress_echo "AstrBot $L_NOT_INSTALLED，$L_INSTALLING..."
    echo "正在获取 AstrBot 最新版本..."
    if [ -n "$CUSTOM_GIT_CLONE" ]; then
      echo "使用自定义 Git Clone 命令..."
      if ! eval "$CUSTOM_GIT_CLONE"; then echo "自定义 Git Clone 命令执行失败"; exit 1; fi
      if [ -d "AstrBot" ]; then mv "AstrBot" "$CLONE_TEMP_DIR"; else echo "错误: 未找到 AstrBot 目录"; exit 1; fi
    else
      network_test
      LATEST_TAG=$(git ls-remote --tags --sort='-v:refname' ${target_proxy:+${target_proxy}/}https://github.com/AstrBotDevs/AstrBot.git | awk -F'/' '{print $3}' | sed 's/\^{}//g' | grep -E '^v?[0-9]+(\.[0-9]+){1,2}$' | head -n 1)
      if [ -z "$LATEST_TAG" ]; then echo "警告: 无法获取最新 tag，使用 master 分支"; CLONE_BRANCH="master"; else echo "最新正式版: $LATEST_TAG"; CLONE_BRANCH="$LATEST_TAG"; fi
      echo "正在克隆 AstrBot 仓库，分支/标签: $CLONE_BRANCH..."
      if ! git clone --depth=1 --branch "$CLONE_BRANCH" ${target_proxy:+${target_proxy}/}https://github.com/AstrBotDevs/AstrBot.git "$CLONE_TEMP_DIR"; then
        echo "克隆 AstrBot 仓库失败"; rm -rf "$CLONE_TEMP_DIR"; exit 1
      fi
    fi
    mv "$CLONE_TEMP_DIR" "$INSTALL_DIR"
  else
    progress_echo "AstrBot $L_INSTALLED"
  fi
  progress_echo "AstrBot 初始化中"
  cd "$INSTALL_DIR"
  if [ ! -d "$INSTALL_DIR/data" ]; then
    echo "检测到 data 目录不存在，初始化数据目录..."
    mkdir "$INSTALL_DIR/data"
    if [ -d "$HOME/AstrBot_data_reinstall_backup" ]; then
      echo "恢复重装前 AstrBot 数据..."
      rm -rf "$INSTALL_DIR/data"
      mv "$HOME/AstrBot_data_reinstall_backup" "$INSTALL_DIR/data"
      REINSTALL_PLUGINS_FLAG=1
    else
    if [ -d "$BACKUP_DIR" ]; then
      echo "扫描备份目录: $BACKUP_DIR"
      LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/AstrBotBubble-backup-*.tar.gz 2>/dev/null | head -n 1)
      if [ -n "$LATEST_BACKUP" ]; then
        echo "找到备份文件: $LATEST_BACKUP"
        if tar -xzf "$LATEST_BACKUP" -C "$INSTALL_DIR"; then
          echo "备份恢复成功"; REINSTALL_PLUGINS_FLAG=1
        else
          echo "备份恢复失败，使用默认配置"
          cp "$HOME/cmd_config.json" "$INSTALL_DIR/data"; chmod +w "$INSTALL_DIR/data/cmd_config.json"
        fi
      else
        echo "未找到备份文件，使用默认配置"
        cp "$HOME/cmd_config.json" "$INSTALL_DIR/data"; chmod +w "$INSTALL_DIR/data/cmd_config.json"
      fi
    else
      echo "备份目录不存在，使用默认配置"
      cp "$HOME/cmd_config.json" "$INSTALL_DIR/data"; chmod +w "$INSTALL_DIR/data/cmd_config.json"
    fi
    fi
    rm -rf "$INSTALL_DIR/.venv"
  fi
  if [ ! -d "$INSTALL_DIR/.venv" ] || ! $HOME/.local/bin/uv run --no-sync python -c "import aiohttp" >/dev/null 2>&1; then
    echo "同步 AstrBot 依赖..."
    if ! $HOME/.local/bin/uv sync; then echo "依赖同步失败"; exit 1; fi
    REINSTALL_PLUGINS_FLAG=1
  fi
  if [ "$REINSTALL_PLUGINS_FLAG" -eq 1 ]; then
    echo "检测到重装插件依赖标记，开始重装..."
    if [ -d "$INSTALL_DIR/data/plugins" ]; then
      for plugin_dir in "$INSTALL_DIR/data/plugins"/*; do
        if [ -d "$plugin_dir" ] && [ -f "$plugin_dir/requirements.txt" ]; then
          echo "安装插件依赖: $(basename "$plugin_dir")..."
          cd "$INSTALL_DIR"
          $HOME/.local/bin/uv pip install -r "$plugin_dir/requirements.txt" 2>/dev/null || echo "警告: 插件依赖安装失败，将在启动时重试"
        fi
      done
    fi
  fi
  progress_echo "AstrBot 安装完成"
}
]==]

-- 每个按钮下面就是它自己那一步的命令序列:
local function step_base(reinstall)
  host.spawn(env_pre(reinstall and "base" or "") .. "\n" .. SH_HELPERS .. SH_BASE .. [==[
maybe_prepare_reinstall base
install_sudo_curl_git
]==], "基础命令")
  host.nav.go(2)
end

local function step_uv(reinstall)
  host.spawn(env_pre(reinstall and "uv" or "") .. "\n" .. SH_HELPERS .. SH_NET .. SH_BASE .. SH_UV .. [==[
maybe_prepare_reinstall uv
install_sudo_curl_git
install_uv
]==], "uv")
  host.nav.go(2)
end

local function step_napcat(reinstall)
  host.spawn(env_pre(reinstall and "napcat" or "") .. "\n" .. SH_HELPERS .. SH_BASE .. SH_NAPCAT .. [==[
maybe_prepare_reinstall napcat
install_sudo_curl_git
install_napcat
]==], "NapCat")
  host.nav.go(2)
end

local function step_astrbot(reinstall, force_plugins)
  local pre = env_pre(reinstall and "astrbot" or "")
  local flag = force_plugins and "1" or "0"
  host.spawn(pre .. "\nexport REINSTALL_PLUGINS_FLAG=" .. flag .. "\nCUSTOM_GIT_CLONE=\"\"\n"
    .. SH_HELPERS .. SH_NET .. SH_BASE .. SH_UV .. SH_ASTRBOT .. [==[
maybe_prepare_reinstall astrbot
install_sudo_curl_git
install_uv
install_astrbot
]==], "AstrBot")
  host.nav.go(2)
end

local STEP_RUN = {
  base = step_base,
  uv = step_uv,
  napcat = step_napcat,
  astrbot = step_astrbot,
  opencode = function(reinstall) agent.install(reinstall) end,
}

-- ============================================================
-- AstrBot 启停: 纯 Lua, 通过通用原语 host.spawn/host.stop, 运行态读 ctx.running
-- 一操作一终端标签页, 手动模式, 无进度/webview 监听
-- ============================================================
local function astrbot_start_command()
  return table.concat({
    "export TMPDIR='" .. host.tmp_path() .. "'",
    "export ASTRBOT_DASHBOARD_PORT='" .. tostring(ports.get("dashboard")) .. "'",
    "if [ ! -x /root/.local/bin/uv ] || [ ! -d /root/AstrBot ] || [ ! -f /root/AstrBot/pyproject.toml ] || [ ! -f /root/AstrBot/main.py ] || [ ! -d /root/AstrBot/.venv ]; then echo 'AstrBot 环境未安装完整，请到主页环境管理安装。'; exit 1; fi",
    "cd /root/AstrBot",
    "echo 'AstrBot 启动中'",
    "/root/.local/bin/uv run --no-sync main.py",
  }, "; ")
end

function astrbot_toggle(running)
  if running then
    host.stop("astrbot")
  else
    host.spawn(astrbot_start_command(), "AstrBot", "astrbot")
    host.nav.go(2)
  end
end

-- ============================================================
-- NapCat: 实例管理 / 启停 / BOT 绑定 —— 全部纯 Lua
-- 数据存 host.get/set("napcat_instances") (JSON), 配置文件直接读写 rootfs,
-- 启停走 host.spawn/host.stop (key = "napcat:<id>"), 运行态读 ctx.running。
-- Dart 侧不含任何 NapCat 逻辑。
-- ============================================================
local NC = {}
local WEBUI_FIRST, WEBUI_LAST = 6099, 6149
local DISPLAY_FIRST = 22
local ONEBOT_FIRST, ONEBOT_LAST = 6199, 6249
local WS_NAME = "WsClient"
local ONEBOT_TOKEN = "kasdkfljsadhlskdjhasdlkfshdlafksjdhf"
local INVALID_PORT, INVALID_TOKEN = 6250, "invalid"

local function nc_root() return host.ubuntu_path() .. "/root" end
local function nc_workdir(id) return nc_root() .. "/napcat_instances/" .. id .. "_napcat" end
local function nc_configdir(id) return nc_workdir(id) .. "/config" end

local function napcat_x_display()
  local d, o, n = ports.get("dashboard"), ports.get("onebot"), ports.get("napcat")
  if d == 6185 and o == 6199 and n == 6099 then return 1 end
  return 10 + d % 80
end

function NC.load()
  local raw = host.get("napcat_instances")
  if type(raw) == "string" and raw ~= "" then
    local ok, v = pcall(json.decode, raw)
    if ok and type(v) == "table" then return v end
  end
  return {}
end

function NC.save(list) host.set("napcat_instances", json.encode(list)) end

function NC.find(list, id)
  for i, v in ipairs(list) do if v.id == id then return i, v end end
end

-- 从 rootfs 里探测该实例已登录的 QQ (通过 onebot11_<qq>.json 文件名)
function NC.detect_qq(id)
  for _, e in ipairs(host.list_dir(nc_configdir(id))) do
    local qq = tostring(e.name):match("^onebot11_(%d+)%.json$")
    if qq then return qq end
  end
  return nil
end

-- ---------- onebot 配置 ----------
local function ws_url(port) return "ws://localhost:" .. port .. "/ws" end
local function ws_port_of(url) return tonumber((tostring(url or "")):match("^wss?://[^/:]+:(%d+)")) end

local function build_onebot_config(port)
  return {
    network = {
      httpServers = {}, httpClients = {}, websocketServers = {},
      websocketClients = {
        { name = WS_NAME, enable = true, url = ws_url(port), messagePostFormat = "array",
          reportSelfMessage = false, reconnectInterval = 5000, token = ONEBOT_TOKEN,
          debug = false, heartInterval = 30000 },
      },
    },
    musicSignUrl = "", enableLocalFile2Url = false, parseMultMsg = false,
  }
end

function NC.ensure_onebot(ins)
  local p = nc_configdir(ins.id) .. "/onebot11.json"
  if host.exists(p) then return end
  host.mkdirs(nc_configdir(ins.id))
  host.write_file(p, json.encode(build_onebot_config(ins.oneBotPort or ONEBOT_FIRST)))
end

-- 读取该实例当前生效的 onebot 配置 (优先账号文件, 回退模板)
function NC.read_onebot(id)
  local qq = NC.detect_qq(id)
  local paths = {}
  if qq then paths[#paths + 1] = nc_configdir(id) .. "/onebot11_" .. qq .. ".json" end
  paths[#paths + 1] = nc_configdir(id) .. "/onebot11.json"
  for _, p in ipairs(paths) do
    local t = host.read_file(p)
    if t then
      local ok, v = pcall(json.decode, t)
      if ok and type(v) == "table" then return v, p end
    end
  end
  return nil, nil
end

function NC.list_clients(id)
  local cfg = NC.read_onebot(id)
  local res = {}
  if not cfg or type(cfg.network) ~= "table" then return res end
  local clients = cfg.network.websocketClients
  if type(clients) ~= "table" then return res end
  for i, c in ipairs(clients) do
    if type(c) == "table" then
      local url = tostring(c.url or "")
      res[#res + 1] = {
        name = (c.name and c.name ~= "") and c.name or ("websocket " .. i),
        enabled = c.enable ~= false, url = url,
        token = tostring(c.token or ""), port = ws_port_of(url),
      }
    end
  end
  return res
end

-- ---------- AstrBot cmd_config (适配器) ----------
local function astrbot_config_files()
  return {
    host.ubuntu_path() .. "/root/AstrBot/data/cmd_config.json",
    host.home_path() .. "/cmd_config.json",
  }
end

local function read_astrbot_config()
  for _, f in ipairs(astrbot_config_files()) do
    local t = host.read_file(f)
    if t then
      local ok, v = pcall(json.decode, t)
      if ok and type(v) == "table" then return v end
    end
  end
  return nil
end

local function write_astrbot_config(cfg)
  local wrote = false
  for _, f in ipairs(astrbot_config_files()) do
    if host.exists(f) then host.write_file(f, json.encode(cfg)); wrote = true end
  end
  if not wrote then host.write_file(astrbot_config_files()[1], json.encode(cfg)) end
end

function NC.list_adapters()
  local cfg = read_astrbot_config()
  local res = {}
  if not cfg or type(cfg.platform) ~= "table" then return res end
  for _, item in ipairs(cfg.platform) do
    if type(item) == "table" and item.type == "aiocqhttp" then
      res[#res + 1] = {
        id = tostring(item.id or ""), enabled = item.enable ~= false,
        port = tonumber(item.ws_reverse_port) or -1,
        token = tostring(item.ws_reverse_token or ""),
      }
    end
  end
  return res
end

local function bound_by_other(list, adapterId, exceptId)
  for _, v in ipairs(list) do
    if v.id ~= exceptId and v.boundAdapterId == adapterId then return true end
  end
  return false
end

local function unique_adapter_id(base, cfg)
  base = (base and base:gsub("^%s+", ""):gsub("%s+$", "") ~= "") and base or "NapCat"
  local used = {}
  if type(cfg.platform) == "table" then
    for _, it in ipairs(cfg.platform) do if type(it) == "table" and it.id then used[tostring(it.id)] = true end end
  end
  if not used[base] then return base end
  local letters = "abcdefghijklmnopqrstuvwxyz"
  local cand
  repeat cand = base .. letters:sub(math.random(1, 26), math.random(1, 26)) until not used[cand]
  return cand
end

-- ---------- 绑定状态 ----------
function NC.compare(client, adapter)
  if not client or not adapter then return "unconfigured" end
  if client.port == adapter.port and client.token == adapter.token then return "configured" end
  return "mismatch"
end

function NC.binding_snapshot(id)
  local list = NC.load()
  local _, ins = NC.find(list, id)
  if not ins then return nil end
  local clients = NC.list_clients(id)
  local adapters = NC.list_adapters()
  local selClient
  for _, c in ipairs(clients) do if c.name == ins.boundWebSocketName then selClient = c end end
  local selAdapter
  for _, a in ipairs(adapters) do if a.id == ins.boundAdapterId then selAdapter = a end end
  return {
    state = NC.compare(selClient, selAdapter),
    clients = clients, adapters = adapters,
    selectedClient = selClient and selClient.name or nil,
    selectedAdapter = selAdapter and selAdapter.id or nil,
  }
end

function NC.bind_ws(id, clientName)
  local qq = NC.detect_qq(id)
  if not qq then host.toast("请先登录 QQ 后再绑定 BOT"); return end
  local path = nc_configdir(id) .. "/onebot11_" .. qq .. ".json"
  local t = host.read_file(path)
  if not t then host.toast("websocket 配置不存在"); return end
  local ok, cfg = pcall(json.decode, t)
  if not ok or type(cfg) ~= "table" or type(cfg.network) ~= "table" then host.toast("配置解析失败"); return end
  local found = false
  for _, c in ipairs(cfg.network.websocketClients or {}) do
    if type(c) == "table" and c.name == clientName then c.enable = true; found = true; break end
  end
  if not found then host.toast("未找到 websocket 配置: " .. clientName); return end
  host.write_file(path, json.encode(cfg))
  local list = NC.load(); local _, ins = NC.find(list, id)
  if ins then ins.boundWebSocketName = clientName; NC.save(list) end
end

-- 写 cmd_config: 把 adapterId 适配器设为与所选 websocket 一致
local function write_adapter(id, adapterId, updateFromWs, invalidatePrev)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return false end
  local client
  for _, c in ipairs(NC.list_clients(id)) do if c.name == ins.boundWebSocketName then client = c end end
  if not client then host.toast("请先绑定 websocket 适配器"); return false end
  if not client.port then host.toast("websocket URL 缺少端口"); return false end
  local cfg = read_astrbot_config()
  if not cfg or type(cfg.platform) ~= "table" then host.toast("AstrBot 配置不存在"); return false end
  local oldId = ins.boundAdapterId or ""
  local found = false
  for _, item in ipairs(cfg.platform) do
    if type(item) == "table" then
      if invalidatePrev and oldId ~= "" and oldId ~= adapterId and item.id == oldId
          and not bound_by_other(list, oldId, id) then
        item.enable = false; item.ws_reverse_port = INVALID_PORT; item.ws_reverse_token = INVALID_TOKEN
      end
      if item.id == adapterId then
        found = true
        if updateFromWs then
          item.enable = true; item.ws_reverse_host = "0.0.0.0"
          item.ws_reverse_port = client.port; item.ws_reverse_token = client.token
        end
      end
    end
  end
  if not found then host.toast("未找到 AstrBot 适配器: " .. adapterId); return false end
  write_astrbot_config(cfg)
  ins.boundAdapterId = adapterId; NC.save(list)
  return true
end

-- 换绑/覆盖/自动修改 的多重确认流 (复刻原编排), done() 用于刷新对话框
function NC.bind_adapter(id, adapterId, done)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return end
  local client
  for _, c in ipairs(NC.list_clients(id)) do if c.name == ins.boundWebSocketName then client = c end end
  if not client then host.toast("请先绑定 websocket 适配器"); return end
  local adapter
  for _, a in ipairs(NC.list_adapters()) do if a.id == adapterId then adapter = a end end
  if not adapter then return end
  local curId = ins.boundAdapterId or ""
  local mismatch = client.port ~= adapter.port or client.token ~= adapter.token
  local invalidatePrev = false

  local function finish()
    if write_adapter(id, adapterId, mismatch, invalidatePrev) then
      if mismatch or invalidatePrev then host.toast("已保存，重启 AstrBot 生效") end
      if done then done() end
    end
  end
  local function step_mismatch()
    if mismatch then
      host.confirm("该 AstrBot 适配器与 websocket 的端口或 token 不一致，自动修改适配器？", function(y)
        if y then finish() end
      end)
    else finish() end
  end
  local function step_overtaken()
    if mismatch and bound_by_other(list, adapter.id, id) then
      host.confirm(adapter.id .. " 已被其他账号绑定，按当前 websocket 覆盖换绑？", function(y)
        if y then step_mismatch() end
      end)
    else step_mismatch() end
  end
  if curId ~= "" and curId ~= adapter.id then
    host.confirm("当前已绑定 " .. curId .. "，换绑到 " .. adapter.id .. "？", function(y)
      if y then invalidatePrev = true; step_overtaken() end
    end)
  else
    step_overtaken()
  end
end

function NC.repair(id, done)
  local snap = NC.binding_snapshot(id)
  if not snap or not snap.selectedClient or not snap.selectedAdapter then
    host.toast("请先选择 websocket 和 AstrBot 适配器"); return
  end
  host.confirm("将 AstrBot 适配器同步为所选 websocket 的端口和 token？", function(y)
    if not y then return end
    if write_adapter(id, snap.selectedAdapter, true, false) then
      host.toast("BOT 绑定已修复，重启 AstrBot 生效"); if done then done() end
    end
  end)
end

function NC.create_adapter(id, name, done)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return end
  local client
  for _, c in ipairs(NC.list_clients(id)) do if c.name == ins.boundWebSocketName then client = c end end
  if not client then host.toast("请先绑定 websocket 适配器"); return end
  if not client.port then host.toast("websocket URL 缺少端口"); return end
  local oldId = ins.boundAdapterId or ""
  local shared = oldId ~= "" and bound_by_other(list, oldId, id)

  local function do_create()
    local cfg = read_astrbot_config() or {}
    if type(cfg.platform) ~= "table" then cfg.platform = {} end
    local aid = unique_adapter_id((name ~= "" and name) or ins.name, cfg)
    if oldId ~= "" and not shared then
      for _, item in ipairs(cfg.platform) do
        if type(item) == "table" and item.id == oldId then
          item.enable = false; item.ws_reverse_port = INVALID_PORT; item.ws_reverse_token = INVALID_TOKEN
          break
        end
      end
    end
    cfg.platform[#cfg.platform + 1] = {
      id = aid, type = "aiocqhttp", enable = true, ws_reverse_host = "0.0.0.0",
      ws_reverse_port = client.port, ws_reverse_token = client.token,
    }
    write_astrbot_config(cfg)
    ins.boundAdapterId = aid; NC.save(list)
    host.toast("已新建适配器 " .. aid .. "，重启 AstrBot 生效")
    if done then done() end
  end

  if shared then
    host.confirm("旧适配器 " .. oldId .. " 已被其他账号绑定，继续新建可能端口冲突，是否继续？", function(y)
      if y then do_create() end
    end)
  else
    do_create()
  end
end

-- ---------- launcher 脚本 ----------
local LAUNCHER_TMPL = [==[
#!/bin/bash
set -u

BASE_HOME="/root"
INSTANCE_ID='__ID__'
INSTANCE_HOME="$BASE_HOME/napcat_instances/${INSTANCE_ID}_home"
INSTANCE_WORKDIR="$BASE_HOME/napcat_instances/${INSTANCE_ID}_napcat"
INSTANCE_DISPLAY="__DISPLAY__"
WEBUI_PORT="__PORT__"

mkdir -p "$INSTANCE_HOME" "$INSTANCE_WORKDIR/config" "$INSTANCE_WORKDIR/logs" "$INSTANCE_WORKDIR/cache"
mkdir -p "$INSTANCE_HOME/.config" "$INSTANCE_HOME/.cache" "$INSTANCE_HOME/.local/share"

if [ -d "$BASE_HOME/napcat/config" ]; then
  cp -n "$BASE_HOME/napcat/config/"*.json "$INSTANCE_WORKDIR/config/" 2>/dev/null || true
fi

cat > "$INSTANCE_WORKDIR/config/webui.json" <<'WEBUIEOF'
__WEBUI_JSON__
WEBUIEOF

echo "[napcat-instance] id=$INSTANCE_ID"
echo "[napcat-instance] DISPLAY=:$INSTANCE_DISPLAY"
echo "[napcat-instance] NAPCAT_WORKDIR=$INSTANCE_WORKDIR"
echo "[napcat-instance] WEBUI_PORT=$WEBUI_PORT"

if [ -f "$INSTANCE_WORKDIR/xvfb.pid" ]; then
  kill "$(cat "$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null || true
fi
pkill -f "Xvfb :$INSTANCE_DISPLAY" 2>/dev/null || true
rm -f "/tmp/.X${INSTANCE_DISPLAY}-lock" "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

Xvfb ":$INSTANCE_DISPLAY" -screen 0 800x600x16 +extension GLX +render > "$INSTANCE_WORKDIR/xvfb.log" 2>&1 &
echo "$!" > "$INSTANCE_WORKDIR/xvfb.pid"
for i in $(seq 1 50); do
  if [ -S "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" ]; then
    break
  fi
  if ! kill -0 "$(cat "$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null; then
    echo "[napcat-instance] Xvfb 启动失败"
    cat "$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done
if [ ! -S "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" ]; then
  echo "[napcat-instance] Xvfb 未就绪，无法启动 QQ"
  cat "$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
  exit 1
fi
export DISPLAY=":$INSTANCE_DISPLAY"
export NAPCAT_WORKDIR="$INSTANCE_WORKDIR"
export HOME="$INSTANCE_HOME"
export XDG_CONFIG_HOME="$INSTANCE_HOME/.config"
export XDG_CACHE_HOME="$INSTANCE_HOME/.cache"
export XDG_DATA_HOME="$INSTANCE_HOME/.local/share"

mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

cd "$BASE_HOME"
trap "" SIGPIPE
LD_PRELOAD=./libnapcat_launcher.so qq --no-sandbox
]==]

function NC.write_launcher(ins)
  local webui = json.encode({
    host = "0.0.0.0", port = ins.webUiPort, prefix = "", token = "",
    loginRate = 3, autoLoginAccount = ins.qq or "",
  })
  local s = LAUNCHER_TMPL
  s = s:gsub("__ID__", (ins.id:gsub("%%", "%%%%")))
  s = s:gsub("__DISPLAY__", tostring(ins.display))
  s = s:gsub("__PORT__", tostring(ins.webUiPort))
  s = s:gsub("__WEBUI_JSON__", (webui:gsub("%%", "%%%%")))
  host.write_file(nc_root() .. "/launcher_" .. ins.id .. ".sh", s)
end

-- ---------- 生命周期 ----------
function NC.add()
  local list = NC.load()
  local usedDisp = { [napcat_x_display()] = true }
  for _, v in ipairs(list) do usedDisp[v.display] = true end
  local display
  for d = DISPLAY_FIRST, 99 do if not usedDisp[d] then display = d; break end end
  if not display then host.toast("没有可用 DISPLAY"); return end

  local wexcl = { ports.get("dashboard"), ports.get("onebot") }
  for _, v in ipairs(list) do wexcl[#wexcl + 1] = v.webUiPort end
  host.free_port(WEBUI_FIRST, WEBUI_LAST, wexcl, function(webPort)
    if not webPort then host.toast("没有可用 WebUI 端口"); return end
    local oexcl = { ports.get("dashboard") }
    for _, v in ipairs(list) do if v.oneBotPort then oexcl[#oexcl + 1] = v.oneBotPort end end
    host.free_port(ONEBOT_FIRST, ONEBOT_LAST, oexcl, function(obPort)
      if not obPort then host.toast("没有可用 OneBot 端口"); return end
      local idx = #list + 1
      local ins = {
        id = "qq" .. idx .. "_" .. tostring(os.time()) .. tostring(math.random(1000, 9999)),
        name = "账号" .. idx, qq = "", webUiPort = webPort, display = display,
        oneBotPort = obPort, token = "", boundWebSocketName = WS_NAME, boundAdapterId = "",
      }
      list[#list + 1] = ins
      NC.save(list)
      NC.ensure_onebot(ins)
    end)
  end)
end

function NC.edit(id, name, webPort)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return end
  if name and name ~= "" then ins.name = name end
  if webPort and webPort ~= ins.webUiPort then
    if webPort < WEBUI_FIRST or webPort > WEBUI_LAST then
      host.toast("WebUI 端口需在 " .. WEBUI_FIRST .. "-" .. WEBUI_LAST); return
    end
    for _, v in ipairs(list) do
      if v.id ~= id and v.webUiPort == webPort then host.toast("端口已被占用"); return end
    end
    ins.webUiPort = webPort
  end
  NC.save(list)
  NC.write_launcher(ins)
end

function NC.start(id)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return end
  NC.ensure_onebot(ins)
  NC.write_launcher(ins)
  local cmd = "echo [napcat] run launcher_" .. id .. ".sh; " ..
    "chmod +x /root/launcher_" .. id .. ".sh; bash /root/launcher_" .. id .. ".sh"
  host.spawn(cmd, ins.name or id, "napcat:" .. id)
  host.nav.go(2)
end

local function nc_cleanup_cmd(id, display)
  local c = {
    'if [ -f /root/napcat_instances/' .. id .. '_napcat/qq.pid ]; then kill "$(cat /root/napcat_instances/' .. id .. '_napcat/qq.pid)" 2>/dev/null || true; fi',
    'if [ -f /root/napcat_instances/' .. id .. '_napcat/xvfb.pid ]; then kill "$(cat /root/napcat_instances/' .. id .. '_napcat/xvfb.pid)" 2>/dev/null || true; fi',
    'pkill -f "launcher_' .. id .. '.sh" || true',
    'pkill -f "napcat_instances/' .. id .. '_napcat" || true',
    'pkill -f "napcat_instances/' .. id .. '_home" || true',
  }
  if display and display > 0 then c[#c + 1] = 'pkill -f "Xvfb :' .. display .. '" || true' end
  c[#c + 1] = 'rm -f /root/napcat_instances/' .. id .. '_napcat/qq.pid'
  c[#c + 1] = 'rm -f /root/napcat_instances/' .. id .. '_napcat/xvfb.pid'
  return table.concat(c, "; ")
end

function NC.stop(id)
  host.stop("napcat:" .. id)
  local list = NC.load(); local _, ins = NC.find(list, id)
  host.exec(nc_cleanup_cmd(id, ins and ins.display or -1))
end

function NC.logout(id)
  NC.stop(id)
  host.exec('rm -rf /root/napcat_instances/' .. id .. '_napcat; ' ..
    'rm -rf /root/napcat_instances/' .. id .. '_home; rm -f /root/launcher_' .. id .. '.sh')
  local list = NC.load(); local _, ins = NC.find(list, id)
  if ins then
    ins.qq = ""; ins.token = ""; ins.boundWebSocketName = ""; ins.boundAdapterId = ""
    NC.save(list)
  end
end

function NC.delete(id)
  NC.logout(id)
  local list = NC.load(); local i = NC.find(list, id)
  if i then table.remove(list, i); NC.save(list) end
end

function NC.webui_url(ins)
  local url = "http://127.0.0.1:" .. ins.webUiPort .. "/webui"
  if ins.token and ins.token ~= "" then url = url .. "?token=" .. ins.token end
  return url
end

-- ============================================================
-- 主页 UI
-- ============================================================

local function quick_start_card(ctx)
  local running = ctx.running and ctx.running["astrbot"]
  local dash = ports.get("dashboard")
  return card("AstrBot", {
    tile("监听端口", {
      icon = "settings_ethernet",
      subtitle = "127.0.0.1:" .. dash,
      trailing = iconbutton("edit", function()
        host.input({ title = "AstrBot 监听端口", default = tostring(dash), hint = "6185" }, function(v)
          if v and v ~= "" and tonumber(v) then
            ports.set("dashboard", tonumber(v))
            host.toast("端口已保存，重启 AstrBot 后生效")
          end
        end)
      end),
    }),
    spacer(12),
    row({
      expanded(button(running and "停止" or "启动 AstrBot", function()
        astrbot_toggle(running)
      end, { icon = running and "stop" or "play" })),
      expanded(button("打开 WebUI", function()
        host.webview_open("http://127.0.0.1:" .. dash .. "/", "AstrBot")
      end, { variant = "tonal", icon = "language" })),
    }, { gap = 12 }),
  })
end

local function env_card()
  local children = {
    select({
      title = "GitHub 代理",
      value = host.get("environment_github_proxy") or "auto",
      options = PROXIES,
      onChanged = function(v) host.set("environment_github_proxy", v) end,
    }),
  }
  for _, s in ipairs(ENV_STEPS) do
    local done = env_installed(s.id)
    children[#children + 1] = tile(s.title, {
      icon = done and "check_circle" or "error",
      iconColor = done and "green" or "orange",
      subtitle = s.sub,
      trailing = button(done and "重装" or "安装", function()
        STEP_RUN[s.id](done)
      end, { variant = "tonal" }),
    })
  end
  return expansion("环境管理", children, { icon = "build" })
end

local function add_napcat()
  NC.add()
end

-- BOT 绑定对话框 (自定义组件对话框)
local function bind_bot_dialog(ins)
  local id = ins.id
  local d = state("bind." .. id, nil)
  local function reload() d.set(NC.binding_snapshot(id)) end
  reload()
  host.dialog({
    title = "绑定 BOT",
    build = function()
      local data = d.get()
      if not data then return center(spinner()) end
      local kids = {}
      local scolor = data.state == "configured" and "green"
        or (data.state == "mismatch" and "orange" or "red")
      local stext = data.state == "configured" and "已绑定 BOT"
        or (data.state == "mismatch" and "BOT 绑定异常" or "未绑定 BOT")
      kids[#kids + 1] = chip(stext, { color = scolor })
      if data.state == "mismatch" then
        kids[#kids + 1] = button("修复绑定", function()
          NC.repair(id, function() reload() end)
        end, { variant = "tonal", icon = "build" })
      end
      kids[#kids + 1] = text("websocket 适配器", { weight = "bold" })
      local clients = data.clients or {}
      if #clients == 0 then
        kids[#kids + 1] = text("未找到 websocket client 配置", { color = "grey" })
      else
        for _, c in ipairs(clients) do
          local sel = data.selectedClient == c.name
          kids[#kids + 1] = tile(c.name, {
            subtitle = (c.enabled and "已启用" or "未启用") .. " · " .. (c.url or ""),
            icon = sel and "check_circle" or nil,
            iconColor = sel and "green" or nil,
            onTap = function() NC.bind_ws(id, c.name); reload() end,
          })
        end
      end
      kids[#kids + 1] = divider()
      kids[#kids + 1] = row({
        expanded(text("AstrBot 适配器", { weight = "bold" })),
        button("新建", function()
          host.input({ title = "新建 AstrBot 适配器", default = ins.name, hint = "留空使用账号名" },
            function(name) NC.create_adapter(id, name or "", function() reload() end) end)
        end, { variant = "text", icon = "add" }),
      }, { cross = "center" })
      local adapters = data.adapters or {}
      if #adapters == 0 then
        kids[#kids + 1] = text("未找到 AstrBot OneBot 适配器", { color = "grey" })
      else
        for _, ad in ipairs(adapters) do
          local sel = data.selectedAdapter == ad.id
          local tk = (ad.token and ad.token ~= "") and "已设置" or "空"
          kids[#kids + 1] = tile(ad.id, {
            subtitle = (ad.enabled and "已启用" or "未启用") .. " · " .. tostring(ad.port) .. " · token " .. tk,
            icon = sel and "check_circle" or nil,
            iconColor = sel and "green" or nil,
            onTap = function() NC.bind_adapter(id, ad.id, function() reload() end) end,
          })
        end
      end
      return column(kids, { cross = "stretch", gap = 4 })
    end,
  })
end

local function napcat_tile(ins)
  local running = ins.running
  local logged = ins.qq and ins.qq ~= ""
  return tile(ins.name, {
    icon = running and "play_circle" or "pause_circle",
    iconColor = running and "green" or nil,
    subtitle = "QQ " .. (logged and ins.qq or "未登录，启动后扫码") .. "\nWebUI " .. tostring(ins.webUiPort),
    trailing = row({
      iconbutton("language", function() host.webview_open(NC.webui_url(ins), ins.name) end, { tooltip = "打开 WebUI" }),
      iconbutton(running and "stop" or "play", function()
        if running then NC.stop(ins.id) else NC.start(ins.id) end
      end, { tooltip = running and "停止" or "启动" }),
      menu("more", {
        { label = "编辑", onTap = function()
          host.input({ title = "编辑账号名", default = ins.name }, function(name)
            if name and name ~= "" then NC.edit(ins.id, name, ins.webUiPort) end
          end)
        end },
        { label = "绑定 BOT", onTap = function() bind_bot_dialog(ins) end },
        { label = "复制 token", enabled = (ins.token ~= nil and ins.token ~= ""), onTap = function()
          host.clipboard.copy(ins.token); host.toast("已复制 token")
        end },
        { label = "复制完整链接", onTap = function()
          host.clipboard.copy(NC.webui_url(ins)); host.toast("已复制链接")
        end },
        { label = "退出登录", onTap = function()
          host.confirm("确定退出该账号登录?", function(y) if y then NC.logout(ins.id) end end)
        end },
        { label = "删除", onTap = function()
          host.confirm("确定删除该账号?", function(y) if y then NC.delete(ins.id) end end)
        end },
      }),
    }, { main = "end" }),
  })
end

local function napcat_card(ctx)
  local children = {
    row({
      icon("pets"),
      spacer(8),
      expanded(text("NapCat 账号", { weight = "bold", size = 16 })),
      iconbutton("add", function() add_napcat() end, { tooltip = "添加账号" }),
    }, { cross = "center" }),
  }
  local list = NC.load()
  if #list == 0 then
    children[#children + 1] = padding(text("暂无账号，点击右上角 + 添加", { color = "grey" }), 8)
  else
    for _, ins in ipairs(list) do
      ins.running = ctx.running and ctx.running["napcat:" .. ins.id] or false
      children[#children + 1] = napcat_tile(ins)
    end
  end
  return card(nil, children)
end

local function do_backup(cb)
  local ub = host.ubuntu_path()
  if not host.exists(ub .. "/root/AstrBot/data") then
    host.toast("AstrBot 数据目录不存在"); if cb then cb(false) end; return
  end
  local dir = host.backup_dir()
  host.mkdirs(dir)
  local name = "AstrBotBubble-backup-" .. os.date("%Y%m%d-%H%M%S") .. ".tar.gz"
  local path = dir .. "/" .. name
  host.run(host.bin_path() .. "/busybox",
    { "tar", "-czf", path, "-C", ub .. "/root/AstrBot", "data" },
    function(res)
      if res.code == 0 then
        host.toast("备份成功: " .. name); if cb then cb(true) end
      else
        host.toast("备份失败: " .. (res.stderr or "")); if cb then cb(false) end
      end
    end)
end

local function do_restore()
  local dir = host.backup_dir()
  local files = {}
  for _, e in ipairs(host.list_dir(dir)) do
    if (not e.isDir) and e.name:match("^AstrBotBubble%-backup%-") and e.name:match("%.tar%.gz$") then
      files[#files + 1] = e
    end
  end
  if #files == 0 then host.toast("未找到备份文件"); return end
  host.dialog({
    title = "选择备份还原",
    build = function()
      local kids = {}
      for _, f in ipairs(files) do
        kids[#kids + 1] = tile(f.name, {
          icon = "restore",
          onTap = function()
            host.confirm("还原将覆盖当前数据，确定?", function(y)
              if y then
                local ub = host.ubuntu_path()
                host.run(host.bin_path() .. "/busybox",
                  { "tar", "-xzf", f.path, "-C", ub .. "/root/AstrBot" },
                  function(res)
                    host.close_dialog()
                    if res.code == 0 then
                      host.toast("还原成功，应用即将退出"); host.exit_app()
                    else
                      host.toast("还原失败: " .. (res.stderr or ""))
                    end
                  end)
              end
            end)
          end,
        })
      end
      return column(kids, { cross = "stretch" })
    end,
  })
end

local function manage_section()
  return expansion("AstrBot 管理", {
    tile("覆盖安装插件依赖", {
      icon = "build", subtitle = "重新安装 AstrBot 并覆盖插件依赖",
      trailing = button("执行", function() step_astrbot(false, true) end, { variant = "tonal" }),
    }),
    tile("备份 AstrBot 数据", {
      icon = "backup", subtitle = "打包 data 到下载目录",
      trailing = button("备份", function() do_backup() end, { variant = "tonal" }),
    }),
    tile("还原 AstrBot 数据", {
      icon = "restore", subtitle = "从备份文件恢复 data",
      trailing = button("还原", do_restore, { variant = "tonal" }),
    }),
    tile("清除 AstrBot 数据", {
      icon = "delete", subtitle = "删除 data 数据目录 (不可恢复)",
      trailing = button("清除", function()
        host.confirm("确定要清除 AstrBot 数据吗?", function(yes)
          if yes then host.delete_dir(host.ubuntu_path() .. "/root/AstrBot/data"); host.exit_app() end
        end)
      end, { danger = true }),
    }),
    tile("重置 Python 环境", {
      icon = "refresh", subtitle = "删除 .venv 并重建依赖",
      trailing = button("重置", function()
        host.confirm("确定要重置 Python 环境吗?", function(yes)
          if yes then host.delete_dir(host.ubuntu_path() .. "/root/AstrBot/.venv"); host.exit_app() end
        end)
      end, { danger = true }),
    }),
  }, { icon = "settings" })
end

app.page("home", function(ctx)
  return {
    quick_start_card(ctx),
    napcat_card(ctx),
    env_card(),
    manage_section(),
  }
end)

-- 主页顶栏自定义按钮 (设置按钮左侧): DIY = 启动 opencode 引擎并打开 WebUI
app.actions({
  { icon = "smart_toy", tooltip = "opencode", onTap = function() agent.launch() end },
})
