import 'package:flutter/material.dart';
import '../models/invoice.dart';
import 'package:flutter/services.dart';

class AddEditInvoiceScreen extends StatefulWidget {
  final Invoice? invoice;
  final bool startAsPaid;

  const AddEditInvoiceScreen({
    super.key, 
    this.invoice, 
    this.startAsPaid = false,
    });

  


  @override
  State<AddEditInvoiceScreen> createState() => _AddEditInvoiceScreenState();
}

class _AddEditInvoiceScreenState extends State<AddEditInvoiceScreen> {
  final _clientController = TextEditingController();
  final _amountController = TextEditingController();
  final _notesController = TextEditingController();

  DateTime _selectedDate = DateTime.now();

  bool _isPaid = false;

  
  @override
  void initState() {
    super.initState();

    _isPaid = widget.invoice?.isPaid ?? widget.startAsPaid;

    if (widget.invoice != null) {
      _clientController.text = widget.invoice!.clientName;
      _amountController.text =
          widget.invoice!.amount.toStringAsFixed(2);
      _notesController.text = widget.invoice!.notes ?? '';
      _selectedDate = widget.invoice!.isPaid
        ? (widget.invoice!.paidAt ?? DateTime.now())
        : widget.invoice!.dueDate;
    }
  }

  @override
  void dispose() {
    _clientController.dispose();
    _amountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _saveInvoice() {
    final clientName = _clientController.text.trim();
    final amount = double.tryParse(_amountController.text);

    if (clientName.isEmpty || amount == null) return;

    final invoice = widget.invoice ??
        Invoice(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          createdAt: DateTime.now(),
          dueDate: _selectedDate,
          clientName: clientName,
          amount: amount,
        );

    invoice.clientName = clientName;
    invoice.amount = amount;
    invoice.notes = _notesController.text.trim().isEmpty
        ? null
        : _notesController.text.trim();

    invoice.isPaid = _isPaid;

    if (_isPaid) {
      invoice.paidAt = _selectedDate;
    } else {
      invoice.dueDate = _selectedDate;
    }

    Navigator.pop(context, invoice);
  }

  void _addDays(int days) {
    setState(() {
      _selectedDate = DateTime.now().add(Duration(days: days));
    });
  }

  void _firstOfNextMonth() {
    final now = DateTime.now();
    setState(() {
      _selectedDate = DateTime(now.year, now.month + 1, 1);
    });
  }

  void _endOfMonth() {
    final now = DateTime.now();
    setState(() {
      _selectedDate = DateTime(now.year, now.month + 1, 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.invoice != null
              ? 'Edit Invoice'
              : widget.startAsPaid
                  ? 'Add Paid Invoice'
                  : 'Add New Invoice',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saveInvoice,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _clientController,
              decoration: const InputDecoration(
                labelText: 'Client name',
                labelStyle: TextStyle(fontWeight: FontWeight.w600)
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Amount',
                labelStyle: TextStyle(fontWeight: FontWeight.w600),
                prefixText: '\$ ',
              ),
            ),
            const SizedBox(height: 16),

            ListTile(
              title: Text(
                _isPaid ? 'Date Paid' : 'Due Date',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '${_selectedDate.month}/${_selectedDate.day}/${_selectedDate.year}',
              ),
              trailing: const Icon(Icons.calendar_today),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
                );

                if (picked != null) {
                  setState(() => _selectedDate = picked);
                }
              },
            ),


            if (!_isPaid) ...[
              const SizedBox(height: 12),

              Wrap(
                alignment: WrapAlignment.center,
                runAlignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: const Text('7D'),
                    onPressed: () => _addDays(7),
                  ),
                  ActionChip(
                    label: const Text('14D'),
                    onPressed: () => _addDays(14),
                  ),
                  ActionChip(
                    label: const Text('30D'),
                    onPressed: () => _addDays(30),
                  ),
                  ActionChip(
                    label: const Text('90D'),
                    onPressed: () => _addDays(90),
                  ),
                  ActionChip(
                    label: const Text('First of Next Month'),
                    onPressed: _firstOfNextMonth,
                  ),
                  ActionChip(
                    label: const Text('End of Current Month'),
                    onPressed: _endOfMonth,
                  ),
                ],
              ),
            ],

            const SizedBox(height: 16),

            TextField(
              controller: _notesController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                labelStyle: TextStyle(fontWeight: FontWeight.w600)
              ),
              maxLines: 3,
            ),
            if (widget.invoice != null) ...[
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 8),

              TextButton.icon(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Delete invoice?'),
                      content: const Text('This action cannot be undone.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () {
                            HapticFeedback.mediumImpact();
                            Navigator.pop(context, true);
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red,
                          ),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );

                  if (!context.mounted) return;

                  if (confirmed == true) {
                    Navigator.pop(context, 'delete');
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete Invoice'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.red,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
