import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../controllers/terminal_controller.dart';
import '../../widgets/glass_panel.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_tab_view.dart';
import '../../navbar/bottom_nav_bar.dart';
import '../../../core/services/password_manager.dart';
import '../../../core/config/service_ports.dart';

class WebViewPage extends StatefulWidget {
  final bool embedded;
  final double bottomContentInset;

  const WebViewPage({
    super.key,
    this.embedded = false,
    this.bottomContentInset = 0,
  });

  static WebViewController? _astrBotController;
  static WebViewController? _napCatController;

  static WebViewController get astrBotController =>
      _astrBotController ??= WebViewController();

  static WebViewController get napCatController =>
      _napCatController ??= WebViewController();

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  int _currentIndex = 0;
  int _previousNavItemCount = 0; // 记录上一次导航栏项目数量

  late final WebViewController _astrBotController;
  late final WebViewController _napCatController;
  final Map<String, WebViewController> _customControllers =
      {}; // 存储自定义 WebView 控制器，使用 URL 作为 key
  final Map<String, int> _webUiZoomLevels = {};
  Worker? _customWebViewsWorker;
  Worker? _napCatTokenWorker;

  final HomeController homeController = Get.find<HomeController>();

  // 标记 AstrBot WebView 是否初始化
  // Flag for AstrBot WebView initialization
  bool _astrBotInitialized = false;

  @override
  void initState() {
    super.initState();
    final args = Get.arguments;
    if (args is Map && args['openSettings'] == true) {
      _currentIndex = 9999;
    } else if (args is Map && args['openTerminal'] == true) {
      _currentIndex = 9998;
    }
    _initSystemUI();
    _astrBotController = WebViewPage.astrBotController;
    _napCatController = WebViewPage.napCatController;
    _initAstrBotController();
    _initNapCatController();

    // 监听自定义 WebView 列表变化,清理已删除的控制器
    _customWebViewsWorker = ever(homeController.customWebViews,
        (List<Map<String, String>> webviews) {
      // 清理不再存在的控制器
      final validUrls = webviews.map((wv) => wv['url'] ?? '').toSet();
      final controllersToRemove = _customControllers.keys
          .where((key) => !validUrls.contains(key))
          .toList();
      for (final key in controllersToRemove) {
        _customControllers.remove(key);
      }
    });
  }

  @override
  void dispose() {
    _customWebViewsWorker?.dispose();
    _napCatTokenWorker?.dispose();
    _restoreSystemUI();
    super.dispose();
  }

  void _initSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
    ));
  }

  void _restoreSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
  }

  // 检查URL是否为本地地址
  bool _isLocalUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host.toLowerCase();
      // 检查是否为本地地址
      return host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '0.0.0.0' ||
          host.startsWith('192.168.') ||
          host.startsWith('10.') ||
          (host.startsWith('172.') && _isPrivateIp172(host));
    } catch (e) {
      debugPrint('Error parsing URL: $e');
      return false;
    }
  }

  // 检查是否为172.16.0.0 - 172.31.255.255范围的私有IP
  bool _isPrivateIp172(String host) {
    final parts = host.split('.');
    if (parts.length >= 2) {
      final secondOctet = int.tryParse(parts[1]);
      return secondOctet != null && secondOctet >= 16 && secondOctet <= 31;
    }
    return false;
  }

  // 在外部浏览器中打开URL
  Future<void> _launchInBrowser(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } else {
        debugPrint('Cannot launch URL: $url');
        if (mounted) {
          Get.snackbar(
            '无法打开链接',
            '无法在浏览器中打开此链接',
            snackPosition: SnackPosition.BOTTOM,
          );
        }
      }
    } catch (e) {
      debugPrint('Error launching URL: $e');
      if (mounted) {
        Get.snackbar(
          '打开失败',
          '打开链接时出错: $e',
          snackPosition: SnackPosition.BOTTOM,
        );
      }
    }
  }

  void _initAstrBotController() {
    _astrBotController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // 拦截外域URL
            if (!_isLocalUrl(request.url)) {
              debugPrint('Intercepting external URL: ${request.url}');
              _launchInBrowser(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            _injectClipboardScript(_astrBotController);
            _disableZoom(_astrBotController);
            _applyWebUiZoom('astrbot', _astrBotController);
            _injectPasswordScript(_astrBotController, url);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('AstrBot WebView error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(ServicePorts.dashboardUrl));

    if (_astrBotController.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode);
      final androidController =
          _astrBotController.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
      // 设置混合内容模式以提高兼容性（Android 9+ 需要）
      androidController.setMixedContentMode(MixedContentMode.compatibilityMode);
      // 允许访问本地文件和内容
      androidController.setAllowFileAccess(true);
      androidController.setAllowContentAccess(true);
      // 设置文件选择回调
      androidController.setOnShowFileSelector(_handleFileSelection);
    }

    _astrBotController.addJavaScriptChannel(
      'Android',
      onMessageReceived: (JavaScriptMessage message) {
        if (message.message == 'getClipboardData') {
          _getClipboardData(_astrBotController);
        } else if (message.message.startsWith('savePassword:')) {
          _handlePasswordSave(message.message);
        }
      },
    );

    setState(() {
      _astrBotInitialized = true;
    });
  }

  void _initNapCatController() {
    _napCatController
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // 拦截外域URL
            if (!_isLocalUrl(request.url)) {
              debugPrint('Intercepting external URL: ${request.url}');
              _launchInBrowser(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String url) {
            _disableZoom(_napCatController);
            _applyWebUiZoom('napcat', _napCatController);
            _injectPasswordScript(_napCatController, url);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('NapCat WebView error: ${error.description}');
          },
        ),
      );

    // 监听 Token 变化
    _napCatTokenWorker = ever(homeController.napCatWebUiToken, (String token) {
      if (token.isNotEmpty) {
        final url = '${ServicePorts.napCatWebUiUrl}?token=$token';
        _napCatController.loadRequest(Uri.parse(url));
      }
    });

    // 初始加载
    if (homeController.napCatWebUiToken.isNotEmpty) {
      final url =
          '${ServicePorts.napCatWebUiUrl}?token=${homeController.napCatWebUiToken.value}';
      _napCatController.loadRequest(Uri.parse(url));
    } else {
      _napCatController.loadRequest(Uri.parse(ServicePorts.napCatWebUiUrl));
    }

    if (_napCatController.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode);
      final androidController =
          _napCatController.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
      // 设置混合内容模式以提高兼容性（Android 9+ 需要）
      androidController.setMixedContentMode(MixedContentMode.compatibilityMode);
      // 允许访问本地文件和内容
      androidController.setAllowFileAccess(true);
      androidController.setAllowContentAccess(true);
      // 设置文件选择回调
      androidController.setOnShowFileSelector(_handleFileSelection);
    }

    _napCatController.addJavaScriptChannel(
      'Android',
      onMessageReceived: (JavaScriptMessage message) {
        if (message.message.startsWith('savePassword:')) {
          _handlePasswordSave(message.message);
        }
      },
    );
  }

  // 创建自定义 WebView 控制器
  WebViewController _createCustomController(String url) {
    final controller = WebViewController();

    // 检查初始URL是否为本地地址，如果是则启用外域拦截
    final shouldInterceptExternal = _isLocalUrl(url);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            // 仅对配置为本地URL的WebView启用外域拦截
            if (shouldInterceptExternal && !_isLocalUrl(request.url)) {
              debugPrint(
                  'Intercepting external URL from custom WebView: ${request.url}');
              _launchInBrowser(request.url);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (String pageUrl) {
            _disableZoom(controller);
            _applyWebUiZoom('custom:$url', controller);
            _injectPasswordScript(controller, pageUrl);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('Custom WebView error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    if (controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(kDebugMode);
      final androidController = controller.platform as AndroidWebViewController;
      androidController.setMediaPlaybackRequiresUserGesture(false);
      androidController.setMixedContentMode(MixedContentMode.compatibilityMode);
      androidController.setAllowFileAccess(true);
      androidController.setAllowContentAccess(true);
      // 设置文件选择回调
      androidController.setOnShowFileSelector(_handleFileSelection);
    }

    controller.addJavaScriptChannel(
      'Android',
      onMessageReceived: (JavaScriptMessage message) {
        if (message.message.startsWith('savePassword:')) {
          _handlePasswordSave(message.message);
        }
      },
    );

    return controller;
  }

  // 获取或创建自定义 WebView 控制器
  WebViewController _getCustomController(String url) {
    // 如果控制器存在但URL已更改，删除旧控制器并创建新的
    if (_customControllers.containsKey(url)) {
      return _customControllers[url]!;
    }

    // 创建新控制器
    _customControllers[url] = _createCustomController(url);
    return _customControllers[url]!;
  }

  // 处理文件选择
  Future<List<String>> _handleFileSelection(FileSelectorParams params) async {
    try {
      // 根据参数配置文件选择器
      FilePickerResult? result;

      // 判断是否接受多个文件
      final bool allowMultiple = params.mode == FileSelectorMode.openMultiple;

      // 判断文件类型
      if (params.acceptTypes.isNotEmpty) {
        // 如果指定了接受的文件类型
        final acceptTypes = params.acceptTypes;

        // 检查是否只接受图片
        final bool isImageOnly = acceptTypes.every((type) =>
            type.startsWith('image/') ||
            [
              'jpg',
              'jpeg',
              'png',
              'gif',
              'webp',
              'bmp',
              '.jpg',
              '.jpeg',
              '.png',
              '.gif',
              '.webp',
              '.bmp'
            ].contains(type.toLowerCase()));

        // 检查是否只接受视频
        final bool isVideoOnly = acceptTypes.every((type) =>
            type.startsWith('video/') ||
            [
              'mp4',
              'avi',
              'mov',
              'mkv',
              'flv',
              'wmv',
              '.mp4',
              '.avi',
              '.mov',
              '.mkv',
              '.flv',
              '.wmv'
            ].contains(type.toLowerCase()));

        // 检查是否只接受音频
        final bool isAudioOnly = acceptTypes.every((type) =>
            type.startsWith('audio/') ||
            [
              'mp3',
              'wav',
              'ogg',
              'flac',
              'm4a',
              'aac',
              '.mp3',
              '.wav',
              '.ogg',
              '.flac',
              '.m4a',
              '.aac'
            ].contains(type.toLowerCase()));

        if (isImageOnly) {
          result = await FilePicker.pickFiles(
            type: FileType.image,
            allowMultiple: allowMultiple,
          );
        } else if (isVideoOnly) {
          result = await FilePicker.pickFiles(
            type: FileType.video,
            allowMultiple: allowMultiple,
          );
        } else if (isAudioOnly) {
          result = await FilePicker.pickFiles(
            type: FileType.audio,
            allowMultiple: allowMultiple,
          );
        } else {
          // 提取所有允许的扩展名
          final List<String> allowedExtensions = [];
          for (final type in acceptTypes) {
            // 如果是扩展名格式 (如 .txt, .pdf)
            if (type.startsWith('.')) {
              allowedExtensions.add(type.substring(1));
            }
            // 如果是文件扩展名格式 (如 txt, pdf)
            else if (!type.contains('/')) {
              allowedExtensions.add(type);
            }
          }

          if (allowedExtensions.isNotEmpty) {
            result = await FilePicker.pickFiles(
              type: FileType.custom,
              allowedExtensions: allowedExtensions,
              allowMultiple: allowMultiple,
            );
          } else {
            result = await FilePicker.pickFiles(
              type: FileType.any,
              allowMultiple: allowMultiple,
            );
          }
        }
      } else {
        // 没有指定类型，允许选择任何文件
        result = await FilePicker.pickFiles(
          type: FileType.any,
          allowMultiple: allowMultiple,
        );
      }

      // 返回选中的文件路径,转换为 file:// URI 格式
      if (result != null && result.files.isNotEmpty) {
        final List<String> filePaths =
            result.files.where((file) => file.path != null).map((file) {
          final path = file.path!;
          // 如果路径已经是 file:// 开头,直接返回
          if (path.startsWith('file://')) {
            return path;
          }
          // 否则转换为 file:// URI
          // 在 Windows 上路径可能包含反斜杠,需要替换为正斜杠
          final normalizedPath = path.replaceAll('\\', '/');
          return 'file://$normalizedPath';
        }).toList();

        debugPrint('Selected files: $filePaths');
        return filePaths;
      }

      return [];
    } catch (e) {
      debugPrint('File selection error: $e');
      return [];
    }
  }

  void _injectClipboardScript(WebViewController controller) {
    const String jsCode = '''
      if (!window.__astrbotClipboardPatched) {
        window.__astrbotClipboardPatched = true;
      const originalReadText = navigator.clipboard.readText;
      navigator.clipboard.readText = function () {
        return new Promise((resolve) => {
          Android.postMessage('getClipboardData');
          setTimeout(() => {
            originalReadText.call(navigator.clipboard).then(text => {
              resolve(text);
            }).catch(() => resolve(''));
          }, 100);
        });
      };
      }
    ''';
    controller.runJavaScript(jsCode);
  }

  void _disableZoom(WebViewController controller) {
    const String jsCode = '''
      (function() {
        if (window.__astrbotZoomPatched) return;
        window.__astrbotZoomPatched = true;
        var meta = document.querySelector('meta[name="viewport"]');
        if (meta) {
          meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
        } else {
          meta = document.createElement('meta');
          meta.name = 'viewport';
          meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
          document.head.appendChild(meta);
        }

        // 禁用双击缩放
        var lastTouchEnd = 0;
        document.addEventListener('touchend', function(event) {
          var now = Date.now();
          if (now - lastTouchEnd <= 300) {
            event.preventDefault();
          }
          lastTouchEnd = now;
        }, false);

        // 禁用手势缩放
        document.addEventListener('gesturestart', function(event) {
          event.preventDefault();
        }, false);
      })();
    ''';
    controller.runJavaScript(jsCode);
  }

  Future<void> _getClipboardData(WebViewController controller) async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text ?? '';
    controller.runJavaScript('window.clipboardText = "$text";');
  }

  // 注入密码捕获和自动填充脚本
  void _injectPasswordScript(WebViewController controller, String url) {
    // 先尝试加载已保存的密码
    final savedPassword = PasswordManager.getPassword(url);

    final String jsCode = '''
      (function() {
        if (window.__astrbotPasswordPatched) return;
        window.__astrbotPasswordPatched = true;
        // 自动填充已保存的密码
        ${savedPassword != null ? '''
        function autoFillPassword() {
          const usernameFields = document.querySelectorAll('input[type="text"], input[type="email"], input[name*="user"], input[name*="account"], input[id*="user"], input[id*="account"]');
          const passwordFields = document.querySelectorAll('input[type="password"]');

          if (usernameFields.length > 0 && passwordFields.length > 0) {
            usernameFields[0].value = '${savedPassword['username']?.replaceAll("'", "\\'")}';
            passwordFields[0].value = '${savedPassword['password']?.replaceAll("'", "\\'")}';

            // 触发input事件，确保框架能检测到值变化
            usernameFields[0].dispatchEvent(new Event('input', { bubbles: true }));
            passwordFields[0].dispatchEvent(new Event('input', { bubbles: true }));
          }
        }

        // 页面加载完成后自动填充
        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', autoFillPassword);
        } else {
          autoFillPassword();
        }

        // 延迟填充,确保动态表单也能被填充
        setTimeout(autoFillPassword, 500);
        setTimeout(autoFillPassword, 1000);
        ''' : ''}

        // 监听表单提交,捕获密码
        function capturePassword(event) {
          const form = event.target;
          const usernameField = form.querySelector('input[type="text"], input[type="email"], input[name*="user"], input[name*="account"], input[id*="user"], input[id*="account"]');
          const passwordField = form.querySelector('input[type="password"]');

          if (usernameField && passwordField) {
            const username = usernameField.value;
            const password = passwordField.value;

            if (username && password) {
              // 发送到Flutter端保存
              try {
                Android.postMessage('savePassword:' + JSON.stringify({
                  url: window.location.href,
                  username: username,
                  password: password
                }));
              } catch(e) {
                console.log('Failed to save password:', e);
              }
            }
          }
        }

        // 监听所有表单的submit事件
        document.addEventListener('submit', capturePassword, true);

        // 监听可能的登录按钮点击(某些页面不用form标签)
        document.addEventListener('click', function(event) {
          const target = event.target;
          // 检查是否是登录按钮
          if (target.tagName === 'BUTTON' || target.type === 'submit' ||
              target.textContent.includes('登录') || target.textContent.includes('Login') ||
              target.textContent.includes('Sign in') || target.textContent.includes('提交')) {

            setTimeout(function() {
              const passwordFields = document.querySelectorAll('input[type="password"]');
              if (passwordFields.length > 0) {
                const passwordField = passwordFields[0];
                const form = passwordField.closest('form') || passwordField.parentElement;
                const usernameField = form.querySelector('input[type="text"], input[type="email"], input[name*="user"], input[name*="account"], input[id*="user"], input[id*="account"]');

                if (usernameField && passwordField.value) {
                  try {
                    Android.postMessage('savePassword:' + JSON.stringify({
                      url: window.location.href,
                      username: usernameField.value,
                      password: passwordField.value
                    }));
                  } catch(e) {
                    console.log('Failed to save password:', e);
                  }
                }
              }
            }, 100);
          }
        }, true);
      })();
    ''';

    controller.runJavaScript(jsCode);
  }

  // 处理密码保存请求
  void _handlePasswordSave(String message) {
    try {
      // 消息格式: "savePassword:{json}"
      final jsonStr = message.substring('savePassword:'.length);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;

      final url = data['url'] as String?;
      final username = data['username'] as String?;
      final password = data['password'] as String?;

      if (url != null && username != null && password != null) {
        PasswordManager.savePassword(
          url: url,
          username: username,
          password: password,
        );
        debugPrint('Password saved for: $url');
      }
    } catch (e) {
      debugPrint('Error saving password: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_astrBotInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (widget.embedded) {
      return _buildEmbeddedWebUiPage();
    }

    return Obx(() {
      // 检查 NapCat WebUI 是否启用
      final bool napCatEnabled = homeController.napCatWebUiEnabledRx.value;
      final customWebViews = homeController.customWebViews;

      final pageCount = 2 + customWebViews.length + (napCatEnabled ? 1 : 0);

      // 计算设置页的索引（终端页在倒数第二，设置页在最后）
      final int settingsIndex = pageCount + 1;
      final int currentNavItemCount = pageCount + 2; // 总导航项数量

      // 最简单的逻辑：导航栏数量变化时，直接锁定焦点到最大值（设置页）
      int validCurrentIndex = _currentIndex;
      if (validCurrentIndex == 9998) {
        validCurrentIndex = settingsIndex - 1;
      } else if (validCurrentIndex > settingsIndex) {
        validCurrentIndex = settingsIndex;
      }
      if (_previousNavItemCount != 0 &&
          _previousNavItemCount != currentNavItemCount) {
        // 导航栏数量发生变化，锁定到设置页
        validCurrentIndex = settingsIndex;
        _previousNavItemCount = currentNavItemCount;
        // 异步更新状态
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _currentIndex = settingsIndex;
            });
          }
        });
      } else if (_previousNavItemCount == 0) {
        // 首次加载，记录导航栏数量
        _previousNavItemCount = currentNavItemCount;
      }

      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.white,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(
            top: true,
            child: _buildVisiblePage(
              validCurrentIndex,
              napCatEnabled,
              customWebViews,
            ),
          ),
          bottomNavigationBar: WebViewBottomNavBar(
            currentIndex: validCurrentIndex,
            onTap: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
          ),
        ),
      );
    });
  }

  Widget _buildVisiblePage(
    int index,
    bool napCatEnabled,
    List<Map<String, String>> customWebViews,
  ) {
    if (index == 0) {
      return WebViewWidget(controller: _astrBotController);
    }

    var cursor = 1;
    if (napCatEnabled) {
      if (index == cursor) {
        return WebViewWidget(controller: _napCatController);
      }
      cursor++;
    }

    for (var i = 0; i < customWebViews.length; i++) {
      if (index == cursor + i) {
        final url = customWebViews[i]['url'] ?? '';
        return WebViewWidget(controller: _getCustomController(url));
      }
    }

    final terminalIndex = cursor + customWebViews.length;
    if (index == terminalIndex) {
      return const TerminalTabView();
    }

    final settingsIndex = terminalIndex + 1;
    if (index == settingsIndex) {
      return SettingsPage(
        astrBotController: _astrBotController,
        napCatController: _napCatController,
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildEmbeddedWebUiPage() {
    return Obx(() {
      final targets = _buildWebUiTargets();
      if (targets.isEmpty) {
        return Column(
          children: [
            _buildWebUiTabBar(targets, 0),
            const Expanded(
              child: Center(
                child: Text('暂无 WebUI 标签，点击右上角 + 添加'),
              ),
            ),
          ],
        );
      }

      final maxIndex = targets.length - 1;
      var selectedIndex = _currentIndex.clamp(0, maxIndex).toInt();
      final pendingTargetId = homeController.pendingWebUiTargetId.value;
      if (pendingTargetId != null && pendingTargetId.isNotEmpty) {
        final pendingIndex = targets.indexWhere(
          (target) => target.id == pendingTargetId,
        );
        if (pendingIndex >= 0) {
          selectedIndex = pendingIndex;
          _restoreWebUiTargetIfNeeded(targets[pendingIndex]);
          _loadWebUiTargetUrl(targets[pendingIndex]);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _currentIndex = pendingIndex;
            });
            homeController.clearPendingWebUiTargetId(pendingTargetId);
          });
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            homeController.clearPendingWebUiTargetId(pendingTargetId);
          });
        }
      }
      if (selectedIndex != _currentIndex) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _currentIndex = selectedIndex;
            });
          }
        });
      }

      return Column(
        children: [
          _buildWebUiTabBar(targets, selectedIndex),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: widget.bottomContentInset),
              child: IndexedStack(
                index: selectedIndex,
                children: targets
                    .map(
                      (target) => WebViewWidget(controller: target.controller),
                    )
                    .toList(),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildWebUiTabBar(List<_WebUiTarget> targets, int selectedIndex) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        opacity: homeController.topNavGlassOpacity.value,
        blur: homeController.glassBlurAmount.value * 30,
        child: MediaQuery.withNoTextScaling(
          child: SizedBox(
            height: 38,
            child: Row(
              children: [
                Expanded(
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: targets.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, index) {
                      final target = targets[index];
                      final selected = index == selectedIndex;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: GestureDetector(
                          child: InputChip(
                            selected: selected,
                            showCheckmark: false,
                            label: Text(target.title),
                            avatar: Icon(target.icon, size: 16),
                            deleteIcon: const Icon(Icons.close, size: 16),
                            onDeleted: () => _confirmCloseWebUiTarget(target),
                            onSelected: (_) {
                              setState(() {
                                _currentIndex = index;
                              });
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
                IconButton(
                  tooltip: 'WebUI 菜单',
                  onPressed: () => _showWebUiBrowserMenu(
                    targets.isEmpty ? null : targets[selectedIndex],
                  ),
                  icon: const Icon(Icons.more_horiz, size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<_WebUiTarget> _buildWebUiTargets() {
    final hidden = homeController.hiddenWebUiTargetIds.toSet();
    final targets = <_WebUiTarget>[];

    if (!hidden.contains('astrbot')) {
      targets.add(_WebUiTarget(
        id: 'astrbot',
        title: 'AstrBot',
        icon: Icons.smart_toy,
        url: ServicePorts.dashboardUrl,
        controller: _astrBotController,
      ));
    }

    for (final instance in homeController.napCatInstances) {
      final id = 'napcat:${instance['id'] ?? ''}';
      if (hidden.contains(id)) continue;
      final title = instance['name']?.toString() ?? 'NapCat';
      final url = homeController.napCatInstanceWebUiUrl(instance);
      final controller = _getCustomController(url);
      targets.add(
        _WebUiTarget(
          id: id,
          title: title,
          icon: Icons.account_circle,
          url: url,
          controller: controller,
        ),
      );
    }

    for (var i = 0; i < homeController.customWebViews.length; i++) {
      final webview = homeController.customWebViews[i];
      final url = _normalizeEmbeddedWebUiUrl(webview['url'] ?? '');
      if (url == null) continue;
      final controller = _getCustomController(url);
      targets.add(
        _WebUiTarget(
          id: 'custom:$url',
          title: webview['title'] ?? 'WebUI',
          icon: Icons.language,
          url: url,
          controller: controller,
          customWebViewIndex: i,
        ),
      );
    }

    return targets;
  }

  String? _normalizeEmbeddedWebUiUrl(String input) {
    final value = input.trim();
    if (value.isEmpty) return null;

    final isFullUrl =
        value.startsWith('http://') || value.startsWith('https://');
    if (!isFullUrl) {
      final port = int.tryParse(value);
      if (port == null || !ServicePorts.isValidPort(port)) {
        return null;
      }
      return 'http://127.0.0.1:$port';
    }

    try {
      final uri = Uri.parse(value);
      if (!uri.hasScheme || uri.host.isEmpty) return null;
      if (uri.scheme != 'http' && uri.scheme != 'https') return null;
      if (uri.hasPort && !ServicePorts.isValidPort(uri.port)) return null;
      return uri.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _showAddEmbeddedWebUiDialog() async {
    final result = await showDialog<_AddWebUiResult>(
      context: context,
      builder: (context) => const _AddWebUiDialog(),
    );

    if (result == null) {
      return;
    }

    final title = result.title.trim();
    final urlInput = result.url.trim();

    if (title.isEmpty || urlInput.isEmpty) {
      Get.snackbar(
        '输入错误',
        '标题和 URL 不能为空',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
      return;
    }

    final url = _normalizeEmbeddedWebUiUrl(urlInput);
    if (url == null) {
      Get.snackbar(
        '输入错误',
        '请输入 1024-65535 的端口号，或完整的 http/https URL',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
      return;
    }

    homeController.addCustomWebView(title, url);
    Get.snackbar(
      '添加成功',
      '自定义 WebUI "$title" 已添加',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _showWebUiBrowserMenu(_WebUiTarget? target) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: MediaQuery.withNoTextScaling(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListTile(
                        leading: const Icon(Icons.add),
                        title: const Text('新建标签页'),
                        onTap: () {
                          Navigator.of(context).pop();
                          _showAddEmbeddedWebUiDialog();
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.refresh),
                        title: const Text('刷新页面'),
                        enabled: target != null,
                        onTap: target == null
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                _refreshWebUiTarget(target);
                              },
                      ),
                      ListTile(
                        leading: const Icon(Icons.open_in_browser),
                        title: const Text('在浏览器中打开'),
                        enabled: target != null,
                        onTap: target == null
                            ? null
                            : () {
                                Navigator.of(context).pop();
                                _launchInBrowser(target.url);
                              },
                      ),
                      if (target != null) ...[
                        const Divider(height: 20),
                        _buildZoomMenuItem(
                          target,
                          onChanged: () => setSheetState(() {}),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildZoomMenuItem(
    _WebUiTarget target, {
    required VoidCallback onChanged,
  }) {
    final zoom = _zoomForTarget(target);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.text_increase),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              '调整页面大小',
              style: TextStyle(fontSize: 16),
            ),
          ),
          IconButton(
            tooltip: '小',
            onPressed: zoom <= 50
                ? null
                : () {
                    _setWebUiZoom(target, zoom - 10);
                    onChanged();
                  },
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '$zoom%',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '大',
            onPressed: zoom >= 150
                ? null
                : () {
                    _setWebUiZoom(target, zoom + 10);
                    onChanged();
                  },
            icon: const Icon(Icons.add),
          ),
          TextButton(
            onPressed: zoom == 100
                ? null
                : () {
                    _setWebUiZoom(target, 100);
                    onChanged();
                  },
            child: const Text('默认'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmCloseWebUiTarget(_WebUiTarget target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('关闭标签'),
        content: Text('关闭 WebUI 标签 "${target.title}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final customIndex = target.customWebViewIndex;
    if (customIndex == null) {
      homeController.hideWebUiTarget(target.id);
    } else {
      homeController.removeCustomWebView(customIndex);
    }
    await _releaseWebUiTargetResources(target);

    if (_currentIndex > 0) {
      setState(() {
        _currentIndex -= 1;
      });
    }
  }

  Future<void> _releaseWebUiTargetResources(_WebUiTarget target) async {
    if (target.id == 'astrbot') {
      await _astrBotController.clearCache();
      await _astrBotController.loadRequest(Uri.parse('about:blank'));
      return;
    }
    if (target.id.startsWith('napcat:') || target.customWebViewIndex != null) {
      final controller = _customControllers.remove(target.url);
      await controller?.clearCache();
    }
  }

  void _restoreWebUiTargetIfNeeded(_WebUiTarget target) {
    if (target.id == 'astrbot') {
      _astrBotController.loadRequest(Uri.parse(ServicePorts.dashboardUrl));
    }
  }

  Future<void> _loadWebUiTargetUrl(_WebUiTarget target) async {
    await target.controller.loadRequest(Uri.parse(target.url));
  }

  Future<void> _refreshWebUiTarget(_WebUiTarget target) async {
    await target.controller.reload();
  }

  int _zoomForTarget(_WebUiTarget target) {
    return _webUiZoomLevels[target.id] ??
        _webUiZoomLevels['custom:${target.url}'] ??
        100;
  }

  Future<void> _setWebUiZoom(_WebUiTarget target, int zoom) async {
    final normalizedZoom = zoom.clamp(50, 150).toInt();
    setState(() {
      _webUiZoomLevels[target.id] = normalizedZoom;
      _webUiZoomLevels['custom:${target.url}'] = normalizedZoom;
    });
    await _applyWebUiZoom(target.id, target.controller);
  }

  Future<void> _applyWebUiZoom(
    String targetId,
    WebViewController controller,
  ) async {
    final zoom = (_webUiZoomLevels[targetId] ?? 100).clamp(50, 150).toInt();
    final scale = (zoom / 100).toStringAsFixed(2);
    final inverseScale = (100 / zoom).toStringAsFixed(4);
    final jsCode = '''
      (function() {
        var id = 'astrbot-webui-zoom-style';
        var style = document.getElementById(id);
        if (!style) {
          style = document.createElement('style');
          style.id = id;
          document.head.appendChild(style);
        }
        style.textContent = [
          'html {',
          '  zoom: $scale !important;',
          '}',
          '@supports not (zoom: 1) {',
          '  html {',
          '    transform: scale($scale) !important;',
          '    transform-origin: 0 0 !important;',
          '    width: $inverseScale% !important;',
          '    min-height: $inverseScale% !important;',
          '  }',
          '}'
        ].join('\\n');
      })();
    ''';
    try {
      await controller.runJavaScript(jsCode);
    } catch (e) {
      debugPrint('Failed to apply WebUI zoom: $e');
    }
  }
}

class _WebUiTarget {
  final String id;
  final String title;
  final IconData icon;
  final String url;
  final WebViewController controller;
  final int? customWebViewIndex;

  const _WebUiTarget({
    required this.id,
    required this.title,
    required this.icon,
    required this.url,
    required this.controller,
    this.customWebViewIndex,
  });
}

/// 添加自定义 WebUI 对话框的返回值
class _AddWebUiResult {
  final String title;
  final String url;
  const _AddWebUiResult(this.title, this.url);
}

/// 添加自定义 WebUI 的对话框。
/// 自行管理 TextEditingController 生命周期(在 State.dispose 中释放),
/// 避免在对话框退出动画期间使用已释放的 controller。
class _AddWebUiDialog extends StatefulWidget {
  const _AddWebUiDialog();

  @override
  State<_AddWebUiDialog> createState() => _AddWebUiDialogState();
}

class _AddWebUiDialogState extends State<_AddWebUiDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自定义 WebUI'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: '标题',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'URL',
              helperText: '自动添加前缀 http://127.0.0.1:\n若需使用 https，请输入完整 URL',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _AddWebUiResult(_titleController.text, _urlController.text),
          ),
          child: const Text('添加'),
        ),
      ],
    );
  }
}


