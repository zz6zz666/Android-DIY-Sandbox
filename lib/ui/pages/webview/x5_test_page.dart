import 'package:flutter/material.dart';
import 'package:x5_webview/x5_sdk.dart';
import 'package:x5_webview/x5_webview.dart';

import '../../../core/config/service_ports.dart';

/// 实验页: 使用腾讯 X5(TBS) 独立内核渲染, 用于在老安卓上对比系统 WebView 的效果。
///
/// 注意:
/// - X5 内核首次运行需要联网从腾讯服务器下载(约 40MB), 下载并安装成功后
///   通常需要重启 App 才会真正启用; 未就绪时会自动回退到系统 WebView。
/// - 顶部状态栏会显示当前实际使用的是 X5 独立内核还是系统内核, 以及 UA。
class X5TestPage extends StatefulWidget {
  const X5TestPage({super.key});

  @override
  State<X5TestPage> createState() => _X5TestPageState();
}

class _X5TestPageState extends State<X5TestPage> {
  X5WebViewController? _controller;

  final String _initUrl = ServicePorts.dashboardUrl;
  String _sdkStatus = '正在初始化 X5 内核...';
  String _kernelStatus = '未知';
  String _userAgent = '';
  int _progress = 0;
  bool _pageFinished = false;

  @override
  void initState() {
    super.initState();
    _initX5Sdk();
  }

  Future<void> _initX5Sdk() async {
    X5Sdk.setX5SdkListener(
      X5SdkListener(
        onDownloadProgress: (progress) {
          if (!mounted) return;
          setState(() => _sdkStatus = 'X5 内核下载中: $progress%');
        },
        onDownloadFinish: (code) {
          if (!mounted) return;
          setState(() => _sdkStatus = 'X5 内核下载完成 (code=$code)');
        },
        onInstallFinish: (code) {
          if (!mounted) return;
          setState(() => _sdkStatus = 'X5 内核安装完成 (code=$code), 可能需重启 App 生效');
        },
      ),
    );
    // 允许非 WiFi 下载, 方便直接测试
    await X5Sdk.setDownloadWithoutWifi(true);
    final ok = await X5Sdk.init();
    if (!mounted) return;
    setState(() {
      _sdkStatus = ok ? 'X5 SDK 初始化调用成功' : 'X5 SDK 初始化失败/不支持';
    });
  }

  Future<void> _refreshKernelInfo() async {
    final c = _controller;
    if (c == null) return;
    try {
      final isX5 = await c.isX5WebViewLoadSuccess();
      String ua = '';
      try {
        ua = await c.evaluateJavascript('navigator.userAgent');
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _kernelStatus = isX5 ? 'X5 独立内核 ✅' : '系统 WebView (已回退) ⚠️';
        _userAgent = ua;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _kernelStatus = '查询失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('X5 内核渲染测试'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '刷新内核信息',
            onPressed: _refreshKernelInfo,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新加载',
            onPressed: () => _controller?.reload(),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(),
          if (_progress > 0 && _progress < 100)
            LinearProgressIndicator(value: _progress / 100),
          Expanded(
            child: X5WebView(
              url: _initUrl,
              javaScriptEnabled: true,
              domStorageEnabled: true,
              onWebViewCreated: (controller) {
                _controller = controller;
              },
              onProgressChanged: (progress) {
                if (!mounted) return;
                setState(() => _progress = progress);
              },
              onPageFinished: () {
                if (!mounted) return;
                setState(() => _pageFinished = true);
                _refreshKernelInfo();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      color: Colors.black87,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white, fontSize: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SDK: $_sdkStatus'),
            Text('当前内核: $_kernelStatus'),
            Text('加载地址: $_initUrl'),
            Text('页面完成: $_pageFinished'),
            if (_userAgent.isNotEmpty)
              Text('UA: $_userAgent', maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
