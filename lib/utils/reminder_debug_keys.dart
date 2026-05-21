import 'package:shared_preferences/shared_preferences.dart';

const String kLastAlarmCallbackKey = 'last_alarm_callback';
const String kLastAlarmScheduledForKey = 'last_alarm_scheduled_for';
const String kLastReconciliationSlotFiredKey = 'last_reconciliation_slot_fired';
const String kLastSuccessfulReconciliationScheduleSlotKey =
    'last_successful_reconciliation_schedule_slot';
const String kNextReconciliation2AmScheduledForKey =
    'next_reconciliation_2am_scheduled_for';
const String kNextReconciliation4AmScheduledForKey =
    'next_reconciliation_4am_scheduled_for';
const String kNextReconciliation6AmScheduledForKey =
    'next_reconciliation_6am_scheduled_for';
const String kLastWorkerProbe1AmFiredKey = 'last_worker_probe_1am_fired';
const String kLastWorkerProbe1AmOutcomeKey = 'last_worker_probe_1am_outcome';
const String kNextWorkerProbe1AmScheduledForKey =
    'next_worker_probe_1am_scheduled_for';
const String kLastWorkerProbe7AmFiredKey = 'last_worker_probe_7am_fired';
const String kLastWorkerProbe7AmOutcomeKey = 'last_worker_probe_7am_outcome';
const String kNextWorkerProbe7AmScheduledForKey =
    'next_worker_probe_7am_scheduled_for';

const String kPipelineRunCountKey = 'pipeline_run_count';
const String kLastPipelineRunKey = 'last_pipeline_run';
const String kDebugLastSuccessfulDayKey = 'debug_last_successful_day';
const String kLastPipelineFireTimeKey = 'last_pipeline_fire_time';

const String kLastPipelineSoonCountKey = 'last_pipeline_soon_count';
const String kLastPipelineTodayCountKey = 'last_pipeline_today_count';
const String kLastPipelinePastCountKey = 'last_pipeline_past_count';

const String kLastPipelineOutstandingKey = 'last_pipeline_outstanding';
const String kLastPipelineNowKey = 'last_pipeline_now';
const String kLastPipelineTodayKey = 'last_pipeline_today';
const String kLastPipelineLeaseOwnerKey = 'last_pipeline_lease_owner';
const String kLastPipelineLeaseDayKey = 'last_pipeline_lease_day';
const String kLastPipelineLeaseTimestampKey = 'last_pipeline_lease_timestamp';
const String kLastPipelineLeaseActionKey = 'last_pipeline_lease_action';

const String kLastPipelineSkipReasonKey = 'last_pipeline_skip_reason';

const String kSummaryScheduledForDayKey = 'summary_scheduled_for_day';
const String kSummaryEntryLeaseDayKey = 'summary_entry_lease_day';
const String kSummaryEntryLeaseOwnerKey = 'summary_entry_lease_owner';
const String kSummaryEntryLeaseExpiresAtKey = 'summary_entry_lease_expires_at';

const String kReminderDebugLogListKey = 'reminder_debug_log_list';

// Appends one timestamped debug line to persistent reminder diagnostics.
// Stores a bounded log list in SharedPreferences for the debug screen.
Future<void> appendReminderDebugLog(String line) async {
  final prefs = await SharedPreferences.getInstance();

  final logs =
      prefs.getStringList(kReminderDebugLogListKey) ?? [];

  logs.add("${DateTime.now().toIso8601String()} → $line");

  if (logs.length > 150) {
    logs.removeRange(0, logs.length - 150);
  }

  await prefs.setStringList(kReminderDebugLogListKey, logs);
}
