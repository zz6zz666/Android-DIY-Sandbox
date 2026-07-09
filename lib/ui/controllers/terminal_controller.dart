import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/config/environment_config.dart';
import '../../core/config/service_ports.dart';
import '../../core/config/ui_preferences.dart';
import '../../generated/l10n.dart';
import '../../core/constants/scripts.dart';
import '../../core/utils/file_utils.dart';
import '../routes/app_routes.dart';
import 'terminal_tab_manager.dart';
import 'webview_tab_manager.dart';

class NapCatInstanceDefaults {
  static const String storageKey = 'napcat_instances';
  static const String legacyBindingMigrationKey =
      'napcat_legacy_binding_migration_v2';
  static const int firstExtraWebUiPort = 6099;
  static const int lastExtraWebUiPort = 6149;
  static const int firstExtraDisplay = 22;
  static const int firstOneBotPort = 6199;
  static const int lastOneBotPort = 6249;
  static const String defaultWebSocketClientName = 'WsClient';
  static const String defaultOneBotToken =
      'kasdkfljsadhlskdjhasdlkfshdlafksjdhf';
  static const int invalidOneBotPort = 6250;
  static const String invalidOneBotToken = 'invalid';
}

const int _napCatQrExpireSeconds = 120;

class _NapCatQrDialogState {
  final RxInt secondsLeft;
  Timer? timer;
  VoidCallback? close;
  bool closed = false;

  _NapCatQrDialogState({required this.secondsLeft});
}

class NapCatWebSocketClient {
  final int index;
  final String name;
  final bool enabled;
  final String url;
  final String token;
  final int? port;

  const NapCatWebSocketClient({
    required this.index,
    required this.name,
    required this.enabled,
    required this.url,
    required this.token,
    required this.port,
  });
}

class AstrBotOneBotAdapter {
  final int index;
  final String id;
  final bool enabled;
  final int port;
  final String token;

  const AstrBotOneBotAdapter({
    required this.index,
    required this.id,
    required this.enabled,
    required this.port,
    required this.token,
  });
}

enum BotBindingConfigState {
  unconfigured,
  configured,
  mismatch,
}

class HomeController extends GetxController {
  // 终端标签页管理器
  late final TerminalTabManager terminalTabManager;
  // 通用 WebUI 标签页管理器 (无 AstrBot/NapCat 语义)
  final WebViewTabManager webViewTabManager = WebViewTabManager();
  // 再次点击当前导航图标的信号: 终端页弹出更多菜单; WebUI 页切换二级浏览器工具栏
  final RxInt terminalMenuSignal = 0.obs;
  final RxBool webviewToolbarVisible = false.obs;
  // bool vsCodeStaring = false;
  SettingNode privacySetting = 'privacy'.setting;
  SettingNode napCatWebUiEnabled = 'napcat_webui_enabled'.setting;
  Pty? pseudoTerminal;
  Pty? napcatTerminal;

  final RxString napCatWebUiToken = ''.obs; // 存储 NapCat WebUI Token
  final RxBool _isQrcodeShowing = false.obs;
  final RxBool napCatWebUiEnabledRx = false.obs; // GetX 响应式变量用于导航栏更新
  final RxList<Map<String, String>> customWebViews =
      <Map<String, String>>[].obs; // 自定义 WebView 列表
  final RxList<Map<String, dynamic>> napCatInstances =
      <Map<String, dynamic>>[].obs;
  final RxBool isAstrBotStarting = false.obs;
  final RxBool isAstrBotRunning = false.obs;
  final RxBool isAstrBotStopping = false.obs;
  final RxString homeBackgroundPath = ''.obs;
  final RxDouble cardGlassOpacity = 0.62.obs;
  final RxDouble glassBlurAmount = 0.45.obs;
  final RxDouble topNavGlassOpacity = 0.62.obs;
  final RxDouble statusOverlayOpacity = 0.38.obs;
  final RxDouble terminalOverlayOpacity = 0.55.obs;
  final Map<String, Pty> _napCatInstanceTerminals = {};
  final Map<String, StreamSubscription> _napCatInstanceSubscriptions = {};
  final Set<String> _napCatInstanceQqProbing = {};
  final Map<String, _NapCatQrDialogState> _napCatQrDialogs = {};
  final RxList<String> hiddenWebUiTargetIds = <String>[].obs;
  final RxnString pendingWebUiTargetId = RxnString();
  final RxnInt pendingMainTabIndex = RxnInt();
  Dialog? _qrcodeDialog;
  StreamSubscription? _qrcodeSubscription;
  StreamSubscription? _webviewSubscription; // 添加webview监听订阅

  late Terminal terminal = _createMainTerminal();
  bool webviewHasOpen = false;
  bool _isLocalhostDetected = false; // AstrBot dashboard 端口检测标志
  bool _isQrcodeProcessed = false; // 二维码处理完成标志
  bool _isAppInForeground = true; // 应用是否在前台
  bool showStartupProgress = true; // 是否显示启动进度浮层
  static const int _maxStartupLogChars = 120000;
  String _startupLogText = '';
  String _terminalWriteBuffer = '';
  Timer? _terminalWriteTimer;

  Terminal _createMainTerminal() {
    return Terminal(
      maxLines: 10000,
      onResize: (width, height, pixelWidth, pixelHeight) {
        pseudoTerminal?.resize(height, width);
      },
      onOutput: (data) {
        pseudoTerminal?.writeString(data);
      },
    );
  }

  void _resetMainTerminal() {
    _terminalWriteTimer?.cancel();
    _terminalWriteTimer = null;
    _terminalWriteBuffer = '';
    terminal = _createMainTerminal();
    // 不再常驻只读 Main 终端标签; 终端标签全部由动作(spawn)按需创建。
  }

  String get startupLogText => _startupLogText;

  void clearStartupLog() {
    _startupLogText = '';
  }

  File progressFile = File('${RuntimeEnvir.tmpPath}/progress');
  File progressDesFile = File('${RuntimeEnvir.tmpPath}/progress_des');
  double progress = 0.0;
  double step = 14.0;
  String currentProgress = '';

  // 进度 +1
  // Progress +1
  void bumpProgress() {
    try {
      int current = 0;
      if (progressFile.existsSync()) {
        final content = progressFile.readAsStringSync().trim();
        if (content.isNotEmpty) {
          current = int.tryParse(content) ?? 0;
        }
      } else {
        progressFile.createSync(recursive: true);
      }
      progressFile.writeAsStringSync('${current + 1}');
    } catch (e) {
      progressFile.writeAsStringSync('1');
    }
    update();
  }

  String _cleanTerminalLog(String text) {
    return text
        .replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
  }

  void _recordStartupLog(String text) {
    if (text.isEmpty) return;
    _startupLogText += _cleanTerminalLog(text);
    if (_startupLogText.length > _maxStartupLogChars) {
      _startupLogText = _startupLogText
          .substring(_startupLogText.length - _maxStartupLogChars);
    }
  }

  void _writeTerminal(String text) {
    _recordStartupLog(text);
    _terminalWriteBuffer += text;
    if (_terminalWriteBuffer.length > 20000) {
      _terminalWriteBuffer =
          _terminalWriteBuffer.substring(_terminalWriteBuffer.length - 20000);
    }
    _terminalWriteTimer ??= Timer(const Duration(milliseconds: 50), () {
      final buffered = _terminalWriteBuffer;
      _terminalWriteBuffer = '';
      _terminalWriteTimer = null;
      if (buffered.isNotEmpty) {
        terminal.write(buffered);
      }
    });
  }

  void _writeInstanceOutput(String instanceName, String text) {
    if (text.length > 4000) {
      text = '${text.substring(text.length - 4000)}\r\n';
    }
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty && i == lines.length - 1) continue;
      _writeTerminal('[$instanceName] $line\r\n');
    }
  }

  void _requestMainTab(int index) {
    pendingMainTabIndex.value = index;
  }

  void clearPendingMainTabIndex(int index) {
    if (pendingMainTabIndex.value == index) {
      pendingMainTabIndex.value = null;
    }
  }

  // 检查两个条件是否都满足，如果满足则切到新版主界面的 WebUI 页。
  void _checkAndNavigateToWebview() {
    if (_isLocalhostDetected &&
        _isQrcodeProcessed &&
        _isAppInForeground &&
        !webviewHasOpen) {
      Future.microtask(() {
        requestOpenAstrBotWebUi();
        _requestMainTab(1);
        webviewHasOpen = true;
      });
    }
  }

  void _markStartupReady({bool qrcodeProcessed = false}) {
    if (qrcodeProcessed) {
      _isQrcodeProcessed = true;
    }
    isAstrBotStarting.value = false;
    isAstrBotRunning.value = true;
    showStartupProgress = false;
    update();
    _checkAndNavigateToWebview();
  }

  void revealStartupLog() {
    showStartupProgress = false;
    update();
  }

  // 监听输出，当输出中包含启动成功的标志时，启动 VewView 和导航栏页面
  void initWebviewListener() {
    if (pseudoTerminal == null) return;

    _webviewSubscription = pseudoTerminal!.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((event) async {
      _recordStartupLog(event);
      // 输出到 Flutter 控制台
      // Output to Flutter console
      if (event.trim().isNotEmpty) {
        // 按行分割输出，避免控制台输出混乱
        final lines = event.split('\n');
        for (var line in lines) {
          if (line.trim().isNotEmpty) {
            Log.i(line, tag: 'AstrBot');
          }
        }
      }

      // 检查是否包含当前配置的 AstrBot dashboard 端口
      if (event.contains('__ASTRBOT_MANUAL_ENV_REQUIRED__')) {
        _writeTerminal(
          '\r\n[环境] 运行环境还没安装完整，请进入 主页 -> 环境管理 分步安装。\r\n',
        );
        _openHomeForManualEnvironment();
        return;
      }

      if (_containsDashboardUrl(event)) {
        _isLocalhostDetected = true;
        bumpProgress();

        // AstrBot 控制台端口已经可用。若当前没有二维码弹窗，说明无需等待扫码
        // 流程（常见于已登录/已初始化场景），可以直接进入 WebView。
        if (!_isQrcodeShowing.value) {
          _markStartupReady(qrcodeProcessed: true);
        } else {
          _checkAndNavigateToWebview();
        }

        Future.delayed(const Duration(milliseconds: 2000), () {
          update();
        });

        // 不取消订阅，继续监听以便终端日志持续更新
      }

      _writeTerminal(event);
    }, onDone: () {
      isAstrBotStarting.value = false;
      isAstrBotRunning.value = false;
      showStartupProgress = false;
      update();
    }, onError: (error) {
      isAstrBotStarting.value = false;
      isAstrBotRunning.value = false;
      showStartupProgress = false;
      _writeTerminal('\r\n[AstrBot] 进程输出异常: $error\r\n');
      update();
    });
  }

  bool _containsDashboardUrl(String event) {
    final port = ServicePorts.dashboardPort;
    return event.contains('http://localhost:$port') ||
        event.contains('http://127.0.0.1:$port') ||
        event.contains('http://0.0.0.0:$port');
  }

  void _openHomeForManualEnvironment() {
    isAstrBotStarting.value = false;
    isAstrBotRunning.value = false;
    showStartupProgress = false;
    _isLocalhostDetected = true;
    _isQrcodeProcessed = true;
    update();

    if (_isAppInForeground && !webviewHasOpen) {
      Future.microtask(() {
        Get.toNamed(
          AppRoutes.main,
        );
        webviewHasOpen = true;
      });
    }
  }

  void initQrcodeListener() {
    if (napcatTerminal == null) return;

    _qrcodeSubscription = napcatTerminal!.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((event) async {
      _recordStartupLog(event);
      // 先判断订阅是否已取消，避免重复处理
      if (_qrcodeSubscription == null) return;

      // 输出到 Flutter 控制台
      // Output to Flutter console
      if (event.trim().isNotEmpty) {
        _writeTerminal(event);

        // 按行分割输出，避免控制台输出混乱
        final lines = event.split('\n');
        for (var line in lines) {
          if (line.trim().isNotEmpty) {
            Log.i(line, tag: 'AstrBot-Napcat');
          }
        }
      }

      // 捕获 NapCat WebUI Token
      if (event.contains('WebUi Token:')) {
        final match = RegExp(r'WebUi Token:\s+(\w+)').firstMatch(event);
        if (match != null) {
          final token = match.group(1);
          if (token != null) {
            napCatWebUiToken.value = token;
            Log.i('捕获到 NapCat Token: $token', tag: 'AstrBot');
          }
        }
      }

      // 检测指令1显示二维码
      if (event.contains('二维码已保存到') && !_isQrcodeShowing.value) {
        _isQrcodeShowing.value = true;
        final qrcodePath = '$ubuntuPath/root/napcat/cache/qrcode.png';
        final qrcodeFile = File(qrcodePath);

        if (await qrcodeFile.exists()) {
          _qrcodeDialog = Dialog(
            backgroundColor: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '请用手机QQ扫码登录',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Image.file(
                    qrcodeFile,
                    width: 200,
                    height: 200,
                    fit: BoxFit.contain,
                  ),
                ],
              ),
            ),
          );

          // 使用GetX的导航管理避免上下文问题
          await Get.dialog(
            _qrcodeDialog!,
            barrierDismissible: false,
          );

          _isQrcodeShowing.value = false;
          _qrcodeDialog = null;
        } else {
          Get.showSnackbar(GetSnackBar(
            message: '二维码图片不存在：$qrcodePath',
            duration: const Duration(seconds: 3),
          ));
          _isQrcodeShowing.value = false;
        }
      }

      // 检测指令2关闭二维码并取消监听
      if (event.contains('配置加载') && _isQrcodeShowing.value) {
        // 关闭对话框
        if (_qrcodeDialog != null) {
          Get.back();
          _isQrcodeShowing.value = false;
          _qrcodeDialog = null;
        }

        // 标记二维码处理完成
        _markStartupReady(qrcodeProcessed: true);

        // 取消订阅，后续不再监听任何指令
        await _qrcodeSubscription?.cancel();
        _qrcodeSubscription = null; // 置空标记已取消
      }

      // 检测指令3处理登录错误
      if (event.contains('Login Error') && _isQrcodeShowing.value) {
        // 关闭二维码对话框
        if (_qrcodeDialog != null) {
          Get.back();
          _isQrcodeShowing.value = false;
          _qrcodeDialog = null;
        }

        // 提取错误信息
        String errorMsg = '登录失败';
        if (event.contains('"message":"')) {
          final match = RegExp(r'"message":"([^"]+)"').firstMatch(event);
          if (match != null) {
            errorMsg = match.group(1) ?? errorMsg;
          }
        }

        // 显示错误提示
        Get.snackbar(
          'NapCat 登录失败',
          errorMsg,
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red.withValues(alpha: 0.8),
          colorText: Colors.white,
          duration: const Duration(seconds: 5),
        );

        // 不取消订阅，允许用户重新扫码
      }
    });
  }

  // 初始化环境，将动态库中的文件链接到数据目录
  // Init environment and link files from the dynamic library to the data directory
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
  void syncProgress() {
    progressFile.createSync(recursive: true);
    progressFile.writeAsStringSync('0');
    progressFile.watch(events: FileSystemEvent.all).listen((event) async {
      if (event.type == FileSystemEvent.modify) {
        String content = await progressFile.readAsString();
        Log.e('content -> $content');
        if (content.isEmpty) {
          return;
        }
        progress = int.parse(content) / step;
        Log.e('progress -> $progress');
        update();
      }
    });
    progressDesFile.createSync(recursive: true);
    progressDesFile.writeAsStringSync('');
    progressDesFile.watch(events: FileSystemEvent.all).listen((event) async {
      if (event.type == FileSystemEvent.modify) {
        String content = await progressDesFile.readAsString();
        currentProgress = content;

        update();
      }
    });
  }

  // 创建 busybox 的软连接，来确保 proot 会用到的命令正常运行
  // create busybox symlinks, to ensure proot can use the commands normally
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

  void setProgress(String description) {
    currentProgress = description;
    terminal.writeProgress(currentProgress);
  }

  Future<void> loadAstrBot() async {
    if (isAstrBotStarting.value || isAstrBotRunning.value) return;
    isAstrBotStarting.value = true;
    isAstrBotRunning.value = false;
    showStartupProgress = true;
    _isLocalhostDetected = false;
    _isQrcodeProcessed = false;
    webviewHasOpen = false;
    _startupLogText = '';
    _webviewSubscription?.cancel();
    _qrcodeSubscription?.cancel();
    pseudoTerminal?.kill();
    pseudoTerminal = null;
    _resetMainTerminal();
    update();

    try {
      syncProgress();

      // 创建相关文件夹
      Directory(RuntimeEnvir.tmpPath).createSync(recursive: true);
      Directory(RuntimeEnvir.homePath).createSync(recursive: true);
      Directory(RuntimeEnvir.binPath).createSync(recursive: true);

      await initEnvir();
      createBusyboxLink();

      // 创建终端
      pseudoTerminal = createPTY(
        rows: max(terminal.viewHeight, 24),
        columns: max(terminal.viewWidth, 80),
      );
      napcatTerminal = null;

      setProgress('准备启动 AstrBot...');
      bumpProgress();

      // 获取当前应用版本号
      final appVersion = await getAppVersion();

      // 写入 common.sh 脚本
      File('${RuntimeEnvir.homePath}/common.sh').writeAsStringSync(
        _toUnixLineEndings(getCommonScript(appVersion)),
      );

      initWebviewListener();
      bumpProgress();

      startAstrBot(pseudoTerminal!);
    } catch (e) {
      isAstrBotStarting.value = false;
      isAstrBotRunning.value = false;
      showStartupProgress = false;
      update();
      rethrow;
    }
  }

  Future<void> syncAstrBotDashboardPortConfig() async {
    final files = [
      File('${RuntimeEnvir.homePath}/cmd_config.json'),
      File('$ubuntuPath/root/AstrBot/data/cmd_config.json'),
    ];

    for (final file in files) {
      await _patchAstrBotDashboardPortConfig(file);
    }
  }

  String _toUnixLineEndings(String content) {
    return content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Future<void> startAstrBot(Pty pseudoTerminal) async {
    setProgress('开始启动 AstrBot...');
    pseudoTerminal.writeString(
        'source ${RuntimeEnvir.homePath}/common.sh\nstart_astrbot\n');
  }

  Future<void> stopAstrBot() async {
    if (isAstrBotStopping.value) return;
    isAstrBotStopping.value = true;
    isAstrBotStarting.value = false;
    showStartupProgress = false;
    update();

    try {
      await _webviewSubscription?.cancel();
      _webviewSubscription = null;

      pseudoTerminal?.kill();
      pseudoTerminal = null;

      if (File('${RuntimeEnvir.homePath}/common.sh').existsSync()) {
        await _runUbuntuShell(
          'pkill -f "uv run --no-sync main.py" 2>/dev/null || true; '
          'pkill -f "python.*main.py" 2>/dev/null || true; '
          'pkill -f "/root/AstrBot/.venv.*main.py" 2>/dev/null || true',
        );
      }

      _isLocalhostDetected = false;
      _isQrcodeProcessed = false;
      webviewHasOpen = false;
      isAstrBotRunning.value = false;
      _writeTerminal('\r\n[AstrBot] 已停止\r\n');
    } catch (e) {
      _writeTerminal('\r\n[AstrBot] 停止失败: $e\r\n');
      rethrow;
    } finally {
      isAstrBotStopping.value = false;
      update();
    }
  }

  Future<void> _patchAstrBotDashboardPortConfig(File file) async {
    if (!await file.exists()) return;

    try {
      final jsonData = jsonDecode(await file.readAsString());
      if (jsonData is! Map<String, dynamic>) return;

      final dashboard = jsonData['dashboard'];
      if (dashboard is Map<String, dynamic>) {
        dashboard['port'] = ServicePorts.dashboardPort;
      }

      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(jsonData),
      );
      Log.i('已同步 AstrBot 面板端口配置: ${file.path}', tag: 'AstrBot');
    } catch (e) {
      Log.e('同步 AstrBot 面板端口配置失败: ${file.path}, $e', tag: 'AstrBot');
    }
  }

  Future<void> runEnvironmentStep({
    required String step,
    required String title,
    bool reinstall = false,
    void Function()? onCommandDone,
  }) async {
    await _prepareEnvironmentScripts();
    final doneMarker = '__ASTRBOT_ENV_STEP_DONE__:$step';
    final command = StringBuffer()
      ..writeln('source ${RuntimeEnvir.homePath}/common.sh')
      ..writeln('install_ubuntu')
      ..writeln('copy_files')
      ..writeln(
        'login_ubuntu "export TMPDIR=${RuntimeEnvir.tmpPath}; '
        'export L_NOT_INSTALLED=${S.current.uninstalled}; '
        'export L_INSTALLING=${S.current.installing}; '
        'export L_INSTALLED=${S.current.installed}; '
        'export ASTRBOT_DASHBOARD_PORT=${ServicePorts.dashboardPort}; '
        'export ASTRBOT_ONEBOT_WS_PORT=${ServicePorts.oneBotWsPort}; '
        'export ASTRBOT_GITHUB_PROXY=${EnvironmentConfig.githubProxy}; '
        'export ASTRBOT_FORCE_REINSTALL_STEP=${reinstall ? step : ''}; '
        'chmod +x /root/astrbot-startup.sh; '
        'bash /root/astrbot-startup.sh --step $step; '
        'echo \\"__ASTRBOT_ENV_\\"\\"STEP_DONE__:$step\\""',
      );
    await terminalTabManager.addCommandTerminalTab(
      title: title,
      command: command.toString(),
      onDoneMarker: doneMarker,
      onCommandDone: onCommandDone,
    );
  }

  Future<void> _prepareEnvironmentScripts() async {
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
    await AssetsUtils.copyAssetToPath(
        'assets/cmd_config.json', '${RuntimeEnvir.homePath}/cmd_config.json');

    final appVersion = await getAppVersion();

    File('${RuntimeEnvir.homePath}/common.sh').writeAsStringSync(
      _toUnixLineEndings(getCommonScript(appVersion)),
    );
  }

  @override
  void onInit() {
    super.onInit();

    // 初始化终端标签页管理器
    terminalTabManager = TerminalTabManager();

    // 初始化 NapCat WebUI 启用状态
    napCatWebUiEnabledRx.value = napCatWebUiEnabled.get() ?? false;

    // 从持久化存储加载自定义 WebView 列表
    _loadCustomWebViews();
    _loadHiddenWebUiTargetIds();
    _loadNapCatInstances();
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
        onResume: () {
          _isAppInForeground = true;
          // 当应用回到前台且 AstrBot 已就绪时，切到新版主界面的 WebUI 页。
          if (_isLocalhostDetected && _isQrcodeProcessed && !webviewHasOpen) {
            Future.microtask(() {
              requestOpenAstrBotWebUi();
              _requestMainTab(1);
              webviewHasOpen = true;
            });
          }
        },
        onPause: () {
          _isAppInForeground = false;
        },
      ),
    );
  }

  // 加载自定义 WebView 列表
  void _loadCustomWebViews() {
    final stored = box!.get('custom_webviews', defaultValue: <dynamic>[]);
    if (stored is List) {
      customWebViews.value = stored.map((e) {
        if (e is Map) {
          return {
            'title': e['title']?.toString() ?? '',
            'url': e['url']?.toString() ?? '',
          };
        }
        return <String, String>{};
      }).toList();
    }
  }

  // 保存自定义 WebView 列表
  void _saveCustomWebViews() {
    box!.put('custom_webviews', customWebViews.toList());
  }

  // 添加自定义 WebView
  void addCustomWebView(String title, String url) {
    customWebViews.add({'title': title, 'url': url});
    _saveCustomWebViews();
  }

  // 删除自定义 WebView
  void removeCustomWebView(int index) {
    if (index >= 0 && index < customWebViews.length) {
      customWebViews.removeAt(index);
      _saveCustomWebViews();
    }
  }

  // 更新自定义 WebView
  void updateCustomWebView(int index, String title, String url) {
    if (index >= 0 && index < customWebViews.length) {
      customWebViews[index] = {'title': title, 'url': url};
      _saveCustomWebViews();
    }
  }

  // 更新 NapCat WebUI 启用状态（用于同步响应式变量）
  void setNapCatWebUiEnabled(bool value) {
    napCatWebUiEnabled.set(value);
    napCatWebUiEnabledRx.value = value;
  }

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

  void _loadNapCatInstances() {
    final stored = box!.get(
      NapCatInstanceDefaults.storageKey,
      defaultValue: <dynamic>[],
    );
    if (stored is! List) return;

    napCatInstances.value = stored
        .whereType<Map>()
        .map((e) => _normalizeNapCatInstance(Map<String, dynamic>.from(e)))
        .toList();
    unawaited(_migrateLegacyBotBindingsOnce());
  }

  void _loadHiddenWebUiTargetIds() {
    final stored = box!.get('hidden_webui_targets', defaultValue: <dynamic>[]);
    if (stored is List) {
      hiddenWebUiTargetIds.value =
          stored.map((item) => item.toString()).toList();
    }
  }

  void _saveHiddenWebUiTargetIds() {
    box!.put('hidden_webui_targets', hiddenWebUiTargetIds.toList());
  }

  String _defaultNapCatName(int index) => '账号$index';

  int _nextNapCatAccountIndex() => napCatInstances.length + 1;

  Map<String, dynamic> _normalizeNapCatInstance(Map<String, dynamic> instance) {
    final id = instance['id']?.toString().trim().isNotEmpty == true
        ? instance['id'].toString()
        : 'qq_${DateTime.now().millisecondsSinceEpoch}';
    final webUiPort = _parseInt(
      instance['webUiPort'],
      NapCatInstanceDefaults.firstExtraWebUiPort,
    );
    final display = _parseInt(
      instance['display'],
      NapCatInstanceDefaults.firstExtraDisplay,
    );
    final autoLogin = instance['autoLogin'] == true;
    final name = instance['name']?.toString().trim().isNotEmpty == true
        ? instance['name'].toString()
        : _defaultNapCatName(napCatInstances.length + 1);
    return {
      'id': id,
      'name': name,
      'qq': instance['qq']?.toString() ?? '',
      'webUiPort': webUiPort,
      'display': display,
      'token': instance['token']?.toString() ?? '',
      'autoLogin': autoLogin,
      'autoLoginTouched': instance['autoLoginTouched'] == true,
      'qqAutoDetected': instance['qqAutoDetected'] == true,
      'boundWebSocketName': instance['boundWebSocketName']?.toString() ?? '',
      'boundAdapterId': instance['boundAdapterId']?.toString() ?? '',
      'running': _napCatInstanceTerminals.containsKey(id),
    };
  }

  int _parseInt(dynamic value, int fallback) {
    return value is int
        ? value
        : int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  void _saveNapCatInstances() {
    box!.put(
      NapCatInstanceDefaults.storageKey,
      napCatInstances
          .map((instance) => {
                'id': instance['id'],
                'name': instance['name'],
                'qq': instance['qq'],
                'webUiPort': instance['webUiPort'],
                'display': instance['display'],
                'token': instance['token'],
                'autoLogin': instance['autoLogin'] ?? false,
                'autoLoginTouched': instance['autoLoginTouched'] ?? false,
                'qqAutoDetected': instance['qqAutoDetected'] ?? false,
                'boundWebSocketName': instance['boundWebSocketName'] ?? '',
                'boundAdapterId': instance['boundAdapterId'] ?? '',
              })
          .toList(),
    );
  }

  Future<void> _migrateLegacyBotBindingsOnce() async {
    if (box!.get(NapCatInstanceDefaults.legacyBindingMigrationKey) == true) {
      return;
    }
    if (napCatInstances.isEmpty) {
      box!.put(NapCatInstanceDefaults.legacyBindingMigrationKey, true);
      return;
    }

    final adapters = await listAstrBotOneBotAdapters();
    var inspectedNapCatConfig = false;
    var migrated = false;

    for (final instance in List<Map<String, dynamic>>.from(napCatInstances)) {
      final id = instance['id']?.toString() ?? '';
      if (id.isEmpty) continue;

      final boundAdapterId = instance['boundAdapterId']?.toString() ?? '';
      final boundWebSocketName =
          instance['boundWebSocketName']?.toString() ?? '';

      final clients = await listNapCatWebSocketClients(id);
      if (clients.isEmpty) continue;
      inspectedNapCatConfig = true;

      final selectedClient = clients.firstWhereOrNull(
        (client) => client.name == boundWebSocketName,
      );
      final selectedAdapter = adapters.firstWhereOrNull(
        (adapter) => adapter.id == boundAdapterId,
      );
      if (compareBotBinding(selectedClient, selectedAdapter) ==
          BotBindingConfigState.configured) {
        continue;
      }

      var matchedClient = selectedClient;
      var matchedAdapter = matchedClient == null
          ? null
          : adapters.firstWhereOrNull(
              (adapter) =>
                  matchedClient?.port != null &&
                  adapter.port == matchedClient?.port &&
                  adapter.token == matchedClient?.token,
            );
      if (matchedAdapter == null) {
        for (final client in clients) {
          matchedAdapter = adapters.firstWhereOrNull(
            (adapter) =>
                client.port != null &&
                adapter.port == client.port &&
                adapter.token == client.token,
          );
          if (matchedAdapter != null) {
            matchedClient = client;
            break;
          }
        }
      }
      if (matchedClient == null || matchedAdapter == null) continue;
      _updateNapCatInstance(id, {
        if (boundWebSocketName != matchedClient.name)
          'boundWebSocketName': matchedClient.name,
        if (boundAdapterId != matchedAdapter.id)
          'boundAdapterId': matchedAdapter.id,
      });
      migrated = true;
    }

    if (inspectedNapCatConfig && adapters.isNotEmpty) {
      box!.put(NapCatInstanceDefaults.legacyBindingMigrationKey, true);
      if (migrated) {
        Log.i('已自动迁移旧版 NapCat / AstrBot 绑定关系', tag: 'AstrBot');
      }
    }
  }

  int _findInstanceIndex(String id) {
    return napCatInstances.indexWhere((instance) => instance['id'] == id);
  }

  void _updateNapCatInstance(String id, Map<String, dynamic> patch) {
    final index = _findInstanceIndex(id);
    if (index < 0) return;
    napCatInstances[index] = {
      ...napCatInstances[index],
      ...patch,
    };
    _saveNapCatInstances();
  }

  Future<bool> _isPortAvailable(int port) async {
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      return true;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }

  File _napCatOneBotTemplateConfigFile(String id) =>
      File('$ubuntuPath/root/napcat_instances/${id}_napcat/config/onebot11.json');

  String _napCatInstanceQq(String id) {
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    return instance?['qq']?.toString().trim() ?? '';
  }

  File? _napCatOneBotAccountConfigFile(String id) {
    final qq = _napCatInstanceQq(id);
    if (qq.isEmpty) return null;
    return File(
      '$ubuntuPath/root/napcat_instances/${id}_napcat/config/onebot11_$qq.json',
    );
  }

  Future<Map<String, dynamic>?> _readActiveNapCatOneBotConfig(String id) async {
    final file = _napCatOneBotAccountConfigFile(id);
    if (file == null) return null;
    return _readJsonMap(file);
  }

  Future<Map<String, dynamic>?> _readNapCatOneBotConfigForPortScan(
    String id,
  ) async {
    final accountFile = _napCatOneBotAccountConfigFile(id);
    if (accountFile != null && await accountFile.exists()) {
      return _readJsonMap(accountFile);
    }
    return _readJsonMap(_napCatOneBotTemplateConfigFile(id));
  }

  List<File> get _astrBotConfigFiles => [
        File('$ubuntuPath/root/AstrBot/data/cmd_config.json'),
        File('${RuntimeEnvir.homePath}/cmd_config.json'),
      ];

  Future<Map<String, dynamic>?> _readJsonMap(File file) async {
    if (!await file.exists()) return null;
    try {
      final data = jsonDecode(await file.readAsString());
      return data is Map<String, dynamic> ? data : null;
    } catch (e) {
      Log.e('读取 JSON 失败: ${file.path}, $e', tag: 'AstrBot');
      return null;
    }
  }

  Future<void> _writeJsonMap(File file, Map<String, dynamic> data) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
    );
  }

  int? _extractWsPort(String url) {
    final match = RegExp(r'^wss?://[^/:]+:(\d+)/?.*$', caseSensitive: false)
        .firstMatch(url.trim());
    return int.tryParse(match?.group(1) ?? '');
  }

  String _oneBotWsUrl(int port) => 'ws://localhost:$port/ws';

  Map<String, dynamic> _buildDefaultNapCatOneBotConfig(int port) => {
        'network': {
          'httpServers': [],
          'httpClients': [],
          'websocketServers': [],
          'websocketClients': [
            {
              'name': NapCatInstanceDefaults.defaultWebSocketClientName,
              'enable': true,
              'url': _oneBotWsUrl(port),
              'messagePostFormat': 'array',
              'reportSelfMessage': false,
              'reconnectInterval': 5000,
              'token': NapCatInstanceDefaults.defaultOneBotToken,
              'debug': false,
              'heartInterval': 30000,
            }
          ],
        },
        'musicSignUrl': '',
        'enableLocalFile2Url': false,
        'parseMultMsg': false,
      };

  List<dynamic> _webSocketClientList(Map<String, dynamic> config) {
    final network = config['network'];
    if (network is! Map<String, dynamic>) return <dynamic>[];
    final clients = network['websocketClients'];
    if (clients is List) return clients;
    network['websocketClients'] = <dynamic>[];
    return network['websocketClients'] as List<dynamic>;
  }

  Future<List<NapCatWebSocketClient>> listNapCatWebSocketClients(
    String id,
  ) async {
    final config = await _readActiveNapCatOneBotConfig(id);
    if (config == null) return const [];
    final clients = _webSocketClientList(config);
    final result = <NapCatWebSocketClient>[];
    for (var i = 0; i < clients.length; i++) {
      final client = clients[i];
      if (client is! Map) continue;
      final data = Map<String, dynamic>.from(client);
      final name = data['name']?.toString().trim().isNotEmpty == true
          ? data['name'].toString()
          : 'websocket ${i + 1}';
      final url = data['url']?.toString() ?? '';
      result.add(
        NapCatWebSocketClient(
          index: i,
          name: name,
          enabled: data['enable'] != false,
          url: url,
          token: data['token']?.toString() ?? '',
          port: _extractWsPort(url),
        ),
      );
    }
    return result;
  }

  Future<List<AstrBotOneBotAdapter>> listAstrBotOneBotAdapters() async {
    final config = await _readAstrBotConfig();
    if (config == null) return const [];
    final platforms = config['platform'];
    if (platforms is! List) return const [];
    final result = <AstrBotOneBotAdapter>[];
    for (var i = 0; i < platforms.length; i++) {
      final item = platforms[i];
      if (item is! Map) continue;
      final data = Map<String, dynamic>.from(item);
      if (data['type']?.toString() != 'aiocqhttp') continue;
      result.add(
        AstrBotOneBotAdapter(
          index: i,
          id: data['id']?.toString() ?? '',
          enabled: data['enable'] != false,
          port: _parseInt(data['ws_reverse_port'], -1),
          token: data['ws_reverse_token']?.toString() ?? '',
        ),
      );
    }
    return result;
  }

  Future<Map<String, dynamic>?> _readAstrBotConfig() async {
    for (final file in _astrBotConfigFiles) {
      final config = await _readJsonMap(file);
      if (config != null) return config;
    }
    return null;
  }

  Future<void> _writeAstrBotConfig(Map<String, dynamic> config) async {
    var wrote = false;
    for (final file in _astrBotConfigFiles) {
      if (await file.exists()) {
        await _writeJsonMap(file, config);
        wrote = true;
      }
    }
    if (!wrote) {
      await _writeJsonMap(_astrBotConfigFiles.first, config);
    }
  }

  Future<Set<int>> _usedNapCatOneBotPorts({String? exceptId}) async {
    final ports = <int>{};
    for (final instance in napCatInstances) {
      final id = instance['id']?.toString() ?? '';
      if (id.isEmpty || id == exceptId) continue;
      final config = await _readNapCatOneBotConfigForPortScan(id);
      if (config == null) continue;
      for (final client in _webSocketClientList(config)) {
        if (client is! Map) continue;
        final port = _extractWsPort(client['url']?.toString() ?? '');
        if (port != null) ports.add(port);
      }
    }
    return ports;
  }

  Future<Set<int>> _matchingAstrBotOneBotPorts() async {
    final ports = <int>{};
    for (final adapter in await listAstrBotOneBotAdapters()) {
      if (adapter.token != NapCatInstanceDefaults.defaultOneBotToken) continue;
      if (adapter.port >= NapCatInstanceDefaults.firstOneBotPort &&
          adapter.port <= NapCatInstanceDefaults.lastOneBotPort) {
        ports.add(adapter.port);
      }
    }
    return ports;
  }

  Future<int> _allocateOneBotPort({String? exceptId}) async {
    final blackList = await _usedNapCatOneBotPorts(exceptId: exceptId);
    final whiteList = await _matchingAstrBotOneBotPorts();
    for (var port = NapCatInstanceDefaults.firstOneBotPort;
        port <= NapCatInstanceDefaults.lastOneBotPort;
        port++) {
      if (blackList.contains(port) || port == ServicePorts.dashboardPort) {
        continue;
      }
      if (whiteList.contains(port)) return port;
      if (await _isPortAvailable(port)) return port;
    }
    throw '没有找到可用的 OneBot 端口';
  }

  Future<void> _ensureNapCatOneBotConfig(
    Map<String, dynamic> instance, {
    int? oneBotPort,
  }) async {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final file = _napCatOneBotTemplateConfigFile(id);
    if (await file.exists()) return;
    final port = oneBotPort ?? await _allocateOneBotPort(exceptId: id);
    await _writeJsonMap(file, _buildDefaultNapCatOneBotConfig(port));
    _updateNapCatInstance(id, {
      'boundWebSocketName': NapCatInstanceDefaults.defaultWebSocketClientName,
    });
  }

  Future<NapCatWebSocketClient?> selectedNapCatWebSocketClient(
    Map<String, dynamic> instance,
  ) async {
    final id = instance['id']?.toString() ?? '';
    final name = instance['boundWebSocketName']?.toString() ?? '';
    if (id.isEmpty || name.isEmpty) return null;
    final clients = await listNapCatWebSocketClients(id);
    return clients.firstWhereOrNull((client) => client.name == name);
  }

  Future<AstrBotOneBotAdapter?> selectedAstrBotAdapter(
    Map<String, dynamic> instance,
  ) async {
    final id = instance['boundAdapterId']?.toString() ?? '';
    if (id.isEmpty) return null;
    final adapters = await listAstrBotOneBotAdapters();
    return adapters.firstWhereOrNull((adapter) => adapter.id == id);
  }

  Future<AstrBotOneBotAdapter?> matchingAstrBotAdapterForClient(
    NapCatWebSocketClient client,
  ) async {
    final adapters = await listAstrBotOneBotAdapters();
    return adapters.firstWhereOrNull(
      (adapter) => adapter.port == client.port && adapter.token == client.token,
    );
  }

  BotBindingConfigState compareBotBinding(
    NapCatWebSocketClient? client,
    AstrBotOneBotAdapter? adapter,
  ) {
    if (client == null || adapter == null) return BotBindingConfigState.unconfigured;
    if (client.port == adapter.port && client.token == adapter.token) {
      return BotBindingConfigState.configured;
    }
    return BotBindingConfigState.mismatch;
  }

  bool isAstrBotAdapterBoundByOther(String adapterId, String napCatId) {
    return napCatInstances.any(
      (instance) =>
          instance['id']?.toString() != napCatId &&
          instance['boundAdapterId']?.toString() == adapterId,
    );
  }

  Future<void> bindNapCatWebSocketClient({
    required String id,
    required String clientName,
  }) async {
    final file = _napCatOneBotAccountConfigFile(id);
    if (file == null) throw '请先登录 QQ 后再绑定 BOT';
    final config = await _readJsonMap(file);
    if (config == null) throw 'NapCat websocket 配置不存在';
    final clients = _webSocketClientList(config);
    var found = false;
    for (final client in clients) {
      if (client is! Map) continue;
      if (client['name']?.toString() == clientName) {
        client['enable'] = true;
        found = true;
        break;
      }
    }
    if (!found) throw '未找到 websocket 配置：$clientName';
    await _writeJsonMap(file, config);
    _updateNapCatInstance(id, {'boundWebSocketName': clientName});
  }

  Future<void> bindAstrBotAdapter({
    required String id,
    required String adapterId,
    required bool updateAdapterFromWebSocket,
    bool invalidatePreviousAdapter = false,
  }) async {
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    if (instance == null) return;
    final client = await selectedNapCatWebSocketClient(instance);
    if (client == null) throw '请先绑定 websocket 适配器';
    if (client.port == null) throw 'websocket URL 缺少端口';
    final config = await _readAstrBotConfig();
    if (config == null) throw 'AstrBot 配置不存在';
    final platforms = config['platform'];
    if (platforms is! List) throw 'AstrBot platform 配置不存在';

    final oldAdapterId = instance['boundAdapterId']?.toString() ?? '';
    var foundAdapter = false;
    for (final item in platforms) {
      if (item is! Map) continue;
      if (invalidatePreviousAdapter &&
          oldAdapterId.isNotEmpty &&
          oldAdapterId != adapterId &&
          item['id']?.toString() == oldAdapterId &&
          !isAstrBotAdapterBoundByOther(oldAdapterId, id)) {
        item['enable'] = false;
        item['ws_reverse_port'] = NapCatInstanceDefaults.invalidOneBotPort;
        item['ws_reverse_token'] = NapCatInstanceDefaults.invalidOneBotToken;
      }
      if (item['id']?.toString() == adapterId) {
        foundAdapter = true;
        if (updateAdapterFromWebSocket) {
          item['enable'] = true;
          item['ws_reverse_host'] = '0.0.0.0';
          item['ws_reverse_port'] = client.port;
          item['ws_reverse_token'] = client.token;
        }
      }
    }
    if (!foundAdapter) throw '未找到 AstrBot 适配器：$adapterId';

    await _writeAstrBotConfig(config);
    _updateNapCatInstance(id, {'boundAdapterId': adapterId});
  }

  Future<String> createAstrBotAdapterForNapCat({
    required String id,
    required String preferredName,
    bool allowSharedPreviousAdapter = false,
  }) async {
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    if (instance == null) throw 'NapCat 账号不存在';
    final client = await selectedNapCatWebSocketClient(instance);
    if (client == null) throw '请先绑定 websocket 适配器';
    if (client.port == null) throw 'websocket URL 缺少端口';
    final config = (await _readAstrBotConfig()) ?? <String, dynamic>{};
    final platforms = config['platform'];
    final list = platforms is List ? platforms : <dynamic>[];
    config['platform'] = list;
    final oldAdapterId = instance['boundAdapterId']?.toString() ?? '';
    final oldAdapterShared = oldAdapterId.isNotEmpty &&
        isAstrBotAdapterBoundByOther(oldAdapterId, id);
    if (oldAdapterShared && !allowSharedPreviousAdapter) {
      throw '旧 AstrBot 适配器 $oldAdapterId 已被其他账号绑定';
    }
    final adapterId = _uniqueAdapterId(
      preferredName.trim().isEmpty
          ? instance['name']?.toString() ?? 'NapCat'
          : preferredName.trim(),
      list,
    );
    if (oldAdapterId.isNotEmpty && !oldAdapterShared) {
      for (final item in list) {
        if (item is Map && item['id']?.toString() == oldAdapterId) {
          item['enable'] = false;
          item['ws_reverse_port'] = NapCatInstanceDefaults.invalidOneBotPort;
          item['ws_reverse_token'] = NapCatInstanceDefaults.invalidOneBotToken;
          break;
        }
      }
    }
    list.add({
      'id': adapterId,
      'type': 'aiocqhttp',
      'enable': true,
      'ws_reverse_host': '0.0.0.0',
      'ws_reverse_port': client.port,
      'ws_reverse_token': client.token,
    });
    await _writeAstrBotConfig(config);
    _updateNapCatInstance(id, {'boundAdapterId': adapterId});
    return adapterId;
  }

  String _uniqueAdapterId(String baseName, List<dynamic> platforms) {
    final used = platforms
        .whereType<Map>()
        .map((item) => item['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    var candidate = baseName.trim().isEmpty ? 'NapCat' : baseName.trim();
    if (!used.contains(candidate)) return candidate;
    const letters = 'abcdefghijklmnopqrstuvwxyz';
    final random = Random();
    do {
      candidate =
          '${baseName.trim().isEmpty ? 'NapCat' : baseName.trim()}${letters[random.nextInt(letters.length)]}';
    } while (used.contains(candidate));
    return candidate;
  }

  bool _isDisplayReserved(int display, {String? exceptId}) {
    if (display == ServicePorts.napCatXDisplay) return true;
    return napCatInstances.any(
      (instance) =>
          instance['id'] != exceptId &&
          _parseInt(instance['display'], -1) == display,
    );
  }

  Future<int> _allocateNapCatWebUiPort({int? requestedPort}) async {
    if (requestedPort != null) {
      if (requestedPort < NapCatInstanceDefaults.firstExtraWebUiPort ||
          requestedPort > NapCatInstanceDefaults.lastExtraWebUiPort) {
        throw 'WebUI 端口必须在 ${NapCatInstanceDefaults.firstExtraWebUiPort}-${NapCatInstanceDefaults.lastExtraWebUiPort} 之间';
      }
      if (requestedPort == ServicePorts.dashboardPort ||
          requestedPort == ServicePorts.oneBotWsPort ||
          napCatInstances.any(
            (instance) => _parseInt(instance['webUiPort'], -1) == requestedPort,
          )) {
        throw 'WebUI 端口 $requestedPort 已被配置占用';
      }
      if (!await _isPortAvailable(requestedPort)) {
        throw 'WebUI 端口 $requestedPort 当前已被系统占用';
      }
      return requestedPort;
    }

    for (var port = NapCatInstanceDefaults.firstExtraWebUiPort;
        port <= NapCatInstanceDefaults.lastExtraWebUiPort;
        port++) {
      if (port == ServicePorts.dashboardPort ||
          port == ServicePorts.oneBotWsPort ||
          napCatInstances.any(
              (instance) => _parseInt(instance['webUiPort'], -1) == port)) {
        continue;
      }
      if (await _isPortAvailable(port)) return port;
    }
    throw '没有找到可用的 WebUI 端口';
  }

  int _allocateNapCatDisplay({int? requestedDisplay}) {
    if (requestedDisplay != null) {
      if (requestedDisplay < 2 || requestedDisplay > 99) {
        throw 'DISPLAY 建议填写 2-99';
      }
      if (_isDisplayReserved(requestedDisplay)) {
        throw 'DISPLAY :$requestedDisplay 已被配置占用';
      }
      return requestedDisplay;
    }

    for (var display = NapCatInstanceDefaults.firstExtraDisplay;
        display <= 99;
        display++) {
      if (!_isDisplayReserved(display)) return display;
    }
    throw '没有找到可用的 DISPLAY';
  }

  Future<void> addNapCatInstance({
    int? webUiPort,
    int? display,
  }) async {
    final allocatedPort = await _allocateNapCatWebUiPort(
      requestedPort: webUiPort,
    );
    final allocatedDisplay = _allocateNapCatDisplay(
      requestedDisplay: display,
    );
    final oneBotPort = await _allocateOneBotPort();
    final nextIndex = _nextNapCatAccountIndex();
    final id = 'qq${nextIndex}_${DateTime.now().millisecondsSinceEpoch}';
    final instance = {
      'id': id,
      'name': _defaultNapCatName(nextIndex),
      'qq': '',
      'webUiPort': allocatedPort,
      'display': allocatedDisplay,
      'token': '',
      'autoLogin': false,
      'autoLoginTouched': false,
      'qqAutoDetected': false,
      'boundWebSocketName': NapCatInstanceDefaults.defaultWebSocketClientName,
      'boundAdapterId': '',
      'running': false,
    };
    napCatInstances.add(instance);
    _saveNapCatInstances();
    await _ensureNapCatOneBotConfig(instance, oneBotPort: oneBotPort);
    final client = await selectedNapCatWebSocketClient(instance);
    final adapter =
        client == null ? null : await matchingAstrBotAdapterForClient(client);
    if (adapter != null) {
      _updateNapCatInstance(id, {'boundAdapterId': adapter.id});
    }
  }

  Future<void> removeNapCatInstance(String id) async {
    await logoutNapCatInstance(id);
    napCatInstances.removeWhere((instance) => instance['id'] == id);
    _saveNapCatInstances();
  }

  Future<void> updateNapCatInstanceConfig({
    required String id,
    int? webUiPort,
    String? name,
    String? qq,
  }) async {
    final index = _findInstanceIndex(id);
    if (index < 0) return;

    final current = napCatInstances[index];
    final currentPort = _parseInt(
      current['webUiPort'],
      NapCatInstanceDefaults.firstExtraWebUiPort,
    );
    final nextPort = webUiPort ?? currentPort;

    if (nextPort != currentPort) {
      if (nextPort < NapCatInstanceDefaults.firstExtraWebUiPort ||
          nextPort > NapCatInstanceDefaults.lastExtraWebUiPort) {
        throw 'WebUI 端口必须在 ${NapCatInstanceDefaults.firstExtraWebUiPort}-${NapCatInstanceDefaults.lastExtraWebUiPort} 之间';
      }
      final duplicated = napCatInstances.any(
        (instance) =>
            instance['id'] != id &&
            _parseInt(instance['webUiPort'], -1) == nextPort,
      );
      if (duplicated ||
          nextPort == ServicePorts.dashboardPort ||
          nextPort == ServicePorts.oneBotWsPort) {
        throw 'WebUI 端口 $nextPort 已被配置占用';
      }
      if (!await _isPortAvailable(nextPort)) {
        throw 'WebUI 端口 $nextPort 当前已被系统占用';
      }
    }

    _updateNapCatInstance(id, {
      'webUiPort': nextPort,
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (qq != null) ...{
        'qq': qq.trim(),
        'qqAutoDetected': false,
      },
    });
    final updated =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    if (updated == null) return;
    await _writeNapCatInstanceLauncher(updated);
    await _patchNapCatInstanceWebUiJson(updated);
  }

  Future<void> setNapCatInstanceAutoLogin(String id, bool enabled) async {
    _updateNapCatInstance(id, {
      'autoLogin': enabled,
      'autoLoginTouched': true,
    });
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    if (instance == null) return;
    await _writeNapCatInstanceLauncher(instance);
    await _patchNapCatInstanceWebUiJson(instance);
  }

  // Compatibility shim for legacy settings UI paths. New UI no longer exposes
  // manual QQ quick-login input.
  Future<void> setNapCatInstanceQuickLogin(String id, String qq) async {
    _updateNapCatInstance(id, {
      'qq': qq,
      'autoLogin': qq.isNotEmpty,
      'autoLoginTouched': true,
      'qqAutoDetected': false,
    });
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    if (instance == null) return;
    await _writeNapCatInstanceLauncher(instance);
    await _patchNapCatInstanceWebUiJson(instance);
  }

  Future<void> startNapCatInstance(String id) async {
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    if (instance == null || _napCatInstanceTerminals.containsKey(id)) return;

    final port = _parseInt(instance['webUiPort'], 0);
    if (!await _isPortAvailable(port)) {
      throw 'WebUI 端口 $port 当前已被占用，请换一个端口';
    }

    final terminalName = instance['name']?.toString() ?? id;
    _writeInstanceOutput(
      terminalName,
      '收到启动请求，正在准备 Ubuntu 入口脚本...',
    );
    await _prepareEnvironmentScripts();
    await _ensureNapCatOneBotConfig(instance);
    await _writeNapCatInstanceLauncher(instance);
    await _patchNapCatInstanceWebUiJson(instance);

    _writeInstanceOutput(
      terminalName,
      '启动 NapCat：端口 $port，DISPLAY :${instance['display']}',
    );
    _scheduleNapCatInstanceQqProbe(id, terminalName);
    final pty = createPTY();
    _napCatInstanceTerminals[id] = pty;
    _updateNapCatInstance(id, {'running': true});

    final subscription = pty.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((event) async {
      _writeInstanceOutput(terminalName, event);
      if (event.contains('WebUi Token:')) {
        final match = RegExp(r'WebUi Token:\s+(\w+)').firstMatch(event);
        final token = match?.group(1);
        if (token != null && token.isNotEmpty) {
          _updateNapCatInstance(id, {'token': token});
        }
        _scheduleNapCatInstanceQqProbe(id, terminalName);
      }
      if (event.contains('二维码已保存到')) {
        unawaited(_showNapCatInstanceQrCode(instance));
        _scheduleNapCatInstanceQqProbe(id, terminalName);
      }
      if (_looksLikeNapCatLoginStateEvent(event) || event.contains('配置加载')) {
        _closeNapCatQrDialog(id);
        _scheduleNapCatInstanceQqProbe(id, terminalName);
      }
    }, onDone: () {
      _closeNapCatQrDialog(id);
      _napCatInstanceTerminals.remove(id);
      _napCatInstanceSubscriptions.remove(id);
      _updateNapCatInstance(id, {'running': false});
      _writeInstanceOutput(terminalName, 'NapCat 进程已退出');
    }, onError: (error) {
      _closeNapCatQrDialog(id);
      _writeInstanceOutput(terminalName, '进程输出异常: $error');
      _napCatInstanceTerminals.remove(id);
      _napCatInstanceSubscriptions.remove(id);
      _updateNapCatInstance(id, {'running': false});
    });

    _napCatInstanceSubscriptions[id] = subscription;
    pty.writeString(_napCatInstanceCommand(id));
  }

  bool _looksLikeNapCatLoginStateEvent(String text) {
    final lower = _cleanTerminalLog(text).toLowerCase();
    return lower.contains('login success') ||
        lower.contains('login successful') ||
        lower.contains('已登录') ||
        lower.contains('登录成功') ||
        lower.contains('登陆成功');
  }

  void _scheduleNapCatInstanceQqProbe(
    String id,
    String terminalName,
  ) {
    for (final delay in [
      const Duration(seconds: 3),
      const Duration(seconds: 10),
      const Duration(seconds: 30),
    ]) {
      Future.delayed(delay, () {
        unawaited(_refreshNapCatInstanceQqFromFiles(id, terminalName));
      });
    }
  }

  Future<void> _refreshNapCatInstanceQqFromFiles(
    String id,
    String terminalName,
  ) async {
    if (_napCatInstanceQqProbing.contains(id)) return;
    final index = _findInstanceIndex(id);
    if (index < 0) return;

    final current = napCatInstances[index];
    final existingQq = current['qq']?.toString().trim() ?? '';
    final wasAutoDetected = current['qqAutoDetected'] == true;
    if (existingQq.isNotEmpty && !wasAutoDetected) return;

    _napCatInstanceQqProbing.add(id);
    try {
      final qq = await _detectNapCatInstanceQqFromFiles(id);
      if (qq == null) return;

      final latestIndex = _findInstanceIndex(id);
      if (latestIndex < 0) return;
      final latest = napCatInstances[latestIndex];
      final latestQq = latest['qq']?.toString().trim() ?? '';
      if (latestQq.isNotEmpty && latest['qqAutoDetected'] != true) return;

      _updateNapCatInstance(id, {
        'qq': qq,
        'autoLogin': true,
        'qqAutoDetected': true,
      });
      if (latestQq != qq) {
        _writeInstanceOutput(terminalName, '已从登录配置识别绑定 QQ：$qq');
      }
    } finally {
      _napCatInstanceQqProbing.remove(id);
    }
  }

  Future<String?> _detectNapCatInstanceQqFromFiles(String id) async {
    final configQq = await _readNapCatAutoLoginAccount(id);
    if (_looksLikeQqNumber(configQq)) return configQq;

    final roots = [
      Directory('$ubuntuPath/root/napcat_instances/${id}_home'),
      Directory('$ubuntuPath/root/napcat_instances/${id}_napcat'),
    ];
    for (final root in roots) {
      final qq = await _scanNapCatAccountFiles(root);
      if (_looksLikeQqNumber(qq)) return qq;
    }
    return null;
  }

  Future<String?> _readNapCatAutoLoginAccount(String id) async {
    final file = File(
        '$ubuntuPath/root/napcat_instances/${id}_napcat/config/webui.json');
    if (!await file.exists()) return null;
    try {
      final jsonData = jsonDecode(await file.readAsString());
      if (jsonData is! Map<String, dynamic>) return null;
      return jsonData['autoLoginAccount']?.toString().trim();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _scanNapCatAccountFiles(Directory root) async {
    if (!await root.exists()) return null;

    var scannedFiles = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final name = entity.uri.pathSegments.isEmpty
          ? entity.path
          : entity.uri.pathSegments.last;
      final nameQq = _detectNapCatQqFromPathName(name);
      if (_looksLikeQqNumber(nameQq)) return nameQq;

      if (entity is! File) continue;
      if (scannedFiles >= 120) break;
      if (!_looksLikeAccountConfigFile(entity.path)) continue;

      final stat = await entity.stat();
      if (stat.size > 512 * 1024) continue;
      scannedFiles++;

      try {
        final content = await entity.readAsString();
        final qq = _detectNapCatQqFromConfigText(content);
        if (_looksLikeQqNumber(qq)) return qq;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  String? _detectNapCatQqFromPathName(String name) {
    final exactConfigMatch = RegExp(
      r'^(?:napcat|napcat_protocol|onebot11)_([1-9][0-9]{4,11})\.json$',
      caseSensitive: false,
    ).firstMatch(name);
    if (_looksLikeQqNumber(exactConfigMatch?.group(1))) {
      return exactConfigMatch?.group(1);
    }

    final keyedNameMatch = RegExp(
      r'(?:uin|account|user|qq|napcat|onebot)[_-]?([1-9][0-9]{4,11})',
      caseSensitive: false,
    ).firstMatch(name);
    return keyedNameMatch?.group(1);
  }

  bool _looksLikeAccountConfigFile(String path) {
    final lower = path.toLowerCase().replaceAll('\\', '/');
    if (lower.contains('/logs/') ||
        lower.contains('/log/') ||
        lower.contains('/cache/') ||
        lower.contains('/chat/') ||
        lower.contains('/message/') ||
        lower.contains('/messages/')) {
      return false;
    }
    return lower.endsWith('.json') ||
        lower.endsWith('.dat') ||
        lower.endsWith('.ini') ||
        lower.endsWith('.conf') ||
        lower.endsWith('.config');
  }

  String? _detectNapCatQqFromConfigText(String text) {
    final patterns = [
      RegExp(
        r'"(?:uin|self_uin|selfUin|self_id|selfId|user_id|userId|account|accountUin|qq)"\s*:\s*"?([1-9][0-9]{4,11})"?',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:uin|self_uin|selfUin|self_id|selfId|user_id|userId|account|accountUin|qq)\s*=\s*"?([1-9][0-9]{4,11})"?',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      final qq = match?.group(1);
      if (_looksLikeQqNumber(qq)) return qq;
    }
    return null;
  }

  bool _looksLikeQqNumber(String? value) {
    if (value == null) return false;
    if (!RegExp(r'^[1-9][0-9]{4,11}$').hasMatch(value)) return false;
    final number = int.tryParse(value);
    if (number == null) return false;
    return number >= 10000;
  }

  Future<void> stopNapCatInstance(String id) async {
    _closeNapCatQrDialog(id);
    await _napCatInstanceSubscriptions[id]?.cancel();
    _napCatInstanceSubscriptions.remove(id);
    _napCatInstanceTerminals[id]?.kill();
    _napCatInstanceTerminals.remove(id);
    await _stopNapCatInstanceProcesses(id);
    _updateNapCatInstance(id, {'running': false});
  }

  Future<void> logoutNapCatInstance(String id) async {
    await stopNapCatInstance(id);
    await _deleteNapCatInstanceRuntime(id);
    _updateNapCatInstance(id, {
      'qq': '',
      'token': '',
      'autoLogin': false,
      'autoLoginTouched': false,
      'qqAutoDetected': false,
      'boundWebSocketName': '',
      'boundAdapterId': '',
      'running': false,
    });
  }

  Future<void> deleteNapCatInstance(String id) async {
    await logoutNapCatInstance(id);
    napCatInstances.removeWhere((instance) => instance['id'] == id);
    _saveNapCatInstances();
  }

  Future<void> renameNapCatInstance(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    _updateNapCatInstance(id, {'name': trimmed});
  }

  Future<void> toggleNapCatAutoLogin(String id, bool enabled) async {
    _updateNapCatInstance(id, {
      'autoLogin': enabled,
      'autoLoginTouched': true,
    });
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    if (instance != null) {
      await _patchNapCatInstanceWebUiJson(instance);
    }
  }

  String napCatInstanceWebUiUrl(Map<String, dynamic> instance) {
    final port = _parseInt(
        instance['webUiPort'], NapCatInstanceDefaults.firstExtraWebUiPort);
    final token = instance['token']?.toString() ?? '';
    final baseUrl = 'http://127.0.0.1:$port/webui';
    return token.isEmpty ? baseUrl : '$baseUrl?token=$token';
  }

  void requestOpenNapCatWebUi(String id) {
    final targetId = 'napcat:$id';
    showWebUiTarget(targetId);
    pendingWebUiTargetId.value = targetId;
  }

  void requestOpenAstrBotWebUi() {
    const targetId = 'astrbot';
    showWebUiTarget(targetId);
    pendingWebUiTargetId.value = targetId;
  }

  void hideWebUiTarget(String id) {
    if (!hiddenWebUiTargetIds.contains(id)) {
      hiddenWebUiTargetIds.add(id);
      _saveHiddenWebUiTargetIds();
    }
  }

  void showWebUiTarget(String id) {
    if (hiddenWebUiTargetIds.remove(id)) {
      _saveHiddenWebUiTargetIds();
    }
  }

  void clearPendingWebUiTargetId(String id) {
    if (pendingWebUiTargetId.value == id) {
      pendingWebUiTargetId.value = null;
    }
  }

  String _napCatInstanceCommand(String id) {
    return 'source ${RuntimeEnvir.homePath}/common.sh\n'
        'login_ubuntu "echo [napcat-instance] run /root/launcher_$id.sh; chmod +x /root/launcher_$id.sh; bash /root/launcher_$id.sh"\n';
  }

  String _shellSingleQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  Future<void> _writeNapCatInstanceLauncher(
      Map<String, dynamic> instance) async {
    final id = instance['id'].toString();
    final webUiPort = _parseInt(
      instance['webUiPort'],
      NapCatInstanceDefaults.firstExtraWebUiPort,
    );
    final display = _parseInt(instance['display'], 22);
    final qq = instance['qq']?.toString() ?? '';
    final script = _buildNapCatInstanceLauncher(
      id: id,
      webUiPort: webUiPort,
      display: display,
      qq: qq,
    );
    final file = File('$ubuntuPath/root/launcher_$id.sh');
    await file.writeAsString(_toUnixLineEndings(script));
  }

  String _buildNapCatInstanceLauncher({
    required String id,
    required int webUiPort,
    required int display,
    required String qq,
  }) {
    final quotedId = _shellSingleQuote(id);
    final webUiJson = const JsonEncoder.withIndent('  ').convert({
      'host': '0.0.0.0',
      'port': webUiPort,
      'prefix': '',
      'token': '',
      'loginRate': 3,
      'autoLoginAccount': qq,
    });
    return '''
#!/bin/bash
set -u

BASE_HOME="/root"
INSTANCE_ID=$quotedId
INSTANCE_HOME="\$BASE_HOME/napcat_instances/\${INSTANCE_ID}_home"
INSTANCE_WORKDIR="\$BASE_HOME/napcat_instances/\${INSTANCE_ID}_napcat"
INSTANCE_DISPLAY="$display"
WEBUI_PORT="$webUiPort"

mkdir -p "\$INSTANCE_HOME" "\$INSTANCE_WORKDIR/config" "\$INSTANCE_WORKDIR/logs" "\$INSTANCE_WORKDIR/cache"
mkdir -p "\$INSTANCE_HOME/.config" "\$INSTANCE_HOME/.cache" "\$INSTANCE_HOME/.local/share"

if [ -d "\$BASE_HOME/napcat/config" ]; then
  cp -n "\$BASE_HOME/napcat/config/"*.json "\$INSTANCE_WORKDIR/config/" 2>/dev/null || true
fi

cat > "\$INSTANCE_WORKDIR/config/webui.json" <<'EOF'
$webUiJson
EOF

echo "[napcat-instance] id=\$INSTANCE_ID"
echo "[napcat-instance] DISPLAY=:\$INSTANCE_DISPLAY"
echo "[napcat-instance] NAPCAT_WORKDIR=\$INSTANCE_WORKDIR"
echo "[napcat-instance] WEBUI_PORT=\$WEBUI_PORT"

if [ -f "\$INSTANCE_WORKDIR/xvfb.pid" ]; then
  kill "\$(cat "\$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null || true
fi
pkill -f "Xvfb :\$INSTANCE_DISPLAY" 2>/dev/null || true
rm -f "/tmp/.X\${INSTANCE_DISPLAY}-lock" "/tmp/.X11-unix/X\${INSTANCE_DISPLAY}" 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

Xvfb ":\$INSTANCE_DISPLAY" -screen 0 800x600x16 +extension GLX +render > "\$INSTANCE_WORKDIR/xvfb.log" 2>&1 &
echo "\$!" > "\$INSTANCE_WORKDIR/xvfb.pid"
for i in \$(seq 1 50); do
  if [ -S "/tmp/.X11-unix/X\${INSTANCE_DISPLAY}" ]; then
    break
  fi
  if ! kill -0 "\$(cat "\$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null; then
    echo "[napcat-instance] Xvfb 启动失败"
    cat "\$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done
if [ ! -S "/tmp/.X11-unix/X\${INSTANCE_DISPLAY}" ]; then
  echo "[napcat-instance] Xvfb 未就绪，无法启动 QQ"
  cat "\$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
  exit 1
fi
export DISPLAY=":\$INSTANCE_DISPLAY"
export NAPCAT_WORKDIR="\$INSTANCE_WORKDIR"
export HOME="\$INSTANCE_HOME"
export XDG_CONFIG_HOME="\$INSTANCE_HOME/.config"
export XDG_CACHE_HOME="\$INSTANCE_HOME/.cache"
export XDG_DATA_HOME="\$INSTANCE_HOME/.local/share"

mkdir -p "\$XDG_CONFIG_HOME" "\$XDG_CACHE_HOME" "\$XDG_DATA_HOME"

cd "\$BASE_HOME"
trap "" SIGPIPE
LD_PRELOAD=./libnapcat_launcher.so qq --no-sandbox
''';
  }

  Future<void> _patchNapCatInstanceWebUiJson(
      Map<String, dynamic> instance) async {
    final id = instance['id'].toString();
    final file = File(
        '$ubuntuPath/root/napcat_instances/${id}_napcat/config/webui.json');
    if (!await file.exists()) return;

    try {
      final jsonData = jsonDecode(await file.readAsString());
      if (jsonData is! Map<String, dynamic>) return;
      jsonData['port'] = _parseInt(
        instance['webUiPort'],
        NapCatInstanceDefaults.firstExtraWebUiPort,
      );
      jsonData['autoLoginAccount'] = instance['qq']?.toString() ?? '';
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(jsonData),
      );
    } catch (e) {
      Log.e('同步账号 webui.json 失败: ${file.path}, $e', tag: 'AstrBot-Napcat');
    }
  }

  /// 供 Lua 脚本调用: 在 Ubuntu 容器内执行一条命令并等待结束。
  Future<void> runShellCommand(String command) => _runUbuntuShell(command);

  /// 供 Lua 脚本调用: 某 NapCat 实例是否正在运行 (有活动 Pty)。
  bool isNapCatRunning(String id) => _napCatInstanceTerminals.containsKey(id);

  /// 确保容器脚本就绪 (bin 链接 + rootfs 包 + cmd_config + common.sh 原语)。
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
    await AssetsUtils.copyAssetToPath(
        'assets/cmd_config.json', '${RuntimeEnvir.homePath}/cmd_config.json');
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

  /// 通用 spawn 运行态跟踪 (无 AstrBot/NapCat 语义, 按调用方给的 key)。
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
    final tabId = await terminalTabManager.addCommandTerminalTab(
      title: title,
      command: 'source ${RuntimeEnvir.homePath}/common.sh\n'
          'install_ubuntu\n'
          'copy_config\n'
          'login_ubuntu ${_shellSingleQuote(command)}\n'
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
        'copy_config\n'
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

  Future<void> _stopNapCatInstanceProcesses(String id) async {
    final instance =
        napCatInstances.firstWhereOrNull((item) => item['id'] == id);
    final display = _parseInt(instance?['display'], -1);
    final commands = [
      'if [ -f /root/napcat_instances/${id}_napcat/qq.pid ]; then kill "\$(cat /root/napcat_instances/${id}_napcat/qq.pid)" 2>/dev/null || true; fi',
      'if [ -f /root/napcat_instances/${id}_napcat/xvfb.pid ]; then kill "\$(cat /root/napcat_instances/${id}_napcat/xvfb.pid)" 2>/dev/null || true; fi',
      'pkill -f "launcher_$id.sh" || true',
      'pkill -f "napcat_instances/${id}_napcat" || true',
      'pkill -f "napcat_instances/${id}_home" || true',
      if (display > 0) 'pkill -f "Xvfb :$display" || true',
      'rm -f /root/napcat_instances/${id}_napcat/qq.pid',
      'rm -f /root/napcat_instances/${id}_napcat/xvfb.pid',
    ];
    for (final command in commands) {
      await _runUbuntuShell(command);
    }
  }

  Future<void> _deleteNapCatInstanceRuntime(String id) async {
    await _stopNapCatInstanceProcesses(id);
    final commands = [
      'rm -rf /root/napcat_instances/${id}_napcat',
      'rm -rf /root/napcat_instances/${id}_home',
      'rm -f /root/launcher_$id.sh',
    ];
    for (final command in commands) {
      await _runUbuntuShell(command);
    }
  }

  Future<void> _showNapCatInstanceQrCode(Map<String, dynamic> instance) async {
    final id = instance['id'].toString();
    if (_napCatQrDialogs.containsKey(id)) return;
    final name = instance['name']?.toString() ?? '账号';
    final qrcodePath =
        '$ubuntuPath/root/napcat_instances/${id}_napcat/cache/qrcode.png';
    final qrcodeFile = File(qrcodePath);

    if (!await qrcodeFile.exists()) {
      Get.snackbar(
        '二维码未找到',
        qrcodePath,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 3),
      );
      return;
    }

    final dialogState = _NapCatQrDialogState(
      secondsLeft: _napCatQrExpireSeconds.obs,
    );
    _napCatQrDialogs[id] = dialogState;
    dialogState.timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final next = dialogState.secondsLeft.value - 1;
      if (next <= 0) {
        dialogState.secondsLeft.value = 0;
        _closeNapCatQrDialog(id);
        return;
      }
      dialogState.secondsLeft.value = next;
    });

    await Get.dialog(
      Builder(
        builder: (dialogContext) {
          dialogState.close = () {
            if (Navigator.of(dialogContext).canPop()) {
              Navigator.of(dialogContext).pop();
            }
          };
          return Dialog(
            backgroundColor: Colors.white,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$name QQ 登录',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Image.file(
                    qrcodeFile,
                    width: 220,
                    height: 220,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 8),
                  Obx(
                    () => Text(
                      '二维码将在 ${dialogState.secondsLeft.value} 秒后过期',
                      style: const TextStyle(color: Colors.orange),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'WebUI 端口：${instance['webUiPort']}',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      barrierDismissible: false,
    );
    _disposeNapCatQrDialog(id);
  }

  void _closeNapCatQrDialog(String id) {
    final dialogState = _napCatQrDialogs[id];
    if (dialogState == null || dialogState.closed) return;
    dialogState.closed = true;
    dialogState.close?.call();
    _disposeNapCatQrDialog(id);
  }

  void _disposeNapCatQrDialog(String id) {
    final dialogState = _napCatQrDialogs.remove(id);
    if (dialogState == null) return;
    dialogState.timer?.cancel();
    dialogState.timer = null;
    dialogState.close = null;
  }

  @override
  void onClose() {
    // 清理订阅，避免内存泄漏
    _qrcodeSubscription?.cancel();
    _webviewSubscription?.cancel();
    _qrcodeSubscription = null;
    _webviewSubscription = null;

    // 杀死所有终端进程，释放端口
    try {
      if (pseudoTerminal != null) {
        Log.i('正在关闭主终端进程...', tag: 'AstrBot');
        pseudoTerminal?.kill();
        pseudoTerminal = null;
      }
      if (napcatTerminal != null) {
        Log.i('正在关闭 NapCat 终端进程...', tag: 'AstrBot-Napcat');
        napcatTerminal?.kill();
        napcatTerminal = null;
      }
      for (final subscription in _napCatInstanceSubscriptions.values) {
        subscription.cancel();
      }
      _napCatInstanceSubscriptions.clear();
      for (final id in _napCatQrDialogs.keys.toList()) {
        _closeNapCatQrDialog(id);
      }
      for (final entry in _napCatInstanceTerminals.entries) {
        Log.i('正在关闭账号 NapCat 进程: ${entry.key}', tag: 'AstrBot-Napcat');
        entry.value.kill();
      }
      _napCatInstanceTerminals.clear();
    } catch (e) {
      Log.e('关闭终端进程时出错: $e', tag: 'AstrBot');
    }

    _terminalWriteTimer?.cancel();
    _terminalWriteTimer = null;
    _terminalWriteBuffer = '';

    // 移除生命周期观察者
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
