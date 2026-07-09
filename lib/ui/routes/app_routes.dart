import 'package:get/get.dart';
import '../pages/launcher/launcher_page.dart';
import '../pages/main/main_page.dart';
import '../pages/terminal/terminal_page.dart';
import '../pages/webview/webview_page.dart';
import '../pages/webview/x5_test_page.dart';
import '../pages/lua/lua_preview_page.dart';

class AppRoutes {
  static const String launcher = '/launcher';
  static const String main = '/main';
  static const String terminal = '/terminal';
  static const String webview = '/webview';
  static const String x5Test = '/x5-test';
  static const String luaPreview = '/lua-preview';

  static final routes = [
    GetPage(
      name: main,
      page: () => const MainPage(),
    ),
    GetPage(
      name: launcher,
      page: () => const LauncherPage(),
    ),
    GetPage(
      name: terminal,
      page: () => const TerminalPage(),
    ),
    GetPage(
      name: webview,
      page: () => const WebViewPage(),
      transition: Transition.fadeIn,
    ),
    GetPage(
      name: x5Test,
      page: () => const X5TestPage(),
      transition: Transition.fadeIn,
    ),
    GetPage(
      name: luaPreview,
      page: () => const LuaPreviewPage(),
      transition: Transition.fadeIn,
    ),
  ];
}
