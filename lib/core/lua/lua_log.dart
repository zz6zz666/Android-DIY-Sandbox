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

  /// 每次有新日志自增, 供 UI 建立响应式依赖。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<LuaLogEntry> get entries => _entries;

  void add(LuaLogLevel level, Object? message) {
    _entries.add(LuaLogEntry(level, '${message ?? ''}'));
    if (_entries.length > _cap) {
      _entries.removeRange(0, _entries.length - _cap);
    }
    revision.value++;
    // 同时回显到 logcat, 方便有线调试。
    if (kDebugMode) {
      debugPrint('[Lua/${_entries.last.levelText}] ${_entries.last.message}');
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
