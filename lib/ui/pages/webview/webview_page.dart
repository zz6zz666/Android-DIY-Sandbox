import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../../controllers/terminal_controller.dart';

class WebViewPage extends StatefulWidget {
  const WebViewPage({super.key});

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  int _currentIndex = 0;
  late final WebViewController _astrBotController;
  late final WebViewController _napCatController;
  DateTime? _lastBackPressed;
  
  final HomeController homeController = Get.find<HomeController>();
  
  // 标记 AstrBot WebView 是否初始化
  // Flag for AstrBot WebView initialization
  bool _astrBotInitialized = false;

  @override
  void initState() {
    super.initState();
    _initSystemUI();
    _initAstrBotController();
    _initNapCatController();
  }

  @override
  void dispose() {
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

  void _initAstrBotController() {
    _astrBotController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
            _injectClipboardScript(_astrBotController);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('AstrBot WebView error: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse('http://0.0.0.0:6185'));

    if (_astrBotController.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (_astrBotController.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    _astrBotController.addJavaScriptChannel(
      'Android',
      onMessageReceived: (JavaScriptMessage message) {
        if (message.message == 'getClipboardData') {
          _getClipboardData(_astrBotController);
        }
      },
    );
    
    setState(() {
      _astrBotInitialized = true;
    });
  }

  void _initNapCatController() {
    _napCatController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onWebResourceError: (WebResourceError error) {
            debugPrint('NapCat WebView error: ${error.description}');
          },
        ),
      );

    // 监听 Token 变化
    ever(homeController.napCatWebUiToken, (String token) {
      if (token.isNotEmpty) {
        final url = 'http://0.0.0.0:6099/webui?token=$token';
        _napCatController.loadRequest(Uri.parse(url));
      }
    });

    // 初始加载
    if (homeController.napCatWebUiToken.isNotEmpty) {
      final url = 'http://0.0.0.0:6099/webui?token=${homeController.napCatWebUiToken.value}';
      _napCatController.loadRequest(Uri.parse(url));
    } else {
      _napCatController.loadRequest(Uri.parse('http://0.0.0.0:6099/webui'));
    }

    if (_napCatController.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
      (_napCatController.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }
  }

  void _injectClipboardScript(WebViewController controller) {
    const String jsCode = '''
      const originalReadText = navigator.clipboard.readText;
      navigator.clipboard.readText = function () {
        console.log('Intercepted clipboard read');
        return new Promise((resolve) => {
          Android.postMessage('getClipboardData');
          setTimeout(() => {
            originalReadText.call(navigator.clipboard).then(text => {
              resolve(text);
            }).catch(() => resolve(''));
          }, 100);
        });
      };
    ''';
    controller.runJavaScript(jsCode);
  }

  Future<void> _getClipboardData(WebViewController controller) async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text ?? '';
    controller.runJavaScript('window.clipboardText = "$text";');
  }

  Future<void> _handleBackPress() async {
    // 如果当前是 AstrBot 页面且 WebView 可回退，则回退
    if (_currentIndex == 0 && await _astrBotController.canGoBack()) {
      await _astrBotController.goBack();
      return;
    }
    
    // 如果当前是 NapCat 页面且 WebView 可回退，则回退
    if (_currentIndex == 1 && await _napCatController.canGoBack()) {
      await _napCatController.goBack();
      return;
    }
    
    // 否则执行双击退出逻辑
    final now = DateTime.now();
    final backButtonInterval = _lastBackPressed == null
        ? const Duration(seconds: 3)
        : now.difference(_lastBackPressed!);

    if (backButtonInterval > const Duration(seconds: 2)) {
      _lastBackPressed = now;
      Get.showSnackbar(
        const GetSnackBar(
          message: '再按一次退出',
          duration: Duration(seconds: 2),
          snackPosition: SnackPosition.BOTTOM,
          margin: EdgeInsets.all(10),
          borderRadius: 10,
          backgroundColor: Colors.black87,
          messageText: Text('再按一次退出', style: TextStyle(color: Colors.white)),
        ),
      );
    } else {
      _lastBackPressed = null;
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_astrBotInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackPress();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarColor: Colors.white,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: SafeArea(
            top: true,
            child: IndexedStack(
              index: _currentIndex,
              children: [
                // 1. AstrBot 配置页面
                WebViewWidget(controller: _astrBotController),
                
                // 2. NapCat 配置页面
                WebViewWidget(controller: _napCatController),
                
                // 3. 软件设置页面
                ListView(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        '设置',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('关于软件'),
                      subtitle: const Text('AstrBot Android v1.0.0'),
                      onTap: () {},
                    ),
                    ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('清理缓存'),
                      subtitle: const Text('清理 WebView 缓存'),
                      onTap: () async {
                        await _astrBotController.clearCache();
                        if (context.mounted) {
                          Get.snackbar('成功', '缓存已清理');
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            backgroundColor: Colors.white,
            selectedItemColor: Theme.of(context).primaryColor,
            unselectedItemColor: Colors.grey,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.smart_toy),
                label: 'AstrBot',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.pets), // Cat icon for NapCat
                label: 'NapCat',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings),
                label: '设置',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
