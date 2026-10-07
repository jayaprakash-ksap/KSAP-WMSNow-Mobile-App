import 'package:flutter/material.dart';
import '../services/receiving_store.dart';
import '../services/receiving_sync.dart';
import '../services/serial_receiving_service.dart';
import 'serial_scan_field.dart';

/// One screen: scan a serial, then work each scanned serial through its
/// stages in a table - Receive, then Putaway (once every unit on the LPN is
/// received or declared short), then Sync to WMS.
///
/// The table shows only the serials that have actually been scanned - never
/// the rest of the shipment's catalog. Each row: Shipment / Item / Serial /
/// LPN / Batch, a Status (Not Received -> Received -> Putaway -> Synced to
/// WMS), and the Receive / Putaway / Sync / Short buttons, each enabled
/// strictly by that status and the per-LPN quantity check
/// (`shipped_qty - received_qty - short_qty == 0`).
class SerialReceivingSessionScreen extends StatefulWidget {
  final SerialReceivingService service;
  final ReceivingStore store;
  final ShipmentStaging staging;

  const SerialReceivingSessionScreen({
    super.key,
    required this.service,
    required this.store,
    required this.staging,
  });

  @override
  State<SerialReceivingSessionScreen> createState() =>
      _SerialReceivingSessionScreenState();
}

class _SerialReceivingSessionScreenState
    extends State<SerialReceivingSessionScreen> {
  late final ReceivingSync _sync = ReceivingSync(widget.service, widget.store);
  ShipmentStaging get _s => widget.staging;

  String? _syncingLpn;
  String? _feedback;
  bool _feedbackOk = false;

  bool get _anyLpnOpen =>
      _s.lpnNbrs.any((l) => !_s.isPutawayDone(l) && !_s.isSynced(l));

  Future<void> _save() => widget.store.save(_s);

  Future<void> _onScanSerial(String raw) async {
    final result = _s.addScan(raw);
    if (result.ok) await _save();
    if (!mounted) return;
    setState(() {
      _feedbackOk = result.ok;
      if (result.ok) {
        final lpn = result.scan!.lpnNbr;
        _feedback = '${result.scan!.serialNbr} → $lpn  '
            '(scanned ${_s.scannedCountForLpn(lpn)}/${_s.shippedQtyForLpn(lpn)})';
      } else {
        _feedback = result.message;
      }
    });
  }

  Future<void> _receive(String serial) async {
    if (_s.receiveSerial(serial)) {
      await _save();
      if (mounted) setState(() => _feedback = null);
    }
  }

  Future<void> _undoReceive(String serial) async {
    if (_s.unreceiveSerial(serial)) {
      await _save();
      if (mounted) setState(() {});
    }
  }

  Future<void> _removeSerial(String serial) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove serial?'),
        content: Text('Remove $serial from the list?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true && _s.removeScan(serial)) {
      await _save();
      if (mounted) setState(() => _feedback = null);
    }
  }

  Future<void> _markShort(String lpn) async {
    final gap = _s.shippedQtyForLpn(lpn) - _s.receivedCountForLpn(lpn);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Receive $lpn short?'),
        content: Text(
          '$gap unit(s) of ${_s.shippedQtyForLpn(lpn)} will be marked short. '
          'The LPN can then be put away and synced - WMS receives only the '
          '${_s.receivedCountForLpn(lpn)} unit(s) received here, and the '
          'shipment line stays open.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep receiving')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm short')),
        ],
      ),
    );
    if (ok == true && _s.markShort(lpn)) {
      await _save();
      if (mounted) setState(() {});
    }
  }

  Future<void> _confirmPutaway(String lpn, {bool changing = false}) async {
    final location = await showDialog<String>(
      context: context,
      builder: (_) => _LocationDialog(lpn: lpn, changing: changing),
    );
    if (location == null || location.trim().isEmpty) return;
    if (changing) _s.clearPutaway(lpn);
    if (_s.confirmPutaway(lpn, location)) {
      await _save();
      if (mounted) setState(() {});
    }
  }

  Future<void> _syncLpn(String lpn) async {
    if (_syncingLpn != null) return;
    setState(() => _syncingLpn = lpn);
    final result = await _sync.syncLpn(_s, lpn);
    if (!mounted) return;
    setState(() => _syncingLpn = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.synced
          ? '$lpn synced to WMS.'
          : '$lpn ${result.errorCall} failed: ${result.errorMessage}'),
      backgroundColor:
          result.synced ? Colors.green.shade700 : Colors.red.shade700,
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final lpns = _s.lpnNbrs;
    final syncedCount = lpns.where(_s.isSynced).length;
    final allSynced = lpns.isNotEmpty && syncedCount == lpns.length;

    return Scaffold(
      appBar: AppBar(
        title: Text('Receiving ${_s.shipmentNbr}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text('$syncedCount/${lpns.length} synced',
                  style: const TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _headerCard(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: SerialScanField(
              label: 'Serial Nbr',
              hintText:
                  _anyLpnOpen ? 'Scan a serial number' : 'All LPNs put away',
              autofocus: true,
              enabled: _anyLpnOpen,
              onSubmit: _onScanSerial,
            ),
          ),
          if (_feedback != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
              child: Row(
                children: [
                  Icon(_feedbackOk ? Icons.check_circle : Icons.error,
                      size: 16, color: _feedbackOk ? Colors.green : Colors.red),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_feedback!,
                        style: TextStyle(
                            color: _feedbackOk
                                ? Colors.green.shade800
                                : Colors.red,
                            fontSize: 13)),
                  ),
                ],
              ),
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
                const Expanded(
                    child: Text('All LPNs received, put away and synced.')),
                TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done')),
              ]),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _s.scans.isEmpty
                ? const Center(
                    child: Text('Scan a serial number to add its first row.'))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    children: [
                      for (final lpn in _lpnsWithRows) _lpnCard(lpn),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// LPNs that have at least one scanned serial, in catalog order.
  List<String> get _lpnsWithRows =>
      _s.lpnNbrs.where((l) => _s.scansForLpn(l).isNotEmpty).toList();

  Widget _headerCard() {
    final scanned = _s.scans.length;
    final received = _s.scans.where((s) => s.received).length;
    final expected = _s.expectedSerials.length;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Shipment ${_s.shipmentNbr}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 2),
            Text('${_s.facilityCode} • ${_s.companyCode}',
                style: const TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 6),
            Text('$received received • $scanned scanned • $expected expected  '
                '•  ${_s.lpnNbrs.length} LPN(s)'),
          ],
        ),
      ),
    );
  }

  /// One card per LPN: its scanned-serial rows, then a single shared
  /// action bar (Short / Putaway / Sync) for the whole LPN.
  Widget _lpnCard(String lpn) {
    final lpnRows = _s.scansForLpn(lpn)
      ..sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('LPN $lpn',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(width: 10),
              _lpnStatusText(lpn),
              const Spacer(),
              Text(
                  '${_s.receivedCountForLpn(lpn)} / ${_s.shippedQtyForLpn(lpn)}'
                  '${_s.shortQtyForLpn(lpn) > 0 ? '  (short ${_s.shortQtyForLpn(lpn)})' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowHeight: 34,
                dataRowMinHeight: 40,
                dataRowMaxHeight: 48,
                columnSpacing: 20,
                columns: const [
                  DataColumn(label: Text('Shipment Nbr')),
                  DataColumn(label: Text('Item')),
                  DataColumn(label: Text('Serial Nbr')),
                  DataColumn(label: Text('LPN Nbr')),
                  DataColumn(label: Text('Batch Nbr')),
                  DataColumn(label: Text('Status')),
                  DataColumn(label: Text('Actions')),
                ],
                rows: [
                  for (final r in lpnRows)
                    DataRow(cells: [
                      DataCell(Text(_s.shipmentNbr)),
                      DataCell(Text(r.item)),
                      DataCell(Text(r.serialNbr)),
                      DataCell(Text(r.lpnNbr)),
                      DataCell(Text(r.batchNbr)),
                      DataCell(_statusChip(_s.serialStatus(r.serialNbr))),
                      DataCell(_serialRowActions(r)),
                    ]),
                ],
              ),
            ),
            const Divider(height: 20),
            _lpnActionBar(lpn),
          ],
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

  /// Per-serial actions only, laid out inline on the row: Receive (or Undo)
  /// followed by Remove Serial.
  Widget _serialRowActions(ScannedSerial r) {
    final status = _s.serialStatus(r.serialNbr);
    if (status == SerialStatus.putaway || status == SerialStatus.syncedToWms) {
      return const SizedBox(width: 1);
    }
    final buttons = <Widget>[];
    if (_s.canReceiveSerial(r.serialNbr)) {
      buttons.add(
          _smallButton('Receive', () => _receive(r.serialNbr), filled: true));
    } else if (_s.canUndoReceive(r.serialNbr)) {
      buttons.add(_smallButton('Undo', () => _undoReceive(r.serialNbr)));
    }
    if (_s.canRemoveScan(r.serialNbr)) {
      buttons
          .add(_smallButton('Remove Serial', () => _removeSerial(r.serialNbr)));
    }
    if (buttons.isEmpty) return const SizedBox(width: 1);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          buttons[i],
        ],
      ],
    );
  }

  /// One shared action bar for the whole LPN.
  Widget _lpnActionBar(String lpn) {
    final syncing = _syncingLpn == lpn;
    final children = <Widget>[];

    if (_s.canMarkShort(lpn)) {
      children.add(_smallButton('Short', () => _markShort(lpn)));
    }

    if (_s.canConfirmPutaway(lpn)) {
      children.add(
          _smallButton('Putaway', () => _confirmPutaway(lpn), filled: true));
    } else if (_s.isPutawayDone(lpn) && !_s.isSynced(lpn)) {
      children.add(Text('Location: ${_s.lpns[lpn]!.putawayLocation}',
          style: const TextStyle(fontSize: 13)));
      children.add(_smallButton(
          'Change loc', () => _confirmPutaway(lpn, changing: true)));
    }

    if (_s.canSync(lpn)) {
      final isError = _s.lpns[lpn]?.lastError != null;
      children.add(syncing
          ? const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)))
          : _smallButton(isError ? 'Retry Sync' : 'Sync', () => _syncLpn(lpn),
              filled: true));
    }

    if (_s.isSynced(lpn)) {
      children.add(const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.check_circle, color: Colors.green, size: 18),
        SizedBox(width: 6),
        Text('Synced to WMS', style: TextStyle(color: Colors.green)),
      ]));
    }

    final err = _s.lpns[lpn]?.lastError;
    if (err != null && !_s.isSynced(lpn)) {
      children.add(Text('${err.call} failed: ${err.message}',
          style: const TextStyle(color: Colors.red, fontSize: 12)));
    }

    if (children.isEmpty) {
      children.add(Text(_stageHint(lpn),
          style: const TextStyle(fontSize: 12, color: Colors.black54)));
    }

    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  String _stageHint(String lpn) {
    if (!_s.isLpnQtyComplete(lpn)) {
      return 'Receive every serial for this LPN, or press Short.';
    }
    if (!_s.isPutawayDone(lpn)) return 'Confirm a putaway location.';
    return 'Ready.';
  }

  Widget _lpnStatusText(String lpn) {
    final (label, color) = switch (_s.lpnStatus(lpn)) {
      LpnStatus.receiving => ('Receiving', Colors.blueGrey),
      LpnStatus.readyForPutaway => ('Ready for putaway', Colors.orange),
      LpnStatus.readyForSync => ('Ready to sync', Colors.indigo),
      LpnStatus.syncing => ('Syncing', Colors.indigo),
      LpnStatus.synced => ('Synced', Colors.green),
      LpnStatus.error => ('Error', Colors.red),
    };
    return Text(label,
        style:
            TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600));
  }

  Widget _smallButton(String label, VoidCallback onTap, {bool filled = false}) {
    final style = ButtonStyle(
      visualDensity: VisualDensity.compact,
      padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 12, vertical: 0)),
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
        onSubmit: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
      ],
    );
  }
}
