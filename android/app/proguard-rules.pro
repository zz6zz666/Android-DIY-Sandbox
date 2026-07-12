# ============================================================
# LÖVE / SDL 原生桥: 这些 Java 类的方法由 native (.so) 通过 JNI 按名字反查调用
# (例如 libSDL3.so 的 JNI_OnLoad 会找 org.libsdl.app.SDLActivity.nativeGetVersion)。
# R8 若重命名/裁剪它们, love 子进程会 NoSuchMethodError 崩溃、画布无法渲染。
# 因此对原生回调面整包保留。
# ============================================================
-keep class org.libsdl.app.** { *; }
-keep class org.love2d.** { *; }
-keep class com.diysandbox.android.Love** { *; }

# 保留所有 native 方法及其所属类名 (JNI 按签名/名字解析)
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}
