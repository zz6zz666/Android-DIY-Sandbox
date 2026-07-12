import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:settings/settings.dart';
import 'dart:async';

import 'generated/l10n.dart';
import 'core/services/foreground_service.dart';
import 'core/lua/script_manager.dart';
import 'core/lua/lua_log.dart';
import 'ui/routes/app_routes.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lua 层错误同步输出到 Lua 日志 (保留原生红屏/黄条纹渲染)
  final _defaultOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    _defaultOnError?.call(details);
    final lib = details.library ?? '';
    // 跳过 Flutter framework 自检告警 (ListTile 背景色等), 只记录 Lua 相关错误
    if (lib == 'Flutter framework') return;
    LuaLog.instance.error('[$lib] ${details.exception}');
  };

  // 检查并请求通知权限
  var status = await Permission.notification.status;
  if (status.isDenied || status.isPermanentlyDenied) {
    await Permission.notification.request();
  }

  // 初始化并启动前台服务
  ForegroundServiceManager.init();
  await ForegroundServiceManager.startService();

  // 隐藏系统 UI
  // Hide system UI
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [
    SystemUiOverlay.top,
    // SystemUiOverlay.bottom,
  ]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light, // Android 状态栏图标为白色
    statusBarBrightness: Brightness.dark, // iOS 状态栏图标为白色
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
  ));
  final packageInfo = await PackageInfo.fromPlatform();
  RuntimeEnvir.initEnvirWithPackageName(packageInfo.packageName);
  await initSettingStore(RuntimeEnvir.configPath);

  // 初始化 Lua 脚本运行时 (释放默认脚本 / 加载 prelude+用户脚本 / 注册页面与导航)
  try {
    await ScriptManager.instance.initialize();
  } catch (e, st) {
    debugPrint('[Lua] 初始化失败: $e\n$st');
  }

  runApp(const SandboxApp());
}

class SandboxApp extends StatefulWidget {
  const SandboxApp({super.key});

  @override
  State<SandboxApp> createState() => _SandboxAppState();
}

class _SandboxAppState extends State<SandboxApp> with WidgetsBindingObserver {
  Timer? _serviceMonitorTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 启动服务状态监听器，定期检查服务是否运行
    _startServiceMonitor();
  }

  /// 启动服务状态监听器
  void _startServiceMonitor() {
    // 每10秒检查一次服务状态
    _serviceMonitorTimer =
        Timer.periodic(const Duration(seconds: 10), (timer) async {
      final isRunning = await ForegroundServiceManager.isRunningService();
      final userClickedStop = ForegroundServiceManager.userClickedStopButton;

      // 只有在服务未运行且用户没有点击停止按钮的情况下才重启
      // 这样即使用户从通知栏划掉通知，服务也会被重建
      if (!isRunning && !userClickedStop) {
        Log.w('主应用检测到服务未运行，尝试重启...', tag: 'Sandbox');
        try {
          await ForegroundServiceManager.startService();
          Log.i('服务重启成功', tag: 'Sandbox');
        } catch (e) {
          Log.e('服务重启失败: $e', tag: 'Sandbox');
        }
      }
    });
  }

  @override
  void dispose() {
    _serviceMonitorTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // 当应用完全退出时，确保清理所有资源
    if (state == AppLifecycleState.detached) {
      Log.i('应用正在退出，清理所有资源...', tag: 'Sandbox');
      try {
        // 尝试获取并清理 HomeController
        if (Get.isRegistered<dynamic>()) {
          Get.delete<dynamic>(force: true);
        }
      } catch (e) {
        Log.e('清理资源时出错: $e', tag: 'Sandbox');
      }
    }
  }

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Android DIY Sandbox',
      theme: ThemeData(
        colorSchemeSeed: Colors.primaries[3],
        dialogTheme: const DialogThemeData(
          actionsPadding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        ),
      ),
      // locale: const Locale('zh', 'CN'),
      // locale: const Locale('en'),
      localizationsDelegates: const [
        S.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: S.delegate.supportedLocales,
      // 使用路由管理
      initialRoute: AppRoutes.main,
      getPages: AppRoutes.routes,
    );
  }
}
