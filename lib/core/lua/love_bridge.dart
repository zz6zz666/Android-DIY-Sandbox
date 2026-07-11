import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'lua_engine.dart';
import 'lua_log.dart';

/// 单个 love 画布(canvasId)与其游戏进程之间的双向消息通道。
///
/// 传输:本机回环 TCP。app 侧为服务端(每个 canvasId 监听 127.0.0.1:47600+id),
/// 游戏侧(love_host.lua)为客户端主动连接。消息为按行分隔的 JSON。
/// 首行必须是 {"__hello":"<token>"} 做鉴权,防止本机其它程序乱连。
class LoveBridge {
  LoveBridge._();
  static final LoveBridge instance = LoveBridge._();

  static const int _basePort = 47600;
  final Map<int, _Canvas> _canvases = {};
  final Random _rng = Random.secure();

  int portOf(int canvasId) => _basePort + canvasId;

  /// 为某画布准备通道:登记事件回调、确保服务端已监听、把 love_host.lua 放进游戏目录。
  /// 返回要注入给 love 的参数串 (`--astrbridge=PORT:TOKEN`)。同步返回(服务端异步绑定)。
  String prepare({
    required int canvasId,
    LuaFunctionRef? onEvent,
    String? gamePath,
    required String scriptsDir,
    bool freeze = false,
  }) {
    final c = _canvases.putIfAbsent(canvasId, () {
      final nc = _Canvas(canvasId, _randomToken());
      _bind(nc);
      return nc;
    });
    c.onEvent = onEvent;
    if (gamePath != null) _dropBridgeModule(gamePath, scriptsDir);
    // 第三段 freeze 标志: 1=挂起时冻结游戏时钟(回来从快照继续), 0=按真实时间推进。
    return '--astrbridge=${portOf(canvasId)}:${c.token}:${freeze ? 1 : 0}';
  }

  /// 更新某画布的事件回调(love{} 重建时调用)。
  void setHandler(int canvasId, LuaFunctionRef? onEvent) {
    final c = _canvases[canvasId];
    if (c != null) c.onEvent = onEvent;
  }

  /// app → 游戏:发送一条消息(Map)。游戏未连接时静默丢弃。
  void send(int canvasId, Object? msg) {
    final c = _canvases[canvasId];
    if (c == null || c.client == null) return;
    try {
      c.client!.write('${jsonEncode(msg)}\n');
    } catch (e) {
      LuaLog.instance.warn('love_send 失败(id=$canvasId): $e');
    }
  }

  String _randomToken() {
    final b = List<int>.generate(8, (_) => _rng.nextInt(256));
    return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _bind(_Canvas c) async {
    try {
      c.server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        portOf(c.id),
        shared: true,
      );
      c.server!.listen((socket) => _onClient(c, socket),
          onError: (e) => LuaLog.instance.warn('love bridge server 错误(id=${c.id}): $e'));
      debugPrint('[LoveBridge] listening 127.0.0.1:${portOf(c.id)} (canvas ${c.id})');
    } catch (e) {
      LuaLog.instance.error('love bridge 绑定端口失败(id=${c.id}): $e');
    }
  }

  void _onClient(_Canvas c, Socket socket) {
    // 新连接取代旧连接。
    c.client?.destroy();
    c.client = socket;
    c.helloOk = false;
    c.buffer = '';
    socket.setOption(SocketOption.tcpNoDelay, true);
    socket.listen(
      (data) => _onData(c, data),
      onError: (_) => _dropClient(c, socket),
      onDone: () => _dropClient(c, socket),
      cancelOnError: true,
    );
  }

  void _dropClient(_Canvas c, Socket socket) {
    if (identical(c.client, socket)) {
      c.client = null;
      c.helloOk = false;
      c.buffer = '';
    }
    try {
      socket.destroy();
    } catch (_) {}
  }

  void _onData(_Canvas c, List<int> data) {
    c.buffer += utf8.decode(data, allowMalformed: true);
    while (true) {
      final nl = c.buffer.indexOf('\n');
      if (nl < 0) break;
      final line = c.buffer.substring(0, nl);
      c.buffer = c.buffer.substring(nl + 1);
      if (line.isEmpty) continue;
      Object? msg;
      try {
        msg = jsonDecode(line);
      } catch (_) {
        continue;
      }
      if (!c.helloOk) {
        if (msg is Map && msg['__hello'] == c.token) {
          c.helloOk = true;
        } else {
          LuaLog.instance.warn('love bridge 握手失败(id=${c.id}), 断开');
          _dropClient(c, c.client!);
          return;
        }
        continue;
      }
      _deliver(c, msg);
    }
  }

  void _deliver(_Canvas c, Object? msg) {
    final cb = c.onEvent;
    if (cb == null) return;
    try {
      cb.call([msg]);
    } catch (e) {
      LuaLog.instance.error('love onEvent 回调异常(id=${c.id}): $e');
    }
  }

  final Set<String> _dropped = {};

  /// 通信桥游戏侧源码 (love_host.lua)。由 ScriptManager 在初始化时从 asset 载入一次。
  /// 它对用户完全不可见: 写入 love 的 save 目录 (而非用户可见的脚本/游戏目录),
  /// love 的 require 会在 save 目录搜到它, 游戏 `require("love_host")` 即可用。
  String? bridgeSource;

  void _dropBridgeModule(String gamePath, String scriptsDir) {
    try {
      final src = bridgeSource;
      if (src == null || src.isEmpty) return;
      // love 无 conf.lua 时, identity 默认取游戏目录名; save 目录为
      // <configRoot>/save/love/<identity>。configRoot 为 scriptsDir 的上级 (files 目录)。
      final identity = gamePath.split('/').where((s) => s.isNotEmpty).last;
      final configRoot = Directory(scriptsDir).parent.path;
      final saveDir = Directory('$configRoot/save/love/$identity');
      if (_dropped.contains(identity) &&
          File('${saveDir.path}/love_host.lua').existsSync()) {
        return;
      }
      saveDir.createSync(recursive: true);
      File('${saveDir.path}/love_host.lua').writeAsStringSync(src);
      _dropped.add(identity);
    } catch (e) {
      LuaLog.instance.warn('注入 love_host.lua 失败: $e');
    }
  }
}

class _Canvas {
  _Canvas(this.id, this.token);
  final int id;
  final String token;
  ServerSocket? server;
  Socket? client;
  bool helloOk = false;
  String buffer = '';
  LuaFunctionRef? onEvent;
}
