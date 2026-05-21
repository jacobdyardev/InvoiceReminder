import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:invoice_reminder/services/notification_service.dart';
import 'package:invoice_reminder/services/notification_ids.dart';
import 'package:invoice_reminder/utils/debug_log.dart';
import 'package:invoice_reminder/utils/reminder_debug_keys.dart';

bool _pipelineRunning = false;
const Duration _summaryLeaseTtl = Duration(minutes: 5);

// Formats a date as a canonical lease day string.
// This keeps SharedPreferences lease keys day-scoped.
String _formatLeaseDay(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');

  return '${date.year}-$month-$day';
}

// Creates a unique lease owner token for one pipeline attempt.
// Used to verify lease ownership across async work.
String _newLeaseOwner() {
  final random = Random();
  final millis = DateTime.now().millisecondsSinceEpoch;
  final nonce = random.nextInt(1 << 32);

  return '$millis-$nonce';
}

// Stores the latest lease action for debug visibility.
// This is written on acquire, refresh, block, expiry, and release.
Future<void> _persistLeaseTelemetry({
  required SharedPreferences prefs,
  String? leaseOwner,
  String? leaseDay,
  String? leaseAction,
  required DateTime timestamp,
}) async {
  await prefs.setString(
    kLastPipelineLeaseOwnerKey,
    leaseOwner ?? '-',
  );
  await prefs.setString(
    kLastPipelineLeaseDayKey,
    leaseDay ?? '-',
  );
  await prefs.setString(
    kLastPipelineLeaseTimestampKey,
    timestamp.toIso8601String(),
  );
  await prefs.setString(
    kLastPipelineLeaseActionKey,
    leaseAction ?? '-',
  );
}

// Stores the latest pipeline skip or exit reason in SharedPreferences.
// Used by the debug screen to explain why work did not continue.
Future<void> _persistPipelineSkipReason({
  required SharedPreferences prefs,
  required String reason,
  required DateTime timestamp,
}) async {
  await prefs.setString(kLastPipelineSkipReasonKey, reason);
  await prefs.setString(kLastPipelineNowKey, timestamp.toIso8601String());
}

// Attempts to claim the day-scoped pipeline lease.
// Blocks concurrent or stale retry work across isolates.
Future<bool> _acquireSummaryEntryLease({
  required SharedPreferences prefs,
  required DateTime now,
  required String leaseOwner,
}) async {
  final leaseDay = _formatLeaseDay(now);
  final existingDay = prefs.getString(kSummaryEntryLeaseDayKey);
  final existingExpiryRaw = prefs.getString(kSummaryEntryLeaseExpiresAtKey);
  final existingExpiry =
      existingExpiryRaw != null ? DateTime.tryParse(existingExpiryRaw) : null;

  final hasActiveLeaseForToday =
      existingDay == leaseDay &&
      existingExpiry != null &&
      existingExpiry.isAfter(now);

  if (hasActiveLeaseForToday) {
    await _persistLeaseTelemetry(
      prefs: prefs,
      leaseOwner: prefs.getString(kSummaryEntryLeaseOwnerKey),
      leaseDay: existingDay,
      leaseAction: 'blocked',
      timestamp: now,
    );
    debugLog(
      "PIPELINE LEASE blocked day:$leaseDay expires:$existingExpiryRaw",
      tag: "PIPELINE",
    );
    return false;
  }

  final hadExpiredLeaseForToday =
      existingDay == leaseDay &&
      existingExpiry != null &&
      !existingExpiry.isAfter(now);

  if (hadExpiredLeaseForToday) {
    await _persistLeaseTelemetry(
      prefs: prefs,
      leaseOwner: prefs.getString(kSummaryEntryLeaseOwnerKey),
      leaseDay: existingDay,
      leaseAction: 'expired',
      timestamp: now,
    );
    debugLog(
      "PIPELINE LEASE expired day:$leaseDay expired_at:$existingExpiryRaw",
      tag: "PIPELINE",
    );
  }

  final expiresAt = now.add(_summaryLeaseTtl);

  await prefs.setString(kSummaryEntryLeaseDayKey, leaseDay);
  await prefs.setString(kSummaryEntryLeaseOwnerKey, leaseOwner);
  await prefs.setString(
    kSummaryEntryLeaseExpiresAtKey,
    expiresAt.toIso8601String(),
  );

  final verifiedOwner = prefs.getString(kSummaryEntryLeaseOwnerKey);
  final verifiedDay = prefs.getString(kSummaryEntryLeaseDayKey);

  if (verifiedOwner != leaseOwner || verifiedDay != leaseDay) {
    await _persistLeaseTelemetry(
      prefs: prefs,
      leaseOwner: verifiedOwner,
      leaseDay: verifiedDay,
      leaseAction: 'verification_failed',
      timestamp: now,
    );
    debugLog(
      "PIPELINE LEASE verification_failed day:$leaseDay",
      tag: "PIPELINE",
    );
    return false;
  }

  await _persistLeaseTelemetry(
    prefs: prefs,
    leaseOwner: leaseOwner,
    leaseDay: leaseDay,
    leaseAction: 'acquired',
    timestamp: now,
  );

  debugLog(
    "PIPELINE LEASE acquired day:$leaseDay expires:${expiresAt.toIso8601String()}",
    tag: "PIPELINE",
  );

  return true;
}

// Extends the active pipeline lease after initialization succeeds.
// Prevents another isolate from taking over mid-run.
Future<bool> _refreshSummaryEntryLease({
  required SharedPreferences prefs,
  required DateTime now,
  required String leaseOwner,
}) async {
  final leaseDay = _formatLeaseDay(now);
  final currentOwner = prefs.getString(kSummaryEntryLeaseOwnerKey);
  final currentDay = prefs.getString(kSummaryEntryLeaseDayKey);

  if (currentOwner != leaseOwner || currentDay != leaseDay) {
    await _persistLeaseTelemetry(
      prefs: prefs,
      leaseOwner: currentOwner,
      leaseDay: currentDay,
      leaseAction: 'verification_failed',
      timestamp: now,
    );
    debugLog(
      "PIPELINE LEASE verification_failed day:$leaseDay",
      tag: "PIPELINE",
    );
    return false;
  }

  final expiresAt = now.add(_summaryLeaseTtl);

  await prefs.setString(
    kSummaryEntryLeaseExpiresAtKey,
    expiresAt.toIso8601String(),
  );

  await _persistLeaseTelemetry(
    prefs: prefs,
    leaseOwner: leaseOwner,
    leaseDay: leaseDay,
    leaseAction: 'refreshed',
    timestamp: now,
  );

  debugLog(
    "PIPELINE LEASE refreshed day:$leaseDay expires:${expiresAt.toIso8601String()}",
    tag: "PIPELINE",
  );

  return true;
}

// Releases the lease if this pipeline attempt still owns it.
// This must not clear another isolate's lease state.
Future<void> _releaseSummaryEntryLease({
  required SharedPreferences prefs,
  required DateTime now,
  required String leaseOwner,
}) async {
  final leaseDay = _formatLeaseDay(now);
  final currentOwner = prefs.getString(kSummaryEntryLeaseOwnerKey);
  final currentDay = prefs.getString(kSummaryEntryLeaseDayKey);

  if (currentOwner != leaseOwner || currentDay != leaseDay) {
    return;
  }

  await _persistLeaseTelemetry(
    prefs: prefs,
    leaseOwner: currentOwner,
    leaseDay: currentDay,
    leaseAction: 'released',
    timestamp: now,
  );

  await prefs.remove(kSummaryEntryLeaseDayKey);
  await prefs.remove(kSummaryEntryLeaseOwnerKey);
  await prefs.remove(kSummaryEntryLeaseExpiresAtKey);

  debugLog(
    "PIPELINE LEASE released day:$leaseDay",
    tag: "PIPELINE",
  );
}

// Runs the deterministic morning summary scheduling pipeline.
// Enforces the morning cutoff, daily lock, lease, notification writes, and telemetry.
Future<void> runDailySummaryPipeline() async {

  final now = DateTime.now();
  final hour = now.hour;

  // Runs only inside the allowed morning window.
  // No same-day recovery is allowed after 9:00 AM.
  final isAllowedWindow = hour >= 0 && hour < 9;

  if (!isAllowedWindow) {
    await _persistPipelineSkipReason(
      prefs: await SharedPreferences.getInstance(),
      reason: 'outside_allowed_window',
      timestamp: now,
    );
    debugLog(
      "PIPELINE BLOCKED (outside allowed window)",
      tag: "PIPELINE",
    );
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final leaseOwner = _newLeaseOwner();

  final today = DateTime(now.year, now.month, now.day);

  // Skips if a successful scheduling pass was already recorded for today.
  final lastScheduledDayStr =
      prefs.getString(kSummaryScheduledForDayKey);

  final lastScheduledDay =
      lastScheduledDayStr != null
          ? DateTime.tryParse(lastScheduledDayStr)
          : null;

  final alreadyScheduledToday =
      lastScheduledDay != null &&
      lastScheduledDay.year == today.year &&
      lastScheduledDay.month == today.month &&
      lastScheduledDay.day == today.day;

  if (alreadyScheduledToday) {
    await _persistPipelineSkipReason(
      prefs: prefs,
      reason: 'already_scheduled_today',
      timestamp: now,
    );
    debugLog(
      "PIPELINE SKIPPED (already scheduled today)",
      tag: "PIPELINE",
    );
    return;
  }

  // Blocks overlapping work inside the current isolate.
  if (_pipelineRunning) {
    await _persistPipelineSkipReason(
      prefs: prefs,
      reason: 'already_running',
      timestamp: now,
    );
    debugLog(
      "PIPELINE SKIPPED (already running)",
      tag: "PIPELINE",
    );
    return;
  }

  _pipelineRunning = true;

  try {
    await prefs.setString(kLastPipelineNowKey, now.toIso8601String());

    final leaseAcquired = await _acquireSummaryEntryLease(
      prefs: prefs,
      now: now,
      leaseOwner: leaseOwner,
    );

    if (!leaseAcquired) {
      await _persistPipelineSkipReason(
        prefs: prefs,
        reason: 'lease_blocked_or_verification_failed',
        timestamp: now,
      );
      return;
    }

    debugLog("========== PIPELINE START ==========", tag: "PIPELINE");

    await NotificationService.init(background: true);

    final leaseRefreshed = await _refreshSummaryEntryLease(
      prefs: prefs,
      now: DateTime.now(),
      leaseOwner: leaseOwner,
    );

    if (!leaseRefreshed) {
      await _persistPipelineSkipReason(
        prefs: prefs,
        reason: 'lease_refresh_verification_failed',
        timestamp: DateTime.now(),
      );
      debugLog(
        "PIPELINE EXIT (lease refresh verification failed)",
        tag: "PIPELINE",
      );
      return;
    }

    // Persists the latest pipeline execution telemetry for debug visibility.
    final runCount =
        (prefs.getInt(kPipelineRunCountKey) ?? 0) + 1;

    await prefs.setInt(kPipelineRunCountKey, runCount);
    await prefs.setString(
      kLastPipelineRunKey,
      now.toIso8601String(),
    );

    debugLog("PIPELINE RUN COUNT → $runCount", tag: "PIPELINE");

    // Loads reminder settings and stored invoice data from SharedPreferences.
    final remindersEnabled =
        prefs.getBool('reminders_enabled') ?? true;

    final notifyDaysBefore =
        prefs.getInt('notify_days_before') ?? 1;

    final data = prefs.getString('invoices');

    debugLog(
      "PIPELINE DAY BOUNDARY REBUILD → $today",
      tag: "PIPELINE",
    );

    await prefs.setString(
      kLastPipelineTodayKey,
      today.toIso8601String(),
    );

    debugLog("NOW → $now", tag: "PIPELINE");
    debugLog("TODAY → $today", tag: "PIPELINE");
    debugLog("REMINDERS ENABLED → $remindersEnabled", tag: "PIPELINE");
    debugLog("NOTIFY DAYS BEFORE → $notifyDaysBefore", tag: "PIPELINE");
    debugLog("RAW INVOICE STRING NULL → ${data == null}", tag: "PIPELINE");

    // Treats disabled reminders as a completed day and clears summary IDs.
    if (!remindersEnabled) {

      debugLog("REMINDERS DISABLED → CANCELING SUMMARY IDS", tag: "PIPELINE");

      await NotificationService.cancel(kSummarySoonId);
      await NotificationService.cancel(kSummaryTodayId);
      await NotificationService.cancel(kSummaryPastDueId);
      await NotificationService.cancel(kSummaryAllClearId);

      await prefs.setString(
        'last_summary_refresh',
        now.toIso8601String(),
      );

      // Records the day so later retries do not rebuild notifications.
      await prefs.setString(
        kSummaryScheduledForDayKey,
        today.toIso8601String(),
      );
      await _persistPipelineSkipReason(
        prefs: prefs,
        reason: 'reminders_disabled',
        timestamp: now,
      );

      debugLog("PIPELINE EXIT (reminders disabled)", tag: "PIPELINE");
      return;
    }

    // Treats an empty invoice set as a completed day and clears summary IDs.
    if (data == null || data.trim().isEmpty) {

      debugLog("NO INVOICE DATA → CANCELING SUMMARY IDS", tag: "PIPELINE");

      await NotificationService.cancel(kSummarySoonId);
      await NotificationService.cancel(kSummaryTodayId);
      await NotificationService.cancel(kSummaryPastDueId);
      await NotificationService.cancel(kSummaryAllClearId);

      await prefs.setString(
        'last_summary_refresh',
        now.toIso8601String(),
      );

      // Records the day so later retries do not rebuild notifications.
      await prefs.setString(
        kSummaryScheduledForDayKey,
        today.toIso8601String(),
      );
      await _persistPipelineSkipReason(
        prefs: prefs,
        reason: 'no_invoices',
        timestamp: now,
      );

      debugLog("PIPELINE EXIT (no invoices)", tag: "PIPELINE");
      return;
    }

    // Decodes invoices and computes the summary bucket counts for today.
    final List decoded = jsonDecode(data);

    debugLog("DECODED INVOICE COUNT → ${decoded.length}", tag: "PIPELINE");

    int soon = 0;
    int todayCount = 0;
    int past = 0;

    for (final raw in decoded) {

      if (raw['isPaid'] == true) continue;

      final due = DateTime.tryParse(raw['dueDate']);
      if (due == null) continue;

      final dueDay =
          DateTime(due.year, due.month, due.day);

      if (dueDay.isBefore(today)) {
        past++;
        continue;
      }

      if (dueDay.isAtSameMomentAs(today)) {
        todayCount++;
        continue;
      }

      final daysUntil =
          dueDay.difference(today).inDays;

      if (daysUntil >= 1 &&
          daysUntil <= notifyDaysBefore) {
        soon++;
      }
    }

    final hasOutstanding =
        soon > 0 || todayCount > 0 || past > 0;

    debugLog(
      "COUNTS → soon:$soon today:$todayCount past:$past outstanding:$hasOutstanding",
      tag: "PIPELINE",
    );

    await prefs.setInt(kLastPipelineSoonCountKey, soon);
    await prefs.setInt(kLastPipelineTodayCountKey, todayCount);
    await prefs.setInt(kLastPipelinePastCountKey, past);
    await prefs.setBool(kLastPipelineOutstandingKey, hasOutstanding);

    // Cancels summary IDs only while destructive rebuilds are still allowed.
    if (now.hour < 9) {
      debugLog(
        "CANCELING EXISTING SUMMARY IDS",
        tag: "PIPELINE",
      );

      await NotificationService.cancel(kSummarySoonId);
      await NotificationService.cancel(kSummaryTodayId);
      await NotificationService.cancel(kSummaryPastDueId);
      await NotificationService.cancel(kSummaryAllClearId);
    } else {
      debugLog(
        "SKIP CANCEL (after fire time)",
        tag: "PIPELINE",
      );
    }

    // Uses the 9:00 AM snapshot fire time for all summary notifications.
    DateTime fireTime =
        DateTime(today.year, today.month, today.day, 9);

    if (now.hour >= 9) {
      fireTime =
          fireTime.add(const Duration(days: 1));
    }

    debugLog("FIRE TIME → $fireTime", tag: "PIPELINE");

    await prefs.setString(
      kLastPipelineFireTimeKey,
      fireTime.toIso8601String(),
    );

    // Schedules one-shot summary notifications for the computed buckets.
    if (soon > 0) {
      await NotificationService.scheduleNotification(
        id: kSummarySoonId,
        title: '🟡 Upcoming Invoices',
        body:
            '$soon invoice${soon == 1 ? '' : 's'} approaching payment due date.',
        dateTime: fireTime,
      );
    }

    if (todayCount > 0) {
      await NotificationService.scheduleNotification(
        id: kSummaryTodayId,
        title: '🟠 Invoices Due Today',
        body:
            '$todayCount invoice${todayCount == 1 ? '' : 's'} need attention today.',
        dateTime: fireTime,
      );
    }

    if (past > 0) {
      await NotificationService.scheduleNotification(
        id: kSummaryPastDueId,
        title: '🔴 Customer Follow-Up Needed',
        body:
            '$past invoice${past == 1 ? '' : 's'} past due.',
        dateTime: fireTime,
      );
    }

    if (!hasOutstanding && decoded.isNotEmpty) {
      await NotificationService.scheduleNotification(
        id: kSummaryAllClearId,
        title: 'All Clear Today',
        body: 'All invoices are caught up.',
        dateTime: fireTime,
      );
    }

    await prefs.setString(
      'last_summary_refresh',
      now.toIso8601String(),
    );

    // Records a successful scheduling pass for this calendar day.
    await prefs.setString(
      kSummaryScheduledForDayKey,
      today.toIso8601String(),
    );

    await prefs.setString(
      kDebugLastSuccessfulDayKey,
      today.toIso8601String(),
    );

    debugLog("PENDING AFTER PIPELINE ↓↓↓", tag: "PIPELINE");
    await NotificationService.debugPendingNotifications();

    debugLog("========== PIPELINE COMPLETE ==========", tag: "PIPELINE");

  } finally {
    _pipelineRunning = false;
    await _releaseSummaryEntryLease(
      prefs: prefs,
      now: DateTime.now(),
      leaseOwner: leaseOwner,
    );
  }
}
