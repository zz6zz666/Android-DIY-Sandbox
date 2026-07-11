import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/config/ui_preferences.dart';
import '../../core/constants/scripts.dart';
import '../../core/utils/file_utils.dart';
import 'terminal_tab_manager.dart';
import 'webview_tab_manager.dart';

class HomeController extends GetxController {
  // 终端标签页管理器
  late final TerminalTabManager terminalTabManager;
  // 通用 WebUI 标签页管理器 (无特定业务语义)
  final WebViewTabManager webViewTabManager = WebViewTabManager();
  // 再次点击当前导航图标的信号: 终端页弹出更多菜单; WebUI 页切换二级浏览器工具栏
  final RxInt terminalMenuSignal = 0.obs;
  final RxBool webviewToolbarVisible = false.obs;

  SettingNode privacySetting = 'privacy'.setting;

  final RxString homeBackgroundPath = ''.obs;
  final RxDouble cardGlassOpacity = 0.62.obs;
  final RxDouble glassBlurAmount = 0.45.obs;
  final RxDouble topNavGlassOpacity = 0.62.obs;
  final RxDouble statusOverlayOpacity = 0.38.obs;
  final RxDouble terminalOverlayOpacity = 0.65.obs;
  final RxnInt pendingMainTabIndex = RxnInt();

  void clearPendingMainTabIndex(int index) {
    if (pendingMainTabIndex.value == index) {
      pendingMainTabIndex.value = null;
    }
  }

  // 检查两个条件是否都满足，如果满足则切到新版主界面的 WebUI 页。
  Future<void> initEnvir() async {
    List<String> androidFiles = [
      'libbash.so',
      'libbusybox.so',
      'liblibtalloc.so.2.so',
      'libloader.so',
      'libproot.so',
      'libsudo.so'
    ];
    String libPath = await getLibPath();
    Log.i('libPath -> $libPath');

    for (int i = 0; i < androidFiles.length; i++) {
      // when android target sdk > 28
      // cannot execute file in /data/data/com.xxx/files/usr/bin
      // so we need create a link to /data/data/com.xxx/files/usr/bin
      final sourcePath = '$libPath/${androidFiles[i]}';
      String fileName = androidFiles[i].replaceAll(RegExp('^lib|\\.so\$'), '');
      String filePath = '${RuntimeEnvir.binPath}/$fileName';
      // custom path, termux-api will invoke
      File file = File(filePath);
      FileSystemEntityType type = await FileSystemEntity.type(filePath);
      Log.i('$fileName type -> $type');
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.link) {
        // old version adb is plain file
        Log.i('find plain file -> $fileName, delete it');
        await file.delete();
      }
      Link link = Link(filePath);
      if (link.existsSync()) {
        link.deleteSync();
      }
      try {
        Log.i('create link -> $fileName ${link.path}');
        link.createSync(sourcePath);
      } catch (e) {
        Log.e('installAdbToEnvir error -> $e');
      }
    }
  }

  // 同步当前进度
  // Sync the current progress
  void createBusyboxLink() {
    try {
      List<String> links = [
        ...[
          'awk',
          'ash',
          'basename',
          'bzip2',
          'curl',
          'cp',
          'chmod',
          'cut',
          'cat',
          'du',
          'dd',
          'find',
          'grep',
          'gzip'
        ],
        ...[
          'hexdump',
          'head',
          'id',
          'lscpu',
          'mkdir',
          'realpath',
          'rm',
          'sed',
          'stat',
          'sh',
          'tr',
          'tar',
          'uname',
          'xargs',
          'xz',
          'xxd'
        ]
      ];

      for (String linkName in links) {
        Link link = Link('${RuntimeEnvir.binPath}/$linkName');
        if (!link.existsSync()) {
          link.createSync('${RuntimeEnvir.binPath}/busybox');
        }
      }
      Link link = Link('${RuntimeEnvir.binPath}/file');
      link.createSync('/system/bin/file');
    } catch (e) {
      Log.e('Create link failed -> $e');
    }
  }

  String _toUnixLineEndings(String content) {
    return content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  void onInit() {
    super.onInit();

    // 初始化终端标签页管理器
    terminalTabManager = TerminalTabManager();

    _loadUiPreferences();

    // 为 Google Play 上架做准备
    // For Google Play
    Future.delayed(Duration.zero, () async {
      if (privacySetting.get() == null) {
        await Get.to(PrivacyAgreePage(
          onAgreeTap: () {
            privacySetting.set(true);
            Get.back();
          },
        ));
      }
    });

    // 监听应用生命周期状态变化
    WidgetsBinding.instance.addObserver(
      LifecycleObserver(
        onResume: () {},
        onPause: () {},
      ),
    );
  }

  // 加载自定义 WebView 列表
  void _loadUiPreferences() {
    homeBackgroundPath.value = UiPreferences.homeBackgroundPath;
    cardGlassOpacity.value = UiPreferences.cardGlassOpacity;
    glassBlurAmount.value = UiPreferences.glassBlurAmount;
    topNavGlassOpacity.value = UiPreferences.topNavGlassOpacity;
    statusOverlayOpacity.value = UiPreferences.statusOverlayOpacity;
    terminalOverlayOpacity.value = UiPreferences.terminalOverlayOpacity;
  }

  void setHomeBackgroundPath(String path) {
    UiPreferences.saveHomeBackgroundPath(path);
    homeBackgroundPath.value = path;
  }

  void clearHomeBackgroundPath() {
    UiPreferences.clearHomeBackgroundPath();
    homeBackgroundPath.value = '';
  }

  void setCardGlassOpacity(double value) {
    UiPreferences.saveCardGlassOpacity(value);
    cardGlassOpacity.value = UiPreferences.cardGlassOpacity;
  }

  void setGlassBlurAmount(double value) {
    UiPreferences.saveGlassBlurAmount(value);
    glassBlurAmount.value = UiPreferences.glassBlurAmount;
  }

  void setTopNavGlassOpacity(double value) {
    UiPreferences.saveTopNavGlassOpacity(value);
    topNavGlassOpacity.value = UiPreferences.topNavGlassOpacity;
  }

  void setStatusOverlayOpacity(double value) {
    UiPreferences.saveStatusOverlayOpacity(value);
    statusOverlayOpacity.value = UiPreferences.statusOverlayOpacity;
  }

  void setTerminalOverlayOpacity(double value) {
    UiPreferences.saveTerminalOverlayOpacity(value);
    terminalOverlayOpacity.value = UiPreferences.terminalOverlayOpacity;
  }

  String _shellSingleQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  Future<void> runShellCommand(String command) => _runUbuntuShell(command);

  /// 供 Lua 脚本调用: 某 key 对应的实例是否正在运行 (有活动 Pty)。
  Future<void> ensureContainerScripts() async {
    Directory(RuntimeEnvir.tmpPath).createSync(recursive: true);
    Directory(RuntimeEnvir.homePath).createSync(recursive: true);
    Directory(RuntimeEnvir.binPath).createSync(recursive: true);
    await initEnvir();
    createBusyboxLink();
    final ubuntuAssetFile =
        File('${RuntimeEnvir.homePath}/${Config.ubuntuFileName}');
    if (!await ubuntuAssetFile.exists()) {
      await AssetsUtils.copyAssetToPath(
        'assets/${Config.ubuntuFileName}',
        ubuntuAssetFile.path,
      );
    }
    final appVersion = await getAppVersion();
    File('${RuntimeEnvir.homePath}/common.sh').writeAsStringSync(
      _toUnixLineEndings(getCommonScript(appVersion)),
    );
  }

  /// 原语: 解压/初始化 Ubuntu rootfs (进容器前的准备), 流式输出到终端 tab。
  Future<void> installRootfs({
    String title = '初始化容器',
    void Function()? onExit,
  }) async {
    await ensureContainerScripts();
    await terminalTabManager.addCommandTerminalTab(
      title: title,
      command: 'source ${RuntimeEnvir.homePath}/common.sh\n'
          'install_ubuntu\n'
          'echo __ROOTFS_DONE__\n',
      onDoneMarker: '__ROOTFS_DONE__',
      onCommandDone: onExit,
    );
  }

  /// 通用 spawn 运行态跟踪 (按调用方给的 key)。
  final RxInt spawnRevision = 0.obs;
  final Map<String, bool> spawnRunning = {};
  final Map<String, String> _spawnTabIds = {};

  bool isSpawnRunning(String key) => spawnRunning[key] == true;

  void _setSpawnRunning(String? key, bool value) {
    if (key == null) return;
    spawnRunning[key] = value;
    spawnRevision.value++;
  }

  /// 原语: 在容器内运行一条(可长驻)命令, 流式输出到新终端 tab。
  /// key 非空时跟踪运行态 (标签活着=运行中; 命令退出或标签被关=停止)。
  Future<void> spawnContainer(
    String command, {
    String title = '容器任务',
    String? key,
    void Function()? onExit,
  }) async {
    await ensureContainerScripts();
    const marker = '__SPAWN_DONE__';
    // 进入 ubuntu 后先 clear 清掉 install_ubuntu / proot 登录的 bootstrap 噪声,
    // 再跑真正的命令 (clear 作为 login_ubuntu 命令的第一句, 在 ubuntu 内执行)。
    final cleaned = 'clear\n$command';
    final tabId = await terminalTabManager.addCommandTerminalTab(
      title: title,
      command: 'source ${RuntimeEnvir.homePath}/common.sh\n'
          'install_ubuntu\n'
          'login_ubuntu ${_shellSingleQuote(cleaned)}\n'
          'echo $marker\n',
      onDoneMarker: marker,
      onCommandDone: () {
        if (key != null) _spawnTabIds.remove(key);
        _setSpawnRunning(key, false);
        onExit?.call();
      },
    );
    if (key != null && tabId.isNotEmpty) _spawnTabIds[key] = tabId;
    _setSpawnRunning(key, true);
  }

  /// 停止 key 对应的 spawn (关闭其终端 tab 并 kill 进程)。
  void stopSpawn(String key) {
    final id = _spawnTabIds.remove(key);
    if (id != null) terminalTabManager.closeTabById(id);
    _setSpawnRunning(key, false);
  }

  /// 新建一个交互式终端标签页 (进入容器 bash)。
  /// 末尾的 clear 会被喂给已进入的 ubuntu 交互 bash (而非外层容器),
  /// 从而清掉安装/登录过程的噪声, 得到干净的 root 提示符。
  Future<void> newTerminalTab() async {
    await ensureContainerScripts();
    final n = terminalTabManager.tabs.length + 1;
    final cmd = 'source ${RuntimeEnvir.homePath}/common.sh\n'
        'install_ubuntu\n'
        "login_ubuntu 'bash'\n"
        'clear\n';
    await terminalTabManager.addCommandTerminalTab(title: '终端 $n', command: cmd);
  }

  /// 供 Lua 脚本调用: 在容器内执行命令并捕获输出与退出码。
  /// 返回 { 'code': int, 'output': String }。用唯一标记框住真实输出, 过滤 PTY 回显与提示符。
  Future<Map<String, dynamic>> runShellCapture(
    String command, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    const startMark = '__EXEC_START_7f3a2b__';
    const endMark = '__EXEC_END_7f3a2b__';
    final pty = createPTY();
    final done = Completer<void>();
    final buffer = StringBuffer();
    final sub = pty.output.listen(
      (data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        if (buffer.toString().contains('$endMark:')) {
          if (!done.isCompleted) done.complete();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
    );
    final wrapped = 'echo $startMark; $command; echo "$endMark:\$?"';
    pty.writeString(
      'source ${RuntimeEnvir.homePath}/common.sh\n'
      'login_ubuntu ${_shellSingleQuote(wrapped)}\n'
      'exit\n',
    );
    await done.future.timeout(timeout, onTimeout: () {});
    await sub.cancel();
    pty.kill();

    final raw = buffer.toString();
    var code = -1;
    var out = raw;
    final startIdx = raw.lastIndexOf(startMark);
    if (startIdx >= 0) {
      final afterStart = raw.substring(startIdx + startMark.length);
      final endIdx = afterStart.indexOf(endMark);
      out = endIdx >= 0 ? afterStart.substring(0, endIdx) : afterStart;
    }
    final endMatch = RegExp('$endMark:(\\d+)').firstMatch(raw);
    if (endMatch != null) code = int.tryParse(endMatch.group(1) ?? '') ?? -1;
    out = out.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '').trim();
    return {'code': code, 'output': out};
  }

  Future<void> _runUbuntuShell(String command) async {
    final pty = createPTY();
    final done = Completer<void>();
    final sub = pty.output.listen(
      (_) {},
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
    );
    pty.writeString(
      'source ${RuntimeEnvir.homePath}/common.sh\n'
      'login_ubuntu ${_shellSingleQuote(command)}\n'
      'exit\n',
    );
    await done.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    await sub.cancel();
    pty.kill();
  }

  void onClose() {
    WidgetsBinding.instance.removeObserver(
      LifecycleObserver(
        onResume: () {},
        onPause: () {},
      ),
    );
    super.onClose();
  }
}

// 应用生命周期观察者类
class LifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onResume;
  final VoidCallback onPause;

  LifecycleObserver({required this.onResume, required this.onPause});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        onResume();
        break;
      case AppLifecycleState.paused:
        onPause();
        break;
      default:
        break;
    }
  }
}
