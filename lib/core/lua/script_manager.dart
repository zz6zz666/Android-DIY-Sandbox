import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:convert/convert.dart' show hex;
import 'package:crypto/crypto.dart' as crypto;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/dio.dart' as dio show FormData, MultipartFile;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest, Clipboard, ClipboardData, MethodChannel;
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:settings/settings.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/scripts.dart' show ubuntuPath;
import '../../ui/controllers/terminal_controller.dart';
import '../../ui/lua/lua_view.dart';
import 'lua_engine.dart';
import 'love_bridge.dart';
import 'lua_log.dart';
import 'lua_store.dart';
import 'lua_prelude.dart';

/// Lua 脚本运行时管理器: 加载/执行脚本, 注册 host 能力, 维护页面与导航注册表。
class ScriptManager {
  ScriptManager._();
  static final ScriptManager instance = ScriptManager._();

  /// 内置默认脚本版本; 每次修改 assets/scripts/ 下任何 .lua 后 +1 以触发重新释放。
  static const String _defaultScriptsVersion = '6';

  final LuaEngine _engine = LuaEngine();
  final Map<String, LuaFunctionRef> _pages = {};
  List<Map<String, dynamic>> _navTabs = [];
  /// 由 Lua 注册的主页顶栏自定义按钮 (渲染在设置按钮左侧, 可多个)。
  List<Map<String, dynamic>> _homeActions = [];
  /// Agent 入口按钮 (来自受保护的 agent/main.lua, 与用户 main.lua 解耦, 不会被其覆盖)。
  List<Map<String, dynamic>> _agentActions = [];
  bool _initialized = false;
  String? lastError;

  /// 反应式状态: Lua 页面通过 state(key,default) 读写; 变化时递增触发所有 LuaPage 重建。
  final RxInt stateRevision = 0.obs;
  final Map<String, dynamic> _luaState = {};

  /// 按 key 的细粒度响应式值: set 只重绘绑定了该 key 的单个组件 (如流式文本),
  /// 不触发 stateRevision / 整页重建。用于高频更新 (AI 逐字输出、进度等)。
  final Map<String, ValueNotifier<Object?>> _reactives = {};
  ValueNotifier<Object?> reactiveNotifier(String key, [Object? initial]) =>
      _reactives.putIfAbsent(key, () => ValueNotifier<Object?>(initial));

  // 通用网络原语状态: 自增句柄 + 在途 HTTP 取消令牌 + 存活的 WebSocket 连接。
  int _netSeq = 0;
  final Map<int, CancelToken> _httpCancels = {};
  final Map<int, WebSocket> _sockets = {};
  final Map<int, Timer> _intervals = {};

  // 系统通知: 原生通道 + 自增 id (未指定 id 时使用)。
  // 基址取高位, 避开前台保活服务通知 id(1001)等固定 id, 防止互相覆盖。
  static const MethodChannel _notifyChannel = MethodChannel('astr_notify');
  int _notifySeq = 100000;

  // 外部存储 (原生共享存储 /storage/emulated/0 等) 授权状态缓存。
  // 权限在 Flutter 层按需申请: Lua 文件 API 命中外部路径且未授权时自动弹窗,
  // Lua 侧完全无感 (无需调用任何权限 API)。
  bool _extStorageGranted = false;
  bool _extReqInFlight = false;

  // Agent 控制通道: 本机回环 TCP, 供容器内 agent 用 sandbox 工具被动触发脚本重载/隔离运行。
  ServerSocket? _agentCtrl;
  String _agentToken = '';

  // 本地 WebSocket 回声服务器 (127.0.0.1): 让 WS 演示零外网依赖即可自测。
  HttpServer? _wsEcho;
  int? _wsEchoPort;

  bool get initialized => _initialized;
  List<Map<String, dynamic>> get navTabs => _navTabs;
  List<Map<String, dynamic>> get homeActions => _homeActions;
  List<Map<String, dynamic>> get agentActions => _agentActions;
  List<String> get pageNames => _pages.keys.toList();

  String get scriptsDir => '${RuntimeEnvir.configPath}/scripts';

  Future<void> initialize() async {
    if (_initialized) return;
    _engine.open();
    LuaStore.instance.init('${RuntimeEnvir.configPath}/store');
    try {
      LoveBridge.instance.bridgeSource =
          await rootBundle.loadString('assets/love_host.lua');
    } catch (e) {
      debugPrint('[ScriptManager] 载入 love_host.lua 失败: $e');
    }
    _registerHandlers();
    await _releaseDefaultScripts();
    LuaLog.instance.attachFile('$scriptsDir/agent/lua.log');
    unawaited(_refreshExtStoragePerm());
    unawaited(_startAgentControl());
    unawaited(_startWsEcho());
    try {
      _engine.doString(kLuaPrelude, chunkName: 'prelude');
      _loadUserScripts();
      _initialized = true;
    } catch (e) {
      lastError = '$e';
      debugPrint('[ScriptManager] 加载脚本失败: $e');
    }
  }

  /// 热重载: 清空注册表并重新执行磁盘脚本。
  Future<void> reload() async {
    _disposeRuntimeResources();
    _pages.clear();
    _navTabs = [];
    _homeActions = [];
    _agentActions = [];
    _reactives.clear();
    _initialized = false;
    lastError = null;
    // 重新开一个干净的 lua_State, 避免残留全局
    _engine.close();
    await initialize();
  }

  /// 取消上一轮脚本创建的运行时资源 (定时器/网络), 避免重载后旧回调打进已关闭的
  /// lua_State 造成泄漏或崩溃。love 画布是独立进程, 由各自 keepalive/dispose 管理, 不在此列。
  void _disposeRuntimeResources() {
    for (final t in _intervals.values) {
      t.cancel();
    }
    _intervals.clear();
    for (final tok in _httpCancels.values) {
      try {
        tok.cancel('reload');
      } catch (_) {}
    }
    _httpCancels.clear();
    for (final ws in _sockets.values) {
      try {
        ws.close();
      } catch (_) {}
    }
    _sockets.clear();
  }

  String get _snapshotDir => '${RuntimeEnvir.configPath}/scripts_snapshot';

  /// 快照: 将当前 scriptsDir 下所有 .lua 复制到快照目录。
  void _snapshot() {
    final src = Directory(scriptsDir);
    final dst = Directory(_snapshotDir);
    if (dst.existsSync()) dst.deleteSync(recursive: true);
    dst.createSync(recursive: true);
    for (final f in src.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.lua')) {
        final rel = f.path.substring(src.path.length + 1);
        final target = File('${dst.path}/$rel');
        target.parent.createSync(recursive: true);
        f.copySync(target.path);
      }
    }
  }

  /// 从快照目录恢复所有 .lua 到 scriptsDir (覆盖), 再 reload。
  Future<void> _restoreFromSnapshot() async {
    final src = Directory(_snapshotDir);
    final dst = Directory(scriptsDir);
    if (!src.existsSync()) return;
    for (final f in dst.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.lua')) f.deleteSync();
    }
    for (final f in src.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.lua')) {
        final rel = f.path.substring(src.path.length + 1);
        final target = File('${dst.path}/$rel');
        target.parent.createSync(recursive: true);
        f.copySync(target.path);
      }
    }
    await reload();
    stateRevision.value++;
  }

  /// 快照保护式热重载: 重载成功后弹出 15s 倒计时对话框, 允许保留或回退。
  /// 重载中途 Lua 语法错误 → 自动回退快照。
  /// [silent] 为 true 时不弹倒计时确认框, 直接应用 (供 agent sandbox reload 使用):
  /// 仍保留快照/失败自动回退, 只是成功时不打断用户 (agent 入口受保护, 界面改坏可再改)。
  Future<void> reloadWithGuard({bool silent = false}) async {
    final ctx = Get.context;
    if (ctx == null || !ctx.mounted) return;
    _snapshot();
    await reload();
    if (lastError != null) {
      await _restoreFromSnapshot();
      _toast('脚本加载失败, 已自动回退:\n$lastError');
      return;
    }
    stateRevision.value++;
    if (silent) {
      _toast('脚本已重载');
    } else {
      _showApplyCountdown();
    }
  }

  // ==================== 外部存储授权 (Flutter 层, Lua 无感) ====================

  /// 是否为原生外部/共享存储路径 (需 MANAGE_EXTERNAL_STORAGE 权限)。
  /// 应用私有目录 (/data/data/<pkg>/...) 无需任何权限, 直接放行。
  static bool _isExternalPath(String p) =>
      p.startsWith('/storage/') || p.startsWith('/sdcard/');

  Future<void> _refreshExtStoragePerm() async {
    try {
      _extStorageGranted = await Permission.manageExternalStorage.isGranted;
    } catch (_) {}
  }

  /// 录音权限: 未授权时自动弹窗。返回 true 表示已授权。
  Future<bool> _ensureRecordPermission() async {
    try {
      if (await Permission.microphone.isGranted) return true;
      final status = await Permission.microphone.request();
      if (status.isGranted) return true;
      LuaLog.instance.warn('麦克风权限被拒绝, 录音功能不可用');
    } catch (e) {
      LuaLog.instance.error('麦克风权限请求失败: $e');
    }
    return false;
  }

  /// 文件类 host 处理器调用: 目标在外部存储且未授权时, 主动在 Flutter 层弹窗申请
  /// (Lua 无感)。本次调用先返回失败, 用户授权后重试即可成功。返回 true 表示可访问。
  bool _ensureExternalAccess(String p) {
    if (!_isExternalPath(p)) return true;
    if (_extStorageGranted) return true;
    unawaited(_requestExtStorage(p));
    return false;
  }

  Future<void> _requestExtStorage(String p) async {
    if (_extReqInFlight || _extStorageGranted) return;
    _extReqInFlight = true;
    try {
      LuaLog.instance.warn('访问外部存储需授权, 已弹窗申请 (授权后重试): $p');
      var st = await Permission.manageExternalStorage.request();
      if (!st.isGranted) st = await Permission.storage.request();
      _extStorageGranted = st.isGranted;
      if (_extStorageGranted) {
        LuaLog.instance.info('外部存储已授权');
        stateRevision.value++;
      }
    } catch (_) {} finally {
      _extReqInFlight = false;
    }
  }

  // ==================== Agent 控制通道 (回环 TCP, 被动触发重载) ====================

  /// 启动本地 WebSocket 回声服务器 (幂等)。收到任意消息原样回传, 供 WS 演示零外网自测。
  Future<void> _startWsEcho() async {
    if (_wsEcho != null) return;
    try {
      _wsEcho = await HttpServer.bind(InternetAddress.loopbackIPv4, 0, shared: true);
      _wsEchoPort = _wsEcho!.port;
      _wsEcho!.listen((req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          try {
            final ws = await WebSocketTransformer.upgrade(req);
            ws.add('已连接到本地回声服务器 · 发送任意内容将原样返回');
            ws.listen((data) => ws.add(data), onError: (_) {}, cancelOnError: false);
          } catch (_) {}
        } else {
          req.response.statusCode = HttpStatus.upgradeRequired;
          await req.response.close();
        }
      });
    } catch (e) {
      debugPrint('[ScriptManager] 本地 WS 回声启动失败: $e');
    }
  }

  /// 启动本机回环控制通道; 幂等 (跨 reload 只绑定一次)。
  /// 端口/令牌写入 <scriptsDir>/agent/.control, 供容器内 sandbox 工具读取。
  Future<void> _startAgentControl() async {
    if (_agentCtrl != null) return;
    try {
      _agentCtrl =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 47700, shared: true);
    } catch (_) {
      try {
        _agentCtrl = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      } catch (_) {
        return;
      }
    }
    _agentToken =
        List.generate(16, (_) => math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    try {
      final ctrl = File('$scriptsDir/agent/.control');
      ctrl.parent.createSync(recursive: true);
      ctrl.writeAsStringSync('${_agentCtrl!.port}\n$_agentToken\n');
    } catch (e) {
      debugPrint('[ScriptManager] 写入 agent 控制文件失败: $e');
    }
    _agentCtrl!.listen((sock) {
      final buf = StringBuffer();
      sock.listen((d) {
        buf.write(utf8.decode(d, allowMalformed: true));
        final s = buf.toString();
        if (s.contains('\n')) _handleAgentCommand(s.split('\n').first.trim(), sock);
      }, onError: (_) {}, cancelOnError: true);
    }, onError: (_) {});
  }

  /// 在隔离的 Lua 引擎中执行一个脚本文件 (供 agent 快速调试)。
  /// 独立 lua_State: 不污染在运行的 UI (页面/导航/love 进程均不受影响);
  /// 仅挂少量安全只读 + 工具箱 handler, UI/注册/异步类调用视作 no-op。
  /// 捕获 print / host.log|warn|error / toast 输出与加载/运行错误, 汇总返回。
  Future<String> runIsolated(String path) async {
    final f = File(path.startsWith('/') ? path : '$scriptsDir/$path');
    if (!f.existsSync()) return '✗ 文件不存在: ${f.path}\n';
    String code;
    try {
      code = f.readAsStringSync();
    } catch (e) {
      return '✗ 读取失败: $e\n';
    }
    final out = StringBuffer();
    final eng = LuaEngine();
    eng.open();
    eng.silentUnknown = true; // 其余 UI/注册/异步调用静默 no-op

    void cap(String tag, List<Object?> a) =>
        out.writeln('[$tag] ${a.isNotEmpty ? a[0] : ''}');
    eng.registerHandler('toast', (a) { cap('toast', a); return null; });
    eng.registerHandler('log', (a) { cap('log', a); return null; });
    eng.registerHandler('warn', (a) { cap('warn', a); return null; });
    eng.registerHandler('logerror', (a) { cap('error', a); return null; });

    // 安全只读路径 / 文件
    eng.registerHandler('home_path', (_) => RuntimeEnvir.homePath);
    eng.registerHandler('tmp_path', (_) => RuntimeEnvir.tmpPath);
    eng.registerHandler('bin_path', (_) => RuntimeEnvir.binPath);
    eng.registerHandler('ubuntu_path', (_) => ubuntuPath);
    eng.registerHandler('storage_path', (_) => '/storage/emulated/0');
    eng.registerHandler('backup_dir', (_) => '${RuntimeEnvir.configPath}/backups');
    eng.registerHandler('get_setting', (a) =>
        a.isEmpty ? null : a[0].toString().setting.get());
    eng.registerHandler('read_file', (a) {
      if (a.isEmpty) return null;
      try {
        final ff = File('${a[0]}');
        return ff.existsSync() ? ff.readAsStringSync() : null;
      } catch (_) { return null; }
    });
    eng.registerHandler('exists', (a) =>
        a.isNotEmpty && (File('${a[0]}').existsSync() || Directory('${a[0]}').existsSync()));
    eng.registerHandler('list_dir', (a) {
      if (a.isEmpty) return <Object?>[];
      try {
        final d = Directory('${a[0]}');
        if (!d.existsSync()) return <Object?>[];
        return d.listSync().map((x) => {
              'name': x.path.split('/').last,
              'path': x.path,
              'isDir': x is Directory,
            }).toList();
      } catch (_) { return <Object?>[]; }
    });
    // 让 state/reactive 读回默认值, 使脚本逻辑正常跑
    eng.registerHandler('state_get', (a) => a.length > 1 ? a[1] : null);
    eng.registerHandler('reactive_get', (a) => a.length > 1 ? a[1] : null);
    // 工具箱 (编码/哈希/uuid/now_ms/device_info 等纯函数)
    _registerToolkitHandlers(eng,
        (a, i) => (a.length > i && a[i] is LuaFunctionRef) ? a[i] as LuaFunctionRef : null);
    // 覆盖工具箱里的异步/副作用项为 no-op (隔离引擎运行后即关闭)
    eng.registerHandler('interval', (_) => 0);
    eng.registerHandler('clear_interval', (_) => null);
    eng.registerHandler('write_bytes', (_) => false);

    try {
      eng.doString(kLuaPrelude, chunkName: 'prelude');
      eng.doString('SCRIPTS = [[$scriptsDir]]', chunkName: 'scripts_dir');
      eng.doString(
          "package.path = '$scriptsDir/?.lua;$scriptsDir/?/init.lua;' .. package.path",
          chunkName: 'package_path');
      eng.doString(
          "local ok, mod = pcall(require, 'sandbox.audio_player')\n"
          "host.audio_player = ok and mod or nil",
          chunkName: 'audio_player_load');
      // 把 print 重定向到捕获
      eng.doString(
          "function print(...) local t={} for i=1,select('#',...) do t[i]=tostring((select(i,...))) end "
          "__host_call('log', table.concat(t, '\\t')) end",
          chunkName: 'print_redirect');

      final r = eng.doString(code, chunkName: path);
      out.writeln('--- 加载成功 ---');
      // 若返回模块表且含 build, 调用一次以捕获运行期错误
      if (r is Map && r['build'] is LuaFunctionRef) {
        out.writeln('检测到模块 build(), 试运行...');
        (r['build'] as LuaFunctionRef).call([<String, Object?>{}]);
        out.writeln('build() 执行完毕');
      } else if (r != null) {
        out.writeln('返回值: $r');
      }
    } on LuaError catch (e) {
      out.writeln('✗ ${e.message}');
    } catch (e) {
      out.writeln('✗ 异常: $e');
    } finally {
      eng.close();
    }
    return out.toString();
  }

  void _handleAgentCommand(String line, Socket sock) {
    final parts = line.split(RegExp(r'\s+'));
    final cmd = parts.isNotEmpty ? parts[0] : '';
    final tok = parts.length > 1 ? parts[1] : '';
    void reply(String s) {
      try {
        sock.write(s);
        sock.destroy();
      } catch (_) {}
    }
    if (tok != _agentToken || _agentToken.isEmpty) {
      reply('ERR unauthorized\n');
      return;
    }
    switch (cmd) {
      case 'reload':
        LuaLog.instance.info('[agent] 收到重载指令, 应用脚本更新');
        reply('OK reloading\n');
        Future.delayed(
            const Duration(milliseconds: 50), () => reloadWithGuard(silent: true));
        break;
      case 'ping':
        reply('OK pong\n');
        break;
      case 'run':
        // run <token> <path>: 在隔离引擎里跑一个 .lua 文件, 回传输出 (供快速调试)
        final path = parts.length > 2 ? parts.sublist(2).join(' ') : '';
        if (path.isEmpty) {
          reply('ERR run 需要文件路径 (相对脚本根或绝对路径)\n');
          break;
        }
        LuaLog.instance.info('[agent] 隔离运行: $path');
        runIsolated(path).then((r) => reply('OK\n$r'))
            .catchError((e) => reply('ERR $e\n'));
        break;
      default:
        reply('ERR unknown command: $cmd\n');
    }
  }

  /// 导出整个脚本释放目录 (含 .lua / AGENTS.md / 子目录) 为 zip 到系统下载目录。
  /// 返回文件路径 (失败返回 null)。
  Future<String?> exportScriptsZip() async {
    try {
      final dir = Directory(scriptsDir);
      if (!dir.existsSync()) return null;
      final archive = Archive();
      for (final f in dir.listSync(recursive: true)) {
        if (f is File) {
          final rel = f.path.substring(dir.path.length + 1);
          if (rel == '.default_version') continue; // 版本标记不导出
          final bytes = f.readAsBytesSync();
          archive.addFile(ArchiveFile(rel, bytes.length, bytes));
        }
      }
      final zip = ZipEncoder().encode(archive);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-');
      final outDir = Directory('/storage/emulated/0/Download');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);
      final outPath = '${outDir.path}/lua_scripts_$stamp.zip';
      File(outPath).writeAsBytesSync(zip);
      return outPath;
    } catch (e) {
      LuaLog.instance.error('导出脚本失败: $e');
      return null;
    }
  }

  /// 从 zip 覆盖替换整个脚本释放目录, 然后重载。返回是否成功。
  Future<bool> importScriptsZip(String zipPath) async {
    try {
      final bytes = File(zipPath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      final dir = Directory(scriptsDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      for (final f in archive) {
        final outPath = '$scriptsDir/${f.name}';
        if (f.isFile) {
          final out = File(outPath);
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(f.content as List<int>);
        } else {
          Directory(outPath).createSync(recursive: true);
        }
      }
      // 写入当前版本标记, 防止内置释放机制回头覆盖用户导入的内容。
      File('$scriptsDir/.default_version').writeAsStringSync(_defaultScriptsVersion);
      await reload();
      stateRevision.value++;
      return lastError == null;
    } catch (e) {
      LuaLog.instance.error('导入脚本失败: $e');
      return false;
    }
  }

  /// 15s 倒计时对话框: 保留/回退。
  Future<void> _showApplyCountdown() async {
    final ctx = Get.context;
    if (ctx == null || !ctx.mounted) return;
    await Get.dialog<Object?>(
      _CountdownDialog(
        title: '脚本已刷新',
        onKeep: () {
          Directory(_snapshotDir).deleteSync(recursive: true);
        },
        onRollback: () async {
          await _restoreFromSnapshot();
          _toast('已回退到快照');
        },
      ),
      barrierDismissible: false,
    );
  }

  Future<void> _releaseDefaultScripts() async {
    final dir = Directory(scriptsDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final marker = File('${dir.path}/.default_version');
    final installedVer =
        marker.existsSync() ? marker.readAsStringSync().trim() : '';
    // 内置默认脚本版本变化时重新释放全部文件 (含 AGENTS.md 等非 .lua 文档)
    if (installedVer != _defaultScriptsVersion) {
      try {
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        var copied = 0;
        for (final key in manifest.listAssets()) {
          if (!key.startsWith('assets/scripts/')) continue;
          final name = key.substring('assets/scripts/'.length);
          if (name.isEmpty) continue;
          final out = File('${dir.path}/$name');
          if (!out.parent.existsSync()) out.parent.createSync(recursive: true);
          final data = await rootBundle.load(key);
          out.writeAsBytesSync(data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes));
          copied++;
        }
        debugPrint('[ScriptManager] 已释放 $copied 个默认脚本文件 (v$_defaultScriptsVersion)');
      } catch (e) {
        debugPrint('[ScriptManager] 释放脚本失败: $e');
      }
      marker.writeAsStringSync(_defaultScriptsVersion);
    }
  }

  void _loadUserScripts() {
    // 让 require 能从脚本目录加载模块 (agent.lua 等), 并暴露脚本根目录绝对路径。
    _engine.doString(
      "package.path = '$scriptsDir/?.lua;$scriptsDir/?/init.lua;' .. package.path",
      chunkName: 'package_path',
    );
    _engine.doString("SCRIPTS = [[$scriptsDir]]", chunkName: 'scripts_dir');
    // sandbox/audio_player.lua 是可选的多媒体扩展: 用户脚本包可能不含它。
    // 用 pcall 安全加载, 缺失时 host.audio_player = nil, 不影响其余脚本加载。
    _engine.doString(
      "local ok, mod = pcall(require, 'sandbox.audio_player')\n"
      "host.audio_player = ok and mod or nil",
      chunkName: 'audio_player_load',
    );

    // 1) Agent 入口 (受保护, 独立加载): 与用户 main.lua 解耦。
    //    无论用户 main.lua 是否存在/损坏, agent 入口都先行且独立加载,
    //    这样用户随意定制 UI 也不会把 agent 启动入口弄丢。
    final agentMain = File('$scriptsDir/agent/main.lua');
    if (agentMain.existsSync()) {
      try {
        _engine.doString(agentMain.readAsStringSync(), chunkName: 'agent/main.lua');
      } catch (e) {
        debugPrint('[ScriptManager] agent/main.lua 加载失败: $e');
        LuaLog.instance.error('agent 入口加载失败: $e');
      }
    }

    // 2) 用户主脚本 (可自由定制; 崩溃不影响已加载的 agent 入口)。
    final main = File('$scriptsDir/main.lua');
    if (main.existsSync()) {
      try {
        _engine.doString(main.readAsStringSync(), chunkName: 'main.lua');
      } catch (e) {
        lastError = '$e';
        debugPrint('[ScriptManager] main.lua 加载失败: $e');
        LuaLog.instance.error('main.lua 加载失败: $e');
      }
    }
  }

  /// 调用指定页面的 build(ctx) 函数, 返回声明式描述 (Map/List)。
  Object? buildPage(String name, Map<String, dynamic> ctx) {
    final fn = _pages[name];
    if (fn == null) return null;
    return fn.call([ctx]);
  }

  /// 采集当前应用实时状态, 供 Lua build(ctx) 使用。
  Map<String, dynamic> buildCtx() {
    HomeController? hc;
    try {
      hc = Get.find<HomeController>();
    } catch (_) {}
    return {
      // 通用运行态 (spawn key -> bool); 读 spawnRevision 建立反应式依赖
      'running': hc == null
          ? const <String, dynamic>{}
          : (() {
              hc!.spawnRevision.value;
              return Map<String, dynamic>.from(hc!.spawnRunning);
            })(),
    };
  }

  // ==================== host 处理函数 ====================

  void _registerHandlers() {
    final e = _engine;
    LuaFunctionRef? cbOf(List<Object?> a, int i) =>
        a.length > i && a[i] is LuaFunctionRef ? a[i] as LuaFunctionRef : null;
    e.registerHandler('register_page', (a) {
      final name = a.isNotEmpty ? a[0]?.toString() ?? '' : '';
      final fn = a.length > 1 ? a[1] : null;
      if (name.isNotEmpty && fn is LuaFunctionRef) _pages[name] = fn;
      return null;
    });
    e.registerHandler('nav_tabs', (a) {
      final list = a.isNotEmpty ? a[0] : null;
      if (list is List) {
        _navTabs = [
          for (final t in list)
            if (t is Map) Map<String, dynamic>.from(t),
        ];
      }
      // 兜底: 当脚本定义的导航栏不包含"主页"时, 强制将主页插入为第一项,
      // 以保证顶栏的救命按钮(设置等)始终可访问。
      if (_navTabs.isNotEmpty && !_navTabs.any(_isNavHome)) {
        LuaLog.instance.warn('Lua 脚本未定义主页导航项, 已自动插入兜底主页');
        _navTabs.insert(0, {'title': '主页', 'icon': 'home', 'page': 'home'});
      }
      return null;
    });
    // 注册主页顶栏自定义按钮列表 (渲染在设置按钮左侧)。
    // 每项: { icon=, tooltip=, onTap=fn }
    e.registerHandler('register_actions', (a) {
      final list = a.isNotEmpty ? a[0] : null;
      if (list is List) {
        _homeActions = [
          for (final t in list)
            if (t is Map) Map<String, dynamic>.from(t),
        ];
        stateRevision.value++;
      }
      return null;
    });
    // Agent 入口按钮 (来自受保护的 agent/main.lua): 独立于用户 app.actions,
    // 渲染在最左侧, 不会被用户脚本覆盖。
    e.registerHandler('register_agent_actions', (a) {
      final list = a.isNotEmpty ? a[0] : null;
      if (list is List) {
        _agentActions = [
          for (final t in list)
            if (t is Map) Map<String, dynamic>.from(t),
        ];
        stateRevision.value++;
      }
      return null;
    });

    e.registerHandler('log', (a) {
      LuaLog.instance.info(a.isNotEmpty ? a[0] : '');
      return null;
    });
    e.registerHandler('warn', (a) {
      LuaLog.instance.warn(a.isNotEmpty ? a[0] : '');
      return null;
    });
    e.registerHandler('logerror', (a) {
      LuaLog.instance.error(a.isNotEmpty ? a[0] : '');
      return null;
    });
    // love 双向通信: UI → 游戏发消息 / 组件外登记事件回调。
    e.registerHandler('love_send', (a) {
      final id = a.isNotEmpty && a[0] is int ? a[0] as int : 0;
      final msg = a.length > 1 ? a[1] : null;
      LoveBridge.instance.send(id, msg);
      return null;
    });
    e.registerHandler('love_on', (a) {
      final id = a.isNotEmpty && a[0] is int ? a[0] as int : 0;
      LoveBridge.instance.setHandler(id, cbOf(a, 1));
      return null;
    });
    // headless audio: 不带渲染画布的 love 音频服务。
    e.registerHandler('audio_ensure', (a) {
      LoveAudioManager.instance.ensureStarted(scriptsDir);
      return null;
    });
    e.registerHandler('audio_play', (a) {
      final path = a.isNotEmpty ? '${a[0]}' : '';
      final opts = a.length > 1 && a[1] is Map ? a[1] as Map : <String, dynamic>{};
      LoveAudioManager.instance.play(path,
        channel: (opts['channel'] as String?) ?? 'default',
        volume: (opts['volume'] as num?)?.toDouble() ?? 1.0,
        loop: opts['loop'] == true,
      );
      return null;
    });
    e.registerHandler('audio_pause', (a) {
      final channel = a.isNotEmpty ? '${a[0]}' : 'default';
      LoveAudioManager.instance.pause(channel);
      return null;
    });
    e.registerHandler('audio_resume', (a) {
      final channel = a.isNotEmpty ? '${a[0]}' : 'default';
      LoveAudioManager.instance.resume(channel);
      return null;
    });
    e.registerHandler('audio_stop', (a) {
      final channel = a.isNotEmpty ? '${a[0]}' : 'default';
      LoveAudioManager.instance.stop(channel);
      return null;
    });
    e.registerHandler('audio_seek', (a) {
      final pos = a.isNotEmpty ? (a[0] is num ? (a[0] as num).toDouble() : 0.0) : 0.0;
      final channel = a.length > 1 ? '${a[1]}' : 'default';
      LoveAudioManager.instance.seek(pos, channel);
      return null;
    });
    e.registerHandler('audio_set_volume', (a) {
      final v = a.isNotEmpty ? (a[0] is num ? (a[0] as num).toDouble() : 1.0) : 1.0;
      final channel = a.length > 1 ? '${a[1]}' : 'default';
      LoveAudioManager.instance.setVolume(v, channel);
      return null;
    });
    e.registerHandler('audio_set_loop', (a) {
      final loop = a.isNotEmpty && a[0] == true;
      final channel = a.length > 1 ? '${a[1]}' : 'default';
      LoveAudioManager.instance.setLoop(loop, channel);
      return null;
    });
    e.registerHandler('audio_state', (a) {
      final channel = a.isNotEmpty ? '${a[0]}' : 'default';
      return LoveAudioManager.instance.getState(channel);
    });
    e.registerHandler('audio_on_event', (a) {
      final fn = cbOf(a, 0);
      if (fn == null) return -1;
      return LoveAudioManager.instance.addListener(fn);
    });
    e.registerHandler('audio_off_event', (a) {
      final id = a.isNotEmpty && a[0] is int ? a[0] as int : -1;
      LoveAudioManager.instance.removeListener(id);
      return null;
    });
    // 录音 — 同步启动（权限由 love C++ 层内部自动申请）
    e.registerHandler('audio_record_start', (a) {
      final channel = a.isNotEmpty ? '${a[0]}' : 'default';
      final opts = a.length > 1 && a[1] is Map ? a[1] as Map : <String, dynamic>{};
      final rate = (opts['rate'] as int?) ?? 44100;
      final bits = (opts['bits'] as int?) ?? 16;
      final chans = (opts['chans'] as int?) ?? 1;
      debugPrint('[ScriptManager] audio_record_start -> channel=$channel rate=$rate');
      LoveAudioManager.instance.recordStart(channel, rate: rate, bits: bits, chans: chans);
      return null;
    });
    e.registerHandler('audio_record_stop', (a) {
      LoveAudioManager.instance.recordStop(a.isNotEmpty ? '${a[0]}' : 'default');
      return null;
    });
    e.registerHandler('audio_record_pause', (a) {
      LoveAudioManager.instance.recordPause(a.isNotEmpty ? '${a[0]}' : 'default');
      return null;
    });
    e.registerHandler('audio_record_resume', (a) {
      LoveAudioManager.instance.recordResume(a.isNotEmpty ? '${a[0]}' : 'default');
      return null;
    });
    e.registerHandler('audio_record_discard', (a) {
      LoveAudioManager.instance.recordDiscard(a.isNotEmpty ? '${a[0]}' : 'default');
      return null;
    });
    e.registerHandler('audio_record_play', (a) {
      final channel = a.isNotEmpty ? '${a[0]}' : 'default';
      final opts = a.length > 1 && a[1] is Map ? a[1] as Map : <String, dynamic>{};
      LoveAudioManager.instance.recordPlay(channel,
          volume: (opts['volume'] as num?)?.toDouble() ?? 1.0,
          amp: (opts['amp'] as num?)?.toDouble() ?? 16.0);
      return null;
    });
    // 系统媒体会话 (通知栏播放控件)
    e.registerHandler('media_session_init', (a) {
      MediaSessionBridge.instance.init();
      return null;
    });
    e.registerHandler('media_session_update', (a) {
      final opts = a.isNotEmpty && a[0] is Map ? a[0] as Map : <String, dynamic>{};
      MediaSessionBridge.instance.updateMetadata(
        title: opts['title']?.toString(),
        artist: opts['artist']?.toString(),
        album: opts['album']?.toString(),
        duration: (opts['duration'] is num) ? (opts['duration'] as num).toInt() : 0,
      );
      MediaSessionBridge.instance.updatePlaybackState(
        state: opts['state']?.toString() ?? 'playing',
        position: (opts['position'] is num) ? (opts['position'] as num).toInt() : 0,
      );
      return null;
    });
    e.registerHandler('media_session_release', (a) {
      MediaSessionBridge.instance.release();
      return null;
    });
    e.registerHandler('media_session_on_button', (a) {
      final fn = a.isNotEmpty ? a[0] : null;
      MediaSessionBridge.instance.setButtonHandler(fn is LuaFunctionRef ? fn : null);
      return null;
    });
    // 持久化存储 (原生 SQLite 通道)。
    List<Object?> paramsOf(Object? p) {
      if (p is List) return p;
      if (p is Map) return p.values.toList();
      return const [];
    }
    e.registerHandler('store_open', (a) {
      final name = a.isNotEmpty ? '${a[0]}' : 'default';
      try {
        return LuaStore.instance.open(name);
      } catch (err) {
        LuaLog.instance.error('store.open("$name") 失败: $err');
        return null;
      }
    });
    e.registerHandler('store_exec', (a) {
      final h = a.isNotEmpty && a[0] is int ? a[0] as int : -1;
      final sql = a.length > 1 ? '${a[1]}' : '';
      try {
        LuaStore.instance.exec(h, sql);
      } catch (err) {
        LuaLog.instance.error('store.exec 失败: $err\nSQL: $sql');
      }
      return null;
    });
    e.registerHandler('store_query', (a) {
      final h = a.isNotEmpty && a[0] is int ? a[0] as int : -1;
      final sql = a.length > 1 ? '${a[1]}' : '';
      try {
        return LuaStore.instance.query(h, sql, paramsOf(a.length > 2 ? a[2] : null));
      } catch (err) {
        LuaLog.instance.error('store.query 失败: $err\nSQL: $sql');
        return null;
      }
    });
    e.registerHandler('store_run', (a) {
      final h = a.isNotEmpty && a[0] is int ? a[0] as int : -1;
      final sql = a.length > 1 ? '${a[1]}' : '';
      try {
        return LuaStore.instance.run(h, sql, paramsOf(a.length > 2 ? a[2] : null));
      } catch (err) {
        LuaLog.instance.error('store.run 失败: $err\nSQL: $sql');
        return null;
      }
    });
    e.registerHandler('store_close', (a) {
      final h = a.isNotEmpty && a[0] is int ? a[0] as int : -1;
      LuaStore.instance.close(h);
      return null;
    });
    // 系统通知 (原生 NotificationManager, 通道 astr_notify)。
    e.registerHandler('notify', (a) {
      final spec = a.isNotEmpty && a[0] is Map ? a[0] as Map : const {};
      final id = spec['id'] is int ? spec['id'] as int : (++_notifySeq);
      _notifyChannel.invokeMethod('notify', {
        'id': id,
        'title': '${spec['title'] ?? ''}',
        'body': '${spec['body'] ?? spec['text'] ?? ''}',
        if (spec['channel'] != null) 'channel': '${spec['channel']}',
        'ongoing': spec['ongoing'] == true,
      });
      return id;
    });
    e.registerHandler('cancel_notify', (a) {
      final id = a.isNotEmpty && a[0] is int ? a[0] as int : 1;
      _notifyChannel.invokeMethod('cancel', {'id': id});
      return null;
    });
    e.registerHandler('toast', (a) {
      final msg = a.isNotEmpty ? '${a[0]}' : '';
      _toast(msg);
      return null;
    });
    e.registerHandler('confirm', (a) {
      final msg = a.isNotEmpty ? '${a[0]}' : '';
      final cb = a.length > 1 && a[1] is LuaFunctionRef ? a[1] as LuaFunctionRef : null;
      final opts = a.length > 2 && a[2] is Map ? a[2] as Map : const {};
      _confirm(msg, cb, opts);
      return null;
    });
    e.registerHandler('input', (a) {
      final opts = a.isNotEmpty && a[0] is Map ? a[0] as Map : const {};
      final cb = a.length > 1 && a[1] is LuaFunctionRef ? a[1] as LuaFunctionRef : null;
      _input(opts, cb);
      return null;
    });
    e.registerHandler('exit_app', (_) {
      Future.delayed(const Duration(milliseconds: 300), () => exit(0));
      return null;
    });

    // 设置存储
    e.registerHandler('get_setting', (a) {
      if (a.isEmpty) return null;
      return a[0].toString().setting.get();
    });
    e.registerHandler('set_setting', (a) {
      if (a.length < 2) return null;
      a[0].toString().setting.set(a[1]);
      stateRevision.value++;
      return null;
    });

    // 路径
    e.registerHandler('ubuntu_path', (_) => ubuntuPath);
    e.registerHandler('home_path', (_) => RuntimeEnvir.homePath);
    // 原生共享存储根目录 (需要时文件 API 会自动在 Flutter 层弹窗申请权限)。
    e.registerHandler('storage_path', (_) => '/storage/emulated/0');

    // 文件系统 (接受绝对路径; 命中外部存储且未授权时自动弹窗申请, 本次返回失败)
    e.registerHandler('read_file', (a) {
      if (a.isEmpty) return null;
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return null;
      try {
        final f = File(p);
        return f.existsSync() ? f.readAsStringSync() : null;
      } catch (_) {
        return null;
      }
    });
    e.registerHandler('write_file', (a) {
      if (a.length < 2) return false;
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return false;
      try {
        final f = File(p);
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('${a[1]}');
        return true;
      } catch (e) {
        LuaLog.instance.error('write_file 失败: $p ($e)');
        return false;
      }
    });
    e.registerHandler('exists', (a) {
      if (a.isEmpty) return false;
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return false;
      return File(p).existsSync() || Directory(p).existsSync();
    });
    e.registerHandler('delete_dir', (a) {
      if (a.isEmpty) return false;
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return false;
      final d = Directory(p);
      if (d.existsSync()) d.deleteSync(recursive: true);
      return true;
    });
    e.registerHandler('delete_file', (a) {
      if (a.isEmpty) return false;
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return false;
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
      return true;
    });

    // 容器控制
    e.registerHandler('container', (a) {
      if (a.isEmpty) return null;
      final cmd = '${a[0]}';
      final cb = a.length > 1 && a[1] is LuaFunctionRef ? a[1] as LuaFunctionRef : null;
      final hc = _home();
      if (hc != null) {
        hc.runShellCommand(cmd).then((_) => cb?.call());
      }
      return null;
    });
    e.registerHandler('exec', (a) {
      if (a.isEmpty) return null;
      final cmd = '${a[0]}';
      final cb = a.length > 1 && a[1] is LuaFunctionRef ? a[1] as LuaFunctionRef : null;
      final hc = _home();
      if (hc == null) {
        cb?.call([
          {'code': -1, 'output': 'HomeController 未就绪'}
        ]);
        return null;
      }
      hc.runShellCapture(cmd).then((res) => cb?.call([res]));
      return null;
    });

    e.registerHandler('webview_open', (a) {
      final hc = _home();
      if (hc == null || a.isEmpty) return null;
      final url = '${a[0]}';
      final title = a.length > 1 && a[1] != null ? '${a[1]}' : 'WebUI';
      hc.webViewTabManager.openUrl(url, title);
      // 切到脚本中第一个 webview 类型的导航 tab
      final idx = _navTabs.indexWhere(
          (t) => t['page'] is Map && '${(t['page'] as Map)['type']}' == 'webview');
      if (idx >= 0) hc.pendingMainTabIndex.value = idx;
      return null;
    });

    // 反应式状态
    e.registerHandler('state_get', (a) {
      if (a.isEmpty) return null;
      final key = '${a[0]}';
      final def = a.length > 1 ? a[1] : null;
      return _luaState.containsKey(key) ? _luaState[key] : def;
    });
    e.registerHandler('state_set', (a) {
      if (a.isEmpty) return null;
      _luaState['${a[0]}'] = a.length > 1 ? a[1] : null;
      stateRevision.value++;
      return null;
    });
    // 细粒度响应式值 (流式更新): set 不触发整页重建, 仅重绘绑定组件。
    e.registerHandler('reactive_init', (a) {
      if (a.isEmpty) return null;
      reactiveNotifier('${a[0]}', a.length > 1 ? a[1] : null);
      return null;
    });
    e.registerHandler('reactive_get', (a) {
      if (a.isEmpty) return null;
      final n = _reactives['${a[0]}'];
      return n != null ? n.value : (a.length > 1 ? a[1] : null);
    });
    e.registerHandler('reactive_set', (a) {
      if (a.isEmpty) return null;
      reactiveNotifier('${a[0]}').value = a.length > 1 ? a[1] : null;
      return null;
    });

    // 原生: 剪贴板 / 导航 / 外链 / 目录
    e.registerHandler('clipboard_copy', (a) {
      Clipboard.setData(ClipboardData(text: a.isNotEmpty ? '${a[0]}' : ''));
      return null;
    });
    e.registerHandler('clipboard_paste', (a) async {
      final d = await Clipboard.getData('text/plain');
      return d?.text;
    });
    e.registerHandler('nav_go', (a) {
      final idx = a.isNotEmpty ? (a[0] is int ? a[0] as int : int.tryParse('${a[0]}')) : null;
      final hc = _home();
      if (idx != null && hc != null) hc.pendingMainTabIndex.value = idx;
      return null;
    });
    e.registerHandler('open_url', (a) {
      if (a.isEmpty) return null;
      final uri = Uri.tryParse('${a[0]}');
      if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
      return null;
    });
    e.registerHandler('list_dir', (a) {
      if (a.isEmpty) return const [];
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return const [];
      final d = Directory(p);
      if (!d.existsSync()) return const [];
      return [
        for (final ent in d.listSync())
          {
            'name': ent.path.split('/').last,
            'path': ent.path,
            'isDir': ent is Directory,
          }
      ];
    });
    e.registerHandler('bin_path', (_) => RuntimeEnvir.binPath);
    e.registerHandler('tmp_path', (_) => RuntimeEnvir.tmpPath);
    e.registerHandler('backup_dir',
        (_) => '/storage/emulated/0/Download/AndroidDIYSandbox');
    e.registerHandler('mkdirs', (a) {
      if (a.isNotEmpty) {
        final p = '${a[0]}';
        if (!_ensureExternalAccess(p)) return null;
        final d = Directory(p);
        if (!d.existsSync()) d.createSync(recursive: true);
      }
      return null;
    });
    // 宿主层进程执行 (非容器; 如 busybox tar 备份)
    e.registerHandler('host_run', (a) {
      if (a.isEmpty) return null;
      final program = '${a[0]}';
      final args = a.length > 1 && a[1] is List
          ? (a[1] as List).map((e) => '$e').toList()
          : <String>[];
      final cb = cbOf(a, 2);
      Process.run(program, args).then((r) => cb?.call([
            {
              'code': r.exitCode,
              'stdout': '${r.stdout}',
              'stderr': '${r.stderr}',
            }
          ]));
      return null;
    });
    // 原语: 在容器内跑(长)命令, 流式输出到终端 tab, 可选 key 跟踪运行态
    e.registerHandler('spawn', (a) {
      final hc = _home();
      if (hc == null || a.isEmpty) return null;
      final cmd = '${a[0]}';
      final title = a.length > 1 && a[1] != null ? '${a[1]}' : '容器任务';
      final key = a.length > 2 && a[2] != null ? '${a[2]}' : null;
      final cb = cbOf(a, 3);
      hc.spawnContainer(cmd, title: title, key: key, onExit: () {
        stateRevision.value++;
        cb?.call();
      });
      _focusTerminalTab(hc); // spawn 一定输出到终端 → 自动切到终端页 (不依赖脚本硬编码索引)
      return null;
    });
    // 原语: 停止 key 对应的 spawn (关闭其终端 tab)
    e.registerHandler('stop', (a) {
      final hc = _home();
      if (hc == null || a.isEmpty) return null;
      hc.stopSpawn('${a[0]}');
      stateRevision.value++;
      return null;
    });
    // 原语: 在 [start,end] 范围内找一个可绑定的空闲端口 (跳过 exclude 列表)
    // 通用能力, 无特定业务语义; cb(port|nil)
    e.registerHandler('request_reload', (_) {
      // 延迟到当前 Lua 调用返回后再重载, 避免在回调中关闭 lua_State
      Future.delayed(const Duration(milliseconds: 50), reloadWithGuard);
      return null;
    });

    e.registerHandler('free_port', (a) {
      final start = a.isNotEmpty && a[0] is int ? a[0] as int : 1024;
      final end = a.length > 1 && a[1] is int ? a[1] as int : 65535;
      final exclude = <int>{
        if (a.length > 2 && a[2] is List)
          for (final v in a[2] as List)
            if (v is int) v else if (int.tryParse('$v') != null) int.parse('$v')
      };
      final cb = cbOf(a, 3);
      () async {
        for (var p = start; p <= end; p++) {
          if (exclude.contains(p)) continue;
          ServerSocket? s;
          try {
            s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
            await s.close();
            cb?.call([p]);
            return;
          } catch (_) {
          } finally {
            await s?.close();
          }
        }
        cb?.call([null]);
      }();
      return null;
    });
    // 原语: 解压 / 初始化 Ubuntu rootfs
    e.registerHandler('install_rootfs', (a) {
      final hc = _home();
      if (hc == null) return null;
      final cb = cbOf(a, 0);
      hc.installRootfs(onExit: () {
        stateRevision.value++;
        cb?.call();
      });
      return null;
    });

    // 原语: 延时回调 (Lua 无 sleep; 用于轮询/重试等). delay(ms, cb)
    e.registerHandler('delay', (a) {
      final ms = a.isNotEmpty ? (a[0] as num?)?.toInt() ?? 0 : 0;
      final cb = cbOf(a, 1);
      Future.delayed(Duration(milliseconds: ms), () => cb?.call());
      return null;
    });

    // 自定义对话框: 渲染 Lua 组件树, 依赖 stateRevision 重建
    e.registerHandler('dialog', (a) {
      final spec = a.isNotEmpty && a[0] is Map ? a[0] as Map : const {};
      final buildRef = spec['build'];
      final title = spec['title'];
      if (buildRef is! LuaFunctionRef || Get.context == null) return null;
      Get.dialog(
        Obx(() {
          stateRevision.value;
          final desc = buildRef.call();
          final content = LuaRenderer(onAction: () => stateRevision.value++)
              .buildRoot(Get.context!, desc);
          return _styledDialog(
            title: title == null ? null : '$title',
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(child: content),
            ),
            actions: _dialogActions(spec['actions']),
          );
        }),
      );
      return null;
    });
    e.registerHandler('close_dialog', (_) {
      if (Get.isDialogOpen ?? false) Get.back();
      return null;
    });
    // 通用底部动作列表 (与终端更多菜单同款: 抽屉拖动手柄 + 列表)
    e.registerHandler('sheet', (a) {
      final spec = a.isNotEmpty && a[0] is Map ? a[0] as Map : const {};
      final title = spec['title'];
      final items = spec['items'] is List ? spec['items'] as List : const [];
      if (Get.context == null) return null;
      showModalBottomSheet<void>(
        context: Get.context!,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: MediaQuery.withNoTextScaling(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (title != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('$title',
                            style: Theme.of(ctx)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                  for (final it in items)
                    if (it is Map)
                      ListTile(
                        enabled: it['enabled'] != false,
                        leading: luaIconFor(it['icon']) == null
                            ? null
                            : Icon(luaIconFor(it['icon']),
                                color: it['danger'] == true ? Colors.red : null),
                        title: Text('${it['label'] ?? ''}',
                            style: TextStyle(
                                color:
                                    it['danger'] == true ? Colors.red : null)),
                        onTap: it['enabled'] == false
                            ? null
                            : () {
                                Navigator.of(ctx).pop();
                                final fn = it['onTap'];
                                if (fn is LuaFunctionRef) fn.call();
                                stateRevision.value++;
                              },
                      ),
                ],
              ),
            ),
          ),
        ),
      );
      return null;
    });

    // 通用 HTTP/HTTPS 原语: 供任意 Lua 玩具(含 AI 交互)使用, 无任何业务语义。
    // 入参为配置表 { url, method, headers, body, stream, timeout,
    //   on_response=fn(status,headers), on_chunk=fn(text), on_done=fn(res), on_error=fn(err) }
    // 返回自增句柄, 可用于 host.http_cancel(id) 取消。
    e.registerHandler('http', (a) {
      if (a.isEmpty || a[0] is! Map) return null;
      final spec = a[0] as Map;
      final id = ++_netSeq;
      final token = CancelToken();
      _httpCancels[id] = token;
      _httpRequest(id, spec, token);
      return id;
    });
    e.registerHandler('http_cancel', (a) {
      final id = a.isNotEmpty ? (a[0] as num?)?.toInt() : null;
      if (id != null) _httpCancels.remove(id)?.cancel('cancelled');
      return null;
    });

    // 本地 WS 回声服务器地址 (ws://127.0.0.1:port), 未就绪返回 nil。
    e.registerHandler('ws_echo_url', (_) {
      return _wsEchoPort == null ? null : 'ws://127.0.0.1:$_wsEchoPort';
    });

    // 通用 WebSocket 原语: { url, headers, on_open=fn, on_message=fn(data,binary),
    //   on_close=fn(code,reason), on_error=fn(err) }; 返回句柄用于 ws_send / ws_close。
    e.registerHandler('ws_open', (a) {
      if (a.isEmpty || a[0] is! Map) return null;
      final id = ++_netSeq;
      _wsOpen(id, a[0] as Map);
      return id;
    });
    e.registerHandler('ws_send', (a) {
      final id = a.isNotEmpty ? (a[0] as num?)?.toInt() : null;
      final data = a.length > 1 ? a[1] : null;
      final ws = id == null ? null : _sockets[id];
      if (ws == null || data == null) return false;
      try {
        if (data is List) {
          ws.add(data.map((v) => (v as num).toInt() & 0xff).toList());
        } else {
          ws.add('$data');
        }
        return true;
      } catch (_) {
        return false;
      }
    });
    e.registerHandler('ws_close', (a) {
      final id = a.isNotEmpty ? (a[0] as num?)?.toInt() : null;
      final code = a.length > 1 ? (a[1] as num?)?.toInt() : null;
      final reason = a.length > 2 && a[2] != null ? '${a[2]}' : null;
      final ws = id == null ? null : _sockets.remove(id);
      try {
        ws?.close(code, reason);
      } catch (_) {}
      return null;
    });

    _registerToolkitHandlers(e, cbOf);
  }

  // ==================== DIY 沙盒工具箱 (编码/加密/定时/二进制/设备) ====================

  List<int> _bytesOf(Object? v) {
    // 字符串按 UTF-8; List 视为字节数组 (0-255)。
    if (v is List) {
      return [for (final b in v) (b is num ? b.toInt() : int.tryParse('$b') ?? 0) & 0xff];
    }
    return utf8.encode('${v ?? ''}');
  }

  void _registerToolkitHandlers(
      LuaEngine e, LuaFunctionRef? Function(List<Object?>, int) cbOf) {
    // ---- 编码 ----
    e.registerHandler('base64_encode', (a) {
      if (a.isEmpty) return null;
      return base64.encode(_bytesOf(a[0]));
    });
    e.registerHandler('base64_decode', (a) {
      if (a.isEmpty) return null;
      try {
        final bytes = base64.decode('${a[0]}');
        // asBytes=true 返回字节数组; 否则按 UTF-8 文本
        final asBytes = a.length > 1 && a[1] == true;
        return asBytes ? bytes.toList() : utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return null;
      }
    });
    e.registerHandler('hex_encode', (a) {
      if (a.isEmpty) return null;
      return hex.encode(_bytesOf(a[0]));
    });
    e.registerHandler('hex_decode', (a) {
      if (a.isEmpty) return null;
      try {
        final bytes = hex.decode('${a[0]}');
        final asBytes = a.length > 1 && a[1] == true;
        return asBytes ? bytes : utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return null;
      }
    });
    e.registerHandler('url_encode', (a) {
      if (a.isEmpty) return null;
      // component=false 时用 encodeFull (保留 /:?&= 等); 默认 component 编码。
      final component = !(a.length > 1 && a[1] == false);
      return component ? Uri.encodeComponent('${a[0]}') : Uri.encodeFull('${a[0]}');
    });
    e.registerHandler('url_decode', (a) {
      if (a.isEmpty) return null;
      try {
        return Uri.decodeComponent('${a[0]}');
      } catch (_) {
        return null;
      }
    });

    // ---- 哈希 / HMAC (默认 hex 输出; b64=true 输出 base64) ----
    String digestOut(List<int> bytes, bool b64) =>
        b64 ? base64.encode(bytes) : hex.encode(bytes);
    e.registerHandler('hash', (a) {
      // hash(algo, data, b64?) algo: md5|sha1|sha256|sha512
      if (a.length < 2) return null;
      final algo = '${a[0]}'.toLowerCase();
      final data = _bytesOf(a[1]);
      final b64 = a.length > 2 && a[2] == true;
      crypto.Hash? h;
      switch (algo) {
        case 'md5':
          h = crypto.md5;
          break;
        case 'sha1':
          h = crypto.sha1;
          break;
        case 'sha256':
          h = crypto.sha256;
          break;
        case 'sha512':
          h = crypto.sha512;
          break;
      }
      if (h == null) return null;
      return digestOut(h.convert(data).bytes, b64);
    });
    e.registerHandler('hmac', (a) {
      // hmac(algo, key, data, b64?) algo: sha256|sha1|sha512|md5
      if (a.length < 3) return null;
      final algo = '${a[0]}'.toLowerCase();
      final key = _bytesOf(a[1]);
      final data = _bytesOf(a[2]);
      final b64 = a.length > 3 && a[3] == true;
      crypto.Hash? h;
      switch (algo) {
        case 'md5':
          h = crypto.md5;
          break;
        case 'sha1':
          h = crypto.sha1;
          break;
        case 'sha256':
          h = crypto.sha256;
          break;
        case 'sha512':
          h = crypto.sha512;
          break;
      }
      if (h == null) return null;
      return digestOut(crypto.Hmac(h, key).convert(data).bytes, b64);
    });

    // ---- 随机 ----
    final rnd = math.Random.secure();
    e.registerHandler('random_bytes', (a) {
      final n = a.isNotEmpty ? (a[0] as num?)?.toInt() ?? 16 : 16;
      final bytes = List<int>.generate(n.clamp(0, 4096), (_) => rnd.nextInt(256));
      // 默认 hex; b64=true 或 'raw' 可选
      final fmt = a.length > 1 ? '${a[1]}' : 'hex';
      if (fmt == 'b64' || fmt == 'base64') return base64.encode(bytes);
      if (fmt == 'raw' || fmt == 'bytes') return bytes;
      return hex.encode(bytes);
    });
    e.registerHandler('now_ms', (_) => DateTime.now().millisecondsSinceEpoch);
    e.registerHandler('uuid', (_) {
      final b = List<int>.generate(16, (_) => rnd.nextInt(256));
      b[6] = (b[6] & 0x0f) | 0x40; // version 4
      b[8] = (b[8] & 0x3f) | 0x80; // variant
      final h = hex.encode(b);
      return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
          '${h.substring(16, 20)}-${h.substring(20)}';
    });

    // ---- 二进制文件 IO (base64 <-> 文件) ----
    e.registerHandler('write_bytes', (a) {
      // write_bytes(path, base64Str) -> bool
      if (a.length < 2) return false;
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return false;
      try {
        final bytes = base64.decode('${a[1]}');
        final f = File(p);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
        return true;
      } catch (_) {
        return false;
      }
    });
    e.registerHandler('read_bytes', (a) {
      // read_bytes(path) -> base64Str | nil
      if (a.isEmpty) return null;
      final p = '${a[0]}';
      if (!_ensureExternalAccess(p)) return null;
      final f = File(p);
      if (!f.existsSync()) return null;
      try {
        return base64.encode(f.readAsBytesSync());
      } catch (_) {
        return null;
      }
    });

    // ---- 重复定时器 ----
    e.registerHandler('interval', (a) {
      final ms = a.isNotEmpty ? (a[0] as num?)?.toInt() ?? 0 : 0;
      final cb = cbOf(a, 1);
      if (cb == null || ms <= 0) return null;
      final id = ++_netSeq;
      _intervals[id] = Timer.periodic(Duration(milliseconds: ms), (_) => cb.call());
      return id;
    });
    e.registerHandler('clear_interval', (a) {
      final id = a.isNotEmpty ? (a[0] as num?)?.toInt() : null;
      if (id != null) _intervals.remove(id)?.cancel();
      return null;
    });

    // ---- 设备/应用信息 ----
    e.registerHandler('device_info', (_) => _deviceInfo());
  }

  Map<String, dynamic> _asyncDeviceInfo = {};
  bool _asyncDeviceLoaded = false;
  Object? _deviceInfo() {
    final info = <String, dynamic>{
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'locale': Platform.localeName,
      'numberOfProcessors': Platform.numberOfProcessors,
    };
    // 屏幕信息每次现读 (依赖 context, 早期可能不可用)
    final ctx = Get.context;
    if (ctx != null) {
      final mq = MediaQuery.of(ctx);
      info['screenW'] = mq.size.width;
      info['screenH'] = mq.size.height;
      info['dpr'] = mq.devicePixelRatio;
      info['textScale'] = mq.textScaler.scale(1.0);
      info['darkMode'] = mq.platformBrightness == Brightness.dark;
    }
    // 型号/SDK/应用版本: 异步加载, 加载完成后并入 (首次调用触发, 之后即带上)
    info.addAll(_asyncDeviceInfo);
    if (!_asyncDeviceLoaded) {
      _asyncDeviceLoaded = true;
      () async {
        try {
          final pkg = await PackageInfo.fromPlatform();
          _asyncDeviceInfo['appVersion'] = pkg.version;
          _asyncDeviceInfo['buildNumber'] = pkg.buildNumber;
          _asyncDeviceInfo['packageName'] = pkg.packageName;
          if (Platform.isAndroid) {
            final and = await DeviceInfoPlugin().androidInfo;
            _asyncDeviceInfo['model'] = and.model;
            _asyncDeviceInfo['brand'] = and.brand;
            _asyncDeviceInfo['sdkInt'] = and.version.sdkInt;
            _asyncDeviceInfo['device'] = and.device;
          }
        } catch (_) {}
      }();
    }
    return info;
  }

  /// 执行一次 HTTP 请求; 流式时逐块经 on_chunk 回灌, 完成时 on_done 携完整结果。
  Future<void> _httpRequest(int id, Map spec, CancelToken token) async {
    LuaFunctionRef? fn(Object? key) =>
        spec[key] is LuaFunctionRef ? spec[key] as LuaFunctionRef : null;
    final onResponse = fn('on_response');
    final onChunk = fn('on_chunk');
    final onDone = fn('on_done');
    final onError = fn('on_error');

    var released = false;
    void cleanup() {
      if (released) return;
      released = true;
      _httpCancels.remove(id);
      onResponse?.dispose();
      onChunk?.dispose();
      onDone?.dispose();
      onError?.dispose();
    }

    final url = '${spec['url'] ?? ''}';
    final method = '${spec['method'] ?? 'GET'}'.toUpperCase();
    final stream = spec['stream'] == true;
    final responseType = '${spec['response_type'] ?? 'text'}';
    final wantBytes = responseType == 'bytes' || responseType == 'base64';
    final timeout = (spec['timeout'] as num?)?.toInt();
    final headers = <String, dynamic>{};
    if (spec['headers'] is Map) {
      (spec['headers'] as Map).forEach((k, v) => headers['$k'] = '$v');
    }

    // 请求体: form=multipart 表单; body_base64=二进制; 否则 body 原样。
    Object? requestData;
    if (spec['form'] is Map) {
      requestData = _buildFormData(spec['form'] as Map);
    } else if (spec['body_base64'] != null) {
      try {
        requestData = Stream.value(base64.decode('${spec['body_base64']}'));
        headers.putIfAbsent('content-type', () => 'application/octet-stream');
      } catch (_) {
        requestData = null;
      }
    } else {
      requestData = spec['body'];
    }

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: Duration(seconds: timeout ?? 30),
        receiveTimeout: stream ? null : Duration(seconds: timeout ?? 60),
      ));
      final resp = await dio.request(
        url,
        data: requestData,
        cancelToken: token,
        options: Options(
          method: method,
          headers: headers,
          responseType: stream
              ? ResponseType.stream
              : (wantBytes ? ResponseType.bytes : ResponseType.plain),
          validateStatus: (_) => true,
        ),
      );
      final status = resp.statusCode ?? 0;
      final respHeaders = <String, String>{};
      resp.headers.forEach((k, v) => respHeaders[k] = v.join(', '));
      final ok = status >= 200 && status < 300;
      onResponse?.call([status, respHeaders]);

      if (stream) {
        final sb = StringBuffer();
        final rb = resp.data as ResponseBody;
        rb.stream.cast<List<int>>().transform(utf8.decoder).listen(
          (text) {
            sb.write(text);
            onChunk?.call([text]);
          },
          onDone: () {
            onDone?.call([
              {'status': status, 'ok': ok, 'headers': respHeaders, 'body': sb.toString()}
            ]);
            cleanup();
          },
          onError: (Object err) {
            onError?.call(['$err']);
            cleanup();
          },
          cancelOnError: true,
        );
      } else if (wantBytes) {
        final data = resp.data;
        final bytes = data is List<int> ? data : <int>[];
        onDone?.call([
          {
            'status': status,
            'ok': ok,
            'headers': respHeaders,
            // base64 便于 Lua 侧 host.write_bytes 存文件或再解码
            'body': base64.encode(bytes),
            'is_base64': true,
          }
        ]);
        cleanup();
      } else {
        final body = resp.data == null ? '' : '${resp.data}';
        onDone?.call([
          {'status': status, 'ok': ok, 'headers': respHeaders, 'body': body}
        ]);
        cleanup();
      }
    } catch (e) {
      if (!released) {
        final cancelled = e is DioException && CancelToken.isCancel(e);
        onError?.call([cancelled ? 'cancelled' : '$e']);
      }
      cleanup();
    }
  }

  /// 由 Lua 的 form 规格构造 multipart FormData。
  /// form = { fields={ k=v, ... }, files={ { name=, path= | base64=, filename=, content_type= }, ... } }
  dio.FormData _buildFormData(Map form) {
    final fd = dio.FormData();
    final fields = form['fields'];
    if (fields is Map) {
      fields.forEach((k, v) => fd.fields.add(MapEntry('$k', '$v')));
    }
    final files = form['files'];
    if (files is List) {
      for (final f in files) {
        if (f is! Map) continue;
        final name = '${f['name'] ?? 'file'}';
        final filename = f['filename'] == null ? null : '${f['filename']}';
        dio.MultipartFile? mf;
        if (f['path'] != null) {
          final p = '${f['path']}';
          if (File(p).existsSync()) {
            mf = dio.MultipartFile.fromFileSync(p, filename: filename ?? p.split('/').last);
          }
        } else if (f['base64'] != null) {
          try {
            mf = dio.MultipartFile.fromBytes(base64.decode('${f['base64']}'),
                filename: filename ?? 'blob');
          } catch (_) {}
        } else if (f['text'] != null) {
          mf = dio.MultipartFile.fromString('${f['text']}', filename: filename);
        }
        if (mf != null) fd.files.add(MapEntry(name, mf));
      }
    }
    return fd;
  }

  /// 建立 WebSocket 连接; 存活期间可 ws_send / 收到 on_message, 关闭时 on_close。
  Future<void> _wsOpen(int id, Map spec) async {
    LuaFunctionRef? fn(Object? key) =>
        spec[key] is LuaFunctionRef ? spec[key] as LuaFunctionRef : null;
    final onOpen = fn('on_open');
    final onMessage = fn('on_message');
    final onClose = fn('on_close');
    final onError = fn('on_error');

    var released = false;
    void cleanup() {
      if (released) return;
      released = true;
      _sockets.remove(id);
      onOpen?.dispose();
      onMessage?.dispose();
      onClose?.dispose();
      onError?.dispose();
    }

    final url = '${spec['url'] ?? ''}';
    final headers = <String, dynamic>{};
    if (spec['headers'] is Map) {
      (spec['headers'] as Map).forEach((k, v) => headers['$k'] = '$v');
    }

    try {
      final ws = await WebSocket.connect(url, headers: headers);
      _sockets[id] = ws;
      onOpen?.call();
      ws.listen(
        (Object? data) {
          if (data is String) {
            onMessage?.call([data, false]);
          } else if (data is List<int>) {
            onMessage?.call([data, true]);
          }
        },
        onDone: () {
          onClose?.call([ws.closeCode, ws.closeReason]);
          cleanup();
        },
        onError: (Object err) {
          onError?.call(['$err']);
          cleanup();
        },
        cancelOnError: true,
      );
    } catch (e) {
      onError?.call(['$e']);
      cleanup();
    }
  }

  void fireNavReTap(int index) {
    if (index < 0 || index >= _navTabs.length) return;
    final fn = _navTabs[index]['onReTap'];
    if (fn is LuaFunctionRef) {
      fn.call();
      stateRevision.value++;
    }
  }

  HomeController? _home() {
    try {
      return Get.find<HomeController>();
    } catch (_) {
      return null;
    }
  }

  /// 判断导航项是否为 "主页" (与 main_page.dart 中 _isHome 逻辑一致)。
  static bool _isNavHome(Map<String, dynamic> tab) {
    final page = tab['page'];
    if (page is String) return page == 'home';
    if (page is Map) return '${page['type']}' == 'home' || '${page['page']}' == 'home';
    return false;
  }

  /// 切到脚本里第一个「终端」类型的导航页 (供 spawn 自动聚焦, 不依赖硬编码索引)。
  void _focusTerminalTab(HomeController hc) {
    final idx = _navTabs.indexWhere(
        (t) => t['page'] is Map && '${(t['page'] as Map)['type']}' == 'terminal');
    if (idx >= 0) hc.pendingMainTabIndex.value = idx;
  }

  void _toast(String msg) {
    if (Get.context == null) {
      debugPrint('[Lua toast] $msg');
      return;
    }
    Get.rawSnackbar(message: msg, duration: const Duration(seconds: 2));
  }

  /// 统一对话框模板: 所有 host.dialog/confirm/input 共用同一间距与外观,
  /// 保证不同来源的对话框表现一致 (标题/内容/按钮间距固定, Lua 无需关心)。
  Widget _styledDialog({
    String? title,
    required Widget content,
    required List<Widget> actions,
  }) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      title: title == null ? null : Text('$title'),
      content: content,
      actions: actions,
    );
  }

  /// 由 Lua 的 actions 规格构造对话框按钮; 为空则默认单个"关闭"。
  /// 每项: { label=, onTap=fn, variant="text|filled|tonal|outlined", danger=bool, close=bool }
  List<Widget> _dialogActions(Object? spec) {
    if (spec is! List || spec.isEmpty) {
      return [TextButton(onPressed: () => Get.back(), child: const Text('关闭'))];
    }
    final ctx = Get.context;
    final out = <Widget>[];
    for (final it in spec) {
      if (it is! Map) continue;
      final label = '${it['label'] ?? ''}';
      final danger = it['danger'] == true;
      final variant = '${it['variant'] ?? 'text'}';
      final onTap = it['onTap'];
      void handle() {
        if (it['close'] != false) {
          if (Get.isDialogOpen ?? false) Get.back();
        }
        if (onTap is LuaFunctionRef) {
          onTap.call();
          stateRevision.value++;
        }
      }

      final dangerColor = ctx != null ? Theme.of(ctx).colorScheme.error : Colors.red;
      switch (variant) {
        case 'filled':
          out.add(FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: dangerColor) : null,
            onPressed: handle,
            child: Text(label),
          ));
          break;
        case 'tonal':
          out.add(FilledButton.tonal(onPressed: handle, child: Text(label)));
          break;
        case 'outlined':
          out.add(OutlinedButton(onPressed: handle, child: Text(label)));
          break;
        default:
          out.add(TextButton(
            style: danger ? TextButton.styleFrom(foregroundColor: dangerColor) : null,
            onPressed: handle,
            child: Text(label),
          ));
      }
    }
    return out;
  }

  Future<void> _confirm(String msg, LuaFunctionRef? cb, [Map opts = const {}]) async {
    if (Get.context == null) {
      cb?.call([false]);
      cb?.dispose();
      return;
    }
    final ok = await Get.dialog<bool>(
      _styledDialog(
        title: opts['title'] == null ? null : '${opts['title']}',
        content: Text(msg),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: false),
              child: Text('${opts['cancel_text'] ?? '取消'}')),
          TextButton(
              onPressed: () => Get.back(result: true),
              child: Text('${opts['ok_text'] ?? '确定'}')),
        ],
      ),
    );
    cb?.call([ok ?? false]);
    cb?.dispose();
    stateRevision.value++; // 对话框回调里可能改了 state/DB, 触发整页重建刷新
  }

  Future<void> _input(Map opts, LuaFunctionRef? cb) async {
    if (Get.context == null) {
      cb?.call([null]);
      cb?.dispose();
      return;
    }
    final controller = TextEditingController(text: '${opts['default'] ?? ''}');
    final result = await Get.dialog<String?>(
      _styledDialog(
        title: '${opts['title'] ?? '输入'}',
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: '${opts['hint'] ?? ''}'),
        ),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: null),
              child: Text('${opts['cancel_text'] ?? '取消'}')),
          TextButton(
              onPressed: () => Get.back(result: controller.text),
              child: Text('${opts['ok_text'] ?? '确定'}')),
        ],
      ),
    );
    Future.delayed(const Duration(seconds: 1), controller.dispose);
    cb?.call([result]);
    cb?.dispose();
    stateRevision.value++; // 输入回调里可能改了 state/DB, 触发整页重建刷新
  }
}

/// 15s 倒计时对话框: 保留/回退 脚本修改。
class _CountdownDialog extends StatefulWidget {
  final String title;
  final VoidCallback onKeep;
  final VoidCallback onRollback;
  const _CountdownDialog({
    required this.title,
    required this.onKeep,
    required this.onRollback,
  });

  @override
  State<_CountdownDialog> createState() => _CountdownDialogState();
}

class _CountdownDialogState extends State<_CountdownDialog> {
  int _seconds = 15;
  late final Timer _timer;
  bool _resolved = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_resolved) return;
      setState(() {
        _seconds--;
        if (_seconds <= 0) {
          _resolved = true;
          _timer.cancel();
          widget.onRollback();
          _close();
        }
      });
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  void _resolve(VoidCallback action) {
    if (_resolved) return;
    _resolved = true;
    _timer.cancel();
    action();
    _close();
  }

  void _close() {
    if (Get.isDialogOpen ?? false) Get.back();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Text('${_seconds}s 后自动回退。请确认脚本正常工作后点击"保留更改"。'),
      actions: [
        TextButton(
          onPressed: _resolved ? null : () => _resolve(widget.onRollback),
          child: const Text('回退'),
        ),
        TextButton(
          onPressed: _resolved ? null : () => _resolve(widget.onKeep),
          child: const Text('保留更改'),
        ),
      ],
    );
  }
}
