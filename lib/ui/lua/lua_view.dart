import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/lua/lua_engine.dart';
import '../../core/lua/script_manager.dart';
import '../widgets/glass_panel.dart';
import '../widgets/tab_strip.dart';

/// 字符串图标名 -> IconData (运行时无法反射查图标, 故用静态映射表)。
const Map<String, IconData> _kIcons = {
  'home': Icons.home_outlined,
  'dashboard': Icons.dashboard_outlined,
  'language': Icons.language,
  'terminal': Icons.terminal,
  'lan': Icons.lan_outlined,
  'settings_ethernet': Icons.settings_ethernet,
  'refresh': Icons.refresh,
  'delete': Icons.delete_outline,
  'restart_alt': Icons.restart_alt,
  'backup': Icons.backup_outlined,
  'restore': Icons.restore,
  'build': Icons.build_outlined,
  'science': Icons.science_outlined,
  'folder': Icons.folder_outlined,
  'code': Icons.code,
  'battery': Icons.battery_saver,
  'exit': Icons.exit_to_app,
  'info': Icons.info_outline,
  'image': Icons.image_outlined,
  'layers': Icons.layers_outlined,
  'blur': Icons.blur_on,
  'privacy': Icons.privacy_tip_outlined,
  'settings': Icons.settings_outlined,
  'play': Icons.play_arrow,
  'play_circle': Icons.play_circle,
  'pause_circle': Icons.pause_circle_outline,
  'stop': Icons.stop,
  'link': Icons.link,
  'download': Icons.download,
  'upload': Icons.upload,
  'edit': Icons.edit_outlined,
  'add': Icons.add,
  'more': Icons.more_vert,
  'star': Icons.star_outline,
  'bug': Icons.bug_report_outlined,
  'extension': Icons.extension,
  'construction': Icons.construction,
  'pets': Icons.pets,
  'check_circle': Icons.check_circle,
  'error': Icons.error_outline,
  'lock': Icons.lock_outline,
  'copy': Icons.copy,
  'logout': Icons.logout,
  'qr': Icons.qr_code,
  'warning': Icons.warning_amber,
};

IconData? luaIconFor(Object? name) => name == null ? null : _kIcons[name.toString()];

// ============================ 样式系统 ============================

class LuaStyle {
  static num? _num(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');
  static double? _d(Object? v) => _num(v)?.toDouble();

  static Color? color(Object? v, BuildContext ctx) {
    if (v == null) return null;
    final s = v.toString();
    if (s.startsWith('#')) {
      var hex = s.substring(1);
      if (hex.length == 6) hex = 'FF$hex';
      final val = int.tryParse(hex, radix: 16);
      return val == null ? null : Color(val);
    }
    final cs = Theme.of(ctx).colorScheme;
    switch (s) {
      case 'primary':
        return cs.primary;
      case 'secondary':
        return cs.secondary;
      case 'error':
        return cs.error;
      case 'surface':
        return cs.surface;
      case 'onSurface':
        return cs.onSurface;
      case 'white':
        return Colors.white;
      case 'black':
        return Colors.black;
      case 'red':
        return Colors.red;
      case 'green':
        return Colors.green;
      case 'orange':
        return Colors.orange;
      case 'blue':
        return Colors.blue;
      case 'grey':
      case 'gray':
        return Colors.grey;
      default:
        return null;
    }
  }

  static FontWeight? weight(Object? v) {
    if (v == null) return null;
    if (v == 'bold' || v == 'w700') return FontWeight.w700;
    if (v == 'w600' || v == 'semibold') return FontWeight.w600;
    if (v == 'w500' || v == 'medium') return FontWeight.w500;
    if (v == 'normal' || v == 'w400') return FontWeight.w400;
    final n = _num(v);
    if (n != null) {
      final idx = (n ~/ 100 - 1).clamp(0, 8);
      return FontWeight.values[idx];
    }
    return null;
  }

  static EdgeInsets? edge(Object? v) {
    if (v == null) return null;
    if (v is num) return EdgeInsets.all(v.toDouble());
    if (v is List) {
      final n = v.map((e) => _d(e) ?? 0).toList();
      if (n.length == 2) return EdgeInsets.symmetric(horizontal: n[0], vertical: n[1]);
      if (n.length == 4) return EdgeInsets.fromLTRB(n[0], n[1], n[2], n[3]);
      if (n.length == 1) return EdgeInsets.all(n[0]);
    }
    if (v is Map) {
      return EdgeInsets.only(
        left: _d(v['left']) ?? 0,
        top: _d(v['top']) ?? 0,
        right: _d(v['right']) ?? 0,
        bottom: _d(v['bottom']) ?? 0,
      );
    }
    return null;
  }

  static Alignment alignment(Object? v) {
    switch ('$v') {
      case 'topLeft':
        return Alignment.topLeft;
      case 'topCenter':
        return Alignment.topCenter;
      case 'topRight':
        return Alignment.topRight;
      case 'centerLeft':
        return Alignment.centerLeft;
      case 'center':
        return Alignment.center;
      case 'centerRight':
        return Alignment.centerRight;
      case 'bottomLeft':
        return Alignment.bottomLeft;
      case 'bottomCenter':
        return Alignment.bottomCenter;
      case 'bottomRight':
        return Alignment.bottomRight;
      default:
        return Alignment.center;
    }
  }

  static MainAxisAlignment mainAxis(Object? v) {
    switch ('$v') {
      case 'start':
        return MainAxisAlignment.start;
      case 'end':
        return MainAxisAlignment.end;
      case 'center':
        return MainAxisAlignment.center;
      case 'spaceBetween':
        return MainAxisAlignment.spaceBetween;
      case 'spaceAround':
        return MainAxisAlignment.spaceAround;
      case 'spaceEvenly':
        return MainAxisAlignment.spaceEvenly;
      default:
        return MainAxisAlignment.start;
    }
  }

  static CrossAxisAlignment crossAxis(Object? v) {
    switch ('$v') {
      case 'start':
        return CrossAxisAlignment.start;
      case 'end':
        return CrossAxisAlignment.end;
      case 'center':
        return CrossAxisAlignment.center;
      case 'stretch':
        return CrossAxisAlignment.stretch;
      default:
        return CrossAxisAlignment.center;
    }
  }

  /// 用通用样式属性包裹子组件 (margin/width/height/bg/radius/border/align/opacity)。
  static Widget wrap(Widget child, Map? style, BuildContext ctx) {
    if (style == null) return child;
    var w = child;
    final bg = color(style['bg'], ctx);
    final radius = _d(style['radius']);
    final border = color(style['border'], ctx);
    final width = _d(style['width']);
    final height = _d(style['height']);
    final pad = edge(style['padding']);
    final margin = edge(style['margin']);
    final opacity = _d(style['opacity']);
    if (opacity != null) w = Opacity(opacity: opacity, child: w);
    if (bg != null || radius != null || border != null || pad != null || width != null || height != null) {
      w = Container(
        width: width,
        height: height,
        padding: pad,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: radius == null ? null : BorderRadius.circular(radius),
          border: border == null ? null : Border.all(color: border),
        ),
        child: w,
      );
    }
    if (margin != null) w = Padding(padding: margin, child: w);
    if (style['align'] != null) w = Align(alignment: alignment(style['align']), child: w);
    return w;
  }
}

// ============================ 页面容器 ============================

/// 渲染一个 Lua 定义的页面: 始终包在 Obx 中, 依赖 stateRevision + HomeController Rx。
class LuaPage extends StatefulWidget {
  const LuaPage({super.key, required this.pageName});
  final String pageName;

  @override
  State<LuaPage> createState() => _LuaPageState();
}

class _LuaPageState extends State<LuaPage> {
  void _afterAction() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      // 建立反应式依赖: 脚本 state 变化 / HomeController 状态变化都会触发重建
      ScriptManager.instance.stateRevision.value;
      final ctx = ScriptManager.instance.buildCtx();
      final desc = ScriptManager.instance.buildPage(widget.pageName, ctx);
      if (desc == null) return _missing(context);
      final renderer = LuaRenderer(onAction: _afterAction);
      // 单个填充型根组件 (如 tabs / fill=true): 占满页面, 不套 ListView, 便于内部 Expanded 布局。
      if (desc is Map &&
          ('${desc['__type']}' == 'tabs' || desc['fill'] == true)) {
        return renderer.build(context, desc);
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [renderer.buildRoot(context, desc)],
      );
    });
  }

  Widget _missing(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '页面 "${widget.pageName}" 未在脚本中注册\n${ScriptManager.instance.lastError ?? ''}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.redAccent),
        ),
      ),
    );
  }
}

// ============================ 渲染器 ============================

/// 将 Lua 声明式描述 (Map/List) 转换为 Flutter widget。
class LuaRenderer {
  LuaRenderer({required this.onAction});

  final VoidCallback onAction;

  Widget buildRoot(BuildContext context, Object? node) {
    if (node is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final child in node)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: build(context, child),
            ),
        ],
      );
    }
    return build(context, node);
  }

  Widget build(BuildContext context, Object? node) {
    if (node is List) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in node) build(context, c)],
      );
    }
    if (node is! Map) {
      return node == null ? const SizedBox.shrink() : Text('$node');
    }
    final style = node['style'] is Map ? node['style'] as Map : null;
    final w = _buildByType(context, node);
    return LuaStyle.wrap(w, style, context);
  }

  Widget _buildByType(BuildContext context, Map node) {
    switch ('${node['__type'] ?? ''}') {
      // 布局
      case 'column':
        return _flex(context, node, Axis.vertical);
      case 'row':
        return _flex(context, node, Axis.horizontal);
      case 'stack':
        return Stack(children: _children(context, node['children']));
      case 'wrap':
        return Wrap(
          spacing: LuaStyle._d(node['spacing']) ?? 8,
          runSpacing: LuaStyle._d(node['runSpacing']) ?? 8,
          children: _children(context, node['children']),
        );
      case 'padding':
        return Padding(
          padding: LuaStyle.edge(node['pad']) ?? const EdgeInsets.all(8),
          child: build(context, node['child']),
        );
      case 'align':
        return Align(
          alignment: LuaStyle.alignment(node['align']),
          child: build(context, node['child']),
        );
      case 'center':
        return Center(child: build(context, node['child']));
      case 'expanded':
        return Expanded(
          flex: (LuaStyle._num(node['flex']) ?? 1).toInt(),
          child: build(context, node['child']),
        );
      case 'spacer':
        final s = LuaStyle._d(node['size']);
        return s == null ? const Spacer() : SizedBox(width: s, height: s);
      case 'box':
        return SizedBox(
          width: LuaStyle._d(node['width']),
          height: LuaStyle._d(node['height']),
          child: node['child'] == null ? null : build(context, node['child']),
        );
      case 'scroll':
        return SingleChildScrollView(
          scrollDirection:
              '${node['axis']}' == 'horizontal' ? Axis.horizontal : Axis.vertical,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _children(context, node['children']),
          ),
        );

      // 内容
      case 'text':
        return _text(context, node);
      case 'icon':
        return Icon(
          luaIconFor(node['icon']),
          size: LuaStyle._d(node['size']),
          color: LuaStyle.color(node['color'], context),
        );
      case 'image':
        return _image(node);
      case 'spinner':
        return Center(
          child: SizedBox(
            width: LuaStyle._d(node['size']) ?? 22,
            height: LuaStyle._d(node['size']) ?? 22,
            child: const CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case 'progress':
        final v = LuaStyle._d(node['value']);
        return LinearProgressIndicator(value: v);
      case 'chip':
        return _chip(context, node);
      case 'badge':
        return Badge(
          label: node['label'] == null ? null : Text('${node['label']}'),
          child: build(context, node['child']),
        );
      case 'divider':
        return const Divider();

      // 交互
      case 'button':
        return _button(context, node);
      case 'iconbutton':
        return IconButton(
          tooltip: node['tooltip'] == null ? null : '${node['tooltip']}',
          icon: Icon(luaIconFor(node['icon']),
              color: LuaStyle.color(node['color'], context)),
          onPressed: _tap(node['onTap']),
        );
      case 'menu':
        return _menu(context, node);
      case 'tile':
        return _tile(context, node);
      case 'switch':
        return _LuaSwitch(props: node, onAction: onAction);
      case 'slider':
        return _LuaSlider(props: node, onAction: onAction);
      case 'select':
        return _LuaSelect(props: node, onAction: onAction);
      case 'textfield':
        return _LuaTextField(props: node, onAction: onAction);
      case 'checkbox':
        return _LuaCheckbox(props: node, onAction: onAction);

      // 容器
      case 'card':
        return _card(context, node);
      case 'section':
        return _section(context, node);
      case 'expansion':
        return _expansion(context, node);
      case 'tabs':
        return _tabs(context, node);

      default:
        return Text('未知组件: ${node['__type']}',
            style: const TextStyle(color: Colors.orange));
    }
  }

  List<Widget> _children(BuildContext context, Object? children) {
    if (children is List) return [for (final c in children) build(context, c)];
    return const [];
  }

  VoidCallback? _tap(Object? fn) {
    if (fn is LuaFunctionRef) {
      return () {
        fn.call();
        onAction();
      };
    }
    return null;
  }

  void _invoke(Object? fn, [List<Object?> args = const []]) {
    if (fn is LuaFunctionRef) {
      fn.call(args);
      onAction();
    }
  }

  Widget _flex(BuildContext context, Map node, Axis axis) {
    final children = _children(context, node['children']);
    final main = LuaStyle.mainAxis(node['main']);
    final cross = LuaStyle.crossAxis(node['cross'] ?? (axis == Axis.vertical ? 'stretch' : 'center'));
    final gap = LuaStyle._d(node['gap']);
    final list = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      list.add(children[i]);
      if (gap != null && i != children.length - 1) {
        list.add(SizedBox(width: axis == Axis.horizontal ? gap : 0, height: axis == Axis.vertical ? gap : 0));
      }
    }
    return Flex(
      direction: axis,
      mainAxisAlignment: main,
      crossAxisAlignment: cross,
      mainAxisSize: node['expand'] == true ? MainAxisSize.max : MainAxisSize.min,
      children: list,
    );
  }

  Widget _text(BuildContext context, Map node) {
    final base = Theme.of(context).textTheme.bodyMedium;
    return Text(
      '${node['text'] ?? ''}',
      textAlign: node['align'] == 'center'
          ? TextAlign.center
          : node['align'] == 'right'
              ? TextAlign.right
              : null,
      maxLines: node['maxLines'] is int ? node['maxLines'] as int : null,
      overflow: node['ellipsis'] == true ? TextOverflow.ellipsis : null,
      style: base?.copyWith(
        fontSize: LuaStyle._d(node['size']),
        fontWeight: LuaStyle.weight(node['weight']),
        color: LuaStyle.color(node['color'], context),
      ),
    );
  }

  Widget _image(Map node) {
    final path = '${node['path'] ?? ''}';
    final w = LuaStyle._d(node['width']);
    final h = LuaStyle._d(node['height']);
    if (path.startsWith('http')) {
      return Image.network(path, width: w, height: h, fit: BoxFit.cover);
    }
    final f = File(path);
    if (f.existsSync()) {
      return Image.file(f, width: w, height: h, fit: BoxFit.cover);
    }
    return SizedBox(width: w, height: h);
  }

  Widget _chip(BuildContext context, Map node) {
    final bg = LuaStyle.color(node['color'], context);
    return Chip(
      label: Text('${node['label'] ?? ''}',
          style: TextStyle(
              fontSize: 12,
              color: bg == null ? null : Colors.white)),
      backgroundColor: bg,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _menu(BuildContext context, Map node) {
    final items = node['items'] is List ? node['items'] as List : const [];
    return PopupMenuButton<int>(
      icon: Icon(luaIconFor(node['icon']) ?? Icons.more_vert),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          if (items[i] is Map)
            PopupMenuItem<int>(
              value: i,
              enabled: (items[i] as Map)['enabled'] != false,
              child: Text('${(items[i] as Map)['label'] ?? ''}'),
            ),
      ],
      onSelected: (i) {
        final it = items[i];
        if (it is Map) _invoke(it['onTap']);
      },
    );
  }

  Widget _button(BuildContext context, Map node) {
    final onTap = _tap(node['onTap']);
    final variant = '${node['variant'] ?? 'filled'}';
    final danger = node['danger'] == true;
    final iconName = luaIconFor(node['icon']);
    final label = Text('${node['label'] ?? ''}');
    final child = iconName == null
        ? label
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(iconName, size: 18),
            const SizedBox(width: 6),
            label,
          ]);
    final bg = danger ? Theme.of(context).colorScheme.error : LuaStyle.color(node['color'], context);
    switch (variant) {
      case 'tonal':
        return FilledButton.tonal(onPressed: onTap, child: child);
      case 'outlined':
        return OutlinedButton(onPressed: onTap, child: child);
      case 'text':
        return TextButton(onPressed: onTap, child: child);
      default:
        return FilledButton(
          style: bg == null ? null : FilledButton.styleFrom(backgroundColor: bg),
          onPressed: onTap,
          child: child,
        );
    }
  }

  Widget _tile(BuildContext context, Map node) {
    final icon = luaIconFor(node['icon']);
    final onTap = node['onTap'];
    final trailing = node['trailing'];
    Widget? trailingWidget;
    if (trailing is Map) {
      trailingWidget = build(context, trailing);
    } else if (onTap is LuaFunctionRef) {
      trailingWidget = const Icon(Icons.chevron_right);
    }
    return ListTile(
      leading: icon == null
          ? null
          : Icon(icon, color: LuaStyle.color(node['iconColor'], context)),
      title: Text('${node['title'] ?? ''}'),
      subtitle: node['subtitle'] == null ? null : Text('${node['subtitle']}'),
      trailing: trailingWidget,
      onTap: onTap is LuaFunctionRef ? () => _invoke(onTap) : null,
    );
  }

  Widget _card(BuildContext context, Map node) {
    final title = node['title'];
    return GlassPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Text('$title',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
          ],
          ..._children(context, node['children']),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, Map node) {
    final title = node['title'];
    return GlassPanel(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text('$title',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.primary)),
            ),
          ..._children(context, node['children']),
        ],
      ),
    );
  }

  Widget _expansion(BuildContext context, Map node) {
    return GlassPanel(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text('${node['title'] ?? ''}'),
          leading: luaIconFor(node['icon']) == null
              ? null
              : Icon(luaIconFor(node['icon'])),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: _children(context, node['children']),
        ),
      ),
    );
  }

  /// 通用多标签组件: TabStrip + 当前标签内容; 标签态由 Lua 管理 (active 为 1 基)。
  Widget _tabs(BuildContext context, Map node) {
    final items = node['items'] is List ? node['items'] as List : const [];
    final count = items.length;
    final active = count == 0
        ? 0
        : ((LuaStyle._num(node['active']) ?? 1).toInt() - 1).clamp(0, count - 1);
    final onSelect = node['onSelect'];
    final onClose = node['onClose'];
    final onReorder = node['onReorder'];

    final stripItems = <TabStripItem>[];
    for (var i = 0; i < count; i++) {
      final it = items[i];
      final m = it is Map ? it : const {};
      stripItems.add(TabStripItem(
        id: '${m['key'] ?? i}',
        title: '${m['title'] ?? ''}',
        icon: luaIconFor(m['icon']) ?? Icons.tab,
      ));
    }

    final trailingSpec = node['trailing'];
    final trailing = <Widget>[];
    if (trailingSpec is List) {
      for (final t in trailingSpec) {
        trailing.add(build(context, t));
      }
    } else if (trailingSpec is Map) {
      trailing.add(build(context, trailingSpec));
    }

    final Widget content = count == 0
        ? Center(child: Text('${node['empty'] ?? ''}'))
        : build(context, (items[active] as Map)['content']);

    return Column(
      children: [
        TabStrip(
          items: stripItems,
          activeIndex: active,
          onSelect: (i) => _invoke(onSelect, [i + 1]),
          onClose: onClose is LuaFunctionRef ? (i) => _invoke(onClose, [i + 1]) : null,
          onReorder: onReorder is LuaFunctionRef
              ? (o, n) => _invoke(onReorder, [o + 1, n + 1])
              : null,
          trailing: trailing,
        ),
        Expanded(child: content),
      ],
    );
  }
}

// ============================ 有状态交互组件 ============================

class _LuaSlider extends StatefulWidget {
  const _LuaSlider({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaSlider> createState() => _LuaSliderState();
}

class _LuaSliderState extends State<_LuaSlider> {
  late double _value;
  @override
  void initState() {
    super.initState();
    _value = (widget.props['value'] as num?)?.toDouble() ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    final min = (widget.props['min'] as num?)?.toDouble() ?? 0;
    final max = (widget.props['max'] as num?)?.toDouble() ?? 1;
    final label = widget.props['label'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label != null)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('$label')),
        Slider(
          value: _value.clamp(min, max),
          min: min,
          max: max,
          onChanged: (v) => setState(() => _value = v),
          onChangeEnd: (v) {
            final fn = widget.props['onChanged'];
            if (fn is LuaFunctionRef) fn.call([v]);
            widget.onAction();
          },
        ),
      ],
    );
  }
}

class _LuaSwitch extends StatefulWidget {
  const _LuaSwitch({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaSwitch> createState() => _LuaSwitchState();
}

class _LuaSwitchState extends State<_LuaSwitch> {
  late bool _value;
  @override
  void initState() {
    super.initState();
    _value = widget.props['value'] == true;
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text('${widget.props['title'] ?? ''}'),
      subtitle: widget.props['subtitle'] == null
          ? null
          : Text('${widget.props['subtitle']}'),
      value: _value,
      onChanged: (v) {
        setState(() => _value = v);
        final fn = widget.props['onChanged'];
        if (fn is LuaFunctionRef) fn.call([v]);
        widget.onAction();
      },
    );
  }
}

class _LuaSelect extends StatefulWidget {
  const _LuaSelect({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaSelect> createState() => _LuaSelectState();
}

class _LuaSelectState extends State<_LuaSelect> {
  Object? _value;
  @override
  void initState() {
    super.initState();
    _value = widget.props['value'];
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.props['options'];
    final items = <DropdownMenuItem<Object?>>[];
    if (options is List) {
      for (final o in options) {
        if (o is Map) {
          items.add(DropdownMenuItem(
              value: o['value'], child: Text('${o['label'] ?? o['value']}')));
        } else {
          items.add(DropdownMenuItem(value: o, child: Text('$o')));
        }
      }
    }
    return ListTile(
      title: Text('${widget.props['title'] ?? ''}'),
      trailing: DropdownButton<Object?>(
        value: _value,
        items: items,
        onChanged: (v) {
          setState(() => _value = v);
          final fn = widget.props['onChanged'];
          if (fn is LuaFunctionRef) fn.call([v]);
          widget.onAction();
        },
      ),
    );
  }
}

class _LuaTextField extends StatefulWidget {
  const _LuaTextField({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaTextField> createState() => _LuaTextFieldState();
}

class _LuaTextFieldState extends State<_LuaTextField> {
  late final TextEditingController _c;
  @override
  void initState() {
    super.initState();
    _c = TextEditingController(text: '${widget.props['value'] ?? ''}');
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      decoration: InputDecoration(
        labelText: widget.props['label'] == null ? null : '${widget.props['label']}',
        hintText: widget.props['hint'] == null ? null : '${widget.props['hint']}',
        border: const OutlineInputBorder(),
      ),
      onChanged: (v) {
        final fn = widget.props['onChanged'];
        if (fn is LuaFunctionRef) fn.call([v]);
      },
    );
  }
}

class _LuaCheckbox extends StatefulWidget {
  const _LuaCheckbox({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaCheckbox> createState() => _LuaCheckboxState();
}

class _LuaCheckboxState extends State<_LuaCheckbox> {
  late bool _value;
  @override
  void initState() {
    super.initState();
    _value = widget.props['value'] == true;
  }

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      title: Text('${widget.props['title'] ?? ''}'),
      value: _value,
      onChanged: (v) {
        setState(() => _value = v ?? false);
        final fn = widget.props['onChanged'];
        if (fn is LuaFunctionRef) fn.call([_value]);
        widget.onAction();
      },
    );
  }
}
