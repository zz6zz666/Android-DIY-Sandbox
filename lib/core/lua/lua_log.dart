import 'dart:io';
import 'package:flutter/foundation.dart';

/// 日志级别。
enum LuaLogLevel { debug, info, warn, error }

class LuaLogEntry {
  LuaLogEntry(this.level, this.message) : time = DateTime.now();
  final LuaLogLevel level;
  final String message;
  final DateTime time;

  String get timeText {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${three(time.millisecond)}';
  }

  String get levelText {
    switch (level) {
      case LuaLogLevel.debug:
        return 'DEBUG';
      case LuaLogLevel.info:
        return 'INFO';
      case LuaLogLevel.warn:
        return 'WARN';
      case LuaLogLevel.error:
        return 'ERROR';
    }
  }
}

/// 全局 Lua 开发日志。纯 Dart, 与脚本状态无关: 即使 main.lua 损坏/缺失也可查看。
/// 汇聚: host.log/warn/error、Lua print()、脚本加载错误、回调运行期错误、host 调用异常。
class LuaLog {
  LuaLog._();
  static final LuaLog instance = LuaLog._();

  static const int _cap = 2000;
  final List<LuaLogEntry> _entries = [];

  /// 文件镜像 (供容器内 opencode `tail` 查看; 路径通常在 scriptsDir/agent/lua.log,
  /// 该目录挂载到容器 /app-lua-runtime)。
  File? _sink;

  /// 绑定日志文件并清空 (每次 App 启动/重载重新开始, 避免无限增长)。
  void attachFile(String path) {
    try {
      final f = File(path);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        '# Lua 运行日志 (host.log/warn/error + print + 加载/运行错误)\n'
        '# 容器内查看: tail -n 200 -f /app-lua-runtime/agent/lua.log\n',
      );
      _sink = f;
    } catch (_) {
      _sink = null;
    }
  }

  void _writeSink(LuaLogEntry e) {
    final s = _sink;
    if (s == null) return;
    try {
      s.writeAsStringSync('${e.timeText} [${e.levelText}] ${e.message}\n',
          mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  /// 每次有新日志自增, 供 UI 建立响应式依赖。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<LuaLogEntry> get entries => _entries;

  void add(LuaLogLevel level, Object? message) {
    final entry = LuaLogEntry(level, '${message ?? ''}');
    _entries.add(entry);
    if (_entries.length > _cap) {
      _entries.removeRange(0, _entries.length - _cap);
    }
    _writeSink(entry);
    revision.value++;
    // 同时回显到 logcat, 方便有线调试。
    if (kDebugMode) {
      debugPrint('[Lua/${entry.levelText}] ${entry.message}');
    }
  }

  void debug(Object? m) => add(LuaLogLevel.debug, m);
  void info(Object? m) => add(LuaLogLevel.info, m);
  void warn(Object? m) => add(LuaLogLevel.warn, m);
  void error(Object? m) => add(LuaLogLevel.error, m);

  void clear() {
    _entries.clear();
    revision.value++;
  }

  /// 导出为纯文本 (供复制/分享)。
  String dump() {
    final sb = StringBuffer();
    for (final e in _entries) {
      sb.writeln('${e.timeText} [${e.levelText}] ${e.message}');
    }
    return sb.toString();
  }
}
