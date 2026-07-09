import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// LuaJIT (Lua 5.1 ABI) 原始 FFI 绑定。
/// 只绑定运行时+桥接所需的最小 C API 子集。
class LuaJit {
  LuaJit._(this._lib) {
    _bind();
  }

  final DynamicLibrary _lib;

  static LuaJit? _instance;
  static LuaJit get instance => _instance ??= LuaJit._(_open());

  static DynamicLibrary _open() {
    // Android: jniLibs/arm64-v8a/libluajit.so 会被解压到 nativeLibraryDir
    return DynamicLibrary.open('libluajit.so');
  }

  // ---- Lua 5.1 常量 ----
  static const int luaGlobalsIndex = -10002;
  static const int luaRegistryIndex = -10000;
  static const int luaMultRet = -1;
  static const int luaRefNil = -1;
  static const int luaNoRef = -2;

  static const int luaTNil = 0;
  static const int luaTBoolean = 1;
  static const int luaTLightUserData = 2;
  static const int luaTNumber = 3;
  static const int luaTString = 4;
  static const int luaTTable = 5;
  static const int luaTFunction = 6;

  // ---- 函数指针 ----
  late final Pointer<Void> Function() luaLNewState;
  late final void Function(Pointer<Void>) luaLOpenLibs;
  late final void Function(Pointer<Void>) luaClose;
  late final int Function(Pointer<Void>, Pointer<Utf8>) luaLLoadString;
  late final int Function(Pointer<Void>, int, int, int) luaPcall;

  late final int Function(Pointer<Void>) luaGetTop;
  late final void Function(Pointer<Void>, int) luaSetTop;
  late final int Function(Pointer<Void>, int) luaType;

  late final void Function(Pointer<Void>, double) luaPushNumber;
  late final void Function(Pointer<Void>, int) luaPushInteger;
  late final void Function(Pointer<Void>, Pointer<Utf8>) luaPushString;
  late final void Function(Pointer<Void>, int) luaPushBoolean;
  late final void Function(Pointer<Void>) luaPushNil;
  late final void Function(Pointer<Void>, Pointer<NativeFunction<LuaCFunctionNative>>, int) luaPushCClosure;

  late final Pointer<Utf8> Function(Pointer<Void>, int, Pointer<Size>) luaToLString;
  late final double Function(Pointer<Void>, int) luaToNumber;
  late final int Function(Pointer<Void>, int) luaToBoolean;

  late final void Function(Pointer<Void>, int, Pointer<Utf8>) luaSetField;
  late final void Function(Pointer<Void>, int, Pointer<Utf8>) luaGetField;
  late final void Function(Pointer<Void>, int, int) luaCreateTable;
  late final void Function(Pointer<Void>, int) luaGetTable;
  late final void Function(Pointer<Void>, int) luaSetTable;
  late final void Function(Pointer<Void>, int, int) luaRawGetI;
  late final void Function(Pointer<Void>, int, int) luaRawSetI;
  late final int Function(Pointer<Void>, int) luaObjLen;
  late final void Function(Pointer<Void>, int) luaPushValue;
  late final int Function(Pointer<Void>, int) luaNext;
  late final int Function(Pointer<Void>, int) luaLRef;
  late final void Function(Pointer<Void>, int, int) luaLUnref;

  void _bind() {
    luaLNewState = _lib
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('luaL_newstate');
    luaLOpenLibs = _lib
        .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('luaL_openlibs');
    luaClose = _lib
        .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('lua_close');
    luaLLoadString = _lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>),
        int Function(Pointer<Void>, Pointer<Utf8>)>('luaL_loadstring');
    luaPcall = _lib.lookupFunction<Int32 Function(Pointer<Void>, Int32, Int32, Int32),
        int Function(Pointer<Void>, int, int, int)>('lua_pcall');

    luaGetTop = _lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('lua_gettop');
    luaSetTop = _lib.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>('lua_settop');
    luaType = _lib.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('lua_type');

    luaPushNumber = _lib.lookupFunction<Void Function(Pointer<Void>, Double),
        void Function(Pointer<Void>, double)>('lua_pushnumber');
    luaPushInteger = _lib.lookupFunction<Void Function(Pointer<Void>, IntPtr),
        void Function(Pointer<Void>, int)>('lua_pushinteger');
    luaPushString = _lib.lookupFunction<Void Function(Pointer<Void>, Pointer<Utf8>),
        void Function(Pointer<Void>, Pointer<Utf8>)>('lua_pushstring');
    luaPushBoolean = _lib.lookupFunction<Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)>('lua_pushboolean');
    luaPushNil = _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('lua_pushnil');
    luaPushCClosure = _lib.lookupFunction<
        Void Function(Pointer<Void>, Pointer<NativeFunction<LuaCFunctionNative>>, Int32),
        void Function(Pointer<Void>, Pointer<NativeFunction<LuaCFunctionNative>>, int)>('lua_pushcclosure');

    luaToLString = _lib.lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>, Int32, Pointer<Size>),
        Pointer<Utf8> Function(Pointer<Void>, int, Pointer<Size>)>('lua_tolstring');
    luaToNumber = _lib.lookupFunction<Double Function(Pointer<Void>, Int32),
        double Function(Pointer<Void>, int)>('lua_tonumber');
    luaToBoolean = _lib.lookupFunction<Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('lua_toboolean');

    luaSetField = _lib.lookupFunction<Void Function(Pointer<Void>, Int32, Pointer<Utf8>),
        void Function(Pointer<Void>, int, Pointer<Utf8>)>('lua_setfield');
    luaGetField = _lib.lookupFunction<Void Function(Pointer<Void>, Int32, Pointer<Utf8>),
        void Function(Pointer<Void>, int, Pointer<Utf8>)>('lua_getfield');
    luaCreateTable = _lib.lookupFunction<Void Function(Pointer<Void>, Int32, Int32),
        void Function(Pointer<Void>, int, int)>('lua_createtable');
    luaGetTable = _lib.lookupFunction<Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)>('lua_gettable');
    luaSetTable = _lib.lookupFunction<Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)>('lua_settable');
    luaRawGetI = _lib.lookupFunction<Void Function(Pointer<Void>, Int32, Int32),
        void Function(Pointer<Void>, int, int)>('lua_rawgeti');
    luaRawSetI = _lib.lookupFunction<Void Function(Pointer<Void>, Int32, Int32),
        void Function(Pointer<Void>, int, int)>('lua_rawseti');
    luaObjLen = _lib.lookupFunction<IntPtr Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('lua_objlen');
    luaPushValue = _lib.lookupFunction<Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)>('lua_pushvalue');
    luaNext = _lib.lookupFunction<Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('lua_next');
    luaLRef = _lib.lookupFunction<Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)>('luaL_ref');
    luaLUnref = _lib.lookupFunction<Void Function(Pointer<Void>, Int32, Int32),
        void Function(Pointer<Void>, int, int)>('luaL_unref');
  }

  // ---- 5.1 宏的 Dart 等价实现 ----
  void luaSetGlobal(Pointer<Void> l, Pointer<Utf8> name) => luaSetField(l, luaGlobalsIndex, name);
  void luaGetGlobal(Pointer<Void> l, Pointer<Utf8> name) => luaGetField(l, luaGlobalsIndex, name);
  void luaPop(Pointer<Void> l, int n) => luaSetTop(l, -n - 1);

  /// 读取栈上 idx 处的字符串 (null 结尾)。
  String? luaToDartString(Pointer<Void> l, int idx) {
    final p = luaToLString(l, idx, nullptr);
    if (p == nullptr) return null;
    return p.toDartString();
  }
}

typedef LuaCFunctionNative = Int32 Function(Pointer<Void>);
typedef LuaCFunctionDart = int Function(Pointer<Void>);
