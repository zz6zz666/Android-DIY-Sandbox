import 'package:flutter/material.dart';

import 'glass_panel.dart';

/// 一个标签项 (通用, 无业务语义)。
class TabStripItem {
  final String id;
  final String title;
  final IconData icon;

  const TabStripItem({
    required this.id,
    required this.title,
    required this.icon,
  });
}

/// 通用标签栏组件。
/// - 未激活: 仅图标+文字, 无背景/边框
/// - 激活: 紫色泡泡 (填充药丸)
/// - 标签之间有淡灰色隔离竖线
/// - 长按可拖动排序 (带动效)
/// - 右侧固定的自定义按钮 (trailing)
/// - 即使没有任何标签也常驻显示
class TabStrip extends StatelessWidget {
  final List<TabStripItem> items;
  final int activeIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<int>? onClose;
  final void Function(int oldIndex, int newIndex)? onReorder;

  /// 右侧固定按钮 (如刷新 / 新建)。
  final List<Widget> trailing;

  final double opacity;
  final double blur;

  static const Color _activeColor = Color(0xFF8B5CF6);
  static const double _height = 44;

  const TabStrip({
    super.key,
    required this.items,
    required this.activeIndex,
    required this.onSelect,
    this.onClose,
    this.onReorder,
    this.trailing = const [],
    this.opacity = 0.6,
    this.blur = 18,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: GlassPanel(
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        opacity: opacity,
        blur: blur,
        child: MediaQuery.withNoTextScaling(
          child: SizedBox(
            height: _height,
            child: Row(
              children: [
                Expanded(child: _buildList(context)),
                ...trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    if (onReorder == null) {
      return ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        itemBuilder: (context, index) => _buildEntry(context, index),
      );
    }
    return ReorderableListView.builder(
      scrollDirection: Axis.horizontal,
      buildDefaultDragHandles: true,
      itemCount: items.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        if (oldIndex != newIndex) onReorder!(oldIndex, newIndex);
      },
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(animation.value);
            return Transform.scale(
              scale: 1 + 0.08 * t,
              child: Material(
                color: Colors.transparent,
                shadowColor: Colors.black26,
                elevation: 6 * t,
                borderRadius: BorderRadius.circular(20),
                child: child,
              ),
            );
          },
        );
      },
      itemBuilder: (context, index) => _buildEntry(context, index),
    );
  }

  /// 每个条目 = 分隔竖线(非首个) + 标签 chip, 带 key 供拖动排序。
  Widget _buildEntry(BuildContext context, int index) {
    final item = items[index];
    return Padding(
      key: ValueKey(item.id),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (index != 0)
            Container(
              width: 1,
              height: 18,
              margin: const EdgeInsets.symmetric(horizontal: 5),
              color: Colors.grey.withValues(alpha: 0.28),
            ),
          _buildChip(context, index, item),
        ],
      ),
    );
  }

  Widget _buildChip(BuildContext context, int index, TabStripItem item) {
    final active = index == activeIndex;
    final Color fg = active
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.62);

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(item.icon, size: 15, color: fg),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 130),
          child: Text(
            item.title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: fg,
              fontWeight: active ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
        if (onClose != null) ...[
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onClose!(index),
            child: Icon(Icons.close, size: 14, color: fg.withValues(alpha: 0.8)),
          ),
        ],
      ],
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onSelect(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? _activeColor : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: content,
      ),
    );
  }
}
