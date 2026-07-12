import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'lua_engine.dart';
import 'lua_log.dart';

/// .love 归档提取缓存: 记录已解压的归档路径, 避免每次重建都解压。
final Map<String, String> _extractedLoves = {};

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

  /// 注册 Dart 原生事件回调 (headless 场景用, 不等 Lua 回调)。
  void setDartHandler(int canvasId, void Function(Object? msg)? handler) {
    final c = _canvases[canvasId];
    if (c != null) c.dartHandler = handler;
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

  /// 若 gamePath 是 .love 归档, 解压到缓存目录并返回解压后的目录路径;
  /// 否则原样返回。缓存避免每次重建都解压。
  static String resolveGamePath(String gamePath, String scriptsDir) {
    if (!gamePath.toLowerCase().endsWith('.love')) return gamePath;
    if (_extractedLoves.containsKey(gamePath)) return _extractedLoves[gamePath]!;

    final archive = File(gamePath);
    if (!archive.existsSync()) {
      LuaLog.instance.warn('love .love 归档不存在: $gamePath');
      return gamePath;
    }
    final cacheDir =
        Directory('${Directory(scriptsDir).parent.path}/save/love_extracted');
    final name = gamePath.split('/').last.replaceAll('.love', '');
    final extractDir = Directory('${cacheDir.path}/$name');
    if (extractDir.existsSync() && File('${extractDir.path}/main.lua').existsSync()) {
      _extractedLoves[gamePath] = extractDir.path;
      return extractDir.path;
    }
    try {
      extractDir.createSync(recursive: true);
      // .love 文件是重命名的 zip, 调用 busybox unzip 解压。
      final result = Process.runSync(
        '/data/data/com.diysandbox.android.debug/files/busybox',
        ['unzip', '-o', archive.absolute.path, '-d', extractDir.absolute.path],
      );
      if (result.exitCode == 0 && File('${extractDir.path}/main.lua').existsSync()) {
        _extractedLoves[gamePath] = extractDir.path;
        LuaLog.instance.info('已解压 .love: $gamePath → ${extractDir.path}');
        return extractDir.path;
      }
    } catch (e) {
      LuaLog.instance.error('解压 .love 失败: $e');
    }
    return gamePath;
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
    if (msg is Map && msg['type'] == 'log') {
      final d = msg['data'];
      LuaLog.instance.info('[love canvas${c.id}] ${d ?? msg}');
    }
    c.dartHandler?.call(msg);
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
  void Function(Object? msg)? dartHandler;
}

/// Headless love2d 音频服务, 不带渲染画布, 由 Dart 层直接管理生命周期。
///
/// 使用方式 (Lua):
/// ```lua
/// host.audio_play("/sdcard/Music/song.mp3", {channel="bgm", loop=true})
/// host.audio_pause()
/// host.audio_resume()
/// host.audio_stop("bgm")
/// host.audio_seek(30)
/// host.audio_set_volume(0.5, "bgm")
/// local s = host.audio_state()  -- {playing, position, duration, channel}
/// local id = host.audio_on_event(function(ch, ty, data) ... end)
/// host.audio_off_event(id)
/// ```
///
/// 架构: headless love 进程 (audio_svc) 通过 LoveBridge TCP 通道收发命令/事件。
/// 文件访问: 共享存储文件 (/sdcard/) 复制到 audio_svc game 目录下的 temp_audio/,
/// HTTP URL 异步下载到同一目录, love.audio.newSource 读相对路径 (PhysFS 沙盒内)。
class LoveAudioManager {
  LoveAudioManager._();
  static final LoveAudioManager instance = LoveAudioManager._();

  static const int audioCanvasId = 7;

  static const _channel = MethodChannel('love_texture_channel');

  // 多监听器: id → callback
  final Map<int, LuaFunctionRef> _listeners = {};
  int _nextListenerId = 1;

  bool _started = false;
  String _scriptsDir = '';

  // 每个 channel 的最后已知状态
  final Map<String, Map<String, dynamic>> _channelStates = {};
  Map<String, dynamic> _lastState = {
    'playing': false,
    'position': 0,
    'duration': 0,
  };

  // 就绪前的命令队列
  final List<_PendingCmd> _pending = [];

  void _onBridgeMessage(Object? msg) {
    if (msg is! Map) return;
    final type = msg['type']?.toString() ?? '';
    final channel = msg['channel']?.toString() ?? 'default';
    if (type == 'state') {
      final s = {
        'playing': msg['playing'] == true,
        'position': (msg['position'] is num) ? (msg['position'] as num).toDouble() : 0.0,
        'duration': (msg['duration'] is num) ? (msg['duration'] as num).toDouble() : 0.0,
      };
      _channelStates[channel] = s;
      if (channel == 'default') _lastState = s;
    }
    // 分发到所有 Lua 监听器
    final dead = <int>[];
    for (final e in _listeners.entries) {
      try {
        e.value.call([channel, type, msg]);
      } catch (_) {
        dead.add(e.key);
      }
    }
    for (final id in dead) {
      _listeners.remove(id)?.dispose();
    }
  }

  int addListener(LuaFunctionRef fn) {
    final id = _nextListenerId++;
    _listeners[id] = fn;
    return id;
  }

  void removeListener(int id) {
    _listeners.remove(id)?.dispose();
  }

  Future<void> ensureStarted(String scriptsDir) async {
    _scriptsDir = scriptsDir;
    if (_started) return;

    // 清理旧的 temp_audio 文件 (保留 < 1h 内的)
    _cleanupOldTempFiles();

    final gamePath = '$scriptsDir/games/audio_svc';
    final bridge = LoveBridge.instance;
    final bridgeArg = bridge.prepare(
      canvasId: audioCanvasId,
      gamePath: gamePath,
      scriptsDir: scriptsDir,
    );

    bridge.setDartHandler(audioCanvasId, _onBridgeMessage);

    try {
      await _channel.invokeMethod('startHeadless', {
        'canvasId': audioCanvasId,
        'path': gamePath,
        'bridge': bridgeArg,
      });
      _started = true;
      LuaLog.instance.info('[LoveAudioManager] headless audio service started (id=$audioCanvasId)');
      // 排空缓存的命令
      for (final cmd in _pending) {
        cmd.execute();
      }
      _pending.clear();
    } catch (e) {
      LuaLog.instance.error('[LoveAudioManager] startHeadless failed: $e');
    }
  }

  // --- public API (对应 prelude host.audio_*) ---

  void play(String path, {String channel = 'default', double volume = 1.0, bool loop = false}) {
    LuaLog.instance.info('[LoveAudioManager] play: path=$path channel=$channel');
    if (!_started) {
      _pending.add(_PendingCmd(() => play(path, channel: channel, volume: volume, loop: loop)));
      return;
    }
    if (path.startsWith('http://') || path.startsWith('https://')) {
      _startHttpPlay(path, channel, volume, loop);
      return;
    }
    final resolved = _resolveStoragePath(path);
    if (resolved == null) {
      _dispatchToListeners(channel, 'error', {'msg': 'Cannot access file', 'path': path});
      return;
    }
    _send('play', {
      'path': resolved,
      'channel': channel,
      'volume': volume,
      'loop': loop,
    });
  }

  void pause(String channel) => _send('pause', {'channel': channel});
  void resume(String channel) => _send('resume', {'channel': channel});
  void stop(String channel) => _send('stop', {'channel': channel});
  void seek(double pos, String channel) => _send('seek', {'channel': channel, 'position': pos});
  void setVolume(double v, String channel) => _send('set_volume', {'channel': channel, 'volume': v});
  void setLoop(bool loop, String channel) => _send('set_loop', {'channel': channel, 'loop': loop});

  Map<String, dynamic> getState(String channel) {
    final s = _channelStates[channel] ?? _lastState;
    return {'channel': channel, 'playing': s['playing'] ?? false, 'position': s['position'] ?? 0, 'duration': s['duration'] ?? 0};
  }

  // --- 文件路径处理 ---

  final Map<String, String> _pathCache = {};

  String? _resolveStoragePath(String path) {
    if (!path.startsWith('/storage/') && !path.startsWith('/sdcard/')) return path;
    if (_pathCache.containsKey(path)) return _pathCache[path];
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final gameDir = '$_scriptsDir/games/audio_svc';
      final cacheDir = Directory('$gameDir/temp_audio');
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final name = path.split('/').last;
      final dest = File('${cacheDir.path}/$name');
      if (!dest.existsSync()) {
        dest.writeAsBytesSync(f.readAsBytesSync());
      }
      final rel = 'temp_audio/$name';
      _pathCache[path] = rel;
      return rel;
    } catch (e) {
      LuaLog.instance.error('[LoveAudioManager] copy file failed: $e');
      return null;
    }
  }

  // --- HTTP 下载 ---

  void _startHttpPlay(String url, String channel, double volume, bool loop) {
    if (_pathCache.containsKey(url)) {
      _send('play', {'path': _pathCache[url]!, 'channel': channel, 'volume': volume, 'loop': loop});
      return;
    }
    _doHttpDownload(url, channel, volume, loop);
  }

  Future<void> _doHttpDownload(String url, String channel, double volume, bool loop) async {
    try {
      final gameDir = '$_scriptsDir/games/audio_svc';
      final cacheDir = Directory('$gameDir/temp_audio');
      if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
      final raw = url.split('?').first.split('/').last;
      final name = raw.isNotEmpty ? raw : 'stream';
      final dest = File('${cacheDir.path}/http_$name');
      final rel = 'temp_audio/http_$name';

      if (dest.existsSync()) {
        _pathCache[url] = rel;
        _send('play', {'path': rel, 'channel': channel, 'volume': volume, 'loop': loop});
        return;
      }

      LuaLog.instance.info('[LoveAudioManager] downloading: $url');
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        if (response.statusCode != 200) {
          _dispatchToListeners(channel, 'error', {'msg': 'HTTP ${response.statusCode}', 'path': url});
          return;
        }
        // 流式写入, 不缓冲到内存
        final sink = dest.openWrite();
        await for (final chunk in response) {
          sink.add(chunk);
        }
        await sink.close();
        _pathCache[url] = rel;
        LuaLog.instance.info('[LoveAudioManager] downloaded -> $rel');
        _send('play', {'path': rel, 'channel': channel, 'volume': volume, 'loop': loop});
      } finally {
        client.close();
      }
    } catch (e) {
      LuaLog.instance.error('[LoveAudioManager] HTTP download failed: $e');
      _dispatchToListeners(channel, 'error', {'msg': 'Download failed: $e', 'path': url});
    }
  }

  // --- 内部 ---

  void _send(String type, Map<String, dynamic> data) {
    if (!_started) {
      _pending.add(_PendingCmd(() => _send(type, data)));
      return;
    }
    LoveBridge.instance.send(audioCanvasId, {'type': type, 'data': data});
  }

  void _dispatchToListeners(String channel, String type, Map<String, dynamic> data) {
    data['channel'] = channel;
    final dead = <int>[];
    for (final e in _listeners.entries) {
      try {
        e.value.call([channel, type, data]);
      } catch (_) {
        dead.add(e.key);
      }
    }
    for (final id in dead) {
      _listeners.remove(id)?.dispose();
    }
  }

  void _cleanupOldTempFiles() {
    try {
      final cacheDir = Directory('$_scriptsDir/games/audio_svc/temp_audio');
      if (!cacheDir.existsSync()) return;
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      for (final entry in cacheDir.listSync()) {
        if (entry is File) {
          try {
            final mod = entry.lastModifiedSync();
            if (mod.isBefore(cutoff)) entry.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  // --- 生命周期 ---

  Future<void> shutdown() async {
    if (!_started) return;
    _started = false;
    for (final fn in _listeners.values) {
      fn.dispose();
    }
    _listeners.clear();
    LoveBridge.instance.setDartHandler(audioCanvasId, null);
    try {
      await _channel.invokeMethod('destroyHeadless', {'canvasId': audioCanvasId});
    } catch (e) {
      LuaLog.instance.warn('[LoveAudioManager] shutdown error: $e');
    }
  }

  String get scriptsDir => _scriptsDir;
}

class _PendingCmd {
  final void Function() execute;
  _PendingCmd(this.execute);
}
