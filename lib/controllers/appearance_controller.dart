import 'package:flutter/material.dart';

import '../services/local_app_database.dart';

enum AppThemeColor { white, cream, lightGray, darkGray }

enum AppBrightnessMode { system, light, dark }

extension AppThemeColorValues on AppThemeColor {
  String get label => switch (this) {
    AppThemeColor.white => '白色',
    AppThemeColor.cream => '米白色',
    AppThemeColor.lightGray => '浅灰色',
    AppThemeColor.darkGray => '深灰色',
  };

  Color surface(Brightness brightness) {
    return switch ((this, brightness)) {
      (AppThemeColor.white, Brightness.light) => const Color(0xffffffff),
      (AppThemeColor.cream, Brightness.light) => const Color(0xfff6f1e7),
      (AppThemeColor.lightGray, Brightness.light) => const Color(0xffeef0f2),
      (AppThemeColor.darkGray, Brightness.light) => const Color(0xffc7c9cc),
      (AppThemeColor.white, Brightness.dark) => const Color(0xff121212),
      (AppThemeColor.cream, Brightness.dark) => const Color(0xff211f1a),
      (AppThemeColor.lightGray, Brightness.dark) => const Color(0xff202326),
      (AppThemeColor.darkGray, Brightness.dark) => const Color(0xff141618),
    };
  }
}

extension AppBrightnessModeValues on AppBrightnessMode {
  String get label => switch (this) {
    AppBrightnessMode.system => '跟随系统',
    AppBrightnessMode.light => '始终浅色',
    AppBrightnessMode.dark => '始终深色',
  };

  ThemeMode get themeMode => switch (this) {
    AppBrightnessMode.system => ThemeMode.system,
    AppBrightnessMode.light => ThemeMode.light,
    AppBrightnessMode.dark => ThemeMode.dark,
  };
}

class AppearanceController extends ChangeNotifier {
  AppearanceController(this.database);

  final LocalAppDatabase database;

  AppThemeColor themeColor = AppThemeColor.white;
  AppBrightnessMode brightnessMode = AppBrightnessMode.system;

  Future<void> initialize() async {
    final color = await database.preference('appearance_theme_color');
    themeColor = AppThemeColor.values.firstWhere(
      (value) => value.name == color,
      orElse: () => AppThemeColor.white,
    );
    final mode = await database.preference('appearance_brightness_mode');
    brightnessMode = AppBrightnessMode.values.firstWhere(
      (value) => value.name == mode,
      orElse: () => AppBrightnessMode.system,
    );
    notifyListeners();
  }

  Future<void> setThemeColor(AppThemeColor value) async {
    if (themeColor == value) return;
    themeColor = value;
    notifyListeners();
    await database.setPreference('appearance_theme_color', value.name);
  }

  Future<void> setBrightnessMode(AppBrightnessMode value) async {
    if (brightnessMode == value) return;
    brightnessMode = value;
    notifyListeners();
    await database.setPreference('appearance_brightness_mode', value.name);
  }
}
