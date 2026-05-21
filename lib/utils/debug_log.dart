import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:invoice_reminder/utils/reminder_debug_keys.dart';

// Central debug flags for console and persistent reminder diagnostics.
class DebugConfig {
  // Master debug switches
  static const bool forceFreeMode = false;

  static const bool showNotificationLogs = true;
  static const bool verboseScheduling = true;

  // Console logs only
  static bool get enabled => kDebugMode;

  // Persistent reminder diagnostics
  static const bool reminderDiagnosticsEnabled = true;
}

// Writes a tagged debug line to console and persistent reminder logs.
// Used across scheduling, pipeline, worker, and debug flows.
void debugLog(
  Object? message, {
  String tag = "GENERAL",
  bool categoryEnabled = true,
}) {
  if (!categoryEnabled) return;

  final line = "IR_$tag → ${message.toString()}";

  if (DebugConfig.enabled) {
    debugPrint(line);
  }

  if (DebugConfig.reminderDiagnosticsEnabled) {
    unawaited(appendReminderDebugLog(line));
  }
}
