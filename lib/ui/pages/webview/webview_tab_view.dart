import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../controllers/terminal_controller.dart';
import '../../controllers/webview_tab_manager.dart';
import '../../widgets/glass_panel.dart';
import '../../widgets/tab_strip.dart';

/// 通用 WebUI 多标签视图: 与终端标签视图对等。
/// - 默认无标签 (显示空态), 标签栏常驻; 无标签时右侧固定按钮为 +, 有标签时为刷新
/// - 点击已激活标签 -> 独占编辑其 URL (泡泡消失, 整条标签栏变输入框)
/// - + 直接在标签栏新增空标签并进入编辑; 未填写则不创建
/// - 再次点击 WebUI 导航图标 -> 底部弹出二级浏览器工具栏 (< > 居中 + 等)
class WebViewTabView extends StatefulWidget {
  final double bottomContentInset;

  const WebViewTabView({super.key, this.bottomContentInset = 0});

  @override
  State<WebViewTabView> createState() => _WebViewTabViewState();
}

class _WebViewTabViewState extends State<WebViewTabView> {
  late final HomeController homeController = Get.find<HomeController>();
  late final WebViewTabManager manager = homeController.webViewTabManager;
  final TextEditingController _urlCtl = TextEditingController();
  Worker? _editWorker;

  @override
  void initState() {
    super.initState();
    _editWorker = ever<int?>(manager.editingIndex, (idx) {
      if (idx != null && idx >= 0 && idx < manager.tabs.length) {
        _urlCtl.text = manager.tabs[idx].url;
        _urlCtl.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _urlCtl.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    _editWorker?.dispose();
    _urlCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final tabs = manager.tabs;
      final hasTabs = tabs.isNotEmpty;
      final activeIndex =
          hasTabs ? manager.activeIndex.value.clamp(0, tabs.length - 1) : 0;
      final editing = manager.editingIndex.value;
      final showToolbar = homeController.webviewToolbarVisible.value;

      return Column(
        children: [
          if (editing != null)
            _buildEditBar()
          else
            TabStrip(
              items: [
                for (final t in tabs)
                  TabStripItem(id: t.id, title: t.title, icon: Icons.language),
              ],
              activeIndex: activeIndex,
              opacity: homeController.topNavGlassOpacity.value,
              blur: homeController.glassBlurAmount.value * 30,
              onSelect: (i) {
                if (i == manager.activeIndex.value) {
                  manager.beginEdit(i);
                } else {
                  manager.activeIndex.value = i;
                }
              },
              onClose: (i) => manager.closeTab(i),
              onReorder: (o, n) => manager.reorder(o, n),
              trailing: [
                hasTabs
                    ? IconButton(
                        tooltip: '刷新',
                        icon: const Icon(Icons.refresh, size: 22),
                        onPressed: () => manager.refresh(activeIndex),
                      )
                    : IconButton(
                        tooltip: '新建 WebUI',
                        icon: const Icon(Icons.add, size: 22),
                        onPressed: () => manager.beginEditNew(),
                      ),
              ],
            ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: showToolbar ? 0 : widget.bottomContentInset,
              ),
              child: hasTabs
                  ? IndexedStack(
                      index: activeIndex,
                      children: [
                        for (final t in tabs)
                          WebViewWidget(controller: t.controller),
                      ],
                    )
                  : const Center(child: Text('暂无 WebUI')),
            ),
          ),
          if (showToolbar) _buildBrowserToolbar(context, activeIndex),
        ],
      );
    });
  }

  Widget _buildEditBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        opacity: homeController.topNavGlassOpacity.value,
        blur: homeController.glassBlurAmount.value * 30,
        child: SizedBox(
          height: 44,
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlCtl,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'http://... 或 端口号',
                  ),
                  onSubmitted: (v) => manager.commitEdit(v),
                ),
              ),
              IconButton(
                tooltip: '确定',
                icon: const Icon(Icons.check, size: 20),
                onPressed: () => manager.commitEdit(_urlCtl.text),
              ),
              IconButton(
                tooltip: '取消',
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => manager.cancelEdit(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBrowserToolbar(BuildContext context, int activeIndex) {
    final hasTabs = manager.tabs.isNotEmpty;
    final controller = hasTabs ? manager.tabs[activeIndex].controller : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 4, 12, widget.bottomContentInset + 6),
      child: Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(16),
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: '后退',
                icon: const Icon(Icons.chevron_left),
                onPressed: controller == null ? null : () => controller.goBack(),
              ),
              IconButton(
                tooltip: '前进',
                icon: const Icon(Icons.chevron_right),
                onPressed:
                    controller == null ? null : () => controller.goForward(),
              ),
              const Spacer(),
              IconButton(
                tooltip: '新建标签页',
                icon: const Icon(Icons.add),
                onPressed: () => manager.beginEditNew(),
              ),
              const Spacer(),
              IconButton(
                tooltip: '在浏览器中打开',
                icon: const Icon(Icons.open_in_browser),
                onPressed: controller == null
                    ? null
                    : () => _openExternal(manager.tabs[activeIndex].url),
              ),
              IconButton(
                tooltip: '收起工具栏',
                icon: const Icon(Icons.close),
                onPressed: () =>
                    homeController.webviewToolbarVisible.value = false,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
