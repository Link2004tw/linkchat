// Battery-optimization exemption (Android only).
//
// OEM battery managers (Xiaomi, Samsung, Oppo, …) treat a swiped-away app
// as force-stopped and forbid Google Play services from delivering FCM to
// it. The fix is the doze whitelist: a one-tap system dialog that exempts
// the app. This service wraps the small native bridge in MainActivity.kt;
// every call is a safe no-op on other platforms.

import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

const _channel = MethodChannel('chat/battery');

/// Whether the OS already ignores battery optimization for this app.
/// True on non-Android platforms (nothing to exempt).
Future<bool> isIgnoringBatteryOptimizations() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _channel.invokeMethod<bool>('isIgnoringOptimizations') ?? true;
  } on PlatformException catch (e) {
    debugPrint('battery: check failed — $e');
    return true; // Fail open: never nag if the bridge is broken.
  }
}

/// Launches the system "always run in background?" dialog.
Future<void> requestIgnoreBatteryOptimizations() async {
  if (!Platform.isAndroid) return;
  try {
    await _channel.invokeMethod<void>('requestIgnoration');
  } on PlatformException catch (e) {
    debugPrint('battery: request failed — $e');
  }
}

/// Device manufacturer (lowercased), e.g. "xiaomi", "samsung", "huawei".
/// Null off-Android. Used to show ROM-specific setup hints — the doze
/// whitelist alone doesn't stop MIUI/Huawei/Samsung from blocking swiped
/// apps; each needs its own setting enabled too.
Future<String?> deviceManufacturer() async {
  if (!Platform.isAndroid) return null;
  try {
    final m = await _channel.invokeMethod<String>('manufacturer');
    return m?.toLowerCase();
  } on PlatformException {
    return null;
  }
}

/// ROM-specific hint for where the extra kill-switch lives, or a generic
/// fallback. Shown alongside the battery-optimization prompt.
String manufacturerHint(String? manufacturer) {
  switch (manufacturer) {
    case 'xiaomi':
    case 'redmi':
    case 'poco':
      return 'MIUI: also open Settings → Apps → Manage apps → linkchat → '
          'enable Autostart.';
    case 'samsung':
      return 'Samsung: also open Settings → Battery → Background usage '
          'limits → remove linkchat from Sleeping/Deep sleeping apps.';
    case 'huawei':
    case 'honor':
      return 'Huawei/Honor: also open Settings → Battery → App launch → '
          'linkchat → turn off "Manage automatically" and enable all three '
          'options.';
    case 'oppo':
    case 'realme':
    case 'oneplus':
      return 'Oppo/OnePlus: also open Settings → Battery → linkchat → '
          'allow background activity, and enable Auto-start in App info.';
    case 'vivo':
    case 'iqoo':
      return 'Vivo: also open Settings → Apps → linkchat → Autostart on, '
          'and Battery → High background power consumption allowed.';
    default:
      return 'If notifications still don\u2019t arrive when swiped away, '
          'check your phone\u2019s battery/app-autostart settings for '
          'linkchat and allow background activity.';
  }
}
