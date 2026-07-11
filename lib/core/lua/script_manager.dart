import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest, Clipboard, ClipboardData;
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:settings/settings.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/scripts.dart' show ubuntuPath;
import '../../ui/controllers/terminal_controller.dart';
import '../../ui/lua/lua_view.dart';
import 'lua_engine.dart';
import 'lua_prelude.dart';

/// Lua 脚本运行时管理器: 加载/执行脚本, 注册 host 能力, 维护页面与导航注册表。
class ScriptManager {
  ScriptManager._();
  static final ScriptManager instance = ScriptManager._();

  /// 内置默认脚本版本; 每次修改 assets/scripts/ 下任何 .lua 后 +1 以触发重新释放。
  static const String _defaultScriptsVersion = '31';

  final LuaEngine _engine = LuaEngine();
  final Map<String, LuaFunctionRef> _pages = {};
  List<Map<String, dynamic>> _navTabs = [];
  /// 由 Lua 注册的主页顶栏自定义按钮 (渲染在设置按钮左侧, 可多个)。
  List<Map<String, dynamic>> _homeActions = [];
  bool _initialized = false;
  String? lastError;

  /// 反应式状态: Lua 页面通过 state(key,default) 读写; 变化时递增触发所有 LuaPage 重建。
  final RxInt stateRevision = 0.obs;
  final Map<String, dynamic> _luaState = {};

  // 通用网络原语状态: 自增句柄 + 在途 HTTP 取消令牌 + 存活的 WebSocket 连接。
  int _netSeq = 0;
  final Map<int, CancelToken> _httpCancels = {};
  final Map<int, WebSocket> _sockets = {};

  bool get initialized => _initialized;
  List<Map<String, dynamic>> get navTabs => _navTabs;
  List<Map<String, dynamic>> get homeActions => _homeActions;
  List<String> get pageNames => _pages.keys.toList();

  String get scriptsDir => '${RuntimeEnvir.configPath}/scripts';

  Future<void> initialize() async {
    if (_initialized) return;
    _engine.open();
    _registerHandlers();
    await _releaseDefaultScripts();
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
    _pages.clear();
    _navTabs = [];
    _homeActions = [];
    _initialized = false;
    // 重新开一个干净的 lua_State, 避免残留全局
    _engine.close();
    await initialize();
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
  Future<void> reloadWithGuard() async {
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
    _showApplyCountdown();
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
    // 内置默认脚本版本变化时重新释放全部 .lua 文件 (施工期覆盖; 后续可改为仅覆盖未修改文件)
    if (installedVer != _defaultScriptsVersion) {
      try {
        final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
        var copied = 0;
        for (final key in manifest.listAssets()) {
          if (!key.startsWith('assets/scripts/') || !key.endsWith('.lua')) continue;
          final name = key.substring('assets/scripts/'.length);
          final out = File('${dir.path}/$name');
          if (!out.parent.existsSync()) out.parent.createSync(recursive: true);
          final data = await rootBundle.load(key);
          out.writeAsBytesSync(data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes));
          copied++;
        }
        debugPrint('[ScriptManager] 已释放 $copied 个默认脚本 (v$_defaultScriptsVersion)');
      } catch (e) {
        debugPrint('[ScriptManager] 释放脚本失败: $e');
      }
      marker.writeAsStringSync(_defaultScriptsVersion);
    }
  }

  void _loadUserScripts() {
    final main = File('$scriptsDir/main.lua');
    if (main.existsSync()) {
      // 让 require 能从脚本目录加载模块 (agent.lua 等)
      _engine.doString(
        "package.path = '$scriptsDir/?.lua;$scriptsDir/?/init.lua;' .. package.path",
        chunkName: 'package_path',
      );
      // 暴露脚本根目录的绝对路径, 供 Lua 侧构造 game 路径等
      _engine.doString("SCRIPTS = [[$scriptsDir]]", chunkName: 'scripts_dir');
      _engine.doString(main.readAsStringSync(), chunkName: 'main.lua');
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

    e.registerHandler('log', (a) {
      debugPrint('[Lua] ${a.isNotEmpty ? a[0] : ''}');
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

    // 文件系统
    e.registerHandler('read_file', (a) {
      if (a.isEmpty) return null;
      final f = File('${a[0]}');
      return f.existsSync() ? f.readAsStringSync() : null;
    });
    e.registerHandler('write_file', (a) {
      if (a.length < 2) return false;
      File('${a[0]}').writeAsStringSync('${a[1]}');
      return true;
    });
    e.registerHandler('exists', (a) {
      if (a.isEmpty) return false;
      final p = '${a[0]}';
      return File(p).existsSync() || Directory(p).existsSync();
    });
    e.registerHandler('delete_dir', (a) {
      if (a.isEmpty) return false;
      final d = Directory('${a[0]}');
      if (d.existsSync()) d.deleteSync(recursive: true);
      return true;
    });
    e.registerHandler('delete_file', (a) {
      if (a.isEmpty) return false;
      final f = File('${a[0]}');
      if (f.existsSync()) f.deleteSync();
      return true;
    });

    // 容器 / AstrBot 控制
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
      final d = Directory('${a[0]}');
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
        (_) => '/storage/emulated/0/Download/AstrBotBubble');
    e.registerHandler('mkdirs', (a) {
      if (a.isNotEmpty) {
        final d = Directory('${a[0]}');
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
    // 通用能力, 无任何 AstrBot/NapCat 语义; cb(port|nil)
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
    final timeout = (spec['timeout'] as num?)?.toInt();
    final headers = <String, dynamic>{};
    if (spec['headers'] is Map) {
      (spec['headers'] as Map).forEach((k, v) => headers['$k'] = '$v');
    }

    try {
      final dio = Dio(BaseOptions(
        connectTimeout: Duration(seconds: timeout ?? 30),
        receiveTimeout: stream ? null : Duration(seconds: timeout ?? 60),
      ));
      final resp = await dio.request(
        url,
        data: spec['body'],
        cancelToken: token,
        options: Options(
          method: method,
          headers: headers,
          responseType: stream ? ResponseType.stream : ResponseType.plain,
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
