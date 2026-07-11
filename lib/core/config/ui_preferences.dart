import 'package:settings/settings.dart';

class UiPreferences {
  static SettingNode get _homeBackgroundPath => 'home_background_path'.setting;
  static SettingNode get _cardGlassOpacity => 'card_glass_opacity'.setting;
  static SettingNode get _glassBlurAmount => 'glass_blur_amount'.setting;
  static SettingNode get _topNavGlassOpacity => 'top_nav_glass_opacity'.setting;
  static SettingNode get _statusOverlayOpacity =>
      'status_overlay_opacity'.setting;
  static SettingNode get _terminalOverlayOpacity =>
      'terminal_overlay_opacity'.setting;

  static String get homeBackgroundPath =>
      _homeBackgroundPath.get()?.toString() ?? '';
  static double get cardGlassOpacity => _readOpacity(_cardGlassOpacity, 0.62);
  static double get glassBlurAmount => _readPercent(_glassBlurAmount, 0.45);
  static double get topNavGlassOpacity =>
      _readOpacity(_topNavGlassOpacity, 0.62);
  static double get statusOverlayOpacity =>
      _readOpacity(_statusOverlayOpacity, 0.38);
  static double get terminalOverlayOpacity =>
      _readOpacity(_terminalOverlayOpacity, 0.65);

  static void saveHomeBackgroundPath(String path) {
    _homeBackgroundPath.set(path);
  }

  static void clearHomeBackgroundPath() {
    _homeBackgroundPath.set('');
  }

  static void saveCardGlassOpacity(double value) {
    _cardGlassOpacity.set(_normalizeOpacity(value));
  }

  static void saveGlassBlurAmount(double value) {
    _glassBlurAmount.set(_normalizePercent(value));
  }

  static void saveTopNavGlassOpacity(double value) {
    _topNavGlassOpacity.set(_normalizeOpacity(value));
  }

  static void saveStatusOverlayOpacity(double value) {
    _statusOverlayOpacity.set(_normalizeOpacity(value));
  }

  static void saveTerminalOverlayOpacity(double value) {
    _terminalOverlayOpacity.set(_normalizeOpacity(value));
  }

  static double _readOpacity(SettingNode node, double fallback) {
    final value = node.get();
    final opacity = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (opacity == null) return fallback;
    return _normalizeOpacity(opacity);
  }

  static double _readPercent(SettingNode node, double fallback) {
    final value = node.get();
    final percent = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (percent == null) return fallback;
    return _normalizePercent(percent);
  }

  static double _normalizeOpacity(double value) {
    return value.clamp(0.0, 0.95).toDouble();
  }

  static double _normalizePercent(double value) {
    return value.clamp(0.0, 1.0).toDouble();
  }
}
