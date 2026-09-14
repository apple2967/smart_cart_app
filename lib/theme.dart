import 'package:flutter/material.dart';

/// 다크 고정. 순검정(#000) 금지.
/// 테두리·구분선 없이 면의 톤 차이로만 영역을 나눈다.
abstract final class CartColors {
  static const bg = Color(0xFF17171A);
  static const card = Color(0xFF212126);
  static const text = Color(0xFFF2F2F5);
  static const muted = Color(0xFF8A8A92);
  static const warn = Color(0xFFF09595);
  static const warnBg = Color(0xFF2A2024);
  static const accent = Color(0xFF85B7EB);
  static const grid = Color(0xFF3C3C44);
}

abstract final class CartRadii {
  static const card = 18.0;
}

abstract final class CartText {
  static const bigNumber = TextStyle(
    fontSize: 46,
    fontWeight: FontWeight.w500,
    letterSpacing: -1.5,
    height: 1.1,
    color: CartColors.text,
    // 10Hz로 값이 바뀔 때 숫자 폭이 흔들리지 않게
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const unit = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w500,
    color: CartColors.muted,
  );

  static const title = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: CartColors.text,
  );

  static const label = TextStyle(fontSize: 13, color: CartColors.muted);
}

ThemeData buildCartTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: CartColors.bg,
    colorScheme: const ColorScheme.dark(
      surface: CartColors.bg,
      onSurface: CartColors.text,
      primary: CartColors.accent,
      error: CartColors.warn,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: CartColors.text,
      displayColor: CartColors.text,
    ),
    dividerColor: Colors.transparent,
    splashFactory: NoSplash.splashFactory,
  );
}
