import 'package:get/get.dart';
import '../pages/main/main_page.dart';
import '../pages/webview/x5_test_page.dart';
import '../pages/lua/lua_preview_page.dart';

class AppRoutes {
  static const String main = '/main';
  static const String x5Test = '/x5-test';
  static const String luaPreview = '/lua-preview';

  static final routes = [
    GetPage(
      name: main,
      page: () => const MainPage(),
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
