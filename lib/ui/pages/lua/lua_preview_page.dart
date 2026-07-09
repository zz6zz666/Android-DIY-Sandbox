import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/lua/script_manager.dart';
import '../../controllers/terminal_controller.dart';
import '../../lua/lua_view.dart';
import '../../widgets/glass_panel.dart';

/// Phase 2 验证页: 直接渲染 Lua 脚本定义的 "home" 页面。
class LuaPreviewPage extends StatelessWidget {
  const LuaPreviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    HomeController? hc;
    try {
      hc = Get.find<HomeController>();
    } catch (_) {}

    final body = Column(
      children: [
        GlassAppBar(
          title: 'Lua 主页预览',
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Get.back(),
          ),
          actions: [
            IconButton(
              tooltip: '热重载脚本',
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                await ScriptManager.instance.reload();
                Get.rawSnackbar(
                    message: '脚本已重载', duration: const Duration(seconds: 1));
              },
            ),
          ],
        ),
        const Expanded(child: LuaPage(pageName: 'home')),
      ],
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: hc == null
          ? body
          : Obx(() => BubbleBackground(
                imagePath: hc!.homeBackgroundPath.value,
                child: body,
              )),
    );
  }
}
