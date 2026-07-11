import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'lua_log.dart';

/// 持久化存储:向 Lua 暴露原生 SQLite(同步)。
///
/// 每个"命名空间"(store.open 的 name)对应一个独立 .db 文件, 便于隔离/备份/删除。
/// 只提供最底层、最不受限的原生接口:exec / query / run;结构与查询完全交给 SQL。
class LuaStore {
  LuaStore._();
  static final LuaStore instance = LuaStore._();

  String _baseDir = '';
  final Map<int, Database> _dbs = {};
  final Map<String, int> _byName = {};
  int _seq = 0;

  void init(String baseDir) {
    _baseDir = baseDir;
  }

  String _sanitize(String name) {
    var s = name.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
    if (s.isEmpty) s = 'default';
    return s;
  }

  /// 打开(或复用)一个命名空间, 返回句柄。
  int open(String name) {
    final safe = _sanitize(name);
    final existing = _byName[safe];
    if (existing != null && _dbs.containsKey(existing)) return existing;
    Directory(_baseDir).createSync(recursive: true);
    final db = sqlite3.open('$_baseDir/$safe.db');
    // 合理默认:WAL 提升并发/性能, 外键约束开启。
    try {
      db.execute('PRAGMA journal_mode=WAL;');
      db.execute('PRAGMA foreign_keys=ON;');
    } catch (_) {}
    final h = ++_seq;
    _dbs[h] = db;
    _byName[safe] = h;
    return h;
  }

  Database _db(int handle) {
    final db = _dbs[handle];
    if (db == null) throw StateError('无效的 store 句柄: $handle');
    return db;
  }

  /// 执行一条或多条语句(DDL/DML), 无返回。
  void exec(int handle, String sql) {
    _db(handle).execute(sql);
  }

  /// 查询, 返回行数组;每行是 列名→值 的表。
  List<Map<String, Object?>> query(int handle, String sql, List<Object?> params) {
    final rs = _db(handle).select(sql, _bind(params));
    final cols = rs.columnNames;
    final out = <Map<String, Object?>>[];
    for (final row in rs) {
      final m = <String, Object?>{};
      for (final c in cols) {
        m[c] = _outVal(row[c]);
      }
      out.add(m);
    }
    return out;
  }

  /// 执行带参写入(INSERT/UPDATE/DELETE), 返回 { lastId, changes }。
  Map<String, Object?> run(int handle, String sql, List<Object?> params) {
    final db = _db(handle);
    db.execute(sql, _bind(params));
    return {'lastId': db.lastInsertRowId, 'changes': db.updatedRows};
  }

  void close(int handle) {
    final db = _dbs.remove(handle);
    if (db != null) {
      _byName.removeWhere((_, v) => v == handle);
      db.dispose();
    }
  }

  /// 参数编组: bool→int, table→JSON 字符串, 其余原样。
  List<Object?> _bind(List<Object?> params) {
    return [
      for (final p in params)
        if (p is bool)
          (p ? 1 : 0)
        else if (p is Map || p is List)
          jsonEncode(p)
        else
          p,
    ];
  }

  /// 结果值编组: blob(字节)→Lua 字符串。
  Object? _outVal(Object? v) {
    if (v is Uint8List) return String.fromCharCodes(v);
    return v;
  }
}
