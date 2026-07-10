import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// WebView 控制器封装。
///
/// 全部走 webview_flutter 的系统 `android.webkit.WebView`; 该 WebView 在启动时
/// 已被 WebViewUpgrade 用内置的现代 Chromium 内核 (assets/webview/webview.apk)
/// 接管, 因此新旧设备统一获得现代渲染, 无需分后端。
abstract class AppWebController {
  Widget buildView();
  Future<void> loadUrl(String url);
  Future<void> reload();
  Future<void> goBack();
  Future<void> goForward();
  Future<void> clearCache();
  void dispose();
}

class AppWeb {
  AppWeb._();

  static AppWebController create(String url) => SystemWebController(url);

  static bool isLocalUrl(String url) {
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

  static Future<void> launchInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      debugPrint('打开外部链接失败: $e');
    }
  }

  /// 载入完成后注入: 固定视口宽度并禁用双指/双击缩放。
  static const String disableZoomJs = '''
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
}

/// 系统 WebView (webview_flutter) 后端。
class SystemWebController implements AppWebController {
  late final WebViewController _c;
  final bool _interceptExternal;

  SystemWebController(String url) : _interceptExternal = AppWeb.isLocalUrl(url) {
    _c = WebViewController();
    _c.setJavaScriptMode(JavaScriptMode.unrestricted);
    _c.setBackgroundColor(Colors.white);
    _c.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (_interceptExternal && !AppWeb.isLocalUrl(request.url)) {
            AppWeb.launchInBrowser(request.url);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageFinished: (_) {
          _c.runJavaScript(AppWeb.disableZoomJs);
        },
        onWebResourceError: (error) {
          debugPrint('WebUI 加载错误: ${error.description}');
        },
      ),
    );

    if (_c.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode);
      final android = _c.platform as AndroidWebViewController;
      android.setMediaPlaybackRequiresUserGesture(false);
      android.setMixedContentMode(MixedContentMode.compatibilityMode);
      android.setAllowFileAccess(true);
      android.setAllowContentAccess(true);
      android.setOnShowFileSelector(_handleFileSelection);
    }

    _c.loadRequest(Uri.parse(url));
  }

  @override
  Widget buildView() => WebViewWidget(controller: _c);

  @override
  Future<void> loadUrl(String url) => _c.loadRequest(Uri.parse(url));

  @override
  Future<void> reload() => _c.reload();

  @override
  Future<void> goBack() => _c.goBack();

  @override
  Future<void> goForward() => _c.goForward();

  @override
  Future<void> clearCache() => _c.clearCache();

  @override
  void dispose() {
    _c.loadRequest(Uri.parse('about:blank'));
  }

  static Future<List<String>> _handleFileSelection(
      FileSelectorParams params) async {
    try {
      final allowMultiple = params.mode == FileSelectorMode.openMultiple;
      FilePickerResult? result;
      final accept = params.acceptTypes.where((e) => e.isNotEmpty).toList();
      final imageOnly =
          accept.isNotEmpty && accept.every((t) => t.startsWith('image/'));
      final videoOnly =
          accept.isNotEmpty && accept.every((t) => t.startsWith('video/'));
      final audioOnly =
          accept.isNotEmpty && accept.every((t) => t.startsWith('audio/'));
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
