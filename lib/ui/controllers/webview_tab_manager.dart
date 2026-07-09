import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// 一个 WebUI 标签页 (通用, 无任何 AstrBot/NapCat 语义)。
class WebViewTab {
  final String id;
  String title;
  String url;
  final WebViewController controller;

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
      controller: _createController(norm),
    );
    tabs.add(tab);
    activeIndex.value = tabs.length - 1;
  }

  void closeTab(int index) {
    if (index < 0 || index >= tabs.length) return;
    final tab = tabs.removeAt(index);
    tab.controller.clearCache();
    tab.controller.loadRequest(Uri.parse('about:blank'));
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
      controller: _createController('about:blank'),
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
      t.controller.loadRequest(Uri.parse(url));
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
    tab.controller.loadRequest(Uri.parse('about:blank'));
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

  // ==================== 控制器工厂 ====================

  static bool _isLocalUrl(String url) {
    try {
      final host = Uri.parse(url).host.toLowerCase();
      if (host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0') {
        return true;
      }
      if (host.startsWith('192.168.') || host.startsWith('10.')) return true;
      if (host.startsWith('172.')) {
        final parts = host.split('.');
        final o = parts.length >= 2 ? int.tryParse(parts[1]) : null;
        return o != null && o >= 16 && o <= 31;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _launchInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('打开外部链接失败: $e');
    }
  }

  static WebViewController _createController(String url) {
    final interceptExternal = _isLocalUrl(url);
    final controller = WebViewController();
    controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    controller.setBackgroundColor(Colors.white);
    controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (interceptExternal && !_isLocalUrl(request.url)) {
            _launchInBrowser(request.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageFinished: (_) {
          controller.runJavaScript(_disableZoomJs);
        },
        onWebResourceError: (error) {
          debugPrint('WebUI 加载错误: ${error.description}');
        },
      ),
    );

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode);
      final android = controller.platform as AndroidWebViewController;
      android.setMediaPlaybackRequiresUserGesture(false);
      android.setMixedContentMode(MixedContentMode.compatibilityMode);
      android.setAllowFileAccess(true);
      android.setAllowContentAccess(true);
      android.setOnShowFileSelector(_handleFileSelection);
    }

    controller.loadRequest(Uri.parse(url));
    return controller;
  }

  static const String _disableZoomJs = '''
    (function() {
      if (window.__wvZoomPatched) return;
      window.__wvZoomPatched = true;
      var meta = document.querySelector('meta[name="viewport"]');
      var c = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
      if (meta) { meta.content = c; }
      else {
        meta = document.createElement('meta');
        meta.name = 'viewport'; meta.content = c;
        document.head.appendChild(meta);
      }
      var lastTouchEnd = 0;
      document.addEventListener('touchend', function(e) {
        var now = Date.now();
        if (now - lastTouchEnd <= 300) { e.preventDefault(); }
        lastTouchEnd = now;
      }, false);
      document.addEventListener('gesturestart', function(e) { e.preventDefault(); }, false);
    })();
  ''';

  static Future<List<String>> _handleFileSelection(
      FileSelectorParams params) async {
    try {
      final allowMultiple = params.mode == FileSelectorMode.openMultiple;
      FilePickerResult? result;
      final accept = params.acceptTypes.where((e) => e.isNotEmpty).toList();
      final imageOnly = accept.isNotEmpty &&
          accept.every((t) => t.startsWith('image/'));
      final videoOnly = accept.isNotEmpty &&
          accept.every((t) => t.startsWith('video/'));
      final audioOnly = accept.isNotEmpty &&
          accept.every((t) => t.startsWith('audio/'));
      if (imageOnly) {
        result = await FilePicker.pickFiles(
            type: FileType.image, allowMultiple: allowMultiple);
      } else if (videoOnly) {
        result = await FilePicker.pickFiles(
            type: FileType.video, allowMultiple: allowMultiple);
      } else if (audioOnly) {
        result = await FilePicker.pickFiles(
            type: FileType.audio, allowMultiple: allowMultiple);
      } else {
        result = await FilePicker.pickFiles(
            type: FileType.any, allowMultiple: allowMultiple);
      }
      if (result == null) return [];
      return result.files
          .where((f) => f.path != null)
          .map((f) => f.path!.startsWith('file://')
              ? f.path!
              : 'file://${f.path!.replaceAll('\\', '/')}')
          .toList();
    } catch (e) {
      debugPrint('文件选择失败: $e');
      return [];
    }
  }
}
