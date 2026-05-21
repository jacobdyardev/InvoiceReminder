# Invoice Reminder — System Context

## Core Philosophy

The app uses a **deterministic morning snapshot notification model**, not a reactive notification model.

Notifications are intended to remind the user of their invoice situation at the start of the day, not continuously reflect real-time changes.

System stability and predictability are prioritized over constant reactivity.

## Current Implementation Focus

The notification system is being enhanced to use probabilistic morning reconciliation attempts.

The intent is to improve delivery reliability under Android background execution uncertainty without changing the app's deterministic notification model.

- The system will pre-schedule independent reconciliation alarms at **2:00 AM**, **4:00 AM**, and **6:00 AM**.
- These alarms are not chained and exist to improve delivery reliability under Android background execution uncertainty.
- All attempts remain bounded by the existing allowed execution window (**00:00–08:59**).
- Multiple reconciliation attempts are a bounded retry strategy and must never extend outside the defined morning execution window.
- The deterministic morning snapshot philosophy must remain unchanged.

Implementation notes:

- All reconciliation scheduling refresh paths must schedule the full **2/4/6 AM batch**. Startup alone is not sufficient.
- The previous single reconciliation alarm ID should be deprecated first, not immediately removed, to allow safe migration and rollback.
- New observability telemetry should record:
  - Last reconciliation slot fired
  - Last successful scheduling slot
  - Next scheduled reconciliation times for **2:00 AM / 4:00 AM / 6:00 AM**
- Same-day future reconciliation alarms may be optionally cancelled after successful scheduling as a performance optimization, but correctness must not depend on this.

---

## Daily Summary Notification Architecture

### Source of Truth

- Reconciliation alarms scheduled at **2:00 AM / 4:00 AM / 6:00 AM** are the primary trigger sweep.
- These reconciliation alarms call `runDailySummaryPipeline()`.
- The reconciliation alarm system schedules the **next day's 2:00 AM / 4:00 AM / 6:00 AM batch** so the sweep remains self-sustaining even if the app is not reopened.

### Safety Net

- A background worker may also call the pipeline as a recovery mechanism.
- The worker must never destructively interfere with already scheduled notifications.

---

### Deterministic probe layer

- Worker probes run at fixed anchor times (e.g., 1:00 and 7:00) to provide execution coverage if reconciliation alarms fail.
- Probes only trigger pipeline attempts, skip if daily success is present, and deterministically reschedule their next occurrence.
- Worker probes do not cancel or rebuild reconciliation alarms.

---

### Reliability responsibility rule

- Reconciliation alarms = probabilistic retry coverage.
- Worker probes = deterministic recovery attempts.
- Pipeline = scheduling correctness authority.
- New reliability behaviors must be introduced as separate subsystems rather than expanding existing mechanisms.

---

## Pipeline Execution Rules

The daily summary pipeline:

- May execute only between **00:00 and 08:59**.
- Must never cancel or rebuild notifications after the 9:00 AM fire window.
- Should perform **exactly one successful scheduling pass per calendar day**.
- Treats a missed morning window as a **missed day**, not a same-day recovery case.
- Must allow the next valid day to schedule cleanly without being blocked by stale same-day coordination state.

---

## Idempotency Strategy

A persistent daily lock (`kSummaryScheduledForDayKey`) ensures:

- The summary rebuild occurs only once per day.
- Worker retries or app-triggered executions do not duplicate scheduling.
- Late executions do not modify existing summary notifications.

A persisted entry lease protects cross-isolate execution:

- Only one pipeline instance may hold the scheduling lease at a time.
- The lease is day-scoped using canonical `YYYY-MM-DD` formatting.
- The lease uses a **5 minute TTL**.
- The lease expires automatically if a process dies mid-run.
- Expired leases may be reclaimed by a later valid execution on the same day.
- Lease expiration must not block the next day's scheduling pass.

Together, the daily success lock and entry lease provide these invariants:

- At most one active scheduling pass may proceed at a time.
- At most one successful daily scheduling result may be committed per calendar day.
- Lost processes may delay a day temporarily, but must not permanently poison later recovery.

---

## Notification Scheduling Behavior

The pipeline:

- Reads stored invoices from SharedPreferences.
- Counts unpaid invoices in three buckets:
  - Upcoming (within `notify_days_before`)
  - Due today
  - Past due
- Cancels existing summary notification IDs (only within allowed window).
- Schedules one-shot notifications for **9:00 AM** for relevant buckets.
- Schedules an “All Clear” notification if invoices exist but none are outstanding.
- Preserves already-scheduled same-day morning summaries when destructive rebuild is no longer allowed.

---

## Observability / Debug System

The app includes a persistent debug console exposing:

- Pipeline run count
- Last pipeline "now" timestamp
- Last pipeline execution timestamp
- Last pipeline skip / exit reason
- Computed invoice counts
- Scheduled fire time
- Lease action, owner, day, expiry, and timestamp
- Next scheduled **2:00 AM / 4:00 AM / 6:00 AM** reconciliation times
- Last reconciliation slot fired
- Last successful scheduling slot
- Alarm callback timestamps
- Pending notification dumps

This system is critical for validating multi-day reliability behavior.

## Observability Requirement

All future reliability, scheduling, background execution, or state-coordination systems must integrate with the in-app debug observability framework.

New systems should expose, when relevant:

- Execution timeline logs
- Persisted state telemetry
- Debug screen visibility
- Safe manual trigger capability

### Debug Systems Must Remain Safe In Release Builds

- Verbose logging must be gated behind debug flags.
- Debug UI must be hidden or disabled in release.
- Persistent telemetry storage must be lightweight and privacy-safe.

---

## Known Design Constraints

- Summary notifications are **snapshot-based** and do not update after scheduling.
- Invoice edits during the day do not trigger notification rebuilds.
- Background execution timing on Android is non-deterministic and must be guarded against.

---

## Active Reliability Risks (Update As Needed)

- Continue validating edge-case behavior under device clock changes, timezone changes, and OEM background restrictions.
- Consider a stricter worker recovery predicate if background timing behavior proves noisy in production.

---

## Future Evolution Ideas

- Potential next-day pre-scheduling support.
- Additional observability for worker execution frequency.
- More granular lease telemetry or on-device diagnostics if concurrency issues reappear.
- Additional diagnostics for clock skew, timezone changes, and reboot recovery behavior.
