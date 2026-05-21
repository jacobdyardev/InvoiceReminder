import 'package:flutter/foundation.dart';
import 'package:invoice_reminder/services/daily_summary_pipeline.dart';
import 'package:invoice_reminder/services/notification_service.dart';
import 'package:invoice_reminder/utils/debug_log.dart';
import 'package:invoice_reminder/utils/reminder_debug_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

const String kLegacyPeriodicSummaryWorkerUniqueName = 'dailySummaryWorker';
const String kLegacyPeriodicSummaryWorkerTaskName = 'daily_summary_refresh';
const String kSummaryProbeTaskName = 'daily_summary_probe';
const String _anchorHourInputKey = 'anchor_hour';

class _WorkerProbeAnchor {
  const _WorkerProbeAnchor({
    required this.label,
    required this.hour,
    required this.uniqueName,
    required this.lastFiredKey,
    required this.outcomeKey,
    required this.nextScheduledForKey,
  });

  final String label;
  final int hour;
  final String uniqueName;
  final String lastFiredKey;
  final String outcomeKey;
  final String nextScheduledForKey;
}

const _WorkerProbeAnchor _probe1AmAnchor = _WorkerProbeAnchor(
  label: '1AM',
  hour: 1,
  uniqueName: 'dailySummaryProbe1am',
  lastFiredKey: kLastWorkerProbe1AmFiredKey,
  outcomeKey: kLastWorkerProbe1AmOutcomeKey,
  nextScheduledForKey: kNextWorkerProbe1AmScheduledForKey,
);

const _WorkerProbeAnchor _probe7AmAnchor = _WorkerProbeAnchor(
  label: '7AM',
  hour: 7,
  uniqueName: 'dailySummaryProbe7am',
  lastFiredKey: kLastWorkerProbe7AmFiredKey,
  outcomeKey: kLastWorkerProbe7AmOutcomeKey,
  nextScheduledForKey: kNextWorkerProbe7AmScheduledForKey,
);

const List<_WorkerProbeAnchor> _workerProbeAnchors = [
  _probe1AmAnchor,
  _probe7AmAnchor,
];

DateTime _computeNextAnchorTime({
  required DateTime now,
  required int hour,
}) {
  final todayAnchor = DateTime(now.year, now.month, now.day, hour);

  if (now.isBefore(todayAnchor)) {
    return todayAnchor;
  }

  return todayAnchor.add(const Duration(days: 1));
}

bool _isAllowedMorningWindow(DateTime now) {
  return now.hour >= 0 && now.hour < 9;
}

bool _isSameCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

bool _hasDailySuccessLock({
  required SharedPreferences prefs,
  required DateTime now,
}) {
  final raw = prefs.getString(kSummaryScheduledForDayKey);
  final scheduledDay = raw != null ? DateTime.tryParse(raw) : null;

  if (scheduledDay == null) {
    return false;
  }

  return _isSameCalendarDay(scheduledDay, now);
}

_WorkerProbeAnchor? _anchorForHour(int? hour) {
  for (final anchor in _workerProbeAnchors) {
    if (anchor.hour == hour) {
      return anchor;
    }
  }

  return null;
}

Future<void> _scheduleNextAnchorProbe({
  required _WorkerProbeAnchor anchor,
  required SharedPreferences prefs,
  DateTime? now,
}) async {
  final effectiveNow = now ?? DateTime.now();
  final nextRun = _computeNextAnchorTime(
    now: effectiveNow,
    hour: anchor.hour,
  );
  final initialDelay = nextRun.difference(effectiveNow);

  await Workmanager().registerOneOffTask(
    anchor.uniqueName,
    kSummaryProbeTaskName,
    existingWorkPolicy: ExistingWorkPolicy.replace,
    initialDelay: initialDelay,
    inputData: {_anchorHourInputKey: anchor.hour},
  );

  await prefs.setString(
    anchor.nextScheduledForKey,
    nextRun.toIso8601String(),
  );

  debugLog(
    "WORKER ${anchor.label} next probe -> ${nextRun.toIso8601String()}",
    tag: "WORKER",
  );
}

Future<void> registerDeterministicSummaryWorkerProbes() async {
  final now = DateTime.now();
  final prefs = await SharedPreferences.getInstance();

  debugLog(
    "WORKER refreshing deterministic probes @ ${now.toIso8601String()}",
    tag: "WORKER",
  );

  await Workmanager().cancelByUniqueName(kLegacyPeriodicSummaryWorkerUniqueName);

  for (final anchor in _workerProbeAnchors) {
    await _scheduleNextAnchorProbe(
      anchor: anchor,
      prefs: prefs,
      now: now,
    );
  }
}

Future<void> _runDeterministicProbe(_WorkerProbeAnchor anchor) async {
  final now = DateTime.now();

  debugLog(
    "BACKGROUND WORKER ${anchor.label} EXECUTED @ ${now.toIso8601String()}",
    tag: "WORKER",
  );

  await NotificationService.init(background: true);

  final prefs = await SharedPreferences.getInstance();

  await prefs.setString('last_worker_run', now.toIso8601String());
  await prefs.setString(anchor.lastFiredKey, now.toIso8601String());

  String outcome;

  if (_hasDailySuccessLock(prefs: prefs, now: now)) {
    outcome = 'skipped_daily_success';
    debugLog(
      "WORKER ${anchor.label} skipped (daily success lock present)",
      tag: "WORKER",
    );
  } else if (!_isAllowedMorningWindow(now)) {
    outcome = 'skipped_outside_window';
    debugLog(
      "WORKER ${anchor.label} skipped (outside morning window)",
      tag: "WORKER",
    );
  } else {
    outcome = 'pipeline_started';
    debugLog(
      "WORKER ${anchor.label} -> pipeline START",
      tag: "WORKER",
    );
    await runDailySummaryPipeline();
    debugLog(
      "WORKER ${anchor.label} -> pipeline END",
      tag: "WORKER",
    );
  }

  await prefs.setString(anchor.outcomeKey, outcome);
  await _scheduleNextAnchorProbe(anchor: anchor, prefs: prefs, now: DateTime.now());

  if (kDebugMode) {
    await NotificationService.debugPendingNotifications();
  }
}

// Workmanager entry point for deterministic worker probes.
// Each run checks recovery predicates, optionally starts the pipeline,
// then reschedules the next calendar occurrence of the same anchor.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == kLegacyPeriodicSummaryWorkerTaskName) {
      await Workmanager().cancelByUniqueName(kLegacyPeriodicSummaryWorkerUniqueName);
      return Future.value(true);
    }

    if (task != kSummaryProbeTaskName) {
      return Future.value(true);
    }

    final anchorHour = inputData?[_anchorHourInputKey] as int?;
    final anchor = _anchorForHour(anchorHour);

    if (anchor == null) {
      return Future.value(true);
    }

    await _runDeterministicProbe(anchor);

    return Future.value(true);
  });
}
