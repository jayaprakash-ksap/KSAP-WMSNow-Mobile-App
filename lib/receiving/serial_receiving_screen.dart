import 'package:flutter/material.dart';
import '../services/receiving_store.dart';
import '../services/rwmobile_service.dart';
import '../services/serial_receiving_service.dart';
import 'serial_receiving_session_screen.dart';
import 'serial_scan_field.dart';

/// Serial-driven receiving - entry point.
///
/// Bespoke lgfapi-backed feature (not RF-driven), reached via a synthetic
/// main-menu tile (see main.dart's _MenuView) and pushed on top of the live
/// RF session, which it never touches - same pattern as POD.
///
/// The operator scans only a serial number to begin - the shipment is
/// never typed. That first serial is resolved to its shipment (lgfapi
/// `ib_shipment_serial_nbr` by `original_serial_nbr`), the shipment's
/// expected-serial catalog + line detail are fetched once, and the scan is
/// recorded. An in-progress shipment already staged on the device can also
/// be resumed from the list. All the actual receiving, putaway and Sync
/// happen on [SerialReceivingSessionScreen].
class SerialReceivingScreen extends StatefulWidget {
  final RwmobileService rw;
  final String facCode;
  final String compCode;

  const SerialReceivingScreen({
    super.key,
    required this.rw,
    required this.facCode,
    required this.compCode,
  });

  @override
  State<SerialReceivingScreen> createState() => _SerialReceivingScreenState();
}

class _SerialReceivingScreenState extends State<SerialReceivingScreen> {
  late final SerialReceivingService _service =
      SerialReceivingService(widget.rw);
  final ReceivingStore _store = ReceivingStore();

  List<ShipmentStaging> _inProgress = const [];
  bool _loadingList = true;
  bool _opening = false;
  String? _error;
  String _draftSerial = '';

  @override
  void initState() {
    super.initState();
    _refreshList();
  }

  Future<void> _refreshList() async {
    setState(() => _loadingList = true);
    final all = await _store.listAll();
    if (!mounted) return;
    setState(() {
      _inProgress = all;
      _loadingList = false;
    });
  }

  /// Primary entry: the operator scans a serial. Resolve it to its
  /// shipment, open (or resume) that shipment, record the scan, and move to
  /// the session screen.
  Future<void> _openFromSerial(String rawSerial) async {
    final serial = rawSerial.trim();
    if (serial.isEmpty || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });

    try {
      final resolved = await _service.resolveSerial(serial);
      if (resolved == null) {
        setState(() {
          _opening = false;
          _error = 'Serial "$serial" is not an expected serial on any open '
              'shipment.';
        });
        return;
      }

      // Resume if we already have this shipment staged, otherwise fetch.
      var staging = await _store.load(resolved.shipmentNbr);
      staging ??= await _service.openShipment(
        shipmentNbr: resolved.shipmentNbr,
        facilityCode: widget.facCode,
        companyCode: widget.compCode,
      );

      if (staging == null) {
        setState(() {
          _opening = false;
          _error = 'No expected serial numbers found for shipment '
              '"${resolved.shipmentNbr}".';
        });
        return;
      }

      // Record the serial that opened the session (harmless no-op if this
      // shipment was resumed and the serial was already scanned).
      staging.addScan(serial);
      await _store.save(staging);
      _draftSerial = '';
      await _goToSession(staging);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Could not open receiving for serial "$serial": $e';
      });
    }
  }

  /// Resume a staged shipment from the in-progress list (no serial scan).
  Future<void> _resume(String shipmentNbr) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final staging = await _store.load(shipmentNbr);
      if (staging == null) {
        setState(() {
          _opening = false;
          _error = 'Staged data for "$shipmentNbr" could not be read.';
        });
        return;
      }
      await _goToSession(staging);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Could not resume "$shipmentNbr": $e';
      });
    }
  }

  Future<void> _goToSession(ShipmentStaging staging) async {
    if (!mounted) return;
    setState(() => _opening = false);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SerialReceivingSessionScreen(
          service: _service,
          store: _store,
          staging: staging,
        ),
      ),
    );
    await _refreshList();
  }

  Future<void> _confirmDelete(ShipmentStaging s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Discard ${s.shipmentNbr}?'),
        content: Text(
          'Removes the staged receiving data for this shipment from this '
          'device. ${s.pendingSyncLpns().isNotEmpty || s.status != ShipmentStatus.synced ? 'Any unsynced scans and putaways will be lost.' : ''}',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (ok == true) {
      await _store.delete(s.shipmentNbr);
      await _refreshList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Serial Receiving')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SerialScanField(
              label: 'Serial Nbr',
              hintText: 'Scan a serial number to begin',
              autofocus: true,
              enabled: !_opening,
              clearOnSubmit: false,
              onChanged: (v) => setState(() => _draftSerial = v),
              onSubmit: _openFromSerial,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _opening || _draftSerial.isEmpty
                  ? null
                  : () => _openFromSerial(_draftSerial),
              icon: _opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.play_arrow),
              label: Text(_opening ? 'Opening…' : 'Start receiving'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('In progress on this device',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadingList ? null : _refreshList,
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: _loadingList
                  ? const Center(child: CircularProgressIndicator())
                  : _inProgress.isEmpty
                      ? const Center(
                          child: Text(
                              'No staged shipments.\nScan a serial above to '
                              'start.',
                              textAlign: TextAlign.center))
                      : ListView.separated(
                          itemCount: _inProgress.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final s = _inProgress[i];
                            return ListTile(
                              title: Text(s.shipmentNbr),
                              subtitle: Text(_summaryLine(s)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _StatusChip(status: s.status),
                                  IconButton(
                                    tooltip: 'Discard',
                                    icon: const Icon(Icons.delete_outline),
                                    onPressed: () => _confirmDelete(s),
                                  ),
                                ],
                              ),
                              onTap: _opening
                                  ? null
                                  : () => _resume(s.shipmentNbr),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  String _summaryLine(ShipmentStaging s) {
    final lpns = s.lpnNbrs;
    final scanned = s.scans.length; // total serials scanned across the shipment
    final expected = s.expectedSerials.length;
    final synced = lpns.where(s.isSynced).length;
    return '$scanned/$expected serials • $synced/${lpns.length} LPNs synced';
  }
}

class _StatusChip extends StatelessWidget {
  final ShipmentStatus status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ShipmentStatus.receiving => ('Receiving', Colors.blueGrey),
      ShipmentStatus.putawayPending => ('Putaway', Colors.orange),
      ShipmentStatus.partial => ('Partial', Colors.deepOrange),
      ShipmentStatus.synced => ('Synced', Colors.green),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Chip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        backgroundColor: color.withValues(alpha: 0.15),
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
