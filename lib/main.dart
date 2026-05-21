import 'package:flutter/material.dart';
import 'models/invoice.dart';
import 'package:invoice_reminder/screens/add_edit_invoice_screen.dart';
import 'package:invoice_reminder/screens/debug_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:invoice_reminder/services/notification_service.dart';
import 'package:app_settings/app_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'dart:async';
import 'package:workmanager/workmanager.dart';
import 'package:invoice_reminder/background/summary_worker.dart';
import 'package:invoice_reminder/utils/debug_log.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:invoice_reminder/background/alarm_reconciliation.dart';
import 'package:android_alarm_manager_plus/android_alarm_manager_plus.dart';
import 'package:invoice_reminder/services/daily_summary_pipeline.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await AndroidAlarmManager.initialize();

  await NotificationService.init();
  await NotificationService.primeNotificationChannelOnce();

  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: kDebugMode,
  );

  runApp(const InvoiceReminderApp());
}

const int kReminderSchemaVersion = 2;
const _prefsNotifyDaysKey = 'notify_days_before';
const _prefsRemindersEnabledKey = 'reminders_enabled';
const _prefsIsProKey = 'is_pro';
const _prefsThemeModeKey = 'theme_mode';
const String _prefsImmediateEnabledKey = 'immediate_enabled';
const String _prefsDailyPastDueKey = 'daily_past_due_enabled';
const String _prefsPaidRangeKey = 'paid_range';
bool _dailyPastDueEnabled = true;
bool _immediateNotificationsEnabled = true;


enum InvoiceFilter {
  all,
  dueToday,
  upcoming,
  pastDue,
}

class BatteryHelper {
  static final Battery _battery = Battery();

  // Returns true if battery saver is ON
  static Future<bool> isPowerSaverOn() async {
    try {
      return await _battery.isInBatterySaveMode;
    } catch (_) {
      return false;
    }
  }
}

class PowerSaverBanner extends StatelessWidget {
  const PowerSaverBanner({super.key});

  Future<void> _openSettings() async {
    const intent = AndroidIntent(
      action: 'android.settings.BATTERY_SAVER_SETTINGS',
      flags: <int>[Flag.FLAG_ACTIVITY_NEW_TASK],
    );

    await intent.launch();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: _openSettings,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colorScheme.primary.withValues(alpha: 0.12), // subtle background
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: colorScheme.primary, // use your primary color
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "Battery saver may cause invoice reminders to be skipped. Tap to turn off battery saver.",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600, // 👈 add this
                  color: colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PaidRange {
  final String label;
  final int? year;
  final int? days;

  PaidRange(this.label, {this.year, this.days});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PaidRange &&
          label == other.label &&
          year == other.year &&
          days == other.days;

  @override
  int get hashCode => Object.hash(label, year, days);
}

final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>();


class InvoiceReminderApp extends StatefulWidget {
  const InvoiceReminderApp({super.key});

  @override
  State<InvoiceReminderApp> createState() => _InvoiceReminderAppState();
}

class _InvoiceReminderAppState extends State<InvoiceReminderApp> {
  
  ThemeMode _selectedThemeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
    _checkNotificationPermission();
  }

  Future<void> _checkNotificationPermission() async {
    final enabled = await _areNotificationsEnabled();

    if (!enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showNotificationDialog();
      });
    }
  }

  Future<bool> _areNotificationsEnabled() async {
    final android = NotificationService.androidPlugin;
    return await android?.areNotificationsEnabled() ?? false;
  }

  void _showNotificationDialog() {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return;

    showDialog(
      context: navigator.context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Enable notifications?', textAlign: TextAlign.center, 
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)
            ),
        content: const Text(
          'Invoice Reminder needs notifications enabled to alert you before invoices are due.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(navigator.context);
            },
            child: const Text('Maybe later'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(navigator.context);
              AppSettings.openAppSettings(
                type: AppSettingsType.notification,
              );
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_prefsThemeModeKey);

    setState(() {
      _selectedThemeMode = value == 'dark'
          ? ThemeMode.dark
          : value == 'light'
              ? ThemeMode.light
              : ThemeMode.system;
    });
  }

  Future<void> _setTheme(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      _prefsThemeModeKey,
      mode == ThemeMode.dark
          ? 'dark'
          : mode == ThemeMode.light
              ? 'light'
              : 'system',
    );

    setState(() => _selectedThemeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      themeMode: _selectedThemeMode,
      theme: ThemeData(useMaterial3: true),
      darkTheme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
      home: UnpaidInvoicesScreen(onThemeChanged: _setTheme),
    );
  }
}

class UnpaidInvoicesScreen extends StatefulWidget {
  final void Function(ThemeMode) onThemeChanged;

  const UnpaidInvoicesScreen({super.key, required this.onThemeChanged});

  @override
  State<UnpaidInvoicesScreen> createState() => _UnpaidInvoicesScreenState();
}

class _UnpaidInvoicesScreenState extends State<UnpaidInvoicesScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {

  int _notifyDaysBefore = 1;

  bool _isPowerSaverOn = false;
  bool _startupCompleted = false;
  bool _remindersEnabled = true;
  bool _isBusy(String id) =>
    _animatingToPaidId == id || _animatingToUnpaidId == id;

  String? _expandedInvoiceId;
  String _searchQuery = '';
  String? _animatingToPaidId;
  String? _animatingToUnpaidId;
  String _appVersion = '';

  int _versionTapCount = 0;
  DateTime? _lastVersionTap;

  static const int _freeInvoiceLimit = 3;
  bool _isPro = false;

  late TabController _tabController;

  final InAppPurchase _inAppPurchase = InAppPurchase.instance;
  late StreamSubscription<List<PurchaseDetails>> _purchaseSubscription;

  static const String _proProductId = 'invoice_reminder_pro'; // Must match Play Console.

  late PaidRange _selectedPaidRange;

  static const _storageKey = 'invoices';

  InvoiceFilter? _activeFilter;

  final List<Invoice> _invoices = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  ThemeMode _selectedThemeMode = ThemeMode.system;

  Future<void> _exportData() async {
    if (_invoices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No invoices to export')),
      );
      return;
    }

    final data = jsonEncode(_invoices.map((e) => e.toJson()).toList());

    final bytes = Uint8List.fromList(utf8.encode(data));

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Save backup',
      fileName: 'invoice_backup.json',
      bytes: bytes,
    );

    if (result == null) return;
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Backup saved')),
    );
  }

  void _confirmImport() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Restore backup?'),
        content: const Text(
          'This will replace your current invoices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _importData();
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  // Restores invoice data from a backup file and refreshes reminder state.
  // This is a scheduling refresh path for pipeline and reconciliation alarms.
  Future<void> _importData() async {
    Navigator.pop(context); // Closes the drawer before file selection.

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );

    if (result == null) return;

    final file = File(result.files.single.path!);
    final contents = await file.readAsString();

    final prefs = await SharedPreferences.getInstance();

    if (_canRebuildMorningSummaryNow) {
      // Full restore can clear scheduled notifications only inside the morning rebuild window.
      await NotificationService.cancelAllScheduled();
    } else {
      debugLog(
        "Restore skipped destructive cancellation after morning snapshot window",
        tag: "RESTORE",
      );
    }

    // Replaces stored invoices with the imported payload.
    await prefs.setString(_storageKey, contents);

    // Reloads in-memory invoices before rebuilding reminder state.
    await _loadInvoices();

    await runDailySummaryPipeline();

    await scheduleDailyReconciliationBatch();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Backup restored')),
    );
  }

  Widget _buildVersionBadge() {
    final invoiceText =
        '$_unpaidInvoiceCount active invoice${_unpaidInvoiceCount == 1 ? '' : 's'}';

    if (_isPro) {
      return Padding(
        padding: const EdgeInsets.only(top: 0.1),
        child: Text(
          'Pro Version • $invoiceText',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 0.1),
      child: Text(
        'Free Version • $invoiceText',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildHeaderStatsPaid() {
    final paidTotal = _paidAmount(_selectedPaidRange);
    final amountText = '\$${paidTotal.toStringAsFixed(2)}';

    final labelStyle = const TextStyle(fontWeight: FontWeight.w600);
    final amountStyle = const TextStyle(fontWeight: FontWeight.w600);

    const dropdownWidth = 142.0;
    const gap = 8.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableForLeft = constraints.maxWidth - dropdownWidth - gap;

          final singleLineText = 'Total Paid Balance: $amountText';

          final tp = TextPainter(
            text: TextSpan(text: singleLineText, style: labelStyle),
            maxLines: 1,
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context), // Uses the current accessibility text scaling.
          )..layout(maxWidth: availableForLeft);

          final fitsOnOneLine = !tp.didExceedMaxLines;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start, // Applies top alignment only to this row.
            children: [
              Transform.translate(
                offset: const Offset(0, 15),
                child: SizedBox(
                  width: availableForLeft,
                  child: fitsOnOneLine
                      ? Text(
                          singleLineText,
                          style: labelStyle,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.clip,
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Total Paid Balance:',
                              style: labelStyle,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                            Text(
                              amountText,
                              style: amountStyle,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(width: gap),

              DropdownButtonHideUnderline(
                child: SizedBox(
                  width: dropdownWidth,
                  child: DropdownButton2<PaidRange>(
                    value: _selectedPaidRange,
                    alignment: Alignment.centerLeft,
                    onChanged: (v) => setState(() => _selectedPaidRange = v!),
                    items: _paidRanges
                        .map((r) => DropdownMenuItem(
                              value: r,
                              child: Text(
                                r.label,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ))
                        .toList(),
                    dropdownStyleData: const DropdownStyleData(
                      maxHeight: 300,
                      offset: Offset(0, 0),
                    ),
                    buttonStyleData: const ButtonStyleData(
                      padding: EdgeInsets.symmetric(horizontal: 1),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeaderStatsUnpaid() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 21, 16, 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total Unpaid Balance: \$${_outstandingTotal.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeOption(ThemeMode mode, String label) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Radio<ThemeMode>(
        value: mode,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      title: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      onTap: () {
        setState(() => _selectedThemeMode = mode);
        widget.onThemeChanged(mode);
        Navigator.pop(context);
      },
    );
  }

  // Monetization

  bool get _canAddInvoice {
    if (_isPro) return true;
    return _unpaidInvoiceCount < _freeInvoiceLimit;
  }

  void _showUpgradeDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(
          'Invoice Reminder Pro',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          'Unlock unlimited invoices with a one-time purchase.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _buyPro();
            },
            child: const Text('Unlock Pro'),
          ),
        ],
      ),
    );
  }

  Future<void> _buyPro() async {
    final bool available = await _inAppPurchase.isAvailable();
    if (!available) return;

    final response =
        await _inAppPurchase.queryProductDetails({_proProductId});

    if (response.productDetails.isEmpty) return;

    final productDetails = response.productDetails.first;

    final purchaseParam = PurchaseParam(productDetails: productDetails);

    await _inAppPurchase.buyNonConsumable(
      purchaseParam: purchaseParam,
    );
  }

  Future<bool> _restorePurchases() async {
    bool restored = false;

    final completer = Completer<bool>();

    late StreamSubscription sub;

    sub = _inAppPurchase.purchaseStream.listen((purchases) {
      for (final purchase in purchases) {
        if ((purchase.status == PurchaseStatus.purchased ||
            purchase.status == PurchaseStatus.restored) &&
            purchase.productID == _proProductId) {

          restored = true;
          completer.complete(true);
          sub.cancel();
        }
      }
    });

    await _inAppPurchase.restorePurchases();

    // Timeout fallback (important)
    return completer.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        sub.cancel();
        return restored;
      },
    );
  }

  void _unlockPro({bool silent = false}) {
    if (_isPro) return;

    setState(() {
      _isPro = true;
    });

    _saveProStatus();

    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unlimited invoices unlocked 🎉'),
        ),
      );
    }
  }

  // Preferences

  Future<void> _loadReminderSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final cached = prefs.getBool(_prefsIsProKey) ?? false;

    // Only set if we don't already know user is Pro
    if (!_isPro && cached) {
      _isPro = true;
    }

    setState(() {
      _notifyDaysBefore = prefs.getInt(_prefsNotifyDaysKey) ?? 1;
      _remindersEnabled = prefs.getBool(_prefsRemindersEnabledKey) ?? true;
      _immediateNotificationsEnabled = prefs.getBool(_prefsImmediateEnabledKey) ?? true;
      _dailyPastDueEnabled = prefs.getBool(_prefsDailyPastDueKey) ?? true;
    });
  }

  // Persists reminder settings and rebuilds morning scheduling state.
  // This refresh path reruns the pipeline and reconciliation batch.
  Future<void> _saveReminderSettings() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setInt(_prefsNotifyDaysKey, _notifyDaysBefore);
    await prefs.setBool(_prefsRemindersEnabledKey, _remindersEnabled);
    await prefs.setBool( _prefsImmediateEnabledKey, _immediateNotificationsEnabled);
    await prefs.setBool( _prefsDailyPastDueKey, _dailyPastDueEnabled,);

    await runDailySummaryPipeline();

    await scheduleDailyReconciliationBatch();
  }

  bool get _canRebuildMorningSummaryNow {
    final hour = DateTime.now().hour;
    return hour >= 0 && hour < 9;
  }

  // Date helpers

  DateTime get _today {
    final now = DateTime.now();
    
    return DateTime(now.year, now.month, now.day);
  }

  // Posts immediate invoice-related notifications for the current UI action.
  // This does not rebuild the daily summary or reconciliation schedulers.
  void _scheduleInvoiceReminders(Invoice invoice, {bool showImmediate = false,}) {

    if (invoice.isPaid) {      
      debugLog("Skipping paid invoice: ${invoice.clientName}");
      
      return;
    }

    debugLog("Scheduling reminders for ${invoice.clientName}");    

    final now = DateTime.now();

    final notifBase =
      (invoice.id.hashCode & 0x7FFFFFFF);

    final today = DateTime(now.year, now.month, now.day);

    // Builds the immediate notification content for this invoice action.

    final dueDay = DateTime(
      invoice.dueDate.year,
      invoice.dueDate.month,
      invoice.dueDate.day,
    );

    final isPastDue = dueDay.isBefore(today);

    late String immediateTitle;
    late String immediateBody;

    if (isPastDue) {
      // Posts an immediate alert for past-due invoices when the caller requests it.
      if (showImmediate && _immediateNotificationsEnabled) {
        NotificationService.showImmediateNotification(
          id: notifBase + 100000,
          title: '🔴 Invoice past due',
          body: 'Invoice for ${invoice.clientName} is already past due',
        );
      }

      return; // Stops further immediate-notification work for an already past-due invoice.
    }


    if (dueDay.isAtSameMomentAs(today)) {
      immediateTitle = '🟠 Invoice due today';
      immediateBody =
          'Invoice for ${invoice.clientName} is due today';
    } else {
      final daysUntilDue = dueDay.difference(today).inDays;

      if (daysUntilDue <= _notifyDaysBefore) {
        immediateTitle = '🟡 Invoice due soon';
        immediateBody =
            'Invoice for ${invoice.clientName} is coming up soon';
      } else {
        immediateTitle = '🔵 Invoice added';
        immediateBody =
            'Invoice for ${invoice.clientName} was added successfully';
      }
    }

    if (showImmediate && _immediateNotificationsEnabled) {
      NotificationService.showImmediateNotification(
        id: notifBase + 100000,
        title: immediateTitle,
        body: immediateBody,
      );
    }
  }

  // Shows a one-time warning when exact alarm permission is unavailable.
  // This improves reliability but does not change scheduler state.
  Future<void> _maybeShowExactAlarmWarning() async {
    final prefs = await SharedPreferences.getInstance();

    final alreadyShown =
        prefs.getBool('exact_alarm_warning_shown') ?? false;

    if (alreadyShown) return;

    final allowed =
        await NotificationService.canScheduleExactAlarms();

    if (allowed) return;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(
          'Improve reminder reliability',
          textAlign: TextAlign.center,
        ),
        content: const Text(
          'Daily reminders work best when “Alarms & reminders” is enabled '
          'for Invoice Reminder. You can turn this on in system settings.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);

              await NotificationService.openExactAlarmSettings();
            },
            child: const Text('Open settings'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('Later'),
          ),
        ],
      ),
    );

    await prefs.setBool('exact_alarm_warning_shown', true);
  }

  // Warns when background reconciliation appears to have stopped running.
  // This is diagnostic UI only and does not reschedule alarms.
  Future<void> _maybeShowAlarmRecoveryWarning() async {
    final prefs = await SharedPreferences.getInstance();

    final lastRunString =
        prefs.getString('last_reconciliation_run');

    if (lastRunString == null) return;

    final lastRun = DateTime.parse(lastRunString);

    final now = DateTime.now();

    final difference = now.difference(lastRun);

    // Treats a long gap as a possible background execution reliability issue.
    if (difference.inHours < 30) return;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(
          'Reminders may be delayed',
          textAlign: TextAlign.center,
        ),
        content: const Text(
          'Your device may be limiting background activity. '
          'To improve reminder reliability, allow exact alarms and set '
          'battery usage to Unrestricted.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);

              await NotificationService.openExactAlarmSettings();
            },
            child: const Text('Fix now'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('Later'),
          ),
        ],
      ),
    );
  }

  // Shows the one-time startup confirmation notification after launch.
  Future<void> maybeShowFirstRunNotification() async {
    final prefs = await SharedPreferences.getInstance();

    final shown =
        prefs.getBool('startup_notification_shown') ?? false;

    if (shown) return;

    await NotificationService.showImmediateNotification(
      id: 999000,
      title: 'Invoice reminders enabled',
      body:
          'You\'ll get notified before invoices are due and when follow-up is needed.',
    );

    await prefs.setBool('startup_notification_shown', true);

    debugLog("FIRST RUN NOTIFICATION CHECK → shown: $shown");
  }

  // Applies reminder schema migrations that require rebuilding notification state.
  // Destructive notification resets are still blocked outside the morning window.
  Future<void> ensureReminderSchemaUpToDate() async {

    debugLog("SCHEMA MIGRATION CHECK RUNNING", tag: "SCHEMA");

    final prefs = await SharedPreferences.getInstance();

    final savedVersion =
        prefs.getInt('reminder_schema_version') ?? 0;

    final schemaOutdated =
        savedVersion != kReminderSchemaVersion;

    if (!schemaOutdated) return;

    debugLog(
      "Reminder schema outdated → resetting reminders",
      tag: "SCHEMA",
    );

    // Yields briefly before starting rebuild work.
    await Future.delayed(const Duration(milliseconds: 1));

    if (_canRebuildMorningSummaryNow) {
      // Full schema reset can clear notifications only inside the rebuild window.
      await NotificationService.cancelAll();
    } else {
      debugLog(
        "Schema migration skipped destructive cancellation after morning snapshot window",
        tag: "SCHEMA",
      );
    }

    // Rebuilds morning summary notifications for the current stored state.
    await runDailySummaryPipeline();

    // Records completion so the reset does not repeat on the next launch.
    await prefs.setInt(
      'reminder_schema_version',
      kReminderSchemaVersion,
    );

    debugLog("SCHEMA MIGRATION COMPLETE", tag: "SCHEMA");
  }

  // Sends a one-time all-clear notification when every invoice is paid.
  // Also resets that trigger if unpaid invoices return later.
  Future<void> _checkForAllInvoicesPaid() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);

    debugLog("Checking all invoices paid...");

    if (data == null) return;

    final List decoded = jsonDecode(data);

    final hasUnpaid =
        decoded.any((i) => i['isPaid'] != true);

        debugLog("Has unpaid invoices: $hasUnpaid");

    final alreadySent =
        prefs.getBool('all_clear_congrats_sent') ?? false;

        debugLog("Congrats already sent: $alreadySent");

    if (!hasUnpaid && !alreadySent) {
      debugLog("ALL CLEAR TRIGGERED");
      await NotificationService.showImmediateNotification(
        id: 920000,
        title: 'Congratulations! 🎉',
        body: 'All current invoices are paid.',
      );

      await prefs.setBool('all_clear_congrats_sent', true);
    }

    // Resets the one-time all-clear trigger when unpaid invoices return.
    if (hasUnpaid) {
        debugLog("Outstanding invoices detected — reset all_clear flag");
      await prefs.setBool('all_clear_congrats_sent', false);
    }
  }

  // Reapplies invoice-specific reminder state for all loaded invoices.
  // This does not rebuild the daily summary or reconciliation batch.
  Future<void> _rescheduleAllReminders({bool skipCancel = false}) async {
    if (_invoices.isEmpty) return;

    for (final invoice in _invoices) {
      if (!skipCancel) {
        NotificationService.cancelAllForInvoice(invoice.id);
      }

      _scheduleInvoiceReminders(invoice);
    }

    if (kDebugMode) {
      await NotificationService.debugPendingNotifications();
    }
  }

  // Sorting and filtering

  int _urgencyScore(Invoice invoice) {
    final dueDate = DateTime(
      invoice.dueDate.year,
      invoice.dueDate.month,
      invoice.dueDate.day,
    );

    if (dueDate.isBefore(_today)) return 0;
    if (dueDate.isAtSameMomentAs(_today)) return 1;
    return 2;
  }

  List<Invoice> get _filteredInvoices {
    final query = _searchQuery.toLowerCase().trim();

    List<Invoice> result = query.isEmpty
        ? List.from(_invoices)
        : _invoices.where((invoice) {
            final parts = invoice.clientName
                .toLowerCase()
                .split(RegExp(r'\s+'));

            return parts.any(
              (part) => part.startsWith(query),
            );
          }).toList();

    result = result.where((invoice) {
      if (_activeFilter == null) return true;

      final dueDate = DateTime(
        invoice.dueDate.year,
        invoice.dueDate.month,
        invoice.dueDate.day,
      );

      switch (_activeFilter!) {
        case InvoiceFilter.dueToday:
          return dueDate.isAtSameMomentAs(_today);

        case InvoiceFilter.upcoming:
          return dueDate.isAfter(_today);

        case InvoiceFilter.pastDue:
          return dueDate.isBefore(_today);

        case InvoiceFilter.all:
          return true;
      }
    }).toList();

    result.sort((a, b) {
      final urgencyCompare =
          _urgencyScore(a).compareTo(_urgencyScore(b));
      if (urgencyCompare != 0) return urgencyCompare;
      return a.dueDate.compareTo(b.dueDate);
    });

    return result;
  }

  // Persistence

  // Initializes reminder state after launch and triggers startup refresh paths.
  // Startup rebuilds invoice reminders, reconciliation alarms, and worker probes.
  Future<void> _startup() async {
    if (_startupCompleted) {
      debugLog("STARTUP SKIPPED (already completed)", tag: "STARTUP");
      return;
    }

    _startupCompleted = true;

    debugLog("STARTUP BEGIN", tag: "STARTUP");

    await NotificationService.init();
    await NotificationService.primeNotificationChannelOnce();

    final allowed = await NotificationService.areNotificationsAllowed();

    debugLog("NOTIFICATION PERMISSION → $allowed", tag: "STARTUP");

    await _loadInvoices();

    // Defers reminder rebuild work until after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) async {

      debugLog("STARTUP BACKGROUND PHASE BEGIN", tag: "STARTUP");

      await _rescheduleAllReminders();

      // Startup is an explicit refresh path, so it rebuilds the full morning batch.
      await scheduleDailyReconciliationBatch();

      await registerDeterministicSummaryWorkerProbes();

      debugLog("WORKER PROBES REGISTERED", tag: "STARTUP");

      await _maybeShowExactAlarmWarning();
      await _maybeShowAlarmRecoveryWarning();

      await ensureReminderSchemaUpToDate();

      if (allowed) {
        await maybeShowFirstRunNotification();
      }

      debugLog("STARTUP BACKGROUND PHASE COMPLETE", tag: "STARTUP");
    });

    debugLog("REMINDER SYSTEM READY", tag: "STARTUP");
    debugLog("================================", tag: "STARTUP");
    debugLog("STARTUP COMPLETE", tag: "STARTUP");
  }

  Future<void> _initPurchases() async {
    final prefs = await SharedPreferences.getInstance();

    // Temporary UI state (fast load)
    final cached = prefs.getBool(_prefsIsProKey) ?? false;
    if (cached) {
      setState(() {
        _isPro = true;
      });
    }

    // REAL source of truth
    await _inAppPurchase.restorePurchases();
  }

  @override
  void initState() {
    super.initState();

    _checkPowerSaver();

    WidgetsBinding.instance.addObserver(this);

    _tabController = TabController(length: 2, vsync: this);

    _tabController.addListener(() {
      setState(() {});
    });

    _purchaseSubscription =
        _inAppPurchase.purchaseStream.listen((purchases) {
      for (final purchase in purchases) {

        if ((purchase.status == PurchaseStatus.purchased ||
            purchase.status == PurchaseStatus.restored) &&
            purchase.productID == _proProductId) {

          _unlockPro(silent: true);
        }

        if (purchase.pendingCompletePurchase) {
          _inAppPurchase.completePurchase(purchase);
        }
      }
    });

    _initPurchases();

    _selectedPaidRange = _paidRanges.first;

    _loadReminderSettings();
    _loadPaidRange();
    _loadAppVersion();

    _selectedThemeMode = ThemeMode.system;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _startup();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    _purchaseSubscription.cancel();
    super.dispose();
  }

  Future<void> _checkPowerSaver() async {
  final isOn = await BatteryHelper.isPowerSaverOn();

  if (!mounted) return;

  setState(() {
    _isPowerSaverOn = isOn;
  });
}

@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    _checkPowerSaver();
  }
}

  Future<void> _loadInvoices() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_storageKey);

    if (data == null || data.trim().isEmpty) return;

    try {
      final decoded = jsonDecode(data);

      if (decoded is! List) {
        throw Exception("Invalid invoice structure");
      }

      final List invoicesList = decoded;

      setState(() {
        _invoices
          ..clear()
          ..addAll(invoicesList.map((e) => Invoice.fromJson(e)));
      });

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Backup data is corrupted')),
        );
      }
    }
  }

  Future<void> _loadPaidRange() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLabel = prefs.getString(_prefsPaidRangeKey);

    if (savedLabel == null) {
      _selectedPaidRange = _paidRanges.first;
      return;
    }

    _selectedPaidRange = _paidRanges.firstWhere(
      (r) => r.label == savedLabel,
      orElse: () => _paidRanges.first,
    );
  }

  // Persists invoice changes and refreshes summary scheduling state.
  // This is the main UI-triggered refresh path after invoice edits.
  Future<void> _saveInvoices() async {
    final prefs = await SharedPreferences.getInstance();
    final data =
        jsonEncode(_invoices.map((e) => e.toJson()).toList());

    await prefs.setString(_storageKey, data);

    await runDailySummaryPipeline();

    await scheduleDailyReconciliationBatch();
  }

  // UI helpers

  Widget _buildEmptyPaidState() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Column(
              children: [

                SizedBox(height: constraints.maxHeight * 0.2),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    children: [
                      const Text(
                        'No paid invoices yet',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Invoices you mark as paid will appear here for reference.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNoPaidSearchResults() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No matching invoices',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'No paid invoices match “$_searchQuery”.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyUnpaidState(bool hasSearch, bool hasInvoices) {
    // Shows the empty search state when invoices exist but no unpaid item matches.
    if (hasSearch && hasInvoices) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No matching invoices',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'No unpaid invoices match “$_searchQuery”.',
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    // Shows the empty unpaid state when there are no unpaid invoices to display.
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            height: constraints.maxHeight,
            child: Column(
              children: [

                SizedBox(height: constraints.maxHeight * 0.2),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    children: [
                      const Text(
                        'No unpaid invoices',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add your first invoice to start tracking due dates and payment reminders.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInvoiceList(List<Invoice> invoices) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: invoices.length,
      itemBuilder: (context, index) {
        final invoice = invoices[index];
        final isExpanded = _expandedInvoiceId == invoice.id;
        final reduceMotion = MediaQuery.of(context).disableAnimations;
        final animatingToPaid = _animatingToPaidId == invoice.id;
        final animatingToUnpaid = _animatingToUnpaidId == invoice.id;
        final isAnimating = animatingToPaid || animatingToUnpaid;

        return KeyedSubtree(
          key: ValueKey(invoice.id),
          child: AnimatedSlide(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
          offset: animatingToPaid
              ? const Offset(0.75, -2.40)
              : animatingToUnpaid
                  ? const Offset(-0.75, -2.40)
                  : Offset.zero,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 300),
              scale: isAnimating ? 0.85 : 1,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: isAnimating ? 0 : 1,
                child: Column(
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(1),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          setState(() {
                            _expandedInvoiceId =
                                isExpanded ? null : invoice.id;
                          });
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          // Summary row for the invoice item.
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      invoice.clientName,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  if (!invoice.isPaid) _buildStatusIndicator(invoice),
                                ],
                              ),

                              const SizedBox(height: 4),

                              Text(
                                invoice.isPaid
                                  ? 'Paid ${_formatDate(invoice.paidAt!)} • \$${invoice.amount.toStringAsFixed(2)}'
                                  : 'Due ${_formatDate(invoice.dueDate)} • \$${invoice.amount.toStringAsFixed(2)}',
                              ),

                              // Expanded detail and actions for the selected invoice.
                              AnimatedSize(                            
                                duration: reduceMotion
                                    ? Duration.zero
                                    : const Duration(milliseconds: 200),
                                curve: Curves.easeOutCubic,
                                alignment: Alignment.topCenter,
                                child: Align(
                                  alignment: Alignment.topLeft,
                                  child: isExpanded
                                    ? Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (invoice.notes != null &&
                                              invoice.notes!.isNotEmpty) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              invoice.notes!,
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.color,
                                              ),
                                            ),
                                          ],
                                          const SizedBox(height: 12),
                                        
                                          if (!invoice.isPaid)
                                            _buildUnpaidActionRow(invoice)
                                          else
                                            _buildPaidActionRow(invoice),
                                            
                                        ],
                                      )
                                    : const SizedBox.shrink(),
                                ),
                              ),                                
                            ],
                          ),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                ),
              ),
            ),
          ),
        );
      },  
    );
  }

  Widget _buildUnpaidActionRow(Invoice invoice) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [

        // Opens edit flow for an unpaid invoice.
        TextButton(
          onPressed: _isBusy(invoice.id) ? null : () async {

            HapticFeedback.mediumImpact();

            final messenger = ScaffoldMessenger.of(context);

            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AddEditInvoiceScreen(invoice: invoice),
              ),
            );

            if (!mounted) return;

            if (result == 'delete') {

              setState(() {
                _invoices.remove(invoice);
                _expandedInvoiceId = null;
              });

              NotificationService.cancelAllForInvoice(invoice.id);

              await _saveInvoices();

              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Invoice deleted'),
                  duration: Duration(seconds: 3),
                ),
              );
            }
            else if (result is Invoice) {
              setState(() {});      

              NotificationService.cancelAllForInvoice(invoice.id);

              await _saveInvoices();

              _scheduleInvoiceReminders(result);
            }
          },
          child: const Text('Edit'),
        ),

        const SizedBox(width: 8),

        // Deletes an unpaid invoice and refreshes reminder state.
        TextButton(
          onPressed: _isBusy(invoice.id) ? null : () async {

            HapticFeedback.mediumImpact();

            final confirm = await showDialog<bool>(
              context: context,
              builder: (context) {
                return AlertDialog(
                  title: const Text('Delete Invoice'),
                  content: Text(
                    'Are you sure you want to delete ${invoice.clientName}\'s invoice?\n\nThis action cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                );
              },
            );

            if (!mounted) return;
            if (confirm != true) return;

            final messenger = ScaffoldMessenger.of(context);

            final removedIndex = _invoices.indexOf(invoice);
            if (removedIndex == -1) return;

            setState(() {
              _invoices.removeAt(removedIndex);
              _expandedInvoiceId = null;
            });

            NotificationService.cancelAllForInvoice(invoice.id);

            await _saveInvoices();

            messenger.hideCurrentSnackBar();

            messenger.showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 6),
                behavior: SnackBarBehavior.floating,
                showCloseIcon: true,
                content: Row(
                  children: [
                    const Expanded(
                      child: Text('Invoice deleted'),
                    ),
                    GestureDetector(
                      onTap: () async {
                        setState(() {
                          _invoices.insert(removedIndex, invoice);
                        });

                        await _saveInvoices();

                        if (!invoice.isPaid) {
                          _scheduleInvoiceReminders(invoice);
                        }

                        messenger.hideCurrentSnackBar();
                      },
                      child: const Text(
                        'UNDO',
                        style: TextStyle(
                          color: Color(0xFF5E35B1),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          child: const Text(
            'Delete',
            style: TextStyle(color: Colors.red),
          ),
        ),

        const SizedBox(width: 8),

        // Marks the invoice paid and clears invoice-specific reminders.
        TextButton(
          onPressed: _isBusy(invoice.id) ? null : () async {

            HapticFeedback.mediumImpact();

            setState(() {
              _animatingToPaidId = invoice.id;
            });

            final messenger = ScaffoldMessenger.of(context);

            await Future.delayed(const Duration(milliseconds: 450));

            if (!mounted) return;

            setState(() {
              invoice.isPaid = true;
              invoice.paidAt = DateTime.now();
              _expandedInvoiceId = null;
              _animatingToPaidId = null;
            });

            NotificationService.cancelAllForInvoice(invoice.id);

            await _saveInvoices();

            await _checkForAllInvoicesPaid();

            messenger.hideCurrentSnackBar();

            messenger.showSnackBar(
              const SnackBar(
                content: Text('Invoice marked as paid'),
              ),
            );
          },  

          child: const Text(
            'Mark as Paid',
            style: TextStyle(color: Colors.green),
          ),
        ),
      ],
    );
  }

  Widget _buildPaidActionRow(Invoice invoice) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [

        // Opens edit flow for a paid invoice.
        TextButton(
          onPressed: _isBusy(invoice.id) ? null : () async {

            HapticFeedback.mediumImpact();

            final messenger = ScaffoldMessenger.of(context);

            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AddEditInvoiceScreen(invoice: invoice),
              ),
            );

            if (!mounted) return;

            if (result == 'delete') {
              setState(() {
                _invoices.remove(invoice);
                _expandedInvoiceId = null;
              });

              NotificationService.cancelAllForInvoice(invoice.id);

              await _saveInvoices();

              messenger.showSnackBar(
                const SnackBar(content: Text('Invoice deleted')),
              );
            }
            else if (result is Invoice) {
              setState(() {});

              await _saveInvoices();
            }
          },
          child: const Text('Edit'),
        ),

        const SizedBox(width: 8),

        // Moves the invoice back to unpaid and restores invoice reminders.
        TextButton(
          onPressed: _isBusy(invoice.id) ? null : () async {

            HapticFeedback.mediumImpact();

            final messenger = ScaffoldMessenger.of(context);

            setState(() {
              _animatingToUnpaidId = invoice.id;
            });

            await Future.delayed(const Duration(milliseconds: 450));

            if (!mounted) return;

            setState(() {
              invoice.isPaid = false;
              invoice.paidAt = null;
              _expandedInvoiceId = invoice.id;
              _animatingToUnpaidId = null;
            });

            NotificationService.cancelAllForInvoice(invoice.id);

            await _saveInvoices();

            _scheduleInvoiceReminders(invoice);

            messenger.hideCurrentSnackBar();

            messenger.showSnackBar(
              const SnackBar(
                content: Text('Invoice moved back to unpaid'),
              ),
            );
          },
          child: const Text(
            'Mark as Unpaid',
            style: TextStyle(color: Color.fromARGB(255, 250, 143, 36)),
          ),
        ),

        const SizedBox(width: 8),

        // Deletes a paid invoice and refreshes reminder state.
        TextButton(
          onPressed: _isBusy(invoice.id) ? null : () async {

            HapticFeedback.mediumImpact();

            final confirm = await showDialog<bool>(
              context: context,
              builder: (context) {
                return AlertDialog(
                  title: const Text('Delete Invoice'),
                  content: Text(
                    'Are you sure you want to delete ${invoice.clientName}\'s invoice?\n\nThis action cannot be undone.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                );
              },
            );

            if (!mounted) return;
            if (confirm != true) return;

            final messenger = ScaffoldMessenger.of(context);

            final removedIndex = _invoices.indexOf(invoice);
            if (removedIndex == -1) return;

            setState(() {
              _invoices.removeAt(removedIndex);
              _expandedInvoiceId = null;
            });

            NotificationService.cancelAllForInvoice(invoice.id);

            await _saveInvoices();

            messenger.hideCurrentSnackBar();

            messenger.showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 6),
                behavior: SnackBarBehavior.floating,
                showCloseIcon: true,
                content: Row(
                  children: [
                    const Expanded(
                      child: Text('Invoice deleted'),
                    ),
                    GestureDetector(
                      onTap: () async {
                        setState(() {
                          _invoices.insert(removedIndex, invoice);
                        });

                        await _saveInvoices();

                        if (!invoice.isPaid) {
                          _scheduleInvoiceReminders(invoice);
                        }

                        messenger.hideCurrentSnackBar();
                      },
                      child: const Text(
                        'UNDO',
                        style: TextStyle(
                          color: Color(0xFF5E35B1),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
          child: const Text(
            'Delete',
            style: TextStyle(color: Colors.red),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusOrb(Color baseColor) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.3),
          radius: 0.3,
          colors: [
            const Color.fromARGB(255, 255, 255, 255).withValues(alpha: 128), // Highlight overlay.
            baseColor,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: baseColor.withValues(alpha: 102),
            blurRadius: 12,
            offset: const Offset(0, 1),
          ),
        ],
      ),
    );
  }

  int get _unpaidInvoiceCount {
    return _invoices.where((i) => !i.isPaid).length;
  }

  double get _outstandingTotal =>
    _invoices
      .where((i) => !i.isPaid)
      .fold(0.0, (sum, i) => sum + i.amount);

  List<int> get _paidYears {
    final years = _invoices
        .where((i) => i.isPaid && i.paidAt != null)
        .map((i) => i.paidAt!.year)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));

    return years;
  }

  List<PaidRange> get _paidRanges {
    final now = DateTime.now();

    return [
      PaidRange('This Month'),
      PaidRange('Last 90 Days', days: 90),
      PaidRange('Year To Date', year: now.year),
      ..._paidYears.map((y) => PaidRange('$y', year: y)),
    ];
  }

  double _paidAmount(PaidRange range) {
    final now = DateTime.now();

    return _invoices
        .where((i) => i.isPaid && i.paidAt != null)
        .where((i) {
          final paid = i.paidAt!;

          if (range.days != null) {
            return paid.isAfter(
              now.subtract(Duration(days: range.days!)),
            );
          }

          if (range.year != null) {
            return paid.year == range.year;
          }

          return paid.year == now.year &&
                paid.month == now.month;
        })
        .fold(0.0, (sum, i) => sum + i.amount);
  }

  void _showInvoiceLimitDialog() {
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Free Limit Reached', textAlign: TextAlign.center, 
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)
            ),
          content: const Text(
            'You can track up to 3 active invoices on the free version.\n\n'
            'Mark one invoice as paid or Unlock Invoice Reminder Pro',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
            TextButton(
              onPressed: () {
                HapticFeedback.mediumImpact();
                Navigator.pop(context);
                 _buyPro();
              },
              child: const Text('Unlock Pro'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveProStatus() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsIsProKey, _isPro);
  }

  Future<int?> _showDaysPicker() {
    return showModalBottomSheet<int>(
      context: context,
      builder: (_) {
        return ListView(
          shrinkWrap: true,
          children: List.generate(7, (index) {
            final days = index + 1;
            return ListTile(
              title: Text('$days day${days > 1 ? 's' : ''} before'),
              onTap: () => Navigator.pop(context, days),
            );
          }),
        );
      },
    );
  }

  Future<void> printVersion() async {
    final info = await PackageInfo.fromPlatform();

    debugLog("Version: ${info.version}");
    debugLog("Build: ${info.buildNumber}");
  }

  Future<void> _loadAppVersion() async {
  final info = await PackageInfo.fromPlatform();

  if (!mounted) return;

  setState(() {
    _appVersion = '${info.version}+${info.buildNumber}';
  });
}

  Widget _buildDrawer() {
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.receipt_long,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _appTitle,
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 0.1),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 250),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _isPro
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        child: const Text('Invoice tracking made simple'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Divider(),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      'Immediate notifications',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  Switch(
                    value: _immediateNotificationsEnabled,
                    onChanged: (value) async {
                      setState(() {
                        _immediateNotificationsEnabled = value;
                      });

                      await _saveReminderSettings();
                      if (!mounted) return;
                    },
                  ),
                ],
              ),
            ),

            const Divider(),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      'Daily past due reminders',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Switch(
                    value: _dailyPastDueEnabled,
                    onChanged: (value) async {
                      setState(() => _dailyPastDueEnabled = value);

                      await _saveReminderSettings();
                      if (!mounted) return;

                      _rescheduleAllReminders();
                    },
                  ),
                ],
              ),
            ),

            const Divider(),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Invoice reminders',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 250),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _isPro
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          child: const Text('Tomorrow at 9:00 AM'),
                        ),
                      ],
                    ),
                  ),

                  Switch(
                    value: _remindersEnabled,
                    onChanged: (value) async {
                      HapticFeedback.selectionClick();

                      setState(() => _remindersEnabled = value);

                      await _saveReminderSettings();
                      if (!mounted) return;

                      _rescheduleAllReminders();
                    },
                  ),
                ],
              ),
            ),

            const Divider(),

            InkWell(
              onTap: () async {
                final selected = await _showDaysPicker();
                if (selected != null) {
                  setState(() => _notifyDaysBefore = selected);

                  await _saveReminderSettings();
                  if (!mounted) return;

                  await _rescheduleAllReminders();
                }
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Reminder',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),

                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 250),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _isPro
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            child: Text('$_notifyDaysBefore day${_notifyDaysBefore == 1 ? '' : 's'} before due date'),
                          ),
                        ],
                      ),
                    ),

                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),

            const Divider(),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Text(
                'Theme',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: RadioGroup<ThemeMode>(
                groupValue: _selectedThemeMode,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _selectedThemeMode = value);
                  widget.onThemeChanged(value);
                  Navigator.pop(context);
                },
                child: Column(
                  children: [
                    _buildThemeOption(ThemeMode.system, 'System'),
                    _buildThemeOption(ThemeMode.light, 'Light'),
                    _buildThemeOption(ThemeMode.dark, 'Dark'),
                  ],
                ),
              ),
            ),

            const Divider(),

            InkWell(
              onTap: _isPro
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      Navigator.pop(context);
                      _showUpgradeDialog();
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_isPro ? Icons.lock_open : Icons.lock),

                    const SizedBox(width: 16),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _isPro
                                ? 'Invoice Reminder Pro'
                                : 'Unlock Unlimited Invoices',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),

                          Text(
                            'Unlimited invoices unlocked',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),

                          Text(
                            'Thank you for supporting development!',
                            style: TextStyle(
                              fontSize: 12,
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Divider(),            

            InkWell(
              onTap: () async {
                Navigator.pop(context);

                final restored = await _restorePurchases();
                if (!mounted) return;

                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      restored
                          ? 'Purchase restored successfully 🎉'
                          : 'No previous purchase found',
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: const [
                    Icon(Icons.restore),
                    SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Restore purchase',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Divider(),

            InkWell(
              onTap: _exportData,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: const [
                    Icon(Icons.upload_file),
                    SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Backup Data',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            InkWell(
              onTap: _confirmImport,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: const [
                    Icon(Icons.download),
                    SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'Restore Data',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Divider(),

            InkWell(
              onTap: () {
                Navigator.pop(context);

                showDialog(
                  context: context,
                  builder: (_) => const AlertDialog(
                    title: Text('Contact support'),
                    content: Text(
                      'Email us at driftlinesoftware@gmail.com\n\n'
                      'We usually reply within 24 hours.',
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.email),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Contact support',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600),
                          ),
                          SizedBox(height: 4),
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 250),
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _isPro
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            child: const Text('driftlinesoftware@gmail.com'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 24, 0, 16),
              child: Center(
                child: GestureDetector(
                  onTap: () {

                    final now = DateTime.now();

                    if (_lastVersionTap == null ||
                        now.difference(_lastVersionTap!) > const Duration(seconds: 2)) {
                      _versionTapCount = 0;
                    }

                    _versionTapCount++;
                    _lastVersionTap = now;

                    if (_versionTapCount >= 7) {

                      _versionTapCount = 0;

                      Navigator.pop(context); // Closes the drawer before navigating.

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DebugScreen(),
                        ),
                      );
                    }
                  },
                  child: Text(
                    'Version $_appVersion',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Build
  String get _appTitle =>
    _isPro ? 'Invoice Reminder Pro' : 'Invoice Reminder';

  @override
  Widget build(BuildContext context) {
    final unpaidInvoices =
        _filteredInvoices.where((i) => !i.isPaid).toList();

    final paidInvoices = _filteredInvoices
        .where((i) => i.isPaid)
        .toList()
      ..sort((a, b) => b.paidAt!.compareTo(a.paidAt!));

    final hasInvoices = _invoices.any((i) => !i.isPaid);
    final hasSearch = _searchQuery.isNotEmpty;

    


    return PopScope(
      canPop: !(_scaffoldKey.currentState?.isDrawerOpen ?? false),
      onPopInvokedWithResult: (didPop, result) {
        if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
          Navigator.of(context).pop(); // Closes only the drawer.
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: _buildDrawer(),
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _appTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
              _buildVersionBadge(),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.menu),
            tooltip: 'Open menu',
            onPressed: () {
              FocusScope.of(context).unfocus();
              _scaffoldKey.currentState?.openDrawer();
            },
          ),
        ),
        body: SafeArea(
          child: Stack(
            children: [

              Padding(
                padding: const EdgeInsets.only(bottom: 74), // Reserves space for the floating action button.
                child: DefaultTabController(
                length: 2,
                  child: Column(
                    children: [
                      if (_isPowerSaverOn) const PowerSaverBanner(),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [

                          _buildHeaderStatsUnpaid(),

                          const SizedBox(height: 2),

                          _buildHeaderStatsPaid(),

                        ],
                      ),

                      const SizedBox(height: 6),

                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                decoration: InputDecoration(
                                  hintText: 'Search client',
                                  prefixIcon: const Icon(Icons.search),                      
                                  isDense: true,

                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                    horizontal: 12,
                                  ),

                                  prefixIconConstraints: const BoxConstraints(
                                    minHeight: 24,
                                    minWidth: 40,
                                  ),
                                  filled: true,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(5),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                                onChanged: (value) {
                                  setState(() => _searchQuery = value.trim());
                                },
                              ),
                            ),

                            const SizedBox(width: 1),

                            Opacity(
                              opacity: _tabController.index == 0 ? 1 : 0.45,
                              child: DropdownButtonHideUnderline(
                                child: SizedBox(
                                  width: 132,
                                  child: DropdownButton2<InvoiceFilter>(
                                    hint: Text(
                                      'Filter',
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    value: _activeFilter,
                                    alignment: Alignment.centerLeft,

                                    // Disables unpaid-only filters while the Paid tab is active.
                                    onChanged: _tabController.index == 0
                                        ? (value) {
                                            if (value != null) {
                                              setState(() => _activeFilter = value);
                                            }
                                          }
                                        : null,

                                    items: [
                                      DropdownMenuItem(
                                        value: InvoiceFilter.all,
                                        child: Text(
                                          'All',
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      DropdownMenuItem(
                                        value: InvoiceFilter.dueToday,
                                        child: Text(
                                          'Today',
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      DropdownMenuItem(
                                        value: InvoiceFilter.upcoming,
                                        child: Text(
                                          'Upcoming',
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      DropdownMenuItem(
                                        value: InvoiceFilter.pastDue,
                                        child: Text(
                                          'Past Due',
                                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                    dropdownStyleData: const DropdownStyleData(
                                      maxHeight: 300,
                                      offset: Offset(0, 0),
                                    ),
                                    buttonStyleData: const ButtonStyleData(
                                      padding: EdgeInsets.symmetric(horizontal: 1),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      TabBar(
                        controller: _tabController,
                        tabs: const [
                          Tab(text: 'Unpaid'),
                          Tab(text: 'Paid'),
                        ],
                      ),

                      const Divider(height: 1),

                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            unpaidInvoices.isEmpty
                                ? _buildEmptyUnpaidState(hasSearch, hasInvoices)
                                : _buildInvoiceList(unpaidInvoices),

                            paidInvoices.isEmpty
                                ? (hasSearch && hasInvoices
                                    ? _buildNoPaidSearchResults()
                                    : _buildEmptyPaidState())
                                : _buildInvoiceList(paidInvoices),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                right: 16,
                bottom: 16,
                child: Tooltip(
                  message: _tabController.index == 1
                      ? 'Add paid invoice'
                      : 'Add new invoice',
                  preferBelow: false,
                  verticalOffset: 42,
                  child: FloatingActionButton(
                    onPressed: () async {
                      HapticFeedback.lightImpact();

                      if (!_canAddInvoice) {
                        _showInvoiceLimitDialog();
                        return;
                      }

                      final isPaidTab = _tabController.index == 1;

                      final newInvoice = await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AddEditInvoiceScreen(
                            startAsPaid: isPaidTab,
                          ),
                        ),
                      );

                      if (!mounted) return;

                      if (newInvoice is Invoice) {
                        setState(() {
                          _invoices.add(newInvoice);
                        });

                        await _saveInvoices();

                        if (!newInvoice.isPaid) {
                          _scheduleInvoiceReminders(newInvoice, showImmediate: true);
                        }
                      }
                    },
                    child: const Icon(Icons.add),
                  ),
                ),
              ),
            ],            
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIndicator(Invoice invoice) {
    final dueDateOnly = DateTime(
      invoice.dueDate.year,
      invoice.dueDate.month,
      invoice.dueDate.day,
    );

    late final Color color;
    late final String label;

    if (dueDateOnly.isBefore(_today)) {
      color = const Color.fromARGB(255, 255, 13, 0);
      label = 'Invoice overdue';
    } 
    else if (dueDateOnly.isAtSameMomentAs(_today)) {
      color = const Color.fromARGB(255, 255, 102, 0);
      label = 'Invoice due today';
    } 
    else if (!dueDateOnly.isAfter(
        _today.add(Duration(days: _notifyDaysBefore)))) {
      color = const Color.fromARGB(255, 216, 194, 0);
      label = 'Invoice due soon';
    }
    else {
      color = const Color.fromARGB(255, 0, 183, 255);
      label = 'Invoice due in the future';
    }

    return Tooltip(
      message: label,
      preferBelow: false,
      verticalOffset: 24,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        label: label,
        child: _buildStatusOrb(color),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}
