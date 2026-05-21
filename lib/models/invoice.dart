class Invoice {
  String id;
  String clientName;
  double amount;
  DateTime dueDate;
  bool isPaid;
  DateTime createdAt;
  DateTime? paidAt;
  String? notes;

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'clientName': clientName,
      'amount': amount,
      'dueDate': dueDate.toIso8601String(),
      'isPaid': isPaid,
      'createdAt': createdAt.toIso8601String(),
      'paidAt': paidAt?.toIso8601String(),
      'notes': notes,
    };
  }

  static Invoice fromJson(Map<String, dynamic> json) {
    return Invoice(
      id: json['id'],
      clientName: json['clientName'],
      amount: json['amount'],
      dueDate: DateTime.parse(json['dueDate']),
      isPaid: json['isPaid'],
      createdAt: DateTime.parse(json['createdAt']),
      paidAt:
          json['paidAt'] != null ? DateTime.parse(json['paidAt']) : null,
      notes: json['notes'],
    );
  }  

  Invoice({
    required this.id,
    required this.clientName,
    required this.amount,
    required this.dueDate,
    this.isPaid = false,
    required this.createdAt,
    this.paidAt,
    this.notes,
  });
}

extension InvoiceHelpers on Invoice {
  bool get isOverdue {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final dueDateOnly = DateTime(dueDate.year, dueDate.month, dueDate.day);
    return !isPaid && dueDateOnly.isBefore(todayDate);
  }
}
