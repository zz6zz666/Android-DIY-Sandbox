import 'package:get/get.dart';

import 'app_web_controller.dart';

/// 一个 WebUI 标签页 (通用, 无任何 AstrBot/NapCat 语义)。
class WebViewTab {
  final String id;
  String title;
  String url;
  final AppWebController controller;

  WebViewTab({
    required this.id,
    required this.title,
    required this.url,
    required this.controller,
  });
}

/// 通用 WebUI 标签页管理器: 与终端标签页对等。
/// 默认无任何标签; 由动作 (host.webview_open) 按需创建, 同 URL 去重复用。
class WebViewTabManager {
  final RxList<WebViewTab> tabs = <WebViewTab>[].obs;
  final RxInt activeIndex = 0.obs;

  /// 正在编辑 URL 的标签索引; null = 未处于编辑态。
  final RxnInt editingIndex = RxnInt();
  bool _editingIsNew = false;

  /// 打开一个 URL: 若已存在相同 URL 的标签则切换过去 (去重), 否则新建。
  void openUrl(String url, String title) {
    final norm = url.trim();
    if (norm.isEmpty) return;
    final existing = tabs.indexWhere((t) => t.url == norm);
    if (existing >= 0) {
      activeIndex.value = existing;
      return;
    }
    final tab = WebViewTab(
      id: 'webui_${DateTime.now().millisecondsSinceEpoch}',
      title: title.isEmpty ? 'WebUI' : title,
      url: norm,
      controller: AppWeb.create(norm),
    );
    tabs.add(tab);
    activeIndex.value = tabs.length - 1;
  }

  void closeTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    final tab = tabs.removeAt(index);
    tab.controller.clearCache();
    tab.controller.dispose();
    if (tabs.isEmpty) {
      activeIndex.value = 0;
    } else if (activeIndex.value >= tabs.length) {
      activeIndex.value = tabs.length - 1;
    }
  }

  void refresh(int index) {
    if (index < 0 || index >= tabs.length) return;
    tabs[index].controller.reload();
  }

  /// 拖动排序: 移动标签并保持当前激活标签不变
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tabs.length) return;
    if (newIndex < 0 || newIndex >= tabs.length) return;
    if (oldIndex == newIndex) return;
    final active = (activeIndex.value >= 0 && activeIndex.value < tabs.length)
        ? tabs[activeIndex.value]
        : null;
    final moved = tabs.removeAt(oldIndex);
    tabs.insert(newIndex, moved);
    if (active != null) activeIndex.value = tabs.indexOf(active);
  }

  // ==================== URL 编辑 ====================

  /// 新建一个空标签并进入独占编辑态 (未填写 URL 则取消时丢弃)。
  void beginEditNew() {
    final tab = WebViewTab(
      id: 'webui_${DateTime.now().millisecondsSinceEpoch}',
      title: '',
      url: '',
      controller: AppWeb.create('about:blank'),
    );
    tabs.add(tab);
    activeIndex.value = tabs.length - 1;
    _editingIsNew = true;
    editingIndex.value = tabs.length - 1;
  }

  /// 编辑已有标签的 URL。
  void beginEdit(int index) {
    if (index < 0 || index >= tabs.length) return;
    activeIndex.value = index;
    _editingIsNew = false;
    editingIndex.value = index;
  }

  /// 提交编辑: 空 -> 新建的丢弃/已有的保持不变; 非空 -> 载入并变为无名 URL 标签。
  void commitEdit(String text) {
    final i = editingIndex.value;
    if (i == null || i < 0 || i >= tabs.length) {
      editingIndex.value = null;
      return;
    }
    final url = normalizeUrl(text);
    if (url == null) {
      if (_editingIsNew) _removeAt(i);
    } else {
      final t = tabs[i];
      t.url = url;
      t.title = displayTitle(url);
      t.controller.loadUrl(url);
      tabs.refresh();
    }
    editingIndex.value = null;
    _editingIsNew = false;
  }

  void cancelEdit() {
    final i = editingIndex.value;
    if (i != null && _editingIsNew && i >= 0 && i < tabs.length) _removeAt(i);
    editingIndex.value = null;
    _editingIsNew = false;
  }

  void _removeAt(int index) {
    final tab = tabs.removeAt(index);
    tab.controller.dispose();
    if (tabs.isEmpty) {
      activeIndex.value = 0;
    } else if (activeIndex.value >= tabs.length) {
      activeIndex.value = tabs.length - 1;
    }
  }

  /// 归一化用户输入: 空 -> null; 纯端口 -> http://127.0.0.1:port; 无协议 -> 补 http://
  static String? normalizeUrl(String input) {
    var v = input.trim();
    if (v.isEmpty) return null;
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    final port = int.tryParse(v);
    if (port != null && port >= 1 && port <= 65535) {
      return 'http://127.0.0.1:$port';
    }
    return 'http://$v';
  }

  /// 无名 URL 标签的显示标题 (去掉协议前缀)。
  static String displayTitle(String url) {
    return url.replaceFirst(RegExp(r'^https?://'), '');
  }
}
