import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Marks whether the nav page subtree containing a [LoveGameView] is currently
/// the visible one. Used to auto-suspend the game when its page is not shown.
class LovePageActive extends InheritedWidget {
  const LovePageActive({super.key, required this.active, required super.child});

  final bool active;

  static bool of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<LovePageActive>();
    return w?.active ?? true;
  }

  @override
  bool updateShouldNotify(LovePageActive oldWidget) => active != oldWidget.active;
}

/// A "sticker canvas" that renders an embedded LÖVE (love2d) game into a Flutter
/// texture. It behaves like any other Flutter widget and can be sized/placed
/// freely (full content area, or a small card among other widgets).
///
/// Lifecycle: the underlying engine stays alive for the app session (SDL cannot
/// re-init in-process). Rendering is *suspended* (kept in memory, not running)
/// when the widget's nav page is hidden or the app is backgrounded, and resumed
/// when shown again — so game state is never lost on an accidental tab switch.
class LoveGameView extends StatefulWidget {
  const LoveGameView({
    super.key,
    this.canvasId = 0,
    this.gamePath,
    this.bridgeArg,
    this.autoSuspend = true,
    this.keepAlive = true,
    this.quarterTurns = 0,
  });

  /// Stable identity of this canvas (0..3). Each distinct id runs in its own
  /// process and is an independent love instance. Placing multiple canvases
  /// means giving each a different id.
  final int canvasId;

  /// Path to a `.love` archive or a directory with `main.lua`. Null -> sample.
  final String? gamePath;

  /// Extra argument injected into the love game (bidirectional bridge conn info).
  final String? bridgeArg;

  /// Suspend rendering automatically when the page is hidden (default true).
  final bool autoSuspend;

  /// When true (default), the underlying engine/process is kept alive on
  /// dispose (only paused) so state survives re-mounts. When false, disposing
  /// this widget fully destroys the canvas process, so the next mount boots a
  /// brand-new instance from scratch (true "dynamic reload").
  final bool keepAlive;

  /// Quarter turns (0/1/3) to rotate the game 90° while the app frame stays
  /// portrait: the underlying engine renders into a landscape surface (width/
  /// height swapped) and the texture is displayed rotated to fill this widget,
  /// with touch input transformed to match. 1 = clockwise, 3 = counter-clockwise.
  final int quarterTurns;

  @override
  State<LoveGameView> createState() => _LoveGameViewState();
}

class _LoveGameViewState extends State<LoveGameView> with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel('love_texture_channel');

  int? _textureId;
  int _pxW = 0, _pxH = 0;
  double _logW = 1, _logH = 1;
  bool _starting = false;
  bool _running = false; // SDL currently resumed & rendering
  bool _appResumed = true;
  bool _pageActive = true;

  bool get _shouldRun => (!widget.autoSuspend) || (_pageActive && _appResumed);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageActive = LovePageActive.of(context);
    _apply();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _apply();
  }

  Future<void> _apply() async {
    if (_textureId == null) return;
    if (_shouldRun && !_running) {
      _running = true;
      try {
        await _channel.invokeMethod('resume', {'canvasId': widget.canvasId});
      } catch (_) {}
    } else if (!_shouldRun && _running) {
      _running = false;
      try {
        await _channel.invokeMethod('pause', {'canvasId': widget.canvasId});
      } catch (_) {}
    }
  }

  Future<void> _ensureStarted(int w, int h) async {
    if (_starting || _textureId != null) return;
    if (!_shouldRun) return; // don't boot while hidden
    _starting = true;
    try {
      final int id = await _channel.invokeMethod('start', {
        'canvasId': widget.canvasId,
        'width': w,
        'height': h,
        if (widget.gamePath != null) 'path': widget.gamePath,
        if (widget.bridgeArg != null) 'bridge': widget.bridgeArg,
      });
      if (mounted) {
        setState(() {
          _textureId = id;
          _pxW = w;
          _pxH = h;
          _running = true;
        });
      }
    } catch (e) {
      debugPrint('LoveGameView start failed: $e');
    } finally {
      _starting = false;
    }
  }

  Future<void> _resize(int w, int h) async {
    _pxW = w;
    _pxH = h;
    try {
      await _channel.invokeMethod('resize', {
        'canvasId': widget.canvasId,
        'width': w,
        'height': h,
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.keepAlive) {
      // Keep the engine alive; just stop rendering (state preserved on re-mount).
      _channel.invokeMethod('pause', {'canvasId': widget.canvasId});
    } else {
      // Fully tear down: kill the canvas process so the next mount starts fresh.
      _channel.invokeMethod('destroy', {'canvasId': widget.canvasId});
    }
    super.dispose();
  }

  void _sendTouch(int action, Offset local) {
    if (!_running) return;
    final double px = (local.dx / _logW).clamp(0.0, 1.0);
    final double py = (local.dy / _logH).clamp(0.0, 1.0);
    double nx, ny;
    switch (widget.quarterTurns) {
      case 1: // clockwise: game is landscape, displayed rotated 90° CW
        nx = py;
        ny = 1.0 - px;
        break;
      case 3: // counter-clockwise
        nx = 1.0 - py;
        ny = px;
        break;
      default:
        nx = px;
        ny = py;
    }
    _channel.invokeMethod('touch', {
      'canvasId': widget.canvasId,
      'id': 0,
      'action': action,
      'x': nx,
      'y': ny,
      'p': 1.0,
    });
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final bool rotated = widget.quarterTurns == 1 || widget.quarterTurns == 3;
    return LayoutBuilder(
      builder: (context, constraints) {
        _logW = constraints.maxWidth;
        _logH = constraints.maxHeight;
        // The underlying engine renders into a surface sized to the *displayed*
        // orientation. When rotated 90°, the game is landscape, so swap dims.
        final int bw = (constraints.maxWidth * dpr).round().clamp(1, 4096);
        final int bh = (constraints.maxHeight * dpr).round().clamp(1, 4096);
        final int w = rotated ? bh : bw;
        final int h = rotated ? bw : bh;

        if (_textureId == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStarted(w, h));
          return const ColoredBox(
            color: Colors.black,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (w != _pxW || h != _pxH) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _resize(w, h));
        }

        Widget tex = Texture(textureId: _textureId!);
        if (rotated) {
          tex = RotatedBox(quarterTurns: widget.quarterTurns, child: tex);
        }
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _sendTouch(0, e.localPosition), // ACTION_DOWN
          onPointerMove: (e) => _sendTouch(2, e.localPosition), // ACTION_MOVE
          onPointerUp: (e) => _sendTouch(1, e.localPosition), // ACTION_UP
          onPointerCancel: (e) => _sendTouch(3, e.localPosition), // ACTION_CANCEL
          child: tex,
        );
      },
    );
  }
}
