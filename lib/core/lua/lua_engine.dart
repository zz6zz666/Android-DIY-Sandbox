import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'lua_log.dart';
import 'luajit_bindings.dart';

class LuaError implements Exception {
  LuaError(this.message);
  final String message;
  @override
  String toString() => 'LuaError: $message';
}

/// 对 Lua 函数的持久引用 (存于 registry), 可从 Dart 侧回调。
class LuaFunctionRef {
  LuaFunctionRef(this._engine, this.ref);
  final LuaEngine _engine;
  final int ref;
  bool _disposed = false;

  Object? call([List<Object?> args = const []]) {
    if (_disposed) return null;
    return _engine.callRef(ref, args);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _engine.unref(ref);
  }
}

/// Dart 侧 host 处理函数: 收到已编组的参数列表, 返回一个可编组的结果 (可空)。
typedef LuaHostHandler = Object? Function(List<Object?> args);

/// LuaJIT 引擎封装: 管理 lua_State、注册 host 桥、编组 Dart<->Lua 值、执行脚本。
class LuaEngine {
  LuaEngine();

  final LuaJit _lua = LuaJit.instance;
  Pointer<Void> _l = nullptr;
  NativeCallable<LuaCFunctionNative>? _hostCallable;
  final Map<String, LuaHostHandler> _handlers = {};

  /// 为 true 时, 未注册的 host 调用静默返回 nil (不写日志)。
  /// 供隔离调试引擎使用: 只挂少量安全 handler, 其余 UI/注册类调用视作 no-op。
  bool silentUnknown = false;

  bool get isOpen => _l != nullptr;
  Pointer<Void> get state => _l;

  void open() {
    if (isOpen) return;
    _l = _lua.luaLNewState();
    if (_l == nullptr) throw LuaError('luaL_newstate 返回 null');
    _lua.luaLOpenLibs(_l);
    _installHostBridge();
  }

  void close() {
    if (!isOpen) return;
    _lua.luaClose(_l);
    _l = nullptr;
    _hostCallable?.close();
    _hostCallable = null;
    _handlers.clear();
  }

  void registerHandler(String name, LuaHostHandler handler) {
    _handlers[name] = handler;
  }

  void _installHostBridge() {
    _hostCallable =
        NativeCallable<LuaCFunctionNative>.isolateLocal(_dispatch, exceptionalReturn: 0);
    _lua.luaPushCClosure(_l, _hostCallable!.nativeFunction, 0);
    final name = '__host_call'.toNativeUtf8();
    _lua.luaSetGlobal(_l, name);
    malloc.free(name);
  }

  int _dispatch(Pointer<Void> l) {
    try {
      final top = _lua.luaGetTop(l);
      if (top < 1) {
        _lua.luaPushNil(l);
        return 1;
      }
      final name = _lua.luaToDartString(l, 1) ?? '';
      final args = <Object?>[];
      for (var i = 2; i <= top; i++) {
        args.add(readValue(i));
      }
      final handler = _handlers[name];
      if (handler == null) {
        if (!silentUnknown) {
          debugPrint('[Lua] 未注册的 host 调用: $name');
          LuaLog.instance.warn('未注册的 host 调用: $name');
        }
        _lua.luaPushNil(l);
        return 1;
      }
      final result = handler(args);
      pushValue(result);
      return 1;
    } catch (e, st) {
      debugPrint('[Lua] host 调用异常: $e\n$st');
      LuaLog.instance.error('host 调用异常: $e');
      _lua.luaPushNil(l);
      return 1;
    }
  }

  // ---------- 值编组 ----------

  int _absIndex(int idx) {
    if (idx > 0 || idx <= LuaJit.luaRegistryIndex) return idx;
    return _lua.luaGetTop(_l) + idx + 1;
  }

  /// 读取栈上 idx 处的值为 Dart 值 (标量 / Map / List / LuaFunctionRef / null)。
  Object? readValue(int idx) {
    final t = _lua.luaType(_l, idx);
    switch (t) {
      case LuaJit.luaTNil:
        return null;
      case LuaJit.luaTBoolean:
        return _lua.luaToBoolean(_l, idx) != 0;
      case LuaJit.luaTNumber:
        final d = _lua.luaToNumber(_l, idx);
        if (d.isFinite && d == d.truncateToDouble() &&
            d.abs() < 9007199254740992.0) {
          return d.toInt();
        }
        return d;
      case LuaJit.luaTString:
        return _lua.luaToDartString(_l, idx);
      case LuaJit.luaTFunction:
        _lua.luaPushValue(_l, idx);
        final ref = _lua.luaLRef(_l, LuaJit.luaRegistryIndex);
        return LuaFunctionRef(this, ref);
      case LuaJit.luaTTable:
        return _readTable(_absIndex(idx));
      default:
        return _lua.luaToDartString(_l, idx);
    }
  }

  Object? _readTable(int tableAbs) {
    final map = <Object?, Object?>{};
    _lua.luaPushNil(_l); // 首个 key
    while (_lua.luaNext(_l, tableAbs) != 0) {
      // key 在 -2, value 在 -1
      final key = readValue(-2);
      final value = readValue(-1);
      map[key] = value;
      _lua.luaPop(_l, 1); // 弹出 value, 保留 key 供下次迭代
    }
    // 判断是否为连续整数数组
    if (map.isNotEmpty && map.keys.every((k) => k is int)) {
      final keys = map.keys.cast<int>().toList()..sort();
      if (keys.first == 1 && keys.last == keys.length) {
        return [for (final k in keys) map[k]];
      }
    }
    // 统一为 String 键的 Map (便于 Dart 侧访问)
    return map.map((k, v) => MapEntry(k?.toString() ?? '', v));
  }

  /// 将 Dart 值压入栈顶。
  void pushValue(Object? v) {
    if (v == null) {
      _lua.luaPushNil(_l);
    } else if (v is bool) {
      _lua.luaPushBoolean(_l, v ? 1 : 0);
    } else if (v is int) {
      _lua.luaPushInteger(_l, v);
    } else if (v is double) {
      _lua.luaPushNumber(_l, v);
    } else if (v is num) {
      _lua.luaPushNumber(_l, v.toDouble());
    } else if (v is String) {
      final s = v.toNativeUtf8();
      _lua.luaPushString(_l, s);
      malloc.free(s);
    } else if (v is LuaFunctionRef) {
      _lua.luaRawGetI(_l, LuaJit.luaRegistryIndex, v.ref);
    } else if (v is List) {
      _lua.luaCreateTable(_l, v.length, 0);
      final tableAbs = _lua.luaGetTop(_l);
      for (var i = 0; i < v.length; i++) {
        pushValue(v[i]);
        _lua.luaRawSetI(_l, tableAbs, i + 1);
      }
    } else if (v is Map) {
      _lua.luaCreateTable(_l, 0, v.length);
      final tableAbs = _lua.luaGetTop(_l);
      v.forEach((k, val) {
        if (k is String) {
          pushValue(val);
          final key = k.toNativeUtf8();
          _lua.luaSetField(_l, tableAbs, key);
          malloc.free(key);
        } else {
          pushValue(k);
          pushValue(val);
          _lua.luaSetTable(_l, tableAbs);
        }
      });
    } else {
      final s = v.toString().toNativeUtf8();
      _lua.luaPushString(_l, s);
      malloc.free(s);
    }
  }

  /// 调用 registry 中 ref 指向的 Lua 函数。
  Object? callRef(int ref, List<Object?> args) {
    if (!isOpen) return null;
    final top0 = _lua.luaGetTop(_l);
    _lua.luaRawGetI(_l, LuaJit.luaRegistryIndex, ref);
    for (final a in args) {
      pushValue(a);
    }
    final rc = _lua.luaPcall(_l, args.length, 1, 0);
    if (rc != 0) {
      final err = _lua.luaToDartString(_l, -1) ?? '未知错误';
      _lua.luaSetTop(_l, top0);
      debugPrint('[Lua] 回调执行失败: $err');
      LuaLog.instance.error('回调执行失败: $err');
      return null;
    }
    final result = readValue(-1);
    _lua.luaSetTop(_l, top0);
    return result;
  }

  void unref(int ref) {
    if (!isOpen) return;
    _lua.luaLUnref(_l, LuaJit.luaRegistryIndex, ref);
  }

  /// 执行一段 Lua 代码。返回栈顶结果 (编组后的 Dart 值)。
  Object? doString(String code, {String chunkName = 'chunk'}) {
    if (!isOpen) open();
    final codePtr = code.toNativeUtf8();
    try {
      final loadRc = _lua.luaLLoadString(_l, codePtr);
      if (loadRc != 0) {
        final err = _lua.luaToDartString(_l, -1) ?? '未知语法错误';
        _lua.luaPop(_l, 1);
        LuaLog.instance.error('加载失败($chunkName): $err');
        throw LuaError('加载失败($chunkName): $err');
      }
      final top0 = _lua.luaGetTop(_l) - 1; // 减去已压入的 chunk 函数
      final callRc = _lua.luaPcall(_l, 0, 1, 0);
      if (callRc != 0) {
        final err = _lua.luaToDartString(_l, -1) ?? '未知运行错误';
        _lua.luaPop(_l, 1);
        LuaLog.instance.error('运行失败($chunkName): $err');
        throw LuaError('运行失败($chunkName): $err');
      }
      final result = readValue(-1);
      _lua.luaSetTop(_l, top0);
      return result;
    } finally {
      malloc.free(codePtr);
    }
  }

  String? doStringToString(String code, {String chunkName = 'chunk'}) {
    final r = doString(code, chunkName: chunkName);
    return r?.toString();
  }

  /// Phase 0/1 自检: 验证 .so 加载、执行、双向桥、table/函数引用编组。
  static String selfTest() {
    final engine = LuaEngine();
    engine.open();
    final captured = <String>[];
    engine.registerHandler('toast', (args) {
      final msg = args.isNotEmpty ? '${args[0]}' : '';
      captured.add(msg);
      return 'ok:$msg';
    });
    // table 往返 + 函数引用回调
    final ctx = {
      'service': {'running': true, 'port': 8080},
      'items': ['a', 'b', 'c'],
    };
    engine.registerHandler('get_ctx', (_) => ctx);
    final descriptor = engine.doString(
      'local c = __host_call("get_ctx")\n'
      'local t = __host_call("toast", "hi "..tostring(c.service.port))\n'
      'return { tag="card", running=c.service.running, n=#c.items, echo=t }',
      chunkName: 'selftest',
    );
    engine.close();
    return 'descriptor=$descriptor ; toastCaptured=$captured';
  }
}
