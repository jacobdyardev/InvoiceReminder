# Invoice Reminder

Invoice Reminder is a Flutter-based invoice tracking and payment reminder application designed for freelancers, contractors, and small businesses.

The application helps users track unpaid invoices, manage payment history, and receive automated reminders so payments do not get overlooked.

## Features

- Create and manage invoices
- Track paid and unpaid invoices
- Payment history and invoice notes
- Due today, upcoming, and overdue filtering
- Local notification reminders
- Daily scheduling and reminder pipeline
- One-time Pro upgrade support
- Offline-first design

## Technical Highlights

- Built with Flutter/Dart
- Local persistence using SharedPreferences
- Alarm and background scheduling architecture
- Notification scheduling and reconciliation system
- In-app purchase integration
- Debug and observability tooling

## Architecture

The reminder system follows a deterministic pipeline approach:

```text
Invoice Data
    ↓
Daily Reconciliation
    ↓
Reminder Scheduling
    ↓
Notification Generation
    ↓
User Delivery
```

## Installation

```bash
git clone https://github.com/JacobDyarDev/InvoiceReminder.git
cd InvoiceReminder
flutter pub get
flutter run
```

## Status

Published mobile application with active development and ongoing improvements.
