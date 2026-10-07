import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/nonserial_receiving_service.dart';
import '../services/nonserial_receiving_store.dart';
import '../services/nonserial_receiving_sync.dart';
import '../services/serial_receiving_service.dart';
import 'serial_scan_field.dart';

/// Scenario 2.2 - "Receiving without Expected Serial Numbers".
///
/// One table, one row per shipment line (`ib_shipment_dtl`). The operator
/// types a Received Qty per row and presses Receive (or Short). Receiving
/// short of a line group's remaining quantity spawns a continuation line
/// with a blank, scannable LPN for the rest. Then Putaway (scan a
/// location) and Sync, per line - nothing is posted to WMS until Sync.
class NonSerialReceivingSessionScreen extends StatefulWidget {
  final NonSerialReceivingService service;
  final SerialReceivingService wmsService; // shared receive / bulk_locate
  final NonSerialReceivingStore store;
  final NonSerialStaging staging;

  const NonSerialReceivingSessionScreen({
    super.key,
    required this.service,
    required this.wmsService,
    required this.store,
    required this.staging,
  });

  @override
  State<NonSerialReceivingSessionScreen> createState() =>
      _NonSerialReceivingSessionScreenState();
}

class _NonSerialReceivingSessionScreenState
    extends State<NonSerialReceivingSessionScreen> {
  late final NonSerialSync _sync =
      NonSerialSync(widget.wmsService, widget.store);
  NonSerialStaging get _s => widget.staging;

  final Map<String, TextEditingController> _qtyCtrls = {};
  final Map<String, TextEditingController> _lpnCtrls = {};
  String? _syncingId;
  String? _feedback;
  bool _feedbackOk = false;

  @override
  void dispose() {
    for (final c in _qtyCtrls.values) {
      c.dispose();
    }
    for (final c in _lpnCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _qtyCtrl(String id) =>
      _qtyCtrls.putIfAbsent(id, () => TextEditingController());
  TextEditingController _lpnCtrl(String id, String initial) =>
      _lpnCtrls.putIfAbsent(id, () => TextEditingController(text: initial));

  Future<void> _save() => widget.store.save(_s);

  void _say(bool ok, String msg) => setState(() {
        _feedbackOk = ok;
        _feedback = msg;
      });

  int _enteredQty(String id) => int.tryParse(_qtyCtrl(id).text.trim()) ?? 0;

  Future<void> _setLpn(String id) async {
    final r = _s.setLpn(id, _lpnCtrl(id, '').text);
    if (!r.ok) {
      _say(false, r.message);
    } else {
      await _save();
      if (mounted) setState(() => _feedback = null);
    }
  }

  Future<void> _receive(String id) async {
    if (_s.canEditLpn(id)) {
      final lr = _s.setLpn(id, _lpnCtrl(id, '').text);
      if (!lr.ok) {
        _say(false, lr.message);
        return;
      }
    }
    final r = _s.receiveLine(id, _enteredQty(id));
    if (!r.ok) {
      _say(false, r.message);
      return;
    }
    await _save();
    if (mounted) setState(() => _feedback = null);
  }

  Future<void> _short(String id) async {
    if (_s.canEditLpn(id)) {
      final lr = _s.setLpn(id, _lpnCtrl(id, '').text);
      if (!lr.ok) {
        _say(false, lr.message);
        return;
      }
    }
    final line = _s.lineById(id);
    final entered = _qtyCtrl(id).text.trim().isEmpty ? 0 : _enteredQty(id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Short ${line?.item} / ${line?.batchNbr}?'),
        content: Text(
          'Receive $entered unit(s) and write off the remaining '
          '${_s.groupRemaining(line?.groupId ?? id) - entered} as short. '
          'The shipment line stays open in WMS.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm short')),
        ],
      ),
    );
    if (ok != true) return;
    final r = _s.shortLine(id, entered);
    if (!r.ok) {
      _say(false, r.message);
      return;
    }
    await _save();
    if (mounted) setState(() => _feedback = null);
  }

  Future<void> _undo(String id) async {
    if (_s.undoReceiveLine(id)) {
      _qtyCtrl(id).clear();
      await _save();
      if (mounted) setState(() {});
    }
  }

  Future<void> _remove(String id) async {
    if (_s.removeLine(id)) {
      _qtyCtrls.remove(id)?.dispose();
      _lpnCtrls.remove(id)?.dispose();
      await _save();
      if (mounted) setState(() {});
    }
  }

  Future<void> _confirmPutaway(String id, {bool changing = false}) async {
    final loc = await showDialog<String>(
      context: context,
      builder: (_) => _LocationDialog(
          lpn: _s.lineById(id)?.lpnNbr ?? '', changing: changing),
    );
    if (loc == null || loc.trim().isEmpty) return;
    if (changing) _s.clearPutaway(id);
    if (_s.confirmPutaway(id, loc)) {
      await _save();
      if (mounted) setState(() {});
    }
  }

  Future<void> _syncLine(String id) async {
    if (_syncingId != null) return;
    setState(() => _syncingId = id);
    final result = await _sync.syncLine(_s, id);
    if (!mounted) return;
    setState(() => _syncingId = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.synced
          ? '${_s.lineById(id)?.lpnNbr} synced to WMS.'
          : '${result.errorCall} failed: ${result.errorMessage}'),
      backgroundColor:
          result.synced ? Colors.green.shade700 : Colors.red.shade700,
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final lines = _s.lines;
    final syncable = lines.where((l) => l.lpnNbr.trim().isNotEmpty).length;
    final synced = lines.where((l) => _s.isSynced(l.id)).length;
    final allSynced = syncable > 0 && synced == syncable;

    return Scaffold(
      appBar: AppBar(
        title: Text('Non-Serial Receiving ${_s.shipmentNbr}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text('$synced/$syncable synced',
                  style: const TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Shipment ${_s.shipmentNbr}',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(
                      '${_s.facilityCode} • ${_s.companyCode} • '
                      '${lines.length} line(s)',
                      style:
                          const TextStyle(color: Colors.black54, fontSize: 12)),
                ],
              ),
            ),
          ),
          if (_feedback != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Row(children: [
                Icon(_feedbackOk ? Icons.check_circle : Icons.error,
                    size: 16, color: _feedbackOk ? Colors.green : Colors.red),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_feedback!,
                      style: TextStyle(
                          color:
                              _feedbackOk ? Colors.green.shade800 : Colors.red,
                          fontSize: 13)),
                ),
              ]),
            ),
          if (allSynced)
            Container(
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                const Icon(Icons.verified, color: Colors.green, size: 18),
                const SizedBox(width: 8),
                const Expanded(child: Text('All lines received and synced.')),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done')),
              ]),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                child: _table(lines),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(List<NonSerialLine> lines) {
    return DataTable(
      headingRowHeight: 36,
      dataRowMinHeight: 46,
      dataRowMaxHeight: 64,
      columnSpacing: 16,
      columns: const [
        DataColumn(label: Text('Shipment Nbr')),
        DataColumn(label: Text('Item')),
        DataColumn(label: Text('LPN Nbr')),
        DataColumn(label: Text('Batch')),
        DataColumn(label: Text('Lock Code')),
        DataColumn(label: Text('Shipped Qty')),
        DataColumn(label: Text('Received Qty')),
        DataColumn(label: Text('Status')),
        DataColumn(label: Text('Actions')),
      ],
      rows: [
        for (final l in lines)
          DataRow(
            color: l.isOriginal
                ? null
                : WidgetStatePropertyAll(Colors.amber.withValues(alpha: 0.12)),
            cells: [
              DataCell(Text(l.shipmentNbr)),
              DataCell(Text(l.item)),
              DataCell(_lpnCell(l)),
              DataCell(Text(l.batchNbr)),
              DataCell(Text(l.lockCode.isEmpty ? '—' : l.lockCode)),
              DataCell(Text('${l.shippedQty}')),
              DataCell(_receivedQtyCell(l)),
              DataCell(_statusChip(_s.lineStatus(l.id))),
              DataCell(_actions(l)),
            ],
          ),
      ],
    );
  }

  Widget _lpnCell(NonSerialLine l) {
    if (!_s.canEditLpn(l.id)) return Text(l.lpnNbr.isEmpty ? '—' : l.lpnNbr);
    final c = _lpnCtrl(l.id, l.lpnNbr);
    return SizedBox(
      width: 140,
      child: TextField(
        controller: c,
        textCapitalization: TextCapitalization.characters,
        inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Scan LPN',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            onPressed: () async {
              final v = await scanBarcode(context);
              if (v != null) {
                c.text = v.trim();
                _setLpn(l.id);
              }
            },
          ),
        ),
        onSubmitted: (_) => _setLpn(l.id),
      ),
    );
  }

  Widget _receivedQtyCell(NonSerialLine l) {
    if (l.received) {
      return Text('${l.receivedQty}${l.isShort ? ' (short)' : ''}',
          style: TextStyle(
              fontWeight: FontWeight.w600,
              color: l.isShort ? Colors.orange.shade800 : null));
    }
    return SizedBox(
      width: 90,
      child: TextField(
        controller: _qtyCtrl(l.id),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(
          isDense: true,
          hintText: 'Qty',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _statusChip(SerialStatus status) {
    final color = switch (status) {
      SerialStatus.notReceived => Colors.blueGrey,
      SerialStatus.received => Colors.orange,
      SerialStatus.putaway => Colors.indigo,
      SerialStatus.syncedToWms => Colors.green,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(status.label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _actions(NonSerialLine l) {
    final id = l.id;
    if (_s.isSynced(id)) {
      return const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_circle, color: Colors.green, size: 18),
        SizedBox(width: 6),
        Text('Synced', style: TextStyle(color: Colors.green)),
      ]);
    }

    final btns = <Widget>[];
    if (!l.received) {
      btns.add(_btn('Receive', () => _receive(id), filled: true));
      if (_s.canShortLine(id) || l.lpnNbr.trim().isNotEmpty) {
        btns.add(_btn('Short', () => _short(id)));
      }
      if (_s.canRemoveLine(id)) {
        btns.add(_btn('Remove', () => _remove(id)));
      }
    } else if (!_s.isPutawayDone(id)) {
      btns.add(_btn('Putaway', () => _confirmPutaway(id), filled: true));
      if (_s.canUndoReceive(id)) btns.add(_btn('Undo', () => _undo(id)));
    } else {
      btns.add(Text('Loc: ${l.putawayLocation}',
          style: const TextStyle(fontSize: 12)));
      btns.add(_btn('Change', () => _confirmPutaway(id, changing: true)));
      final isErr = l.lastError != null;
      btns.add(_syncingId == id
          ? const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)))
          : _btn(isErr ? 'Retry Sync' : 'Sync', () => _syncLine(id),
              filled: true));
    }
    if (l.lastError != null && !_s.isSynced(id)) {
      btns.add(Text('${l.lastError!.call} failed: ${l.lastError!.message}',
          style: const TextStyle(color: Colors.red, fontSize: 11)));
    }
    return Wrap(spacing: 6, runSpacing: 2, children: btns);
  }

  Widget _btn(String label, VoidCallback onTap, {bool filled = false}) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding:
          WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 10)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
    );
    return filled
        ? FilledButton(onPressed: onTap, style: style, child: Text(label))
        : OutlinedButton(onPressed: onTap, style: style, child: Text(label));
  }
}

class _LocationDialog extends StatelessWidget {
  final String lpn;
  final bool changing;
  const _LocationDialog({required this.lpn, required this.changing});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(changing ? 'Change location for $lpn' : 'Putaway $lpn'),
      content: SerialScanField(
        label: 'Location Barcode',
        hintText: 'Scan or type the location',
        autofocus: true,
        clearOnSubmit: false,
        onSubmit: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
      ],
    );
  }
}
