#!/usr/bin/env bash
# 交叉编译 LuaJIT 为 Android arm64-v8a 的 libluajit.so
# 用法: ./build_luajit.sh [NDK路径] [API等级]
set -e

NDK="${1:-$HOME/Android/Sdk/ndk/27.0.12077973}"
API="${2:-24}"
SRC_DIR="${LUAJIT_SRC:-/tmp/opencode/LuaJIT}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/app/src/main/jniLibs/arm64-v8a/libluajit.so"

if [ ! -d "$SRC_DIR" ]; then
  echo "拉取 LuaJIT 源码到 $SRC_DIR"
  git clone --depth 1 https://github.com/LuaJIT/LuaJIT.git "$SRC_DIR"
fi

TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"

cd "$SRC_DIR"
make clean || true
make -j"$(nproc)" \
  HOST_CC="gcc" \
  CROSS="$TC/bin/llvm-" \
  STATIC_CC="$TC/bin/aarch64-linux-android${API}-clang" \
  DYNAMIC_CC="$TC/bin/aarch64-linux-android${API}-clang -fPIC" \
  TARGET_LD="$TC/bin/aarch64-linux-android${API}-clang" \
  TARGET_AR="$TC/bin/llvm-ar rcus" \
  TARGET_STRIP="$TC/bin/llvm-strip" \
  TARGET_SYS=Linux TARGET_FLAGS="-DLUAJIT_ENABLE_GC64"

cp "$SRC_DIR/src/libluajit.so" "$OUT"
echo "已输出: $OUT"
file "$OUT"
