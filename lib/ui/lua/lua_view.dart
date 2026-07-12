import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/lua/lua_engine.dart';
import '../../core/lua/love_bridge.dart';
import '../../core/lua/script_manager.dart';
import '../widgets/glass_panel.dart';
import '../widgets/tab_strip.dart';
import '../pages/love/love_game_view.dart';
import 'material_icons_map.g.dart';

/// 将 Lua 传入的图标标识解析为 IconData。
/// 统一规则 (无任何历史别名/特例):
///  1. 数值 codepoint:      icon(0xe88a)
///  2. "0x" 前缀的字符串:    icon("0xe88a")
///  3. Material 规范名:      icon("home") / icon("home_outlined") / icon("rocket_launch")
/// 名称即 Flutter `Icons.<name>` 的标识符 (见 material_icons_map.g.dart, 全量 8000+)。
/// 依赖 --no-tree-shake-icons 构建 (运行时动态构造 IconData)。
IconData? luaIconFor(Object? name) {
  if (name == null) return null;
  if (name is num) {
    return IconData(name.toInt(), fontFamily: 'MaterialIcons');
  }
  final s = name.toString();
  if (s.startsWith('0x') || s.startsWith('0X')) {
    final cp = int.tryParse(s.substring(2), radix: 16);
    if (cp != null) return IconData(cp, fontFamily: 'MaterialIcons');
  }
  final cp = kMaterialIconCodepoints[s];
  if (cp == null) return null;
  return IconData(
    cp,
    fontFamily: 'MaterialIcons',
    matchTextDirection: kMaterialIconRtl.contains(s),
  );
}

// ============================ 样式系统 ============================

class LuaStyle {
  static num? _num(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');
  static double? _d(Object? v) => _num(v)?.toDouble();

  /// Material 全色板 (MaterialColor / MaterialAccentColor)。
  static const Map<String, MaterialColor> _swatches = {
    'red': Colors.red,
    'pink': Colors.pink,
    'purple': Colors.purple,
    'deepPurple': Colors.deepPurple,
    'indigo': Colors.indigo,
    'blue': Colors.blue,
    'lightBlue': Colors.lightBlue,
    'cyan': Colors.cyan,
    'teal': Colors.teal,
    'green': Colors.green,
    'lightGreen': Colors.lightGreen,
    'lime': Colors.lime,
    'yellow': Colors.yellow,
    'amber': Colors.amber,
    'orange': Colors.orange,
    'deepOrange': Colors.deepOrange,
    'brown': Colors.brown,
    'grey': Colors.grey,
    'gray': Colors.grey,
    'blueGrey': Colors.blueGrey,
  };

  static const Map<String, Color> _basics = {
    'white': Colors.white,
    'black': Colors.black,
    'transparent': Colors.transparent,
    'white70': Colors.white70,
    'white54': Colors.white54,
    'white38': Colors.white38,
    'white12': Colors.white12,
    'black87': Colors.black87,
    'black54': Colors.black54,
    'black38': Colors.black38,
    'black26': Colors.black26,
    'black12': Colors.black12,
    'redAccent': Colors.redAccent,
    'pinkAccent': Colors.pinkAccent,
    'purpleAccent': Colors.purpleAccent,
    'deepPurpleAccent': Colors.deepPurpleAccent,
    'indigoAccent': Colors.indigoAccent,
    'blueAccent': Colors.blueAccent,
    'lightBlueAccent': Colors.lightBlueAccent,
    'cyanAccent': Colors.cyanAccent,
    'tealAccent': Colors.tealAccent,
    'greenAccent': Colors.greenAccent,
    'lightGreenAccent': Colors.lightGreenAccent,
    'limeAccent': Colors.limeAccent,
    'yellowAccent': Colors.yellowAccent,
    'amberAccent': Colors.amberAccent,
    'orangeAccent': Colors.orangeAccent,
    'deepOrangeAccent': Colors.deepOrangeAccent,
  };

  /// 解析颜色。支持:
  ///  - #RGB / #RRGGBB / #AARRGGBB (十六进制)
  ///  - 主题色: primary/onPrimary/secondary/tertiary/error/surface/onSurface/background/outline...
  ///  - Material 色板名: red/blue/teal... 可带 shade: "blue.700" / "red.300" / "orange.A200"
  ///  - 基础色: white/black/transparent/white70/black54...
  ///  - {r,g,b,a} 表 (0-255, a 0-1 或 0-255)
  static Color? color(Object? v, BuildContext ctx) {
    if (v == null) return null;
    if (v is Map) {
      final r = (_num(v['r']) ?? 0).toInt().clamp(0, 255);
      final g = (_num(v['g']) ?? 0).toInt().clamp(0, 255);
      final b = (_num(v['b']) ?? 0).toInt().clamp(0, 255);
      final an = _num(v['a']);
      final a = an == null ? 255 : (an <= 1 ? (an * 255).round() : an.toInt()).clamp(0, 255);
      return Color.fromARGB(a, r, g, b);
    }
    final s = v.toString();
    if (s.startsWith('#')) {
      var hex = s.substring(1);
      if (hex.length == 3) {
        hex = hex.split('').map((c) => '$c$c').join();
      }
      if (hex.length == 6) hex = 'FF$hex';
      final val = int.tryParse(hex, radix: 16);
      return val == null ? null : Color(val);
    }
    // 色板带 shade: "blue.700" / "orange.A200"
    if (s.contains('.')) {
      final parts = s.split('.');
      final sw = _swatches[parts[0]];
      if (sw != null) return _shade(sw, parts[1]);
    }
    final cs = Theme.of(ctx).colorScheme;
    switch (s) {
      case 'primary':
        return cs.primary;
      case 'onPrimary':
        return cs.onPrimary;
      case 'primaryContainer':
        return cs.primaryContainer;
      case 'secondary':
        return cs.secondary;
      case 'onSecondary':
        return cs.onSecondary;
      case 'secondaryContainer':
        return cs.secondaryContainer;
      case 'tertiary':
        return cs.tertiary;
      case 'error':
        return cs.error;
      case 'onError':
        return cs.onError;
      case 'errorContainer':
        return cs.errorContainer;
      case 'surface':
        return cs.surface;
      case 'onSurface':
        return cs.onSurface;
      case 'surfaceVariant':
        return cs.surfaceContainerHighest;
      case 'onSurfaceVariant':
        return cs.onSurfaceVariant;
      case 'background':
        return cs.surface;
      case 'outline':
        return cs.outline;
      case 'shadow':
        return cs.shadow;
    }
    final basic = _basics[s];
    if (basic != null) return basic;
    final sw = _swatches[s];
    if (sw != null) return sw;
    return null;
  }

  static Color? _shade(MaterialColor sw, String shade) {
    final n = int.tryParse(shade);
    if (n == null) return sw;
    const valid = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900];
    final pick = valid.contains(n) ? n : 500;
    return sw[pick] ?? sw;
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

  /// 用通用样式属性包裹子组件。
  /// 支持: width/height/minWidth/maxWidth/minHeight/maxHeight,
  ///       padding/margin, bg/gradient, radius, border/borderWidth,
  ///       shadow(bool 或 {color,blur,dx,dy,spread}), opacity, align,
  ///       rotate(弧度)/scale, aspectRatio, flex(在 Flex 中扩展)。
  static Widget wrap(Widget child, Map? style, BuildContext ctx) {
    if (style == null) return child;
    var w = child;
    final bg = color(style['bg'], ctx);
    final radius = _d(style['radius']);
    final border = color(style['border'], ctx);
    final borderWidth = _d(style['borderWidth']);
    final width = _d(style['width']);
    final height = _d(style['height']);
    final pad = edge(style['padding']);
    final margin = edge(style['margin']);
    final opacity = _d(style['opacity']);
    final gradient = _gradient(style['gradient'], ctx);
    final shadow = _shadows(style['shadow'], ctx);
    final br = radius == null ? null : BorderRadius.circular(radius);

    if (opacity != null) w = Opacity(opacity: opacity, child: w);

    final hasDecoration = bg != null ||
        radius != null ||
        border != null ||
        gradient != null ||
        shadow != null ||
        pad != null ||
        width != null ||
        height != null;
    if (hasDecoration) {
      w = Container(
        width: width,
        height: height,
        padding: pad,
        decoration: BoxDecoration(
          color: gradient == null ? bg : null,
          gradient: gradient,
          borderRadius: br,
          boxShadow: shadow,
          border: border == null
              ? null
              : Border.all(color: border, width: borderWidth ?? 1),
        ),
        child: w,
      );
    }

    // 约束
    final minW = _d(style['minWidth']);
    final maxW = _d(style['maxWidth']);
    final minH = _d(style['minHeight']);
    final maxH = _d(style['maxHeight']);
    if (minW != null || maxW != null || minH != null || maxH != null) {
      w = ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: minW ?? 0,
          maxWidth: maxW ?? double.infinity,
          minHeight: minH ?? 0,
          maxHeight: maxH ?? double.infinity,
        ),
        child: w,
      );
    }

    final aspect = _d(style['aspectRatio']);
    if (aspect != null) w = AspectRatio(aspectRatio: aspect, child: w);

    // 变换
    final rotate = _d(style['rotate']);
    final scale = _d(style['scale']);
    if (rotate != null) w = Transform.rotate(angle: rotate, child: w);
    if (scale != null) w = Transform.scale(scale: scale, child: w);

    if (radius != null && (bg != null || gradient != null)) {
      w = ClipRRect(borderRadius: br!, child: w);
    }

    if (margin != null) w = Padding(padding: margin, child: w);
    if (style['align'] != null) w = Align(alignment: alignment(style['align']), child: w);
    return w;
  }

  static List<BoxShadow>? _shadows(Object? v, BuildContext ctx) {
    if (v == null || v == false) return null;
    if (v == true) {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.18),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ];
    }
    if (v is Map) {
      return [
        BoxShadow(
          color: color(v['color'], ctx) ?? Colors.black.withValues(alpha: 0.2),
          blurRadius: _d(v['blur']) ?? 8,
          spreadRadius: _d(v['spread']) ?? 0,
          offset: Offset(_d(v['dx']) ?? 0, _d(v['dy']) ?? 3),
        ),
      ];
    }
    return null;
  }

  static Gradient? _gradient(Object? v, BuildContext ctx) {
    if (v is! Map) return null;
    final colorsList = v['colors'];
    final colors = <Color>[];
    if (colorsList is List) {
      for (final c in colorsList) {
        final col = color(c, ctx);
        if (col != null) colors.add(col);
      }
    }
    if (colors.length < 2) return null;
    final type = '${v['type'] ?? 'linear'}';
    if (type == 'radial') {
      return RadialGradient(colors: colors, radius: _d(v['radius']) ?? 0.5);
    }
    return LinearGradient(
      colors: colors,
      begin: v['begin'] != null ? alignment(v['begin']) : Alignment.centerLeft,
      end: v['end'] != null ? alignment(v['end']) : Alignment.centerRight,
    );
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
      // 页面顶层惰性化: 顶层区块用 ListView.builder 按需构建, 首屏外的区块滚到才建。
      if (desc is List) {
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: desc.length,
          itemBuilder: (ctx, i) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: renderer.build(ctx, desc[i]),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [renderer.buildRoot(context, desc)],
      );
    });
  }

  Widget _missing(BuildContext context) {
    // 页面未注册 (如 main.lua 缺失/损坏时的主页): 留空白。
    // 加载失败的具体原因通过 toast + 设置页呈现, 不在页面上堆红字。
    return const SizedBox.shrink();
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
    if (node is LuaFunctionRef) {
      final result = node.call();
      if (result is! List) return build(context, result);
      if (result.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in result) build(context, c)],
      );
    }
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
      case 'flexible':
        return Flexible(
          flex: (LuaStyle._num(node['flex']) ?? 1).toInt(),
          fit: node['tight'] == true ? FlexFit.tight : FlexFit.loose,
          child: build(context, node['child']),
        );
      case 'positioned':
        return Positioned(
          left: LuaStyle._d(node['left']),
          top: LuaStyle._d(node['top']),
          right: LuaStyle._d(node['right']),
          bottom: LuaStyle._d(node['bottom']),
          width: LuaStyle._d(node['width']),
          height: LuaStyle._d(node['height']),
          child: build(context, node['child']),
        );
      case 'aspect':
        return AspectRatio(
          aspectRatio: LuaStyle._d(node['ratio']) ?? 1,
          child: build(context, node['child']),
        );
      case 'fitted':
        return FittedBox(
          fit: _boxFit(node['fit']),
          child: build(context, node['child']),
        );
      case 'safearea':
        return SafeArea(child: build(context, node['child']));
      case 'intrinsic_height':
        return IntrinsicHeight(child: build(context, node['child']));
      case 'intrinsic_width':
        return IntrinsicWidth(child: build(context, node['child']));
      case 'clip':
        final shape = '${node['shape'] ?? 'rrect'}';
        if (shape == 'oval' || shape == 'circle') {
          return ClipOval(child: build(context, node['child']));
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(LuaStyle._d(node['radius']) ?? 8),
          child: build(context, node['child']),
        );
      case 'grid':
        return _grid(context, node);
      case 'list':
        return _list(context, node);
      case 'table':
        return _table(context, node);
      case 'gesture':
      case 'inkwell':
        return _gesture(context, node);
      case 'tooltip':
        return Tooltip(
          message: '${node['message'] ?? node['text'] ?? ''}',
          child: build(context, node['child']),
        );

      // 内容
      case 'text':
        return _text(context, node);
      case 'markdown':
        return MarkdownBody(
          data: '${node['text'] ?? ''}',
          selectable: node['selectable'] == true,
          onTapLink: (text, href, title) {
            if (href != null) {
              final uri = Uri.tryParse(href);
              if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        );
      case 'richtext':
        return _richText(context, node);
      case 'icon':
        return Icon(
          luaIconFor(node['icon']),
          size: LuaStyle._d(node['size']),
          color: LuaStyle.color(node['color'], context),
        );
      case 'avatar':
        return _avatar(context, node);
      case 'image':
        return _image(node);
      case 'spinner':
        return Center(
          child: SizedBox(
            width: LuaStyle._d(node['size']) ?? 22,
            height: LuaStyle._d(node['size']) ?? 22,
            child: CircularProgressIndicator(
              strokeWidth: LuaStyle._d(node['stroke']) ?? 2,
              value: LuaStyle._d(node['value']),
              color: LuaStyle.color(node['color'], context),
            ),
          ),
        );
      case 'progress':
        final v = LuaStyle._d(node['value']);
        return LinearProgressIndicator(
          value: v,
          minHeight: LuaStyle._d(node['height']),
          color: LuaStyle.color(node['color'], context),
          backgroundColor: LuaStyle.color(node['track'], context),
        );
      case 'chip':
        return _chip(context, node);
      case 'badge':
        return Badge(
          label: node['label'] == null ? null : Text('${node['label']}'),
          isLabelVisible: node['show'] != false,
          backgroundColor: LuaStyle.color(node['color'], context),
          child: build(context, node['child']),
        );
      case 'divider':
        return Divider(
          height: LuaStyle._d(node['height']),
          thickness: LuaStyle._d(node['thickness']),
          indent: LuaStyle._d(node['indent']),
          endIndent: LuaStyle._d(node['endIndent']),
          color: LuaStyle.color(node['color'], context),
        );
      case 'vdivider':
        return VerticalDivider(
          width: LuaStyle._d(node['width']),
          thickness: LuaStyle._d(node['thickness']),
          color: LuaStyle.color(node['color'], context),
        );

      case 'love':
        final gp = node['game'];
        final canvasId = (LuaStyle._num(node['id']) ?? 0).toInt();
        final rawPath = gp == null ? null : '$gp';
        final gamePath = rawPath == null ? null
            : LoveBridge.resolveGamePath(rawPath, ScriptManager.instance.scriptsDir);
        final onEvent = node['onEvent'];
        final freeze = node['freeze'] == true;
        final rot = '${node['rotate'] ?? ''}'.toLowerCase();
        final int quarterTurns = rot == 'cw' ? 1 : (rot == 'ccw' ? 3 : 0);
        final bridgeArg = LoveBridge.instance.prepare(
          canvasId: canvasId,
          onEvent: onEvent is LuaFunctionRef ? onEvent : null,
          gamePath: gamePath,
          scriptsDir: ScriptManager.instance.scriptsDir,
          freeze: freeze,
        );
        return SizedBox(
          key: ValueKey('love_canvas_$canvasId'),
          width: LuaStyle._d(node['width']),
          height: LuaStyle._d(node['height']) ?? 200,
          child: LoveGameView(
            key: ValueKey('love_view_$canvasId'),
            canvasId: canvasId,
            gamePath: gamePath,
            bridgeArg: bridgeArg,
            autoSuspend: node['autopause'] != false,
            keepAlive: node['keepalive'] != false,
            quarterTurns: quarterTurns,
          ),
        );


      // 交互
      case 'button':
        return _button(context, node);
      case 'iconbutton':
        return IconButton(
          tooltip: node['tooltip'] == null ? null : '${node['tooltip']}',
          iconSize: LuaStyle._d(node['size']),
          icon: Icon(luaIconFor(node['icon']),
              color: LuaStyle.color(node['color'], context)),
          onPressed: _tap(node['onTap']),
        );
      case 'fab':
        return _fab(context, node);
      case 'menu':
        return _menu(context, node);
      case 'tile':
        return _tile(context, node);
      case 'switch':
        return _LuaSwitch(props: node, onAction: onAction);
      case 'slider':
        return _LuaSlider(props: node, onAction: onAction);
      case 'rangeslider':
        return _LuaRangeSlider(props: node, onAction: onAction);
      case 'select':
        return _LuaSelect(props: node, onAction: onAction);
      case 'textfield':
        return _LuaTextField(props: node, onAction: onAction);
      case 'checkbox':
        return _LuaCheckbox(props: node, onAction: onAction);
      case 'radio':
        return _LuaRadioGroup(props: node, onAction: onAction);
      case 'segmented':
        return _LuaSegmented(props: node, onAction: onAction);
      case 'togglebuttons':
        return _LuaToggleButtons(props: node, onAction: onAction);
      case 'datefield':
        return _LuaDateField(props: node, onAction: onAction, mode: 'date');
      case 'timefield':
        return _LuaDateField(props: node, onAction: onAction, mode: 'time');
      case 'stepper':
        return _LuaStepper(props: node, onAction: onAction);

      // 容器
      case 'card':
        return _card(context, node);
      case 'section':
        return _section(context, node);
      case 'expansion':
        return _expansion(context, node);
      case 'tabs':
        return _tabs(context, node);
      case 'lifecycle':
        return _LuaLifecycle(node: node, renderer: this);
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

  static BoxFit _boxFit(Object? v) {
    switch ('$v') {
      case 'contain':
        return BoxFit.contain;
      case 'cover':
        return BoxFit.cover;
      case 'fill':
        return BoxFit.fill;
      case 'fitWidth':
        return BoxFit.fitWidth;
      case 'fitHeight':
        return BoxFit.fitHeight;
      case 'none':
        return BoxFit.none;
      case 'scaleDown':
        return BoxFit.scaleDown;
      default:
        return BoxFit.contain;
    }
  }

  Widget _gesture(BuildContext context, Map node) {
    final onTap = node['onTap'];
    final onLong = node['onLongPress'];
    final onDouble = node['onDoubleTap'];
    final child = build(context, node['child']);
    if (node['__type'] == 'inkwell' || node['ink'] == true) {
      return InkWell(
        borderRadius: node['radius'] == null
            ? null
            : BorderRadius.circular(LuaStyle._d(node['radius']) ?? 8),
        onTap: onTap is LuaFunctionRef ? () => _invoke(onTap) : null,
        onLongPress: onLong is LuaFunctionRef ? () => _invoke(onLong) : null,
        onDoubleTap: onDouble is LuaFunctionRef ? () => _invoke(onDouble) : null,
        child: child,
      );
    }
    return GestureDetector(
      onTap: onTap is LuaFunctionRef ? () => _invoke(onTap) : null,
      onLongPress: onLong is LuaFunctionRef ? () => _invoke(onLong) : null,
      onDoubleTap: onDouble is LuaFunctionRef ? () => _invoke(onDouble) : null,
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }

  Widget _avatar(BuildContext context, Map node) {
    final radius = LuaStyle._d(node['radius']) ?? 20;
    final bg = LuaStyle.color(node['color'], context);
    final fg = LuaStyle.color(node['textColor'], context);
    final img = node['image'];
    if (img != null) {
      final path = '$img';
      final provider = path.startsWith('http')
          ? NetworkImage(path)
          : FileImage(File(path)) as ImageProvider;
      return CircleAvatar(radius: radius, backgroundImage: provider);
    }
    final iconName = luaIconFor(node['icon']);
    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundColor: fg,
      child: iconName != null
          ? Icon(iconName, size: radius)
          : (node['text'] != null ? Text('${node['text']}') : null),
    );
  }

  Widget _richText(BuildContext context, Map node) {
    final spans = node['spans'];
    final base = Theme.of(context).textTheme.bodyMedium;
    final children = <InlineSpan>[];
    if (spans is List) {
      for (final s in spans) {
        if (s is Map) {
          children.add(TextSpan(
            text: '${s['text'] ?? ''}',
            style: base?.copyWith(
              fontSize: LuaStyle._d(s['size']),
              fontWeight: LuaStyle.weight(s['weight']),
              color: LuaStyle.color(s['color'], context),
              fontStyle: s['italic'] == true ? FontStyle.italic : null,
              decoration:
                  s['underline'] == true ? TextDecoration.underline : null,
            ),
          ));
        } else {
          children.add(TextSpan(text: '$s', style: base));
        }
      }
    }
    return Text.rich(
      TextSpan(children: children),
      textAlign: node['align'] == 'center'
          ? TextAlign.center
          : node['align'] == 'right'
              ? TextAlign.right
              : null,
    );
  }

  Widget _grid(BuildContext context, Map node) {
    final raw = node['children'];
    final items = raw is List ? raw : const [];
    final cols = (LuaStyle._num(node['columns']) ?? 2).toInt();
    final scrollable = node['scroll'] == true;
    return GridView.builder(
      shrinkWrap: !scrollable,
      physics: scrollable ? null : const NeverScrollableScrollPhysics(),
      padding: LuaStyle.edge(node['padding']),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: LuaStyle._d(node['gap']) ?? 8,
        crossAxisSpacing: LuaStyle._d(node['crossGap'] ?? node['gap']) ?? 8,
        childAspectRatio: LuaStyle._d(node['ratio']) ?? 1,
      ),
      itemCount: items.length,
      itemBuilder: (ctx, i) => build(ctx, items[i]),
    );
  }

  // 惰性列表: 仅构建可视项 (scroll=true 时真正虚拟化, 千项列表不再一次性实例化)。
  Widget _list(BuildContext context, Map node) {
    final raw = node['children'];
    final items = raw is List ? raw : const [];
    final horizontal = '${node['axis']}' == 'horizontal';
    final sep = LuaStyle._d(node['separator']);
    final scrollable = node['scroll'] == true;
    return ListView.separated(
      scrollDirection: horizontal ? Axis.horizontal : Axis.vertical,
      shrinkWrap: scrollable ? false : (node['shrink'] != false),
      physics: scrollable ? null : const NeverScrollableScrollPhysics(),
      padding: LuaStyle.edge(node['padding']),
      itemCount: items.length,
      separatorBuilder: (_, __) => sep == null
          ? const SizedBox.shrink()
          : SizedBox(width: horizontal ? sep : 0, height: horizontal ? 0 : sep),
      itemBuilder: (ctx, i) {
        final item = items[i];
        final k = item is Map && item['key'] != null ? item['key'] : i;
        return KeyedSubtree(key: ValueKey(k), child: build(ctx, item));
      },
    );
  }

  Widget _table(BuildContext context, Map node) {
    final rows = node['rows'];
    final headers = node['headers'];
    final columns = <DataColumn>[];
    if (headers is List) {
      for (final h in headers) {
        columns.add(DataColumn(label: h is Map ? build(context, h) : Text('$h')));
      }
    }
    final dataRows = <DataRow>[];
    if (rows is List) {
      for (final r in rows) {
        if (r is List) {
          dataRows.add(DataRow(
            cells: [
              for (final c in r)
                DataCell(c is Map ? build(context, c) : Text('$c')),
            ],
          ));
        }
      }
    }
    if (columns.isEmpty && dataRows.isNotEmpty) {
      final n = dataRows.first.cells.length;
      for (var i = 0; i < n; i++) {
        columns.add(const DataColumn(label: SizedBox.shrink()));
      }
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(columns: columns, rows: dataRows),
    );
  }

  Widget _fab(BuildContext context, Map node) {
    final label = node['label'];
    final iconName = luaIconFor(node['icon']);
    final bg = LuaStyle.color(node['color'], context);
    if (label != null) {
      return FloatingActionButton.extended(
        onPressed: _tap(node['onTap']),
        backgroundColor: bg,
        icon: iconName == null ? null : Icon(iconName),
        label: Text('$label'),
      );
    }
    return FloatingActionButton(
      onPressed: _tap(node['onTap']),
      backgroundColor: bg,
      mini: node['mini'] == true,
      child: Icon(iconName ?? Icons.add),
    );
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
    final bind = node['bind'];
    if (bind is String) {
      // 流式/响应式文本: 只重绘这一个 Text, 不触发整页重建。
      final n = ScriptManager.instance.reactiveNotifier(bind);
      return ValueListenableBuilder<Object?>(
        valueListenable: n,
        builder: (ctx, value, _) =>
            _plainText(ctx, node, '${value ?? node['text'] ?? ''}'),
      );
    }
    return _plainText(context, node, '${node['text'] ?? ''}');
  }

  Widget _plainText(BuildContext context, Map node, String data) {
    final base = Theme.of(context).textTheme.bodyMedium;
    return Text(
      data,
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
    // 允许换行时不做省略; 默认单行省略, 避免窄屏 RenderFlex 溢出。
    final wrapText = node['wrap'] == true;
    final label = Text(
      '${node['label'] ?? ''}',
      textAlign: TextAlign.center,
      maxLines: wrapText ? null : 1,
      overflow: wrapText ? null : TextOverflow.ellipsis,
      softWrap: wrapText,
    );
    final child = iconName == null
        ? label
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(iconName, size: 18),
              const SizedBox(width: 6),
              Flexible(child: label),
            ],
          );
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
  // 判断组件是否"填充型"(自行管理尺寸/滚动, 不应被外层套滚动容器):
  // love 画布 / 虚拟化 list / 嵌套 tabs / 显式 fill=true; lifecycle 透传看其 child。
  bool _isFillLike(Object? desc) {
    if (desc is! Map) return false;
    if (desc['fill'] == true) return true;
    final t = '${desc['__type']}';
    if (t == 'love' || t == 'list' || t == 'tabs') return true;
    if (t == 'lifecycle') return _isFillLike(desc['child']);
    return false;
  }

  // 标签页内容体: 普通内容(列表/卡片流)默认套可滚动容器, 避免超出视口时底部溢出;
  // 填充型内容(love/list/tabs/fill)保持直接填满, 由其自身管理尺寸与滚动。
  Widget _tabBody(BuildContext context, Object? contentDesc) {
    final w = build(context, contentDesc);
    if (_isFillLike(contentDesc)) return w;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: w,
    );
  }

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

    // 所有标签内容都挂载 (IndexedStack), 用 LovePageActive 标记当前可见标签。
    // 与多导航页完全同等: 非激活标签内的 love 暂停渲染但保留状态与纹理,
    // 激活标签恢复渲染。love 复用同一 State 会导致纹理串台, 故必须保持各自挂载。
    // 标签可见性还需叠加父级(导航页)可见性: 导航页隐藏时, 本页所有标签的 love 都应暂停。
    // keepalive=false: 只挂载当前标签, 切走即销毁非激活标签子树 (配合 love{keepalive=false}
    //   可在切标签时彻底销毁其它游戏进程, 而非挂起)。
    final parentActive = LovePageActive.of(context);
    final bool tabsKeepAlive = node['keepalive'] != false;
    final Widget content = count == 0
        ? Center(child: Text('${node['empty'] ?? ''}'))
        : tabsKeepAlive
            ? IndexedStack(
                index: active,
                sizing: StackFit.expand,
                children: [
                  for (var i = 0; i < count; i++)
                    LovePageActive(
                      active: parentActive && i == active,
                      child: _tabBody(context, (items[i] as Map)['content']),
                    ),
                ],
              )
            : LovePageActive(
                active: parentActive,
                child: _tabBody(context, (items[active] as Map)['content']),
              );

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

// -------- 区间滑块 --------
class _LuaRangeSlider extends StatefulWidget {
  const _LuaRangeSlider({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaRangeSlider> createState() => _LuaRangeSliderState();
}

class _LuaRangeSliderState extends State<_LuaRangeSlider> {
  late RangeValues _values;
  @override
  void initState() {
    super.initState();
    final lo = (widget.props['low'] as num?)?.toDouble() ?? 0;
    final hi = (widget.props['high'] as num?)?.toDouble() ?? 1;
    _values = RangeValues(lo, hi);
  }

  @override
  Widget build(BuildContext context) {
    final min = (widget.props['min'] as num?)?.toDouble() ?? 0;
    final max = (widget.props['max'] as num?)?.toDouble() ?? 1;
    final divisions = (widget.props['divisions'] as num?)?.toInt();
    return RangeSlider(
      values: RangeValues(
        _values.start.clamp(min, max),
        _values.end.clamp(min, max),
      ),
      min: min,
      max: max,
      divisions: divisions,
      labels: RangeLabels(
        _values.start.toStringAsFixed(0),
        _values.end.toStringAsFixed(0),
      ),
      onChanged: (v) => setState(() => _values = v),
      onChangeEnd: (v) {
        final fn = widget.props['onChanged'];
        if (fn is LuaFunctionRef) fn.call([v.start, v.end]);
        widget.onAction();
      },
    );
  }
}

// -------- 单选组 --------
class _LuaRadioGroup extends StatefulWidget {
  const _LuaRadioGroup({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaRadioGroup> createState() => _LuaRadioGroupState();
}

class _LuaRadioGroupState extends State<_LuaRadioGroup> {
  Object? _value;
  @override
  void initState() {
    super.initState();
    _value = widget.props['value'];
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.props['options'];
    final tiles = <Widget>[];
    final horizontal = '${widget.props['axis']}' == 'horizontal';
    if (options is List) {
      for (final o in options) {
        final val = o is Map ? o['value'] : o;
        final label = o is Map ? (o['label'] ?? o['value']) : o;
        final tile = RadioListTile<Object?>(
          title: Text('$label'),
          value: val,
          groupValue: _value,
          contentPadding: horizontal ? EdgeInsets.zero : null,
          onChanged: (v) {
            setState(() => _value = v);
            final fn = widget.props['onChanged'];
            if (fn is LuaFunctionRef) fn.call([v]);
            widget.onAction();
          },
        );
        tiles.add(horizontal ? Expanded(child: tile) : tile);
      }
    }
    if (widget.props['title'] != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text('${widget.props['title']}',
                style: Theme.of(context).textTheme.labelLarge),
          ),
          if (horizontal) Row(children: tiles) else ...tiles,
        ],
      );
    }
    return horizontal
        ? Row(children: tiles)
        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: tiles);
  }
}

// -------- 分段按钮 (单选) --------
class _LuaSegmented extends StatefulWidget {
  const _LuaSegmented({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaSegmented> createState() => _LuaSegmentedState();
}

class _LuaSegmentedState extends State<_LuaSegmented> {
  Object? _value;
  @override
  void initState() {
    super.initState();
    _value = widget.props['value'];
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.props['options'];
    final segments = <ButtonSegment<Object?>>[];
    if (options is List) {
      for (final o in options) {
        final val = o is Map ? o['value'] : o;
        final label = o is Map ? (o['label'] ?? o['value']) : o;
        final iconName = o is Map ? luaIconFor(o['icon']) : null;
        segments.add(ButtonSegment<Object?>(
          value: val,
          label: Text('$label'),
          icon: iconName == null ? null : Icon(iconName),
        ));
      }
    }
    if (segments.isEmpty) return const SizedBox.shrink();
    return SegmentedButton<Object?>(
      segments: segments,
      selected: {_value ?? segments.first.value},
      showSelectedIcon: widget.props['showCheck'] == true,
      onSelectionChanged: (s) {
        setState(() => _value = s.first);
        final fn = widget.props['onChanged'];
        if (fn is LuaFunctionRef) fn.call([s.first]);
        widget.onAction();
      },
    );
  }
}

// -------- ToggleButtons (多选或单选) --------
class _LuaToggleButtons extends StatefulWidget {
  const _LuaToggleButtons({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaToggleButtons> createState() => _LuaToggleButtonsState();
}

class _LuaToggleButtonsState extends State<_LuaToggleButtons> {
  late List<bool> _selected;
  late List<Widget> _labels;
  @override
  void initState() {
    super.initState();
    _rebuild();
  }

  void _rebuild() {
    final options = widget.props['options'];
    _labels = [];
    _selected = [];
    final sel = widget.props['selected'];
    final selSet = sel is List ? sel.map((e) => e).toSet() : <Object?>{};
    if (options is List) {
      for (var i = 0; i < options.length; i++) {
        final o = options[i];
        final label = o is Map ? (o['label'] ?? o['value']) : o;
        final iconName = o is Map ? luaIconFor(o['icon']) : null;
        _labels.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: iconName != null ? Icon(iconName) : Text('$label'),
        ));
        _selected.add(selSet.contains(i) || selSet.contains(label));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.props['multi'] == true;
    return ToggleButtons(
      isSelected: _selected,
      borderRadius: BorderRadius.circular(8),
      onPressed: (i) {
        setState(() {
          if (multi) {
            _selected[i] = !_selected[i];
          } else {
            for (var j = 0; j < _selected.length; j++) {
              _selected[j] = j == i;
            }
          }
        });
        final fn = widget.props['onChanged'];
        if (fn is LuaFunctionRef) {
          final active = <int>[];
          for (var j = 0; j < _selected.length; j++) {
            if (_selected[j]) active.add(j + 1);
          }
          fn.call([i + 1, active]);
        }
        widget.onAction();
      },
      children: _labels,
    );
  }
}

// -------- 日期/时间选择字段 --------
class _LuaDateField extends StatefulWidget {
  const _LuaDateField(
      {required this.props, required this.onAction, required this.mode});
  final Map props;
  final VoidCallback onAction;
  final String mode;
  @override
  State<_LuaDateField> createState() => _LuaDateFieldState();
}

class _LuaDateFieldState extends State<_LuaDateField> {
  String? _display;
  @override
  void initState() {
    super.initState();
    _display = widget.props['value']?.toString();
  }

  @override
  Widget build(BuildContext context) {
    final iconName =
        widget.mode == 'time' ? Icons.access_time : Icons.calendar_today;
    return ListTile(
      leading: Icon(iconName),
      title: Text('${widget.props['label'] ?? (widget.mode == 'time' ? '选择时间' : '选择日期')}'),
      subtitle: _display == null ? null : Text(_display!),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        if (widget.mode == 'time') {
          final t = await showTimePicker(
              context: context, initialTime: TimeOfDay.now());
          if (t != null) {
            setState(() => _display = t.format(context));
            final fn = widget.props['onChanged'];
            if (fn is LuaFunctionRef) fn.call([t.hour, t.minute]);
            widget.onAction();
          }
        } else {
          final now = DateTime.now();
          final d = await showDatePicker(
            context: context,
            initialDate: now,
            firstDate: DateTime(now.year - 50),
            lastDate: DateTime(now.year + 50),
          );
          if (d != null) {
            setState(() =>
                _display = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
            final fn = widget.props['onChanged'];
            if (fn is LuaFunctionRef) fn.call([d.year, d.month, d.day]);
            widget.onAction();
          }
        }
      },
    );
  }
}

// -------- 步进器 --------
class _LuaStepper extends StatefulWidget {
  const _LuaStepper({required this.props, required this.onAction});
  final Map props;
  final VoidCallback onAction;
  @override
  State<_LuaStepper> createState() => _LuaStepperState();
}

class _LuaStepperState extends State<_LuaStepper> {
  late int _current;
  @override
  void initState() {
    super.initState();
    _current = ((widget.props['active'] as num?)?.toInt() ?? 1) - 1;
  }

  @override
  Widget build(BuildContext context) {
    final renderer = LuaRenderer(onAction: widget.onAction);
    final stepsSpec = widget.props['steps'];
    final steps = <Step>[];
    if (stepsSpec is List) {
      for (var i = 0; i < stepsSpec.length; i++) {
        final s = stepsSpec[i];
        final m = s is Map ? s : const {};
        steps.add(Step(
          title: Text('${m['title'] ?? ''}'),
          subtitle: m['subtitle'] == null ? null : Text('${m['subtitle']}'),
          content: m['content'] == null
              ? const SizedBox.shrink()
              : renderer.build(context, m['content']),
          isActive: i == _current,
          state: i < _current ? StepState.complete : StepState.indexed,
        ));
      }
    }
    return Stepper(
      currentStep: _current.clamp(0, steps.isEmpty ? 0 : steps.length - 1),
      type: '${widget.props['axis']}' == 'horizontal'
          ? StepperType.horizontal
          : StepperType.vertical,
      physics: const NeverScrollableScrollPhysics(),
      onStepTapped: (i) {
        setState(() => _current = i);
        final fn = widget.props['onStep'];
        if (fn is LuaFunctionRef) fn.call([i + 1]);
        widget.onAction();
      },
      onStepContinue: () {
        if (_current < steps.length - 1) setState(() => _current++);
        final fn = widget.props['onContinue'];
        if (fn is LuaFunctionRef) fn.call([_current + 1]);
        widget.onAction();
      },
      onStepCancel: () {
        if (_current > 0) setState(() => _current--);
        final fn = widget.props['onCancel'];
        if (fn is LuaFunctionRef) fn.call([_current + 1]);
        widget.onAction();
      },
      steps: steps,
    );
  }
}

/// 生命周期可见性包裹组件 (纯 Lua 动态内容按需加载/卸载)。
/// 可见性 = 所在导航页激活 (LovePageActive) 且 App 在前台; 覆盖 nav / tab / 前后台
/// 的组合变化。回调经 postFrame 派发, 避免在 build 阶段改状态。
class _LuaLifecycle extends StatefulWidget {
  const _LuaLifecycle({required this.node, required this.renderer});
  final Map node;
  final LuaRenderer renderer;
  @override
  State<_LuaLifecycle> createState() => _LuaLifecycleState();
}

class _LuaLifecycleState extends State<_LuaLifecycle>
    with WidgetsBindingObserver {
  bool _appResumed = true;
  bool _pageActive = true;
  bool _visible = false;
  bool _inited = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageActive = LovePageActive.of(context);
    _update();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _update();
  }

  void _fire(Object? fn) {
    if (fn is! LuaFunctionRef) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      fn.call();
      widget.renderer.onAction();
    });
  }

  void _update() {
    final v = _pageActive && _appResumed;
    if (!_inited) {
      _inited = true;
      _visible = v; // 首次可见不触发 onShow (内容已在首次渲染)
      return;
    }
    if (v == _visible) return;
    _visible = v;
    _fire(widget.node[v ? 'onShow' : 'onHide']);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 被移出组件树: 若此前仍处可见态, 视作一次隐藏 (统一 onHide 语义); 另发 onDispose。
    if (_visible) {
      final fn = widget.node['onHide'];
      if (fn is LuaFunctionRef) fn.call();
    }
    final od = widget.node['onDispose'];
    if (od is LuaFunctionRef) od.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.renderer.build(context, widget.node['child']);
}
