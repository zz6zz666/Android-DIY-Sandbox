import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../core/config/environment_config.dart';
import '../../../core/config/service_ports.dart';
import '../../../core/constants/scripts.dart' as scripts;
import '../../controllers/terminal_controller.dart';
import '../../widgets/glass_panel.dart';

class LauncherPage extends StatefulWidget {
  final ValueChanged<int>? onNavigate;
  final VoidCallback? onOpenSettings;

  const LauncherPage({super.key, this.onNavigate, this.onOpenSettings});

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage>
    with WidgetsBindingObserver {
  final HomeController homeController = Get.find<HomeController>();
  final Map<String, _EnvStepState> _environmentStates = {};
  final Map<String, _NapCatAccountOperation> _napCatBusyOperations = {};
  final Map<String, BotBindingConfigState> _botBindingStates = {};
  final Set<String> _botBindingStateLoading = {};
  bool _checkingEnvironment = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshEnvironmentStatus();
      _refreshAllBotBindingStates();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshEnvironmentStatus();
      _refreshAllBotBindingStates();
    }
  }

  Future<void> _startAstrBot() async {
    try {
      await homeController.loadAstrBot();
      _showSnack('AstrBot 启动任务已进入 main 终端');
      widget.onNavigate?.call(2);
    } catch (e) {
      _showSnack('启动失败：$e');
    }
  }

  Future<void> _stopAstrBot() async {
    try {
      await homeController.stopAstrBot();
      _showSnack('AstrBot 已停止');
    } catch (e) {
      _showSnack('停止失败：$e');
    }
  }

  Future<void> _runStep(_EnvStep step, _EnvStepState currentState) async {
    if (!currentState.enabled) {
      _showSnack('请先完成上方依赖项');
      return;
    }

    final reinstall = currentState.installed;
    if (reinstall) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('重装 ${step.title}'),
          content: Text(
            step.reinstallMessage,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认重装'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      await homeController.runEnvironmentStep(
        step: step.id,
        title: step.title,
        reinstall: reinstall,
        onCommandDone: () {
          if (mounted) {
            _refreshEnvironmentStatus();
          }
        },
      );
      _showSnack('${step.title} 已在终端运行');
      widget.onNavigate?.call(2);
    } catch (e) {
      _showSnack('启动失败：$e');
    }
  }

  void _openSettings() {
    widget.onOpenSettings?.call();
  }

  Future<void> _showAstrBotPortDialog() async {
    final controller =
        TextEditingController(text: ServicePorts.dashboardPort.toString());
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AstrBot 监听端口'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: '端口',
            hintText: '6185',
            helperText: '范围 1024-65535，保存后重启 AstrBot 生效',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (result != true) {
      controller.dispose();
      return;
    }

    final port = int.tryParse(controller.text.trim());
    controller.dispose();
    if (port == null || !ServicePorts.isValidPort(port)) {
      _showSnack('端口无效：请输入 1024-65535');
      return;
    }
    if (port == ServicePorts.oneBotWsPort) {
      _showSnack('端口 $port 已被 OneBot WS 使用');
      return;
    }
    final duplicatedNapCat = homeController.napCatInstances.any(
      (instance) =>
          int.tryParse(instance['webUiPort']?.toString() ?? '') == port,
    );
    if (duplicatedNapCat) {
      _showSnack('端口 $port 已被 NapCat 账号使用');
      return;
    }

    ServicePorts.saveDashboardPort(port);
    await homeController.syncAstrBotDashboardPortConfig();
    if (mounted) {
      setState(() {});
    }
    _showSnack('AstrBot 端口已保存，重启 AstrBot 后生效');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.of(context).size.height - 170,
        ),
      ),
    );
  }

  Future<void> _refreshEnvironmentStatus() async {
    if (_checkingEnvironment) return;
    _checkingEnvironment = true;

    try {
      final baseCommandReady = await _hasBaseCommands();
      final uvReady = baseCommandReady && await _hasUv();
      final napCatReady = baseCommandReady && await _hasNapCat();
      final astrBotReady = uvReady && await _hasAstrBot();

      setState(() {
        _environmentStates['base'] = _EnvStepState(
          installed: baseCommandReady,
          enabled: true,
        );
        _environmentStates['uv'] = _EnvStepState(
          installed: uvReady,
          enabled: baseCommandReady,
        );
        _environmentStates['napcat'] = _EnvStepState(
          installed: napCatReady,
          enabled: baseCommandReady,
        );
        _environmentStates['astrbot'] = _EnvStepState(
          installed: astrBotReady,
          enabled: uvReady,
        );
      });
    } finally {
      _checkingEnvironment = false;
    }
  }

  Future<bool> _hasBaseCommands() async {
    final rootfs = Directory(scripts.ubuntuPath);
    if (!await rootfs.exists()) return false;
    final hasRoot = await Directory('${scripts.ubuntuPath}/root').exists();
    if (!hasRoot) return false;

    final baseFiles = [
      File('${scripts.ubuntuPath}/usr/bin/curl'),
      File('${scripts.ubuntuPath}/usr/bin/git'),
      File('${scripts.ubuntuPath}/usr/bin/sudo'),
    ];
    for (final file in baseFiles) {
      if (!await file.exists()) return false;
    }
    return true;
  }

  Future<bool> _hasUv() async {
    return await File('${scripts.ubuntuPath}/root/.local/bin/uv').exists() &&
        await File('${scripts.ubuntuPath}/root/.local/bin/uvx').exists();
  }

  Future<bool> _hasNapCat() async {
    return await File('${scripts.ubuntuPath}/root/launcher.sh').exists() &&
        await Directory('${scripts.ubuntuPath}/root/napcat').exists();
  }

  Future<bool> _hasAstrBot() async {
    final root = '${scripts.ubuntuPath}/root/AstrBot';
    if (!await Directory(root).exists()) return false;
    if (!await File('$root/pyproject.toml').exists()) return false;
    if (!await File('$root/main.py').exists()) return false;
    if (!await Directory('$root/.venv').exists()) return false;

    final libDir = Directory('$root/.venv/lib');
    if (!await libDir.exists()) return false;
    await for (final entity in libDir.list(
      recursive: true,
      followLinks: false,
    )) {
      final path = entity.path.replaceAll('\\', '/');
      if (entity is Directory && path.contains('/site-packages/aiohttp')) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GlassAppBar(
          title: 'AstrBot',
          opacity: homeController.topNavGlassOpacity.value,
          blur: homeController.glassBlurAmount.value * 30,
          actions: [
            IconButton(
              tooltip: '设置',
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
            children: [
              _buildQuickStartCard(context),
              const SizedBox(height: 12),
              _buildNapCatAccountsCard(context),
              const SizedBox(height: 12),
              _buildEnvironmentCard(context),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildQuickStartCard(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(16),
      opacity: homeController.cardGlassOpacity.value,
      blur: homeController.glassBlurAmount.value * 30,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AstrBotSparkleIcon(),
              const SizedBox(width: 8),
              Text('AstrBot', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.settings_ethernet),
            title: const Text('监听端口'),
            subtitle: Text('127.0.0.1:${ServicePorts.dashboardPort}'),
            trailing: IconButton(
              tooltip: '修改 AstrBot 端口',
              onPressed: _showAstrBotPortDialog,
              icon: const Icon(Icons.edit),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Obx(
                  () {
                    final starting = homeController.isAstrBotStarting.value;
                    final running = homeController.isAstrBotRunning.value;
                    final stopping = homeController.isAstrBotStopping.value;
                    final busy = starting || stopping;

                    return FilledButton.icon(
                      onPressed: busy
                          ? null
                          : running
                              ? _stopAstrBot
                              : _startAstrBot,
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(running ? Icons.stop : Icons.play_arrow),
                      label: Text(
                        starting
                            ? '启动中'
                            : stopping
                                ? '停止中'
                                : running
                                    ? '停止'
                                    : '启动 AstrBot',
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    homeController.requestOpenAstrBotWebUi();
                    widget.onNavigate?.call(1);
                  },
                  icon: const Icon(Icons.language),
                  label: const Text('打开 WebUI'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNapCatAccountsCard(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.all(16),
      opacity: homeController.cardGlassOpacity.value,
      blur: homeController.glassBlurAmount.value * 30,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.pets),
              const SizedBox(width: 8),
              Text(
                'NapCat 账号',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                tooltip: '添加账号',
                onPressed: _showAddNapCatAccountDialog,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Obx(() {
            final instances = homeController.napCatInstances;
            if (instances.isEmpty) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '添加账号后单独扫码登录，每个账号独立端口和登录态。',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _showAddNapCatAccountDialog,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('添加账号'),
                  ),
                ],
              );
            }

            return Column(
              children: instances
                  .map((instance) => _buildNapCatAccountTileV2(instance))
                  .toList(),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildNapCatAccountTileV2(Map<String, dynamic> instance) {
    final id = instance['id']?.toString() ?? '';
    final running = instance['running'] == true;
    final operation = _napCatBusyOperations[id];
    final busy = operation != null;
    final deleting = operation == _NapCatAccountOperation.deleting;
    final name = instance['name']?.toString() ?? '账号';
    final qq = instance['qq']?.toString() ?? '';
    final port = instance['webUiPort']?.toString() ?? '';
    final canBindBot = qq.trim().isNotEmpty;
    if (running && canBindBot) {
      _ensureBotBindingState(instance);
    }
    final hasBoundAdapter =
        (instance['boundAdapterId']?.toString() ?? '').trim().isNotEmpty;
    final bindingState = running && canBindBot
        ? (_botBindingStates[id] ??
            (hasBoundAdapter
                ? BotBindingConfigState.configured
                : BotBindingConfigState.unconfigured))
        : BotBindingConfigState.unconfigured;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: deleting ? 0.55 : 1,
      child: AbsorbPointer(
        absorbing: busy,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    running ? Icons.play_circle : Icons.pause_circle_outline,
                    color: running ? Colors.green : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                name,
                                style: Theme.of(context).textTheme.titleSmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _buildBotBindingStatusChip(
                              running ? bindingState : null,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          deleting
                              ? '删除中...\n正在清理登录态和实例目录'
                              : 'QQ ${qq.isEmpty ? '未绑定，启动后扫码登录' : qq}\nWebUI $port',
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      IconButton(
                        tooltip: '打开 WebUI',
                        onPressed: () => _openNapCatWebUi(instance),
                        icon: const Icon(Icons.language),
                      ),
                      IconButton(
                        tooltip: busy
                            ? operation.label
                            : running
                                ? '停止'
                                : '启动',
                        onPressed: () => _toggleNapCatInstance(instance),
                        icon: busy
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(running ? Icons.stop : Icons.play_arrow),
                      ),
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        icon: const Icon(Icons.more_vert),
                        onSelected: (value) async {
                          switch (value) {
                            case 'edit':
                              await _showEditNapCatAccountDialog(instance);
                              break;
                            case 'copyToken':
                              await _copyNapCatToken(instance);
                              break;
                            case 'copyUrl':
                              await _copyNapCatWebUiUrl(instance);
                              break;
                            case 'bindBot':
                              if (canBindBot) {
                                await _showBindBotDialog(instance);
                              } else {
                                _showSnack('登录 QQ 后可绑定 BOT');
                              }
                              break;
                            case 'logout':
                              await _confirmLogoutNapCatAccount(instance);
                              break;
                            case 'delete':
                              await _confirmDeleteNapCatAccount(instance);
                              break;
                          }
                        },
                        itemBuilder: (context) {
                          final token = instance['token']?.toString() ?? '';
                          return [
                            const PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(
                              value: 'bindBot',
                              enabled: canBindBot,
                              child: Text(
                                bindingState == BotBindingConfigState.configured
                                    ? '管理 BOT 绑定'
                                    : '绑定 BOT',
                              ),
                            ),
                            PopupMenuItem(
                              value: 'copyToken',
                              enabled: token.isNotEmpty,
                              child: const Text('复制 token'),
                            ),
                            const PopupMenuItem(
                              value: 'copyUrl',
                              child: Text('复制完整链接'),
                            ),
                            const PopupMenuItem(value: 'logout', child: Text('退出登录')),
                            const PopupMenuItem(value: 'delete', child: Text('删除')),
                          ];
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openNapCatWebUi(Map<String, dynamic> instance) {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty) return;
    homeController.requestOpenNapCatWebUi(id);
    widget.onNavigate?.call(1);
  }

  Widget _buildBotBindingStatusChip(BotBindingConfigState? state) {
    final color = switch (state) {
      BotBindingConfigState.configured => Colors.green,
      BotBindingConfigState.mismatch => Colors.orange,
      BotBindingConfigState.unconfigured => Colors.red,
      null => Colors.grey,
    };
    final text = switch (state) {
      BotBindingConfigState.configured => '已绑定BOT',
      BotBindingConfigState.mismatch => 'BOT绑定异常',
      BotBindingConfigState.unconfigured => '未绑定BOT',
      null => '未运行',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 9, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  void _ensureBotBindingState(Map<String, dynamic> instance) {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty ||
        _botBindingStates.containsKey(id) ||
        _botBindingStateLoading.contains(id)) {
      return;
    }
    _refreshBotBindingState(instance);
  }

  void _refreshAllBotBindingStates() {
    for (final instance in homeController.napCatInstances) {
      final qq = instance['qq']?.toString().trim() ?? '';
      if (qq.isNotEmpty && instance['running'] == true) {
        _refreshBotBindingState(instance, force: true);
      }
    }
  }

  Future<void> _refreshBotBindingState(
    Map<String, dynamic> instance, {
    bool force = false,
  }) async {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty) return;
    if (_botBindingStateLoading.contains(id)) {
      if (!force) return;
      _botBindingStateLoading.remove(id);
    }
    _botBindingStateLoading.add(id);
    try {
      final data = await _loadBotBindingData(instance);
      if (!mounted) return;
      setState(() {
        _botBindingStates[id] = data.state;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _botBindingStates[id] = BotBindingConfigState.unconfigured;
      });
    } finally {
      _botBindingStateLoading.remove(id);
    }
  }

  Future<_BotBindingData> _loadBotBindingData(
    Map<String, dynamic> instance,
  ) async {
    final id = instance['id']?.toString() ?? '';
    final current = homeController.napCatInstances.firstWhereOrNull(
          (item) => item['id']?.toString() == id,
        ) ??
        instance;
    final clients = await homeController.listNapCatWebSocketClients(id);
    final adapters = await homeController.listAstrBotOneBotAdapters();
    final selectedClient = await homeController.selectedNapCatWebSocketClient(
      current,
    );
    final selectedAdapter = await homeController.selectedAstrBotAdapter(
      current,
    );
    return _BotBindingData(
      instance: current,
      clients: clients,
      adapters: adapters,
      selectedClient: selectedClient,
      selectedAdapter: selectedAdapter,
      state: homeController.compareBotBinding(selectedClient, selectedAdapter),
    );
  }

  Future<void> _showBindBotDialog(Map<String, dynamic> instance) async {
    final qq = instance['qq']?.toString().trim() ?? '';
    if (qq.isEmpty) {
      _showSnack('登录 QQ 后可绑定 BOT');
      return;
    }
    var refresh = 0;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('绑定BOT'),
            content: SizedBox(
              width: 520,
              child: FutureBuilder<_BotBindingData>(
                key: ValueKey(refresh),
                future: _loadBotBindingData(instance),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const SizedBox(
                      height: 160,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final data = snapshot.data!;
                  return SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildBindingStatusBanner(data.state),
                        if (data.state == BotBindingConfigState.mismatch) ...[
                          const SizedBox(height: 8),
                          Text(
                            '当前 BOT 配置与 websocket 不一致，可修复绑定。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton.icon(
                              onPressed: data.selectedClient == null ||
                                      data.selectedAdapter == null
                                  ? null
                                  : () async {
                                      final repaired =
                                          await _repairBotBinding(data);
                                      if (repaired == true) {
                                        setDialogState(() => refresh++);
                                      }
                                    },
                              icon: const Icon(Icons.build),
                              label: const Text('修复绑定'),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          'websocket适配器',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        if (data.clients.isEmpty)
                          const Text('未找到 websocket client 配置')
                        else
                          ...data.clients.map(
                            (client) => RadioListTile<String>(
                              dense: true,
                              value: client.name,
                              groupValue: data.selectedClient?.name,
                              onChanged: (_) async {
                                try {
                                  await homeController.bindNapCatWebSocketClient(
                                    id: data.instance['id']?.toString() ?? '',
                                    clientName: client.name,
                                  );
                                  setDialogState(() => refresh++);
                                } catch (e) {
                                  _showSnack('绑定 websocket 失败：$e');
                                }
                              },
                              title: Text(client.name),
                              subtitle: Text(
                                '${client.enabled ? '已启用' : '未启用'} · ${client.url}',
                              ),
                            ),
                          ),
                        const Divider(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'AstrBot适配器',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: data.selectedClient == null
                                  ? null
                                  : () async {
                                      final created =
                                          await _createAstrBotAdapter(data);
                                      if (created == true) {
                                        setDialogState(() => refresh++);
                                      }
                                    },
                              icon: const Icon(Icons.add),
                              label: const Text('新建'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (data.adapters.isEmpty)
                          const Text('未找到 AstrBot OneBot 适配器')
                        else
                          ...data.adapters.map(
                            (adapter) => RadioListTile<String>(
                              dense: true,
                              value: adapter.id,
                              groupValue: data.selectedAdapter?.id,
                              onChanged: (_) async {
                                final changed = await _bindAstrBotAdapter(
                                  data,
                                  adapter,
                                );
                                if (changed == true) {
                                  setDialogState(() => refresh++);
                                }
                              },
                              title: Text(adapter.id),
                              subtitle: Text(
                                '${adapter.enabled ? '已启用' : '未启用'} · ${adapter.port} · token ${adapter.token.isEmpty ? '空' : '已设置'}',
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    await _refreshBotBindingState(instance, force: true);
  }

  Widget _buildBindingStatusBanner(BotBindingConfigState state) {
    final color = switch (state) {
      BotBindingConfigState.configured => Colors.green,
      BotBindingConfigState.mismatch => Colors.orange,
      BotBindingConfigState.unconfigured => Colors.red,
    };
    final text = switch (state) {
      BotBindingConfigState.configured => '已绑定BOT',
      BotBindingConfigState.mismatch => 'BOT绑定异常',
      BotBindingConfigState.unconfigured => '未绑定BOT',
    };
    return Row(
      children: [
        Icon(Icons.circle, size: 12, color: color),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(color: color)),
      ],
    );
  }

  Future<bool?> _bindAstrBotAdapter(
    _BotBindingData data,
    AstrBotOneBotAdapter adapter,
  ) async {
    final id = data.instance['id']?.toString() ?? '';
    final client = data.selectedClient;
    if (id.isEmpty || client == null) {
      _showSnack('请先绑定 websocket 适配器');
      return false;
    }

    var invalidatePrevious = false;
    final currentAdapterId = data.instance['boundAdapterId']?.toString() ?? '';
    if (currentAdapterId.isNotEmpty && currentAdapterId != adapter.id) {
      final confirmed = await _confirm(
        title: '换绑适配器',
        content: _withAstrBotRestartNotice(
          '当前账号已经绑定 $currentAdapterId，是否换绑到 ${adapter.id}？',
        ),
        confirmText: '换绑',
      );
      if (confirmed != true) return false;
      invalidatePrevious = true;
    }

    final mismatch = client.port != adapter.port || client.token != adapter.token;
    if (mismatch &&
        homeController.isAstrBotAdapterBoundByOther(adapter.id, id)) {
      final confirmed = await _confirm(
        title: '适配器已被绑定',
        content: _withAstrBotRestartNotice(
          '${adapter.id} 已被其他 NapCat 账号绑定，是否按当前 websocket 配置覆盖并换绑？',
        ),
        confirmText: '覆盖换绑',
      );
      if (confirmed != true) return false;
    }

    if (mismatch) {
      final confirmed = await _confirm(
        title: '配置不一致',
        content: _withAstrBotRestartNotice(
          '该 AstrBot 适配器与当前 websocket 的端口或 token 不一致，是否自动修改 AstrBot 适配器？',
        ),
        confirmText: '自动修改',
      );
      if (confirmed != true) return false;
    }

    try {
      await homeController.bindAstrBotAdapter(
        id: id,
        adapterId: adapter.id,
        updateAdapterFromWebSocket: mismatch,
        invalidatePreviousAdapter: invalidatePrevious,
      );
      if (mismatch || invalidatePrevious) {
        await _restartAstrBotIfRunningAfterAdapterChange();
      }
      return true;
    } catch (e) {
      _showSnack('绑定 AstrBot 适配器失败：$e');
      return false;
    }
  }

  Future<bool?> _repairBotBinding(_BotBindingData data) async {
    final id = data.instance['id']?.toString() ?? '';
    final adapter = data.selectedAdapter;
    if (id.isEmpty || data.selectedClient == null || adapter == null) {
      _showSnack('请先选择 websocket 和 AstrBot 适配器');
      return false;
    }
    final confirmed = await _confirm(
      title: '修复绑定',
      content: _withAstrBotRestartNotice(
        '是否将当前 AstrBot 适配器同步为所选 websocket 的端口和 token？',
      ),
      confirmText: '修复绑定',
    );
    if (confirmed != true) return false;

    try {
      await homeController.bindAstrBotAdapter(
        id: id,
        adapterId: adapter.id,
        updateAdapterFromWebSocket: true,
      );
      await _restartAstrBotIfRunningAfterAdapterChange();
      _showSnack('BOT 绑定已修复');
      return true;
    } catch (e) {
      _showSnack('修复 BOT 绑定失败：$e');
      return false;
    }
  }

  Future<bool?> _createAstrBotAdapter(_BotBindingData data) async {
    final id = data.instance['id']?.toString() ?? '';
    final controller = TextEditingController(
      text: data.instance['name']?.toString() ?? '',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建 AstrBot 适配器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'BOT名称',
                hintText: '留空使用 NapCat 卡片名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _newAstrBotAdapterNotice,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('新建'),
          ),
        ],
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (confirmed != true) return false;
    final oldAdapterId = data.instance['boundAdapterId']?.toString() ?? '';
    var allowSharedPreviousAdapter = false;
    if (oldAdapterId.isNotEmpty &&
        homeController.isAstrBotAdapterBoundByOther(oldAdapterId, id)) {
      final continueCreate = await _confirm(
        title: '旧适配器被复用',
        content: _withAstrBotRestartNotice(
          '旧 AstrBot 适配器 $oldAdapterId 已被其他 NapCat 账号绑定，继续新建不会无效化旧适配器，可能导致端口冲突。是否继续？',
        ),
        confirmText: '继续新建',
      );
      if (continueCreate != true) return false;
      allowSharedPreviousAdapter = true;
    }
    try {
      await homeController.createAstrBotAdapterForNapCat(
        id: id,
        preferredName: name,
        allowSharedPreviousAdapter: allowSharedPreviousAdapter,
      );
      await _restartAstrBotIfRunningAfterAdapterChange();
      return true;
    } catch (e) {
      _showSnack('新建 AstrBot 适配器失败：$e');
      return false;
    }
  }

  static const String _astrBotRestartNotice = '修改后，已运行的 AstrBot 会重启。';
  static const String _newAstrBotAdapterNotice =
      '新建后会自动绑定，已运行的 AstrBot 会重启。';

  String _withAstrBotRestartNotice(String content) {
    return '$content\n\n$_astrBotRestartNotice';
  }

  Future<void> _restartAstrBotIfRunningAfterAdapterChange() async {
    if (!homeController.isAstrBotRunning.value) return;
    try {
      _showSnack('AstrBot 配置已保存，正在重启...');
      await homeController.stopAstrBot();
      await Future.delayed(const Duration(milliseconds: 300));
      await homeController.loadAstrBot();
    } catch (e) {
      _showSnack('配置已保存，但 AstrBot 重启失败：$e');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String content,
    required String confirmText,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  Future<void> _copyNapCatToken(Map<String, dynamic> instance) async {
    final token = instance['token']?.toString() ?? '';
    if (token.isEmpty) {
      _showSnack('暂未获取到 token');
      return;
    }
    await Clipboard.setData(ClipboardData(text: token));
    _showSnack('token 已复制');
  }

  Future<void> _copyNapCatWebUiUrl(Map<String, dynamic> instance) async {
    final url = homeController.napCatInstanceWebUiUrl(instance);
    await Clipboard.setData(ClipboardData(text: url));
    _showSnack('完整链接已复制');
  }

  Future<void> _toggleNapCatInstance(Map<String, dynamic> instance) async {
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty || _napCatBusyOperations.containsKey(id)) return;
    final running = instance['running'] == true;
    setState(() {
      _napCatBusyOperations[id] = running
          ? _NapCatAccountOperation.stopping
          : _NapCatAccountOperation.starting;
    });
    try {
      if (running) {
        await homeController.stopNapCatInstance(id);
      } else {
        widget.onNavigate?.call(2);
        await Future.delayed(const Duration(milliseconds: 50));
        await homeController.startNapCatInstance(id);
      }
    } catch (e) {
      _showSnack('${running ? '停止' : '启动'}失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _napCatBusyOperations.remove(id);
        });
      } else {
        _napCatBusyOperations.remove(id);
      }
    }
  }

  Future<void> _showAddNapCatAccountDialog() async {
    final portController = TextEditingController();
    final result = await _showNapCatAccountDialog(
      title: '添加 NapCat 账号',
      portController: portController,
    );
    final portText = portController.text.trim();
    // 延迟释放: 等对话框退出动画结束再 dispose, 避免使用已释放的 controller
    Future.delayed(const Duration(seconds: 1), portController.dispose);

    if (result != true) return;

    final webUiPort = portText.isEmpty ? null : int.tryParse(portText);
    if (portText.isNotEmpty && webUiPort == null) {
      _showSnack('端口只能填写数字，留空表示自动分配');
      return;
    }

    try {
      await homeController.addNapCatInstance(webUiPort: webUiPort);
      Future.delayed(
          const Duration(milliseconds: 300), _refreshEnvironmentStatus);
    } catch (e) {
      _showSnack('添加失败：$e');
    }
  }

  Future<void> _showEditNapCatAccountDialog(
    Map<String, dynamic> instance,
  ) async {
    final id = instance['id']?.toString() ?? '';
    final nameController = TextEditingController(
      text: instance['name']?.toString() ?? '',
    );
    final portController = TextEditingController(
      text: instance['webUiPort']?.toString() ?? '',
    );
    final result = await _showNapCatAccountDialog(
      title: '编辑 NapCat 账号',
      nameController: nameController,
      portController: portController,
    );
    final port = int.tryParse(portController.text.trim());
    final name = nameController.text.trim();
    // 延迟释放: 等对话框退出动画结束再 dispose, 避免使用已释放的 controller
    Future.delayed(const Duration(seconds: 1), nameController.dispose);
    Future.delayed(const Duration(seconds: 1), portController.dispose);

    if (result != true) return;

    try {
      await homeController.updateNapCatInstanceConfig(
        id: id,
        webUiPort: port,
        name: name,
      );
      Future.delayed(
          const Duration(milliseconds: 300), _refreshEnvironmentStatus);
    } catch (e) {
      _showSnack('保存失败：$e');
    }
  }

  Future<bool?> _showNapCatAccountDialog({
    required String title,
    required TextEditingController portController,
    TextEditingController? nameController,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (nameController != null) ...[
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '账号名称',
                  hintText: '例如：账号1',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'NapCat WebUI 端口',
                hintText: '留空自动分配，范围 6099-6149',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogoutNapCatAccount(
    Map<String, dynamic> instance,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: Text('确定退出 ${instance['name'] ?? '账号'} 吗？后续启动需要重新扫码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty || _napCatBusyOperations.containsKey(id)) return;
    setState(() {
      _napCatBusyOperations[id] = _NapCatAccountOperation.loggingOut;
    });
    try {
      await homeController.logoutNapCatInstance(id);
      _showSnack('已退出登录');
    } catch (e) {
      _showSnack('退出登录失败：$e');
    } finally {
      if (mounted) {
        setState(() {
          _napCatBusyOperations.remove(id);
        });
      } else {
        _napCatBusyOperations.remove(id);
      }
    }
  }

  Future<void> _confirmDeleteNapCatAccount(
    Map<String, dynamic> instance,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除账号'),
        content: Text('确定删除 ${instance['name'] ?? '账号'} 吗？登录态和配置会一并清理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = instance['id']?.toString() ?? '';
    if (id.isEmpty || _napCatBusyOperations.containsKey(id)) return;
    setState(() {
      _napCatBusyOperations[id] = _NapCatAccountOperation.deleting;
    });
    try {
      await homeController.deleteNapCatInstance(id);
      _showSnack('已删除账号');
    } catch (e) {
      _showSnack('删除失败：$e');
      if (mounted) {
        setState(() {
          _napCatBusyOperations.remove(id);
        });
      } else {
        _napCatBusyOperations.remove(id);
      }
    }
  }

  Widget _buildEnvironmentCard(BuildContext context) {
    final steps = [
      _EnvStep(
        'base',
        '基础命令',
        'sudo / git / curl',
        const Icon(Icons.extension),
        reinstallDescription: '将重新检查并补装 sudo / git / curl，不会主动删除系统包。是否继续？',
      ),
      _EnvStep(
        'uv',
        'uv',
        'Python 依赖管理工具',
        const Icon(Icons.construction),
        reinstallDescription: '将删除现有 uv/uvx 后重新下载。是否继续？',
      ),
      _EnvStep(
        'napcat',
        'NapCat',
        '安装或修复 NapCatQQ',
        const Icon(Icons.pets),
        reinstallDescription: '将清理 NapCat 安装文件并重新安装，尽量保留配置目录。是否继续？',
      ),
      _EnvStep(
        'astrbot',
        'AstrBot',
        '克隆 AstrBot 并同步依赖',
        const AstrBotSparkleIcon(),
        reinstallDescription:
            '将重新克隆 AstrBot 并重建 Python 依赖，尽量保留 data 数据目录。是否继续？',
      ),
    ];

    return GlassPanel(
      padding: const EdgeInsets.all(16),
      opacity: homeController.cardGlassOpacity.value,
      blur: homeController.glassBlurAmount.value * 30,
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(Icons.inventory_2_outlined),
        title: Text('环境管理', style: Theme.of(context).textTheme.titleMedium),
        subtitle: const Text('分步安装与修复组件'),
        trailing: _checkingEnvironment
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                tooltip: '刷新状态',
                onPressed: _refreshEnvironmentStatus,
                icon: const Icon(Icons.refresh),
              ),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DropdownButtonFormField<String>(
              initialValue: EnvironmentConfig.githubProxy,
              decoration: const InputDecoration(
                labelText: 'GitHub 代理',
                border: OutlineInputBorder(),
              ),
              items: EnvironmentConfig.githubProxyOptions
                  .map(
                    (option) => DropdownMenuItem<String>(
                      value: option['value'],
                      child: Text(option['name'] ?? option['value']!),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value == null) return;
                EnvironmentConfig.setGithubProxy(value);
                setState(() {});
              },
            ),
          ),
          const SizedBox(height: 8),
          ...steps.map(_buildEnvironmentStepTile),
        ],
      ),
    );
  }

  Widget _buildEnvironmentStepTile(_EnvStep step) {
    final state = _environmentStates[step.id] ?? const _EnvStepState.unknown();
    final color = !state.enabled
        ? Colors.grey
        : state.installed
            ? Colors.green
            : Colors.red;
    final statusIcon = !state.enabled
        ? Icons.lock_outline
        : state.installed
            ? Icons.check_circle
            : Icons.error;
    final buttonText = state.installed ? '重装' : '安装';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          IconTheme.merge(
            data: IconThemeData(color: state.enabled ? null : Colors.grey),
            child: step.icon,
          ),
          Positioned(
            right: -8,
            bottom: -6,
            child: Icon(statusIcon, size: 16, color: color),
          ),
        ],
      ),
      title: Text(
        step.title,
        style: TextStyle(color: state.enabled ? null : Colors.grey),
      ),
      subtitle: Text(
        state.enabled ? step.subtitle : '请先完成上方依赖项',
        style: TextStyle(color: state.enabled ? null : Colors.grey),
      ),
      trailing: FilledButton.tonalIcon(
        onPressed: state.enabled ? () => _runStep(step, state) : null,
        icon: const Icon(Icons.download),
        label: Text(buttonText),
      ),
    );
  }
}

enum _NapCatAccountOperation {
  starting,
  stopping,
  deleting,
  loggingOut,
}

class _BotBindingData {
  final Map<String, dynamic> instance;
  final List<NapCatWebSocketClient> clients;
  final List<AstrBotOneBotAdapter> adapters;
  final NapCatWebSocketClient? selectedClient;
  final AstrBotOneBotAdapter? selectedAdapter;
  final BotBindingConfigState state;

  const _BotBindingData({
    required this.instance,
    required this.clients,
    required this.adapters,
    required this.selectedClient,
    required this.selectedAdapter,
    required this.state,
  });
}

extension _NapCatAccountOperationLabel on _NapCatAccountOperation {
  String get label {
    switch (this) {
      case _NapCatAccountOperation.starting:
        return '正在启动';
      case _NapCatAccountOperation.stopping:
        return '正在停止';
      case _NapCatAccountOperation.deleting:
        return '正在删除';
      case _NapCatAccountOperation.loggingOut:
        return '正在退出登录';
    }
  }
}

class _EnvStep {
  final String id;
  final String title;
  final String subtitle;
  final Widget icon;
  final String? reinstallDescription;

  const _EnvStep(
    this.id,
    this.title,
    this.subtitle,
    this.icon, {
    this.reinstallDescription,
  });

  String get reinstallMessage =>
      reinstallDescription ?? '将先清理现有 $title 组件，再重新安装。是否继续？';
}

class AstrBotSparkleIcon extends StatelessWidget {
  final double? size;
  final Color? color;

  const AstrBotSparkleIcon({
    super.key,
    this.size,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor = color ?? iconTheme.color ?? Colors.black;
    return SizedBox.square(
      dimension: resolvedSize,
      child: CustomPaint(
        painter: _AstrBotSparkleIconPainter(resolvedColor),
      ),
    );
  }
}

class _AstrBotSparkleIconPainter extends CustomPainter {
  final Color color;

  const _AstrBotSparkleIconPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final center = Offset(size.width / 2, size.height / 2);
    final longRadius = size.shortestSide * 0.46;
    final shortRadius = size.shortestSide * 0.16;
    final path = Path();

    for (var i = 0; i < 8; i++) {
      final angle = -1.57079632679 + i * 0.78539816339;
      final radius = i.isEven ? longRadius : shortRadius;
      final point = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }

    canvas.drawPath(path..close(), paint);
  }

  @override
  bool shouldRepaint(_AstrBotSparkleIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _EnvStepState {
  final bool installed;
  final bool enabled;

  const _EnvStepState({
    required this.installed,
    required this.enabled,
  });

  const _EnvStepState.unknown()
      : installed = false,
        enabled = false;
}
