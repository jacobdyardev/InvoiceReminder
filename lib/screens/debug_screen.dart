import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:invoice_reminder/utils/reminder_debug_keys.dart';
import 'package:invoice_reminder/services/daily_summary_pipeline.dart';
import 'package:invoice_reminder/background/alarm_reconciliation.dart';

// Shows persistent scheduler and pipeline telemetry for manual verification.
// This screen is the main in-app reliability debug surface.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});

  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

// Loads SharedPreferences-backed debug state and exposes manual actions.
class _DebugScreenState extends State<DebugScreen> {

  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // Reloads all persisted debug data from SharedPreferences.
  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    setState(() {});
  }

  // Reads a string debug field for display.
  String _read(String key) {
    return _prefs?.getString(key) ?? "-";
  }

  // Reads an integer debug field for display.
  int _readInt(String key) {
    return _prefs?.getInt(key) ?? 0;
  }

  // Reads a boolean debug field for display.
  bool _readBool(String key) {
    return _prefs?.getBool(key) ?? false;
  }

  // Returns the persisted timeline log entries for the console view.
  List<String> _logs() {
    return _prefs?.getStringList(kReminderDebugLogListKey) ?? [];
  }

  // Manually runs the daily summary pipeline from the debug screen.
  // Used to inspect pipeline behavior and resulting telemetry.
  Future<void> _runPipeline() async {
    await runDailySummaryPipeline();

    await Future.delayed(const Duration(milliseconds: 300));

    await _load();
  }

  // Manually rebuilds the full reconciliation alarm batch.
  // Used to verify scheduling telemetry and callback readiness.
  Future<void> _scheduleAlarm() async {
    await scheduleDailyReconciliationBatch();

    await Future.delayed(const Duration(milliseconds: 300));

    await _load();
  }

  // Clears the persisted timeline logs shown by this screen.
  Future<void> _clearLogs() async {
    await _prefs?.remove(kReminderDebugLogListKey);
    await _load();
  }

  @override
  Widget build(BuildContext context) {

    if (_prefs == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Reminder Debug Console"),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
    
          children: [

            const Text("ALARM", style: TextStyle(fontWeight: FontWeight.bold)),
            Text("Earliest Next Slot → ${_read(kLastAlarmScheduledForKey)}"),
            Text("Last Callback → ${_read(kLastAlarmCallbackKey)}"),
            Text("Last Slot Fired → ${_read(kLastReconciliationSlotFiredKey)}"),
            Text(
              "Last Successful Daily Slot → "
              "${_read(kLastSuccessfulReconciliationScheduleSlotKey)}",
            ),
            Text(
              "Next 2 AM Slot → ${_read(kNextReconciliation2AmScheduledForKey)}",
            ),
            Text(
              "Next 4 AM Slot → ${_read(kNextReconciliation4AmScheduledForKey)}",
            ),
            Text(
              "Next 6 AM Slot → ${_read(kNextReconciliation6AmScheduledForKey)}",
            ),

            const SizedBox(height: 16),

            const Text("PIPELINE", style: TextStyle(fontWeight: FontWeight.bold)),
            Text("Last Run → ${_read(kLastPipelineRunKey)}"),
            Text("Last Successful Day → ${_read(kDebugLastSuccessfulDayKey)}"),
            Text("Last Now → ${_read(kLastPipelineNowKey)}"),
            Text("Last Day → ${_read(kLastPipelineTodayKey)}"),
            Text("Fire Time → ${_read(kLastPipelineFireTimeKey)}"),
            Text("Skip Reason → ${_read(kLastPipelineSkipReasonKey)}"),
            Text("Soon → ${_readInt(kLastPipelineSoonCountKey)}"),
            Text("Today → ${_readInt(kLastPipelineTodayCountKey)}"),
            Text("Past → ${_readInt(kLastPipelinePastCountKey)}"),
            Text("Outstanding → ${_readBool(kLastPipelineOutstandingKey)}"),
            Text("Lease Action → ${_read(kLastPipelineLeaseActionKey)}"),
            Text("Lease Owner → ${_read(kSummaryEntryLeaseOwnerKey)}"),
            Text("Lease Day → ${_read(kSummaryEntryLeaseDayKey)}"),
            Text("Lease Expires → ${_read(kSummaryEntryLeaseExpiresAtKey)}"),
            Text("Lease Timestamp → ${_read(kLastPipelineLeaseTimestampKey)}"),

            const SizedBox(height: 16),

            const Text("WORKER", style: TextStyle(fontWeight: FontWeight.bold)),
            Text("Last Worker Run → ${_read('last_worker_run')}"),
            Text("Last 1 AM Probe → ${_read(kLastWorkerProbe1AmFiredKey)}"),
            Text("1 AM Outcome → ${_read(kLastWorkerProbe1AmOutcomeKey)}"),
            Text(
              "Next 1 AM Probe → ${_read(kNextWorkerProbe1AmScheduledForKey)}",
            ),
            Text("Last 7 AM Probe → ${_read(kLastWorkerProbe7AmFiredKey)}"),
            Text("7 AM Outcome → ${_read(kLastWorkerProbe7AmOutcomeKey)}"),
            Text(
              "Next 7 AM Probe → ${_read(kNextWorkerProbe7AmScheduledForKey)}",
            ),

            const SizedBox(height: 24),

            ElevatedButton(
              onPressed: _runPipeline,
              child: const Text("Run Pipeline Now"),
            ),

            ElevatedButton(
              onPressed: _scheduleAlarm,
              child: const Text("Schedule Reconciliation Batch"),
            ),

            ElevatedButton(
              onPressed: _clearLogs,
              child: const Text("Clear Debug Logs"),
            ),

            const SizedBox(height: 24),

            const Text("TIMELINE LOGS",
                style: TextStyle(fontWeight: FontWeight.bold)),

            const SizedBox(height: 8),

            ..._logs().reversed.map((e) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(e, style: const TextStyle(fontSize: 12)),
                )),

          ],
        ),
      ),
    );
  }
}
