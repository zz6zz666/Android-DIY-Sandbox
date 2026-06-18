import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/terminal_controller.dart';
import '../../widgets/glass_panel.dart';
import '../launcher/launcher_page.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_tab_view.dart';
import '../webview/webview_page.dart';

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

  @override
  void initState() {
    super.initState();
    _mainTabWorker = ever<int?>(homeController.pendingMainTabIndex, (index) {
      if (index == null || index < 0 || index > 2) return;
      _openTab(index);
      homeController.clearPendingMainTabIndex(index);
    });
  }

  @override
  void dispose() {
    _mainTabWorker?.dispose();
    super.dispose();
  }

  void _openTab(int index) {
    setState(() {
      _showSettings = false;
      _currentIndex = index;
    });
  }

  void _openSettings() {
    setState(() {
      _showSettings = true;
    });
  }

  void _closeSettings() {
    setState(() {
      _showSettings = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => BubbleBackground(
        imagePath: homeController.homeBackgroundPath.value,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
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
            ),
            Expanded(
              child: SettingsPage(
                astrBotController: WebViewPage.astrBotController,
                napCatController: WebViewPage.napCatController,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMainTabs() {
    return SafeArea(
      bottom: false,
      child: IndexedStack(
        index: _currentIndex,
        children: [
          LauncherPage(
            onNavigate: _openTab,
            onOpenSettings: _openSettings,
          ),
          WebViewPage(embedded: true),
          const TerminalTabView(),
        ],
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: GlassPanel(
          borderRadius: BorderRadius.circular(28),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          opacity: homeController.cardGlassOpacity.value,
          blur: homeController.glassBlurAmount.value * 30,
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: _openTab,
            backgroundColor: Colors.transparent,
            elevation: 0,
            height: 64,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.smart_toy_outlined),
                selectedIcon: Icon(Icons.smart_toy),
                label: '主页',
              ),
              NavigationDestination(
                icon: Icon(Icons.language_outlined),
                selectedIcon: Icon(Icons.language),
                label: 'WebUI',
              ),
              NavigationDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: '终端',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
