import 'package:global_repository/global_repository.dart';
import 'config.dart';
import 'generated/l10n.dart';

// proot distro，ubuntu path
String prootDistroPath = '${RuntimeEnvir.usrPath}/var/lib/proot-distro';
String ubuntuPath = '$prootDistroPath/installed-rootfs/ubuntu';
String ubuntuName = Config.ubuntuFileName.replaceAll(RegExp('-pd.*'), '');

String common = '''
export TMPDIR=${RuntimeEnvir.tmpPath}
export BIN=${RuntimeEnvir.binPath}
export UBUNTU_PATH=$ubuntuPath
export UBUNTU=${Config.ubuntuFileName}
export UBUNTU_NAME=$ubuntuName
export L_NOT_INSTALLED=${S.current.uninstalled}
export L_INSTALLING=${S.current.installing}
export L_INSTALLED=${S.current.installed}
clear_lines(){
  printf "\\033[1A" # Move cursor up one line
  printf "\\033[K"  # Clear the line
  printf "\\033[1A" # Move cursor up one line
  printf "\\033[K"  # Clear the line
}
progress_echo(){
  echo -e "\\033[31m- \$@\\033[0m"
  echo "\$@" > "\$TMPDIR/progress_des"
}
bump_progress(){
  current=0
  if [ -f "\$TMPDIR/progress" ]; then
    current=\$(cat "\$TMPDIR/progress" 2>/dev/null || echo 0)
  fi
  next=\$((current + 1))
  printf "\$next" > "\$TMPDIR/progress"
}
''';

// 切换到清华源
// Switch to Tsinghua source
String changeUbuntuNobleSource = r'''
change_ubuntu_source(){
  cat <<EOF > $UBUNTU_PATH/etc/apt/sources.list
# 默认注释了源码镜像以提高 apt update 速度，如有需要可自行取消注释
# Defaultly commented out source mirrors to speed up apt update, uncomment if needed
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble-updates main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble-updates main restricted universe multiverse
deb http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble-backports main restricted universe multiverse
# deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble-backports main restricted universe multiverse

# 以下安全更新软件源包含了官方源与镜像站配置，如有需要可自行修改注释切换
# The following security update software sources include both official and mirror configurations, modify comments to switch if needed
# deb http://ports.ubuntu.com/ubuntu-ports/ noble-security main restricted universe multiverse
# deb-src http://ports.ubuntu.com/ubuntu-ports/ noble-security main restricted universe multiverse

# 预发布软件源，不建议启用
# The following pre-release software sources are not recommended to be enabled
# deb https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble-proposed main restricted universe multiverse
# # deb-src https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/ noble-proposed main restricted universe multiverse
EOF
}
''';

/// 安装ubuntu的shell
String genCodeConfig = r'''
gen_code_server_config(){
  mkdir -p $UBUNTU_PATH/root/.config/code-server 2>/dev/null
  echo "
  bind-addr: 0.0.0.0:$CSPORT
  auth: none
  password: none
  cert: false
  " > $UBUNTU_PATH/root/.config/code-server/config.yaml
}
''';

String installUbuntu = r'''
install_ubuntu(){
  mkdir -p $UBUNTU_PATH 2>/dev/null
  if [ -z "$(ls -A $UBUNTU_PATH)" ]; then
    progress_echo "Ubuntu $L_NOT_INSTALLED, $L_INSTALLING..."
    ls ~/$UBUNTU
    busybox tar xvf ~/$UBUNTU -C $UBUNTU_PATH/ | while read line; do
      # echo -ne "\033[2K\0337\r$line\0338"
      echo -ne "\033[2K\r$line"
    done
    echo
    mv $UBUNTU_PATH/$UBUNTU_NAME/* $UBUNTU_PATH/
    rm -rf $UBUNTU_PATH/$UBUNTU_NAME
    # 注释掉 code-server 相关的 PATH 设置
    # echo 'export PATH=/opt/code-server-$CSVERSION-linux-arm64/bin:$PATH' >> $UBUNTU_PATH/root/.bashrc
    echo 'export ANDROID_DATA=/home/' >> $UBUNTU_PATH/root/.bashrc
  else
    VERSION=`cat $UBUNTU_PATH/etc/issue.net 2>/dev/null`
    # VERSION=`cat $UBUNTU_PATH/etc/issue 2>/dev/null | sed 's/\\n//g' | sed 's/\\l//g'`
    progress_echo "Ubuntu $L_INSTALLED -> $VERSION"
  fi
  change_ubuntu_source
  echo 'nameserver 8.8.8.8' > $UBUNTU_PATH/etc/resolv.conf
}
''';

// 安装 proot-distro 的脚本
// install proot-distro script
String installProotDistro = r'''
install_proot_distro(){
  proot_distro_path=`which proot-distro`
  if [ -z "$proot_distro_path" ]; then
    progress_echo "proot-distro $L_NOT_INSTALLED, $L_INSTALLING..."
    cd ~
    busybox unzip proot-distro.zip -d proot-distro
    cd ~/proot-distro
    bash ./install.sh
  else
    progress_echo "proot-distro $L_INSTALLED"
  fi
}
''';

// 安装 curl
final String installCurl = r'''
install_curl(){
  curl_path=`which curl`
  if [ -z "$curl_path" ]; then
    progress_echo "curl $L_NOT_INSTALLED, $L_INSTALLING..."
    apt-get update
    apt-get install -y curl
  else
    progress_echo "curl $L_INSTALLED"
  fi
}
''';

// 测试 github 网络
// test github network
String testGithub = r'''
function network_test() {
    local timeout=10
    local status=0
    local found=0
    target_proxy=""
    log "开始网络测试: Github..."

    proxy_arr=("https://ghfast.top" "https://gh.wuliya.xin" "https://gh-proxy.com" "https://github.moeyy.xyz")
    check_url="https://raw.githubusercontent.com/NapNeko/NapCatQQ/main/package.json"

    for proxy in "${proxy_arr[@]}"; do
        log "测试代理: ${proxy}"
        status=$(curl -k -L --connect-timeout ${timeout} --max-time $((timeout*2)) -o /dev/null -s -w "%{http_code}" "${proxy}/${check_url}")
        curl_exit=$?
        if [ $curl_exit -ne 0 ]; then
            log "代理 ${proxy} 测试失败或超时 (错误码: $curl_exit)"
            continue
        fi
        if [ "${status}" = "200" ]; then
            found=1
            target_proxy="${proxy}"
            log "将使用Github代理: ${proxy}"
            break
        fi
    done

    if [ ${found} -eq 0 ]; then
        log "警告: 无法找到可用的Github代理，将尝试直连..."
        status=$(curl -k --connect-timeout ${timeout} --max-time $((timeout*2)) -o /dev/null -s -w "%{http_code}" "${check_url}")
        if [ $? -eq 0 ] && [ "${status}" = "200" ]; then
            log "直连Github成功，将不使用代理"
            target_proxy=""
        else
            log "警告: 无法连接到Github，请检查网络。将继续尝试安装，但可能会失败。"
        fi
    fi
}
''';

// 安装 uv 的脚本
// install uv script
String installUv = r'''
install_uv(){
  uv_path=`which uv`
  if [ -z "$uv_path" ]; then
    network_test
    APP_NAME="uv"
    APP_VERSION="0.9.8"
    ARCHIVE_FILE="uv-aarch64-unknown-linux-gnu.tar.gz"
    # 统一使用 Ubuntu root 目录作为安装路径
    INSTALL_DIR="$UBUNTU_PATH/root/.local/bin"
    DOWNLOAD_URL="${target_proxy:+${target_proxy}/}https://github.com/astral-sh/uv/releases/download/${APP_VERSION}/${ARCHIVE_FILE}"

    # 检查必要命令
    for cmd in tar mkdir cp chmod mktemp rm curl; do
      if ! command -v $cmd >/dev/null 2>&1; then
        progress_echo "错误：缺少必要命令 $cmd，无法安装 $APP_NAME"
        exit 1
      fi
    done

    # 创建安装目录和临时目录
    mkdir -p $INSTALL_DIR
    TMP_DIR=$(mktemp -d)
    TMP_ARCHIVE="$TMP_DIR/$ARCHIVE_FILE"

    # 下载并解压（失败直接退出，不使用return）
    progress_echo "正在下载 $APP_NAME $APP_VERSION..."
    if ! curl -fL $DOWNLOAD_URL -o $TMP_ARCHIVE; then
      progress_echo "下载失败"
      rm -rf $TMP_DIR
      exit 1
    fi
    progress_echo "正在解压 $APP_NAME..."
    if ! tar xf $TMP_ARCHIVE --strip-components 1 -C $TMP_DIR; then
      progress_echo "解压失败"
      rm -rf $TMP_DIR
      exit 1
    fi

    # 安装并授权
    cp $TMP_DIR/uv $TMP_DIR/uvx $INSTALL_DIR/
    chmod +x $INSTALL_DIR/uv $INSTALL_DIR/uvx

    # 自动配置 PATH（写入 Ubuntu root 的 bashrc）
    if ! grep -q "$INSTALL_DIR" $UBUNTU_PATH/root/.bashrc; then
      echo "export PATH=$INSTALL_DIR:\$PATH" >> $UBUNTU_PATH/root/.bashrc
      progress_echo "已自动配置 $APP_NAME 路径到环境变量"
    fi

    # 清理临时文件
    rm -rf $TMP_DIR
    progress_echo "$APP_NAME 安装完成"
  else
    progress_echo "$APP_NAME $L_INSTALLED"
  fi
}
''';

String installAstrBot = r'''
install_astrobot(){
  local INSTALL_DIR="$UBUNTU_PATH/root/Astrobot"
  
  # 检查是否已安装
  if [ ! -d "$INSTALL_DIR" ]; then
    progress_echo "Astrobot $L_NOT_INSTALLED，$L_INSTALLING..."
    network_test

    # 克隆仓库（失败直接退出）
    progress_echo "正在克隆 AstrBot 仓库..."
    if ! git clone ${target_proxy:+${target_proxy}/}https://github.com/AstrBotDevs/AstrBot.git $INSTALL_DIR; then
      progress_echo "克隆 AstrBot 仓库失败"
      exit 1
    fi
    progress_echo "Astrobot $L_INSTALLED"
  else
    progress_echo "Astrobot 已安装，准备启动..."
  fi
  
  # 启动 AstrBot（失败直接退出）
  progress_echo "正在启动 AstrBot..."
  cd $INSTALL_DIR
  if ! uv sync; then
    progress_echo "uv 依赖同步失败"
    exit 1
  fi
  if ! uv run main.py 2>/dev/null; then
    progress_echo "AstrBot 启动失败"
    exit 1
  fi
  
  progress_echo "AstrBot 启动成功"
}
''';

String installNapcat = r'''
install_napcat(){
  local INSTALL_DIR="$UBUNTU_PATH/root/napcat"
  local NAPCAT_SH_PATH="/data/data/com.astrobot.code_lfa/app_flutter/runtime/napcat.sh"
  
  # 检查是否已安装
  if [ ! -d "$INSTALL_DIR" ]; then
    progress_echo "Napcat $L_NOT_INSTALLED，$L_INSTALLING..."
    
    # 检查依赖文件（失败直接退出）
    if [ ! -f "$NAPCAT_SH_PATH" ]; then
      progress_echo "错误：未找到 napcat.sh 文件（路径：$NAPCAT_SH_PATH）"
      exit 1
    fi
    
    # 复制文件并授权（失败直接退出）
    mkdir -p $INSTALL_DIR
    progress_echo "正在复制 napcat.sh 文件..."
    if ! cp $NAPCAT_SH_PATH $INSTALL_DIR/; then
      progress_echo "复制 napcat.sh 失败"
      exit 1
    fi
    if ! chmod +x $INSTALL_DIR/napcat.sh; then
      progress_echo "设置 napcat.sh 执行权限失败"
      exit 1
    fi
    
    progress_echo "Napcat $L_INSTALLED"
  else
    progress_echo "Napcat 已安装，准备启动..."
  fi
  
  # 启动 Napcat（失败直接退出）
  progress_echo "正在启动 Napcat..."
  cd $INSTALL_DIR
  if ! bash napcat.sh; then
    progress_echo "Napcat 启动失败"
    exit 1
  fi
  
  progress_echo "Napcat 启动成功"
}
''';

// // need to be modified
// // 
// String loginUbuntu = r'''
// login_ubuntu(){
//   bash $BIN/proot-distro login --bind /storage/emulated/0:/sdcard/ ubuntu --isolated  -- /opt/code-server-$CSVERSION-linux-arm64/bin/code-server
// }
// ''';

String commonScript = '''
$common
$changeUbuntuNobleSource
$installUbuntu
$installProotDistro
$installCurl
$testGithub
$installUv
$installAstrBot
$installNapcat
clear_lines
# 简化的 start_vs_code 函数，不包含 code-server 相关内容
start_vs_code(){
  install_proot_distro
  sleep 1
  bump_progress
  install_ubuntu
  sleep 1
  bump_progress
  install_curl
  sleep 1
  bump_progress
  network_test
  sleep 1
  bump_progress
  install_uv
  sleep 1
  bump_progress
  install_astrobot
  sleep 1
  bump_progress
  install_napcat
}
''';
