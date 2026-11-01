import 'dart:io';

import 'package:flutter/foundation.dart';

/// Phone vs computer. The same app runs on the S23 (Android) and the Surface (Windows on ARM).
/// [desktopOverride] lets tests run the desktop code paths on Linux.
bool? desktopOverride;

bool get isDesktop => desktopOverride ?? (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS));
bool get isPhone => !isDesktop;
