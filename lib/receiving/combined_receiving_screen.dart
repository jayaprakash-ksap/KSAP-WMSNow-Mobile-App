import 'package:flutter/material.dart';
import '../services/nonserial_receiving_service.dart';
import '../services/nonserial_receiving_store.dart';
import '../services/receiving_store.dart';
import '../services/rwmobile_service.dart';
import '../services/serial_receiving_service.dart';
import 'nonserial_receiving_session_screen.dart';
import 'serial_receiving_session_screen.dart';
import 'serial_scan_field.dart';

/// Combined entry point for scenario 2.1 (serial) and 2.2 (non-serial).
/// A radio at the top picks the mode; it is switchable at any time. Each
/// mode keeps its own in-progress list. The session screens themselves are
/// mode-specific (a shipment's lines are either serialised or not), but the
/// Receive → Putaway → Sync flow and the "nothing goes to WMS until Sync"
/// rule are the same for both.
///
/// This is a new menu item alongside "Serial Receiving" (2.1 only), which
/// stays until this screen is signed off.
enum _Mode { serial, nonSerial }

class CombinedReceivingScreen extends StatefulWidget {
  final RwmobileService rw;
  final String facCode;
  final String compCode;

  const CombinedReceivingScreen({
    super.key,
    required this.rw,
    required this.facCode,
    required this.compCode,
  });

  @override
  State<CombinedReceivingScreen> createState() =>
      _CombinedReceivingScreenState();
}

class _CombinedReceivingScreenState extends State<CombinedReceivingScreen> {
  late final SerialReceivingService _wmsService =
      SerialReceivingService(widget.rw);
  final ReceivingStore _serialStore = ReceivingStore();
  late final NonSerialReceivingService _nsService =
      NonSerialReceivingService(widget.rw);
  final NonSerialReceivingStore _nsStore = NonSerialReceivingStore();

  _Mode _mode = _Mode.serial;

  List<ShipmentStaging> _serialInProgress = const [];
  List<NonSerialStaging> _nsInProgress = const [];
  bool _loadingList = true;
  bool _opening = false;
  String? _error;
  String _draft = '';

  @override
  void initState() {
    super.initState();
    _refreshLists();
  }

  Future<void> _refreshLists() async {
    setState(() => _loadingList = true);
    final serial = await _serialStore.listAll();
    final ns = await _nsStore.listAll();
    if (!mounted) return;
    setState(() {
      _serialInProgress = serial;
      _nsInProgress = ns;
      _loadingList = false;
    });
  }

  void _setMode(_Mode m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
      _error = null;
      _draft = '';
    });
  }

  // ---- serial (2.1) ----

  Future<void> _openFromSerial(String rawSerial) async {
    final serial = rawSerial.trim();
    if (serial.isEmpty || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final resolved = await _wmsService.resolveSerial(serial);
      if (resolved == null) {
        setState(() {
          _opening = false;
          _error = 'Serial "$serial" is not an expected serial on any open '
              'shipment.';
        });
        return;
      }
      var staging = await _serialStore.load(resolved.shipmentNbr);
      staging ??= await _wmsService.openShipment(
        shipmentNbr: resolved.shipmentNbr,
        facilityCode: widget.facCode,
        companyCode: widget.compCode,
      );
      if (staging == null) {
        setState(() {
          _opening = false;
          _error = 'No expected serials for shipment '
              '"${resolved.shipmentNbr}".';
        });
        return;
      }
      staging.addScan(serial);
      await _serialStore.save(staging);
      await _goToSerial(staging);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Could not open receiving for serial "$serial": $e';
      });
    }
  }

  Future<void> _resumeSerial(String shipmentNbr) async {
    if (_opening) return;
    setState(() => _opening = true);
    final staging = await _serialStore.load(shipmentNbr);
    if (staging == null) {
      setState(() {
        _opening = false;
        _error = 'Staged data for "$shipmentNbr" could not be read.';
      });
      return;
    }
    await _goToSerial(staging);
  }

  Future<void> _goToSerial(ShipmentStaging staging) async {
    if (!mounted) return;
    setState(() => _opening = false);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SerialReceivingSessionScreen(
        service: _wmsService,
        store: _serialStore,
        staging: staging,
      ),
    ));
    await _refreshLists();
  }

  // ---- non-serial (2.2) ----

  Future<void> _openShipment(String rawShipment) async {
    final nbr = rawShipment.trim();
    if (nbr.isEmpty || _opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      var staging = await _nsStore.load(nbr);
      staging ??= await _nsService.openShipment(
        shipmentNbr: nbr,
        facilityCode: widget.facCode,
        companyCode: widget.compCode,
      );
      if (staging == null) {
        setState(() {
          _opening = false;
          _error = 'No shipment lines found for "$nbr".';
        });
        return;
      }
      await _nsStore.save(staging);
      await _goToNonSerial(staging);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Could not open shipment "$nbr": $e';
      });
    }
  }

  Future<void> _resumeNonSerial(String shipmentNbr) async {
    if (_opening) return;
    setState(() => _opening = true);
    final staging = await _nsStore.load(shipmentNbr);
    if (staging == null) {
      setState(() {
        _opening = false;
        _error = 'Staged data for "$shipmentNbr" could not be read.';
      });
      return;
    }
    await _goToNonSerial(staging);
  }

  Future<void> _goToNonSerial(NonSerialStaging staging) async {
    if (!mounted) return;
    setState(() => _opening = false);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => NonSerialReceivingSessionScreen(
        service: _nsService,
        wmsService: _wmsService,
        store: _nsStore,
        staging: staging,
      ),
    ));
    await _refreshLists();
  }

  // ---- shared ----

  Future<void> _confirmDelete(String shipmentNbr, bool serial) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Discard $shipmentNbr?'),
        content: const Text(
            'Removes the staged data for this shipment from this device. '
            'Any unsynced work will be lost.'),
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
    if (ok != true) return;
    if (serial) {
      await _serialStore.delete(shipmentNbr);
    } else {
      await _nsStore.delete(shipmentNbr);
    }
    await _refreshLists();
  }

  @override
  Widget build(BuildContext context) {
    final serial = _mode == _Mode.serial;
    return Scaffold(
      appBar: AppBar(title: const Text('Receiving Serial/Non Serial')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioGroup<_Mode>(
              groupValue: _mode,
              onChanged: (v) {
                if (!_opening && v != null) _setMode(v);
              },
              child: const Row(children: [
                Expanded(
                  child: RadioListTile<_Mode>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Serial Items'),
                    value: _Mode.serial,
                  ),
                ),
                Expanded(
                  child: RadioListTile<_Mode>(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Non Serial Items'),
                    value: _Mode.nonSerial,
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 4),
            SerialScanField(
              key: ValueKey(_mode),
              label: serial ? 'Serial Nbr' : 'Shipment Nbr',
              hintText: serial
                  ? 'Scan a serial number to begin'
                  : 'Scan or type the shipment number',
              autofocus: true,
              enabled: !_opening,
              clearOnSubmit: false,
              onChanged: (v) => setState(() => _draft = v),
              onSubmit: serial ? _openFromSerial : _openShipment,
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _opening || _draft.isEmpty
                  ? null
                  : () =>
                      serial ? _openFromSerial(_draft) : _openShipment(_draft),
              icon: _opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Icon(serial
                      ? Icons.play_arrow
                      : Icons.download_for_offline_outlined),
              label: Text(_opening
                  ? 'Opening…'
                  : (serial ? 'Start receiving' : 'Open shipment')),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 16),
            Row(children: [
              const Text('In progress on this device',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: _loadingList ? null : _refreshLists,
              ),
            ]),
            const Divider(height: 1),
            Expanded(
              child: _loadingList
                  ? const Center(child: CircularProgressIndicator())
                  : serial
                      ? _serialList()
                      : _nonSerialList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _serialList() {
    if (_serialInProgress.isEmpty) {
      return const Center(
          child: Text('No staged serial shipments.\nScan a serial above.',
              textAlign: TextAlign.center));
    }
    return ListView.separated(
      itemCount: _serialInProgress.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = _serialInProgress[i];
        final syncedLpns = s.lpnNbrs.where(s.isSynced).length;
        return ListTile(
          title: Text(s.shipmentNbr),
          subtitle: Text('${s.scans.length}/${s.expectedSerials.length} '
              'serials • $syncedLpns/${s.lpnNbrs.length} LPNs synced'),
          trailing: IconButton(
            tooltip: 'Discard',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(s.shipmentNbr, true),
          ),
          onTap: _opening ? null : () => _resumeSerial(s.shipmentNbr),
        );
      },
    );
  }

  Widget _nonSerialList() {
    if (_nsInProgress.isEmpty) {
      return const Center(
          child: Text('No staged non-serial shipments.\nScan a shipment above.',
              textAlign: TextAlign.center));
    }
    return ListView.separated(
      itemCount: _nsInProgress.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final s = _nsInProgress[i];
        final synced = s.lines.where((l) => s.isSynced(l.id)).length;
        final withLpn = s.lines.where((l) => l.lpnNbr.trim().isNotEmpty).length;
        return ListTile(
          title: Text(s.shipmentNbr),
          subtitle: Text('${s.lines.length} line(s) • $synced/$withLpn synced'),
          trailing: IconButton(
            tooltip: 'Discard',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmDelete(s.shipmentNbr, false),
          ),
          onTap: _opening ? null : () => _resumeNonSerial(s.shipmentNbr),
        );
      },
    );
  }
}
