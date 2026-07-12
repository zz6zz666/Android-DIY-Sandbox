import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:global_repository/global_repository.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:file_picker/file_picker.dart';
import '../../controllers/terminal_controller.dart';
import '../../../core/constants/scripts.dart' as scripts;
import '../../../core/services/password_manager.dart';
import '../../../core/config/app_config.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _appVersion = '';
  bool _isBatteryOptimizationIgnored = false;

  // 存储从GitHub API获取的原始下载URL
  String? _originalDownloadUrl;

  // 检查更新: 用户点击遮罩任意处可取消 (置 true 后遍历循环立即中止)
  bool _updateCancelled = false;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    _checkBatteryOptimizationStatus();
  }

  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _appVersion = _displayVersion(packageInfo.version);
    });
  }

  String _displayVersion(String version) {
    return version.split('+').first.replaceAll('-', ' ');
  }

  Future<void> _pickHomeBackground() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return;

      Get.find<HomeController>().setHomeBackgroundPath(path);
      Get.snackbar(
        '已更新背景',
        '主页背景图片已生效',
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 2),
      );
    } catch (e) {
      Get.snackbar(
        '选择失败',
        e.toString(),
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  void _clearHomeBackground() {
    Get.find<HomeController>().clearHomeBackgroundPath();
    Get.snackbar(
      '已清除背景',
      '主页已恢复默认背景',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }

  Widget _buildOpacitySlider({
    required String title,
    required String subtitle,
    required IconData icon,
    required double value,
    required ValueChanged<double> onChanged,
    double max = 0.95,
    int divisions = 19,
  }) {
    final percent = (value * 100).round();
    return ListTile(
      leading: Icon(icon),
      title: Row(
        children: [
          Expanded(child: Text(title)),
          Text('$percent%'),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitle),
          Slider(
            value: value.clamp(0.0, max).toDouble(),
            min: 0.0,
            max: max,
            divisions: divisions,
            label: '$percent%',
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  // 检查电池优化豁免状态
  Future<void> _checkBatteryOptimizationStatus() async {
    if (!Platform.isAndroid) return;

    try {
      final status = await Permission.ignoreBatteryOptimizations.status;
      setState(() {
        _isBatteryOptimizationIgnored = status.isGranted;
      });
    } catch (e) {
      Log.e('检查电池优化豁免状态失败: $e', tag: 'Sandbox');
    }
  }

  // 请求电池优化豁免
  Future<void> _requestBatteryOptimization() async {
    if (!Platform.isAndroid) return;

    try {
      final status = await Permission.ignoreBatteryOptimizations.status;

      if (status.isGranted) {
        Get.snackbar(
          '已授权',
          '已获得电池优化豁免权限',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
        return;
      }

      // 请求权限
      final result = await Permission.ignoreBatteryOptimizations.request();

      // 等待对话框关闭后重新检查状态
      await Future.delayed(const Duration(milliseconds: 500));
      await _checkBatteryOptimizationStatus();

      if (result.isGranted) {
        Get.snackbar(
          '授权成功',
          '已获得电池优化豁免权限',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      } else {
        Get.snackbar(
          '授权失败',
          '未获得电池优化豁免权限',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.orange,
          colorText: Colors.white,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      Log.e('请求电池优化豁免失败: $e', tag: 'Sandbox');
      Get.snackbar(
        '请求失败',
        '请求电池优化豁免时发生错误: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
    }
  }

  // 检查更新
  Future<void> _checkForUpdates() async {
    try {
      // 每次检查更新时重置原始URL
      _originalDownloadUrl = null;
      _updateCancelled = false;

      // 显示可取消的加载遮罩: 点击任意位置终止检查并退出遮罩
      Get.dialog(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _updateCancelled = true;
            if (Get.isDialogOpen ?? false) Get.back();
          },
          child: Container(
            color: Colors.black54,
            alignment: Alignment.center,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 14),
                Text(
                  '检查更新中…\n点击任意位置取消',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
        barrierDismissible: false,
      );

      // 获取当前版本
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // 版本信息获取: 先 GitHub 直连, 再依次回退各镜像源
      final mirrors = [
        '${Config.githubApi}${Config.githubReleasesPath}',
        ...Config.githubApiMirrors.map((mirror) =>
            '$mirror/${Config.githubApi}${Config.githubReleasesPath}'),
      ];

      Map<String, dynamic>? releaseData;

      for (final mirror in mirrors) {
        if (_updateCancelled) return; // 用户已取消, 遮罩已关闭
        try {
          final response = await http.get(
            Uri.parse(mirror),
            headers: {'Accept': 'application/vnd.github.v3+json'},
          ).timeout(const Duration(seconds: 8));

          if (response.statusCode == 200) {
            releaseData = jsonDecode(response.body) as Map<String, dynamic>;
            break;
          }
        } catch (e) {
          Log.w('镜像源 $mirror 请求失败: $e', tag: 'Sandbox');
          continue;
        }
      }

      if (_updateCancelled) return; // 取消: 不再弹任何结果
      if (Get.isDialogOpen ?? false) Get.back(); // 关闭加载遮罩

      if (releaseData == null) {
        Get.snackbar(
          '检查失败',
          '无法连接到更新服务器',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.orange,
          colorText: Colors.white,
        );
        return;
      }

      // 解析最新版本号
      final latestVersion =
          (releaseData['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
      final releaseNotes = releaseData['body'] as String? ?? '暂无更新说明';

      // 比较版本号
      if (_compareVersions(latestVersion, currentVersion) > 0) {
        // 有新版本，显示更新对话框
        _showUpdateDialog(latestVersion, releaseNotes, releaseData);
      } else {
        Get.snackbar(
          '已是最新版本',
          '当前版本 $currentVersion 已是最新版本',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      }
    } catch (e) {
      if (_updateCancelled) return;
      if (Get.isDialogOpen ?? false) Get.back(); // 关闭加载遮罩
      Log.e('检查更新失败: $e', tag: 'Sandbox');
      Get.snackbar(
        '检查失败',
        '检查更新时发生错误: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
      );
    }
  }

  // 版本号比较
  int _compareVersions(String v1, String v2) {
    final parts1 = _versionNumbers(v1);
    final parts2 = _versionNumbers(v2);

    for (int i = 0; i < 3; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }

  List<int> _versionNumbers(String version) {
    final normalized = version.replaceFirst(RegExp(r'^v'), '').split('+').first;
    return normalized.split('.').map((part) {
      final match = RegExp(r'^\d+').firstMatch(part);
      return int.tryParse(match?.group(0) ?? '') ?? 0;
    }).toList();
  }

  // 显示更新对话框
  void _showUpdateDialog(
      String version, String releaseNotes, Map<String, dynamic> releaseData) {
    Get.dialog(
      Dialog(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Text(
                    '发现新版本 $version',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Get.back(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: MarkdownBody(
                  data: releaseNotes,
                  styleSheet: MarkdownStyleSheet(
                    h1: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                    h2: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    h3: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    p: const TextStyle(fontSize: 14),
                    listBullet: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Get.back(),
                    child: const Text('关闭'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      Get.back();
                      _showDownloadSourceDialog(releaseData);
                    },
                    child: const Text('去下载'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 显示下载源选择对话框
  void _showDownloadSourceDialog(Map<String, dynamic> releaseData) {
    // 如果还没有保存原始URL，从releaseData中构造
    if (_originalDownloadUrl == null) {
      final assets = releaseData['assets'] as List?;
      final tagName = releaseData['tag_name'] as String?;

      if (tagName == null || assets == null) {
        Get.snackbar(
          '下载失败',
          '未找到版本信息',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }

      // 查找APK文件名
      String? apkFileName;
      for (final asset in assets) {
        final name = asset['name'] as String? ?? '';
        if (name.endsWith('.apk')) {
          apkFileName = name;
          break;
        }
      }

      if (apkFileName == null) {
        Get.snackbar(
          '下载失败',
          '未找到可下载的APK文件',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white,
        );
        return;
      }

      // 直接构造GitHub原始下载链接，避免使用可能被镜像站污染的URL
      _originalDownloadUrl =
          '${Config.githubDownloadBase}/$tagName/$apkFileName';
    }

    // 使用原始URL构建各个镜像源的下载链接 (GitHub 直连 + 各镜像)
    final sources = <Map<String, String>>[
      {'name': 'GitHub 原始链接', 'url': _originalDownloadUrl!},
      ...Config.downloadMirrors.map((mirror) => {
            'name': mirror['name']!,
            'url': '${mirror['url']}/$_originalDownloadUrl',
          }),
    ];

    // 与 Lua 侧一致的镜像测速弹窗: 测速排序, 点击项跳外部浏览器下载
    Get.dialog(_DownloadMirrorDialog(sources: sources));
  }

  // 执行备份操作
  Future<void> _openFileManager() async {
    try {
      // 使用 DocumentsProvider 的 content URI 打开文件管理器
      // authority: 当前应用包名.documents
      // rootId: ubuntu_root
      final packageName =
          RuntimeEnvir.packageName ?? 'com.diysandbox.android';
      final contentUri = Uri.parse(
        'content://$packageName.documents/root/ubuntu_root',
      );

      if (await canLaunchUrl(contentUri)) {
        await launchUrl(
          contentUri,
          mode: LaunchMode.externalApplication,
        );

        Get.snackbar(
          '已打开',
          '已在文件管理器中打开 Sandbox Ubuntu 文件系统',
          snackPosition: SnackPosition.BOTTOM,
          duration: const Duration(seconds: 2),
        );
      } else {
        // 如果无法打开，提供备选方案
        Get.dialog(
          AlertDialog(
            title: const Text('打开文件系统'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ubuntu 文件系统已挂载至系统"文件"应用的侧栏，名称为:',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sandbox Ubuntu',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '你可以手动打开系统"文件"应用，在侧栏中找到"Sandbox Ubuntu"来访问。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                const Text(
                  '或使用 MT 文件管理器等应用，添加以下路径至侧栏:',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  scripts.ubuntuPath,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Colors.blue,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: scripts.ubuntuPath));
                  Get.back();
                  Get.snackbar(
                    '已复制',
                    '路径已复制到剪贴板',
                    snackPosition: SnackPosition.BOTTOM,
                    duration: const Duration(seconds: 2),
                  );
                },
                child: const Text('复制路径'),
              ),
              TextButton(
                onPressed: () => Get.back(),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      Log.e('打开文件管理器失败: $e', tag: 'Sandbox');
      Get.snackbar(
        '打开失败',
        '无法打开文件管理器: $e',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.red,
        colorText: Colors.white,
        duration: const Duration(seconds: 3),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Padding(
          padding: EdgeInsets.all(16.0),
          child: Text(
            '设置',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
        _updateTile(),
        ..._appearanceItems(context),
        _batteryTile(),
        _fileSystemTile(),
        _clearCacheTile(context),
        _privacyTile(context),
        const Divider(),
        _exitTile(),
      ],
    );
  }

  Widget _updateTile() {
    return ListTile(
      leading: const Icon(Icons.info_outline),
      title: const Text('软件版本'),
      subtitle: Text(
        _appVersion.isEmpty ? '加载中...' : '$_appVersion（点击检查更新）',
      ),
      onTap: () => _checkForUpdates(),
    );
  }

  // 外观调节 (留在设置页)
  List<Widget> _appearanceItems(BuildContext context) {
    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text('外观',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey)),
      ),
      Obx(() {
        final backgroundPath = Get.find<HomeController>().homeBackgroundPath.value;
        return ListTile(
          leading: const Icon(Icons.image_outlined),
          title: const Text('主页背景图片'),
          subtitle: Text(backgroundPath.isEmpty ? '使用默认背景' : backgroundPath),
          trailing: backgroundPath.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除背景',
                  onPressed: _clearHomeBackground,
                  icon: const Icon(Icons.close),
                ),
          onTap: _pickHomeBackground,
        );
      }),
      Obx(() {
        final c = Get.find<HomeController>();
        return _buildOpacitySlider(
          title: '卡片透明度',
          subtitle: '调整主页卡片和底部菜单的毛玻璃底色',
          icon: Icons.layers_outlined,
          value: c.cardGlassOpacity.value,
          onChanged: c.setCardGlassOpacity,
        );
      }),
      Obx(() {
        final c = Get.find<HomeController>();
        return _buildOpacitySlider(
          title: '毛玻璃度',
          subtitle: '调整整体毛玻璃模糊强度',
          icon: Icons.blur_on,
          value: c.glassBlurAmount.value,
          onChanged: c.setGlassBlurAmount,
        );
      }),
      Obx(() {
        final c = Get.find<HomeController>();
        return _buildOpacitySlider(
          title: '顶部导航透明度',
          subtitle: '调整顶部标题栏毛玻璃底色',
          icon: Icons.view_day_outlined,
          value: c.topNavGlassOpacity.value,
          onChanged: c.setTopNavGlassOpacity,
        );
      }),
      Obx(() {
        final c = Get.find<HomeController>();
        return _buildOpacitySlider(
          title: '设置背景遮罩',
          subtitle: '调整设置页背景遮罩浓度',
          icon: Icons.filter_b_and_w_outlined,
          value: c.statusOverlayOpacity.value,
          onChanged: c.setStatusOverlayOpacity,
        );
      }),
      Obx(() {
        final c = Get.find<HomeController>();
        return _buildOpacitySlider(
          title: '终端黑色遮罩',
          subtitle: '调整终端背景黑色遮罩浓度',
          icon: Icons.terminal,
          value: c.terminalOverlayOpacity.value,
          onChanged: c.setTerminalOverlayOpacity,
        );
      }),
    ];
  }

  Widget _batteryTile() {
    return ListTile(
      leading: const Icon(Icons.battery_saver),
      title: const Text('电池优化豁免'),
      subtitle: Text(_isBatteryOptimizationIgnored ? '已授权' : '未授权（点击授权）'),
      trailing: _isBatteryOptimizationIgnored
          ? const Icon(Icons.check_circle, color: Colors.green)
          : const Icon(Icons.warning, color: Colors.orange),
      onTap: () => _requestBatteryOptimization(),
    );
  }

  Widget _fileSystemTile() {
    return ListTile(
      leading: const Icon(Icons.folder),
      title: const Text('文件系统'),
      subtitle: const Text(
        '内置 Ubuntu 文件系统已挂载至 \'文件\'\n可添加至 MT 文件管理器侧栏以快捷访问',
      ),
      onTap: () => _openFileManager(),
    );
  }

  Widget _clearCacheTile(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.delete_outline),
      title: const Text('清空本应用 WebView 缓存'),
      subtitle: const Text('只清理本应用 WebView 缓存和本应用保存的密码'),
      onTap: () async {
        try {
          for (final t in Get.find<HomeController>().webViewTabManager.tabs) {
            await t.controller.clearCache();
          }
          await PasswordManager.clearAllPasswords();
          Get.snackbar('成功', 'WebView 缓存和密码已清理',
              snackPosition: SnackPosition.BOTTOM);
        } catch (e) {
          Get.snackbar('清理失败', e.toString(),
              snackPosition: SnackPosition.BOTTOM,
              backgroundColor: Colors.red,
              colorText: Colors.white);
        }
      },
    );
  }

  Widget _privacyTile(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.privacy_tip_outlined),
      title: const Text('隐私政策'),
      subtitle: const Text('查看应用隐私政策'),
      onTap: () async {
        try {
          final privacyContent =
              await rootBundle.loadString('assets/privacy_policy.md');
          Get.dialog(
            Dialog(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.maxFinite,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: SingleChildScrollView(
                          child: MarkdownBody(data: privacyContent),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Get.back(),
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        } catch (e) {
          Get.snackbar('加载失败', '无法加载隐私政策: $e',
              snackPosition: SnackPosition.BOTTOM,
              backgroundColor: Colors.red,
              colorText: Colors.white);
        }
      },
    );
  }

  Widget _exitTile() {
    return ListTile(
      leading: const Icon(Icons.exit_to_app, color: Colors.red),
      title: const Text('退出应用', style: TextStyle(color: Colors.red)),
      subtitle: const Text('退出 Android DIY Sandbox'),
      onTap: () async {
        final confirm = await Get.dialog<bool>(
          AlertDialog(
            title: const Text('确认退出'),
            content: const Text('确定要退出应用吗？'),
            actions: [
              TextButton(
                  onPressed: () => Get.back(result: false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Get.back(result: true),
                  child: const Text('退出', style: TextStyle(color: Colors.red))),
            ],
          ),
        );
        if (confirm == true) {
          Get.snackbar('退出应用', '应用即将退出',
              snackPosition: SnackPosition.BOTTOM,
              duration: const Duration(seconds: 2));
          Future.delayed(const Duration(seconds: 2), () => exit(0));
        }
      },
    );
  }

  // ignore: unused_element
}

/// 下载镜像测速弹窗 (与 Lua 侧一致): 对每个镜像的下载 URL 测速排序,
/// 点击某项跳转外部浏览器进行下载。
class _DownloadMirrorDialog extends StatefulWidget {
  final List<Map<String, String>> sources; // {name, url}
  const _DownloadMirrorDialog({required this.sources});

  @override
  State<_DownloadMirrorDialog> createState() => _DownloadMirrorDialogState();
}

class _DownloadMirrorDialogState extends State<_DownloadMirrorDialog> {
  // url -> 延迟毫秒; null=测速中; -1=失败
  final Map<String, int?> _ms = {};

  @override
  void initState() {
    super.initState();
    _testAll();
  }

  void _testAll() {
    for (final s in widget.sources) {
      final url = s['url']!;
      _ms[url] = null;
      _testOne(url);
    }
    setState(() {});
  }

  Future<void> _testOne(String url) async {
    final sw = Stopwatch()..start();
    try {
      // 取前 1KB 测速; 跟随代理重定向, 反映端到端可达速度
      final resp = await http.get(
        Uri.parse(url),
        headers: {'Range': 'bytes=0-1023'},
      ).timeout(const Duration(seconds: 10));
      sw.stop();
      final ok = resp.statusCode >= 200 && resp.statusCode < 400;
      if (mounted) setState(() => _ms[url] = ok ? sw.elapsedMilliseconds : -1);
    } catch (_) {
      if (mounted) setState(() => _ms[url] = -1);
    }
  }

  List<Map<String, String>> get _sorted {
    final list = [...widget.sources];
    list.sort((a, b) {
      final ma = _ms[a['url']] ?? 1 << 30; // 测速中沉底
      final mb = _ms[b['url']] ?? 1 << 30;
      final va = ma < 0 ? (1 << 29) : ma; // 失败置于测速中之前、有效值之后
      final vb = mb < 0 ? (1 << 29) : mb;
      return va.compareTo(vb);
    });
    return list;
  }

  Widget _status(String url) {
    final v = _ms[url];
    if (v == null) {
      return const SizedBox(
        width: 16, height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (v < 0) {
      return const Text('失败', style: TextStyle(fontSize: 12, color: Colors.red));
    }
    final color = v < 800
        ? Colors.green
        : (v < 2000 ? Colors.orange : Colors.grey);
    return Text('$v ms',
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.bold));
  }

  Future<void> _pick(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      Get.back();
    } else {
      Get.snackbar('打开失败', '无法打开浏览器',
          snackPosition: SnackPosition.BOTTOM,
          backgroundColor: Colors.red,
          colorText: Colors.white);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('下载镜像测速')),
          IconButton(
            tooltip: '重新测速',
            icon: const Icon(Icons.refresh),
            onPressed: _testAll,
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('点选一个镜像, 将跳转外部浏览器下载',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: _sorted.map((s) {
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.cloud_download_outlined),
                      title: Text(s['name']!),
                      trailing: _status(s['url']!),
                      onTap: () => _pick(s['url']!),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Get.back(), child: const Text('取消')),
      ],
    );
  }
}
