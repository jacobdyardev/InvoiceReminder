import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:invoice_reminder/services/daily_summary_pipeline.dart';
import 'package:invoice_reminder/services/notification_ids.dart';
import 'package:invoice_reminder/services/notification_service.dart';
import 'package:invoice_reminder/utils/debug_log.dart';
import 'package:invoice_reminder/utils/reminder_debug_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Describes one reconciliation slot, including its alarm ID,
// debug key, and callback entry point.
class _ReconciliationSlot {
  const _ReconciliationSlot({
    required this.label,
    required this.hour,
    required this.alarmId,
    required this.nextScheduledForKey,
    required this.callback,
  });

  final String label;
  final int hour;
  final int alarmId;
  final String nextScheduledForKey;
  final Future<void> Function() callback;
}

const List<_ReconciliationSlot> _reconciliationSlots = [
  _ReconciliationSlot(
    label: '2AM',
    hour: 2,
    alarmId: kReconciliation2AmAlarmId,
    nextScheduledForKey: kNextReconciliation2AmScheduledForKey,
    callback: reconciliation2AmAlarmCallback,
  ),
  _ReconciliationSlot(
    label: '4AM',
    hour: 4,
    alarmId: kReconciliation4AmAlarmId,
    nextScheduledForKey: kNextReconciliation4AmScheduledForKey,
    callback: reconciliation4AmAlarmCallback,
  ),
  _ReconciliationSlot(
    label: '6AM',
    hour: 6,
    alarmId: kReconciliation6AmAlarmId,
    nextScheduledForKey: kNextReconciliation6AmScheduledForKey,
    callback: reconciliation6AmAlarmCallback,
  ),
];

// Returns the next valid timestamp for a reconciliation slot.
// Past slots roll forward to the next calendar day.
DateTime _computeNextSlotTimestamp({
  required DateTime now,
  required int hour,
}) {
  final todaySlot = DateTime(now.year, now.month, now.day, hour);

  if (now.isBefore(todaySlot)) {
    return todaySlot;
  }

  return todaySlot.add(const Duration(days: 1));
}

// Compares only the calendar day portion of two timestamps.
bool _isSameCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

// Computes the next intended 2 AM, 4 AM, and 6 AM slot targets.
// This is the scheduler's deterministic source of truth.
Map<_ReconciliationSlot, DateTime> _computeReconciliationSlotTargets({
  DateTime? now,
}) {
  final effectiveNow = now ?? DateTime.now();

  return {
    for (final slot in _reconciliationSlots)
      slot: _computeNextSlotTimestamp(
        now: effectiveNow,
        hour: slot.hour,
      ),
  };
}

// Clears the legacy reconciliation alarm and all known slot alarms.
// Used by full refresh paths before rebuilding the batch.
Future<void> _cancelKnownReconciliationAlarms() async {
  await AndroidAlarmManager.cancel(kReconciliationAlarmId);

  for (final slot in _reconciliationSlots) {
    await AndroidAlarmManager.cancel(slot.alarmId);
  }
}

// Schedules one reconciliation slot and persists its next target time.
// Writes SharedPreferences telemetry for debug visibility.
Future<void> _scheduleSingleReconciliationSlot({
  required SharedPreferences prefs,
  required _ReconciliationSlot slot,
  required DateTime target,
}) async {
  debugLog(
    "Scheduling reconciliation slot ${slot.label} @ $target",
    tag: "ALARM",
  );

  await AndroidAlarmManager.oneShotAt(
    target,
    slot.alarmId,
    slot.callback,
    exact: true,
    wakeup: true,
    rescheduleOnReboot: true,
  );

  await prefs.setString(
    slot.nextScheduledForKey,
    target.toIso8601String(),
  );
}

// Updates the legacy earliest-scheduled telemetry key from slot data.
// This keeps older debug fields usable during migration.
Future<void> _persistLegacyNextScheduledTelemetry(
  SharedPreferences prefs,
) async {
  DateTime? earliest;

  for (final slot in _reconciliationSlots) {
    final raw = prefs.getString(slot.nextScheduledForKey);
    final scheduledFor =
        raw != null ? DateTime.tryParse(raw) : null;

    if (scheduledFor == null) {
      continue;
    }

    if (earliest == null || scheduledFor.isBefore(earliest)) {
      earliest = scheduledFor;
    }
  }

  if (earliest != null) {
    await prefs.setString(
      kLastAlarmScheduledForKey,
      earliest.toIso8601String(),
    );
  }
}

// Rebuilds the full 2 AM, 4 AM, and 6 AM reconciliation batch.
// Used only by explicit refresh paths and always cancels known alarms first.
Future<void> scheduleDailyReconciliationBatch() async {
  final now = DateTime.now();
  final prefs = await SharedPreferences.getInstance();
  final targets = _computeReconciliationSlotTargets(now: now);

  debugLog(
    "Refreshing reconciliation batch @ $now",
    tag: "ALARM",
  );

  await _cancelKnownReconciliationAlarms();

  final orderedTargets = [
    for (final slot in _reconciliationSlots) MapEntry(slot, targets[slot]!),
  ]..sort((a, b) => a.value.compareTo(b.value));

  for (final entry in orderedTargets) {
    await _scheduleSingleReconciliationSlot(
      prefs: prefs,
      slot: entry.key,
      target: entry.value,
    );
  }

  await _persistLegacyNextScheduledTelemetry(prefs);

  debugLog(
    "Reconciliation batch refreshed -> "
    "2AM:${targets[_reconciliationSlots[0]]} "
    "4AM:${targets[_reconciliationSlots[1]]} "
    "6AM:${targets[_reconciliationSlots[2]]}",
    tag: "ALARM",
  );
}

// Compatibility wrapper for older call sites during migration.
// Delegates directly to the batch scheduler.
Future<void> scheduleDailyReconciliationAlarm() async {
  await scheduleDailyReconciliationBatch();
}

// Ensures next-day reconciliation slots exist without removing
// same-day retry alarms. Used only from fired alarm callbacks.
Future<void> ensureNextDayReconciliationScheduled() async {
  final now = DateTime.now();
  final prefs = await SharedPreferences.getInstance();
  final targets = _computeReconciliationSlotTargets(now: now);

  debugLog(
    "Ensuring next-day reconciliation sustain @ $now",
    tag: "ALARM",
  );

  for (final slot in _reconciliationSlots) {
    final target = targets[slot]!;

    if (_isSameCalendarDay(target, now)) {
      continue;
    }

    await AndroidAlarmManager.cancel(slot.alarmId);
    await _scheduleSingleReconciliationSlot(
      prefs: prefs,
      slot: slot,
      target: target,
    );
  }

  await _persistLegacyNextScheduledTelemetry(prefs);
}

// Handles one reconciliation alarm callback from the background.
// Writes callback telemetry, sustains next-day slots, and runs the pipeline.
Future<void> _handleReconciliationAlarm({
  required _ReconciliationSlot slot,
}) async {
  final start = DateTime.now();
  final now = DateTime.now();

  debugLog(
    "ALARM RECONCILIATION RUNNING ${slot.label} @ $now",
    tag: "ALARM",
  );

  await NotificationService.init(background: true);

  final prefs = await SharedPreferences.getInstance();
  final scheduledTodayValue =
      DateTime(now.year, now.month, now.day).toIso8601String();
  final scheduledDayBeforeRun =
      prefs.getString(kSummaryScheduledForDayKey);

  await prefs.setString(
    kLastAlarmCallbackKey,
    now.toIso8601String(),
  );
  await prefs.setString(
    'last_reconciliation_run',
    now.toIso8601String(),
  );
  await prefs.setString(
    kLastReconciliationSlotFiredKey,
    slot.label,
  );

  await ensureNextDayReconciliationScheduled();

  final count = (prefs.getInt(kPipelineRunCountKey) ?? 0) + 1;
  await prefs.setInt(kPipelineRunCountKey, count);

  debugLog(
    "ALARM CALLBACK COUNT -> $count",
    tag: "ALARM",
  );
  debugLog(
    "ALARM ${slot.label} -> pipeline START",
    tag: "ALARM",
  );

  await runDailySummaryPipeline();

  final scheduledDayAfterRun =
      prefs.getString(kSummaryScheduledForDayKey);

  if (scheduledDayBeforeRun != scheduledTodayValue &&
      scheduledDayAfterRun == scheduledTodayValue) {
    await prefs.setString(
      kLastSuccessfulReconciliationScheduleSlotKey,
      slot.label,
    );
  }

  debugLog(
    "ALARM ${slot.label} -> pipeline END",
    tag: "ALARM",
  );

  if (kDebugMode) {
    await NotificationService.showImmediateNotification(
      id: 999999,
      title: "Alarm Fired",
      body: "${slot.label} reconciliation executed",
    );
  }

  debugLog(
    "ALARM RECONCILIATION COMPLETE ${slot.label}",
    tag: "ALARM",
  );

  final duration = DateTime.now().difference(start);

  debugLog(
    "ALARM ${slot.label} duration -> ${duration.inSeconds}s",
    tag: "ALARM",
  );
}

// Entry point for the 2 AM reconciliation alarm callback.
@pragma('vm:entry-point')
Future<void> reconciliation2AmAlarmCallback() async {
  await _handleReconciliationAlarm(slot: _reconciliationSlots[0]);
}

// Entry point for the 4 AM reconciliation alarm callback.
@pragma('vm:entry-point')
Future<void> reconciliation4AmAlarmCallback() async {
  await _handleReconciliationAlarm(slot: _reconciliationSlots[1]);
}

// Entry point for the 6 AM reconciliation alarm callback.
@pragma('vm:entry-point')
Future<void> reconciliation6AmAlarmCallback() async {
  await _handleReconciliationAlarm(slot: _reconciliationSlots[2]);
}
