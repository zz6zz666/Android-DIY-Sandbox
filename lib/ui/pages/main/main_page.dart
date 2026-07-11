import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/lua/lua_engine.dart';
import '../../../core/lua/script_manager.dart';
import '../../controllers/terminal_controller.dart';
import '../../lua/lua_view.dart';
import '../../widgets/glass_panel.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_tab_view.dart';
import '../webview/webview_tab_view.dart';
import '../love/love_game_view.dart';
import '../logs/lua_log_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {

  final HomeController homeController = Get.put(HomeController());
  Worker? _mainTabWorker;
  int _currentIndex = 0;
  bool _showSettings = false;

  /// 由 Lua 脚本定义的导航 tab; 为空(main.lua 缺失/损坏)时回退到内置三页:
  /// 主页(空白) / WebUI(空) / 终端 —— 保证脚本挂掉也能进终端与设置自救。
  List<Map<String, dynamic>> get _tabs {
    final t = ScriptManager.instance.navTabs;
    if (t.isEmpty) {
      return [
        {'title': '主页', 'icon': 'home', 'page': 'home'},
        {'title': 'WebUI', 'icon': 'language', 'page': {'type': 'webview'}},
        {'title': '终端', 'icon': 'terminal', 'page': 'terminal'},
      ];
    }
    return t;
  }

  @override
  void initState() {
    super.initState();
    _mainTabWorker = ever<int?>(homeController.pendingMainTabIndex, (index) {
      if (index == null || index < 0 || index >= _tabs.length) return;
      _switchTab(index);
      homeController.clearPendingMainTabIndex(index);
    });
  }

  @override
  void dispose() {
    _mainTabWorker?.dispose();
    super.dispose();
  }

  void _switchTab(int index) {
    setState(() {
      _showSettings = false;
      _currentIndex = index;
    });
  }

  /// 底部导航点击: 若点的是当前已选中的页, 视为"再次点击"事件。
  void _onNavTap(int index) {
    final tabs = _tabs;
    final reTap = !_showSettings && index == _currentIndex;
    _switchTab(index);
    if (!reTap || index < 0 || index >= tabs.length) return;
    final page = tabs[index]['page'];
    final isTerminal =
        page == 'terminal' || (page is Map && '${page['type']}' == 'terminal');
    final isWebview = page is Map && '${page['type']}' == 'webview';
    if (isTerminal) {
      homeController.terminalMenuSignal.value++;
    } else if (isWebview) {
      homeController.webviewToolbarVisible.toggle();
    } else {
      ScriptManager.instance.fireNavReTap(index);
    }
  }

  void _openSettings() => setState(() => _showSettings = true);
  void _closeSettings() => setState(() => _showSettings = false);

  /// 导出整个脚本释放目录为 zip 到系统下载目录。
  Future<void> _exportScripts() async {
    final path = await ScriptManager.instance.exportScriptsZip();
    if (!mounted) return;
    Get.snackbar(
      path != null ? '导出成功' : '导出失败',
      path != null ? '已保存到 $path' : '请检查存储权限',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 3),
    );
  }

  /// 选择一个 zip, 替换整个脚本释放目录并重载。
  Future<void> _importScripts() async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('导入脚本'),
        content: const Text('将用所选 zip 覆盖替换整个脚本目录 (含 main.lua / agent / 文档), '
            '当前内容会被清空。建议先导出备份。是否继续?'),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('取消')),
          FilledButton(onPressed: () => Get.back(result: true), child: const Text('选择 zip')),
        ],
      ),
    );
    if (confirmed != true) return;
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      allowMultiple: false,
    );
    final path = res?.files.single.path;
    if (path == null) return;
    final ok = await ScriptManager.instance.importScriptsZip(path);
    if (!mounted) return;
    if (ok) setState(() {});
    Get.snackbar(
      ok ? '导入成功' : '导入失败',
      ok ? '脚本已替换并重载' : (ScriptManager.instance.lastError ?? '请检查 zip 内容'),
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 3),
    );
  }

  /// 由 Lua 注册的主页顶栏自定义按钮 (设置按钮左侧, 可多个)。
  /// 顺序: agent 入口按钮 (受保护, 最左) → 用户 app.actions 按钮。
  List<Widget> _buildLuaActions() {
    Widget btn(Map act) => IconButton(
          tooltip: act['tooltip'] == null ? null : '${act['tooltip']}',
          icon: Icon(luaIconFor(act['icon']) ?? Icons.extension),
          onPressed: () {
            final fn = act['onTap'];
            if (fn is LuaFunctionRef) fn.call();
            ScriptManager.instance.stateRevision.value++;
          },
        );
    return [
      for (final act in ScriptManager.instance.agentActions) btn(act),
      for (final act in ScriptManager.instance.homeActions) btn(act),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => BubbleBackground(
        imagePath: homeController.homeBackgroundPath.value,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: _showSettings ? _buildSettingsPage() : _buildMainTabs(),
          bottomNavigationBar: _showSettings ? null : _buildBottomNav(context),
        ),
      ),
    );
  }

  Widget _buildSettingsPage() {
    return Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: Colors.white.withValues(
              alpha: homeController.statusOverlayOpacity.value,
            ),
          ),
        ),
        Column(
          children: [
            GlassAppBar(
              title: '设置',
              opacity: homeController.topNavGlassOpacity.value,
              blur: homeController.glassBlurAmount.value * 30,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: _closeSettings,
              ),
              actions: [
                IconButton(
                  tooltip: '导入脚本 (zip)',
                  icon: const Icon(Icons.file_download_outlined),
                  onPressed: _importScripts,
                ),
                IconButton(
                  tooltip: '导出脚本 (zip)',
                  icon: const Icon(Icons.file_upload_outlined),
                  onPressed: _exportScripts,
                ),
                IconButton(
                  tooltip: 'Lua 日志',
                  icon: const Icon(Icons.article_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LuaLogPage()),
                  ),
                ),
              ],
            ),
            Expanded(
              child: SettingsPage(),
            ),
          ],
        ),
      ],
    );
  }

  /// 判断某 tab 是否为特殊的"主页"。
  bool _isHome(Object? page) {
    if (page is String) return page == 'home';
    if (page is Map) return '${page['type']}' == 'home' || '${page['page']}' == 'home';
    return false;
  }

  /// 根据 Lua 定义的 page 规格构造对应页面。
  /// home / terminal 为特殊内置页; 其余(webview/游戏/自定义 Lua 页)为普通页。
  Widget _pageFor(Map<String, dynamic> tab) {
    final page = tab['page'];

    // 特殊内置页: 主页 (携带固定齿轮顶栏)
    if (_isHome(page)) {
      final pageName =
          page is Map ? '${page['page'] ?? 'home'}' : 'home';
      return Column(
        children: [
          GlassAppBar(
            title: '${tab['title'] ?? '主页'}',
            opacity: homeController.topNavGlassOpacity.value,
            blur: homeController.glassBlurAmount.value * 30,
            titleSuffix: _isHome(page)
                ? IconButton(
                    visualDensity: VisualDensity.compact,
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    tooltip: '应用脚本更改',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => ScriptManager.instance.reloadWithGuard(),
                  )
                : null,
            actions: [
              ..._buildLuaActions(),
              IconButton(
                tooltip: '设置',
                icon: const Icon(Icons.settings),
                onPressed: _openSettings,
              ),
            ],
          ),
          Expanded(child: LuaPage(pageName: pageName)),
        ],
      );
    }

    // 特殊内置页: 终端
    if (page == 'terminal' ||
        (page is Map && '${page['type']}' == 'terminal')) {
      return const TerminalTabView();
    }

    // 普通页: webview (通用多标签, 默认无标签)
    if (page is Map && '${page['type']}' == 'webview') {
      return const WebViewTabView();
    }

    // 普通页: 自定义 Lua 页面 (游戏 / 其它)
    final name = page is Map ? '${page['page'] ?? page['type']}' : '$page';
    return LuaPage(pageName: name);
  }

  Widget _buildMainTabs() {
    final tabs = _tabs;
    final index = _currentIndex.clamp(0, tabs.length - 1);
    return SafeArea(
      bottom: false,
      child: IndexedStack(
        index: index,
        children: [
          for (int i = 0; i < tabs.length; i++)
            LovePageActive(active: i == index, child: _pageFor(tabs[i])),
        ],
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    final tabs = _tabs;
    final index = _currentIndex.clamp(0, tabs.length - 1);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: GlassPanel(
          borderRadius: BorderRadius.circular(24),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          opacity: homeController.cardGlassOpacity.value,
          blur: homeController.glassBlurAmount.value * 30,
          child: MediaQuery.withNoTextScaling(
            child: NavigationBar(
              selectedIndex: index,
              onDestinationSelected: _onNavTap,
              backgroundColor: Colors.transparent,
              elevation: 0,
              height: 46,
              labelTextStyle: WidgetStateProperty.all(
                const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
              destinations: [
                for (final t in tabs)
                  NavigationDestination(
                    icon: Icon(luaIconFor(t['icon']) ?? Icons.circle_outlined,
                        size: 22),
                    label: '${t['title'] ?? ''}',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
