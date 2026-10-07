import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'receiving_store.dart' show SerialStatus, ShipmentStatus, SyncError;

export 'receiving_store.dart'
    show SerialStatus, SerialStatusLabel, ShipmentStatus;

/// On-device staging store for scenario 2.2 - "Receiving without Expected
/// Serial Numbers". Same principle as the serial store: everything is held
/// locally and nothing is posted to WMS until the operator presses Sync on
/// a line.
///
/// Unit of work is a **line** (one `ib_shipment_dtl` row = one LPN). The
/// operator types a Received Qty per line; pressing Receive with a qty
/// below the line group's remaining spawns a continuation line (blank,
/// editable LPN) for the rest, so a shipment line can be split across
/// several LPNs. Excess against Item + Batch is blocked (2.3).

int qtyInt(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.round();
  final s = (v ?? '').toString().trim();
  if (s.isEmpty) return fallback;
  return double.tryParse(s)?.round() ?? int.tryParse(s) ?? fallback;
}

/// One receipt line. Original lines come straight from `ib_shipment_dtl`;
/// continuation lines are spawned locally when a line is received short of
/// its group's remaining quantity.
class NonSerialLine {
  final String id;
  final String groupId; // the original dtl line this belongs to
  final String shipmentNbr;
  final String item;
  final String batchNbr;
  final String attrA;
  final int shippedQty; // group total (same on every line of a group)
  final int wmsReceivedQty; // already received in WMS (original line only)

  String lpnNbr; // from API, or operator-scanned on a continuation line
  final String lockCode; // lpn_lock_code - display only for now
  int receivedQty; // operator-entered; 0 until received
  bool received;
  bool isShort;
  String? putawayLocation;
  DateTime? putawayConfirmedAt;
  bool wmsReceivedOk;
  bool wmsLocatedOk;
  SyncError? lastError;

  NonSerialLine({
    required this.id,
    required this.groupId,
    required this.shipmentNbr,
    required this.item,
    required this.batchNbr,
    required this.attrA,
    required this.shippedQty,
    this.wmsReceivedQty = 0,
    this.lpnNbr = '',
    this.lockCode = '',
    this.receivedQty = 0,
    this.received = false,
    this.isShort = false,
    this.putawayLocation,
    this.putawayConfirmedAt,
    this.wmsReceivedOk = false,
    this.wmsLocatedOk = false,
    this.lastError,
  });

  bool get isOriginal => id == groupId;

  factory NonSerialLine.fromApiRow(Map<String, dynamic> r,
      {required int index}) {
    final id = (r['id'] ?? 'L$index').toString();
    return NonSerialLine(
      id: id,
      groupId: id,
      shipmentNbr: (r['ib_shipment_id__shipment_nbr'] ?? '').toString(),
      item: (r['item_id__part_a'] ?? '').toString(),
      batchNbr: (r['batch_nbr'] ?? '').toString(),
      attrA: (r['invn_attr_id__invn_attr_a'] ?? '').toString(),
      shippedQty: qtyInt(r['shipped_qty']),
      wmsReceivedQty: qtyInt(r['received_qty']),
      lpnNbr: (r['container_nbr'] ?? '').toString(),
      lockCode: (r['lpn_lock_code'] ?? '').toString(),
    );
  }

  factory NonSerialLine.fromJson(Map<String, dynamic> j) => NonSerialLine(
        id: (j['id'] ?? '').toString(),
        groupId: (j['group_id'] ?? j['id'] ?? '').toString(),
        shipmentNbr: (j['shipment_nbr'] ?? '').toString(),
        item: (j['item'] ?? '').toString(),
        batchNbr: (j['batch_nbr'] ?? '').toString(),
        attrA: (j['attr_a'] ?? '').toString(),
        shippedQty: qtyInt(j['shipped_qty']),
        wmsReceivedQty: qtyInt(j['wms_received_qty']),
        lpnNbr: (j['lpn_nbr'] ?? '').toString(),
        lockCode: (j['lock_code'] ?? '').toString(),
        receivedQty: qtyInt(j['received_qty']),
        received: j['received'] == true,
        isShort: j['is_short'] == true,
        putawayLocation:
            (j['putaway_location'] as String?)?.trim().isEmpty ?? true
                ? null
                : (j['putaway_location'] as String),
        putawayConfirmedAt:
            DateTime.tryParse((j['putaway_confirmed_at'] ?? '').toString()),
        wmsReceivedOk: j['wms_received_ok'] == true,
        wmsLocatedOk: j['wms_located_ok'] == true,
        lastError: j['last_error'] is Map<String, dynamic>
            ? SyncError.fromJson(j['last_error'] as Map<String, dynamic>)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'group_id': groupId,
        'shipment_nbr': shipmentNbr,
        'item': item,
        'batch_nbr': batchNbr,
        'attr_a': attrA,
        'shipped_qty': shippedQty,
        'wms_received_qty': wmsReceivedQty,
        'lpn_nbr': lpnNbr,
        'lock_code': lockCode,
        'received_qty': receivedQty,
        'received': received,
        'is_short': isShort,
        'putaway_location': putawayLocation,
        'putaway_confirmed_at': putawayConfirmedAt?.toIso8601String(),
        'wms_received_ok': wmsReceivedOk,
        'wms_located_ok': wmsLocatedOk,
        'last_error': lastError?.toJson(),
      };
}

enum NsActionResultKind { ok, badQty, excess, noLpn, dupLpn, notEditable }

class NsActionResult {
  final NsActionResultKind kind;
  final String message;
  const NsActionResult(this.kind, [this.message = '']);
  bool get ok => kind == NsActionResultKind.ok;
  static const okResult = NsActionResult(NsActionResultKind.ok);
}

class NonSerialStaging {
  final String shipmentNbr;
  final String facilityCode;
  final String companyCode;
  final DateTime openedAt;
  final List<NonSerialLine> lines;

  NonSerialStaging({
    required this.shipmentNbr,
    required this.facilityCode,
    required this.companyCode,
    required this.openedAt,
    required this.lines,
  });

  factory NonSerialStaging.fromApi({
    required String shipmentNbr,
    required String facilityCode,
    required String companyCode,
    required List<Map<String, dynamic>> dtlRows,
  }) {
    final lines = <NonSerialLine>[];
    for (var i = 0; i < dtlRows.length; i++) {
      lines.add(NonSerialLine.fromApiRow(dtlRows[i], index: i));
    }
    return NonSerialStaging(
      shipmentNbr: shipmentNbr,
      facilityCode: facilityCode,
      companyCode: companyCode,
      openedAt: DateTime.now(),
      lines: lines,
    );
  }

  factory NonSerialStaging.fromJson(Map<String, dynamic> j) => NonSerialStaging(
        shipmentNbr: (j['shipment_nbr'] ?? '').toString(),
        facilityCode: (j['facility_code'] ?? '').toString(),
        companyCode: (j['company_code'] ?? '').toString(),
        openedAt: DateTime.tryParse((j['opened_at'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        lines: (j['lines'] as List? ?? [])
            .map((e) => NonSerialLine.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'shipment_nbr': shipmentNbr,
        'facility_code': facilityCode,
        'company_code': companyCode,
        'opened_at': openedAt.toIso8601String(),
        'status': status.name,
        'lines': lines.map((e) => e.toJson()).toList(),
      };

  // ---- lookups ----

  NonSerialLine? lineById(String id) {
    for (final l in lines) {
      if (l.id == id) return l;
    }
    return null;
  }

  List<NonSerialLine> groupLines(String groupId) =>
      lines.where((l) => l.groupId == groupId).toList();

  int groupShippedQty(String groupId) {
    final g = groupLines(groupId);
    return g.isEmpty ? 0 : g.first.shippedQty;
  }

  int groupWmsReceivedQty(String groupId) {
    for (final l in lines) {
      if (l.id == groupId) return l.wmsReceivedQty;
    }
    return 0;
  }

  /// Qty received in the app across the whole group so far.
  int groupReceivedQty(String groupId) => groupLines(groupId)
      .where((l) => l.received)
      .fold(0, (sum, l) => sum + l.receivedQty);

  /// What is still open on this group = shipped - already-in-WMS - received
  /// here. Zero once the group has been declared short (the rest is written
  /// off). Never negative.
  int groupRemaining(String groupId) {
    if (groupIsShort(groupId)) return 0;
    final r = groupShippedQty(groupId) -
        groupWmsReceivedQty(groupId) -
        groupReceivedQty(groupId);
    return r < 0 ? 0 : r;
  }

  bool groupIsShort(String groupId) =>
      groupLines(groupId).any((l) => l.isShort);

  bool isSynced(String id) {
    final l = lineById(id);
    return l != null && l.wmsReceivedOk && l.wmsLocatedOk;
  }

  bool isPutawayDone(String id) =>
      (lineById(id)?.putawayLocation ?? '').isNotEmpty;

  bool lpnInUse(String lpn, {String? exceptId}) {
    final v = lpn.trim();
    if (v.isEmpty) return false;
    return lines.any((l) => l.id != exceptId && l.lpnNbr.trim() == v);
  }

  SerialStatus lineStatus(String id) {
    final l = lineById(id);
    if (l == null) return SerialStatus.notReceived;
    if (isSynced(id)) return SerialStatus.syncedToWms;
    if (isPutawayDone(id)) return SerialStatus.putaway;
    if (l.received) return SerialStatus.received;
    return SerialStatus.notReceived;
  }

  // ---- gates ----

  bool canEditLpn(String id) {
    final l = lineById(id);
    return l != null && !l.received && !isSynced(id);
  }

  NsActionResult canReceiveLine(String id, int q) {
    final l = lineById(id);
    if (l == null) return const NsActionResult(NsActionResultKind.notEditable);
    if (l.received || isPutawayDone(id) || isSynced(id)) {
      return const NsActionResult(
          NsActionResultKind.notEditable, 'Line already received.');
    }
    if (l.lpnNbr.trim().isEmpty) {
      return const NsActionResult(
          NsActionResultKind.noLpn, 'Scan an LPN for this line first.');
    }
    if (q <= 0) {
      return const NsActionResult(
          NsActionResultKind.badQty, 'Enter a quantity greater than 0.');
    }
    final remaining = groupRemaining(l.groupId);
    if (q > remaining) {
      return NsActionResult(
          NsActionResultKind.excess,
          '$q exceeds the $remaining unit(s) still expected for '
          '${l.item} / ${l.batchNbr}.');
    }
    return NsActionResult.okResult;
  }

  bool canShortLine(String id) {
    final l = lineById(id);
    return l != null &&
        !l.received &&
        !isPutawayDone(id) &&
        !isSynced(id) &&
        l.lpnNbr.trim().isNotEmpty &&
        groupRemaining(l.groupId) > 0;
  }

  bool canConfirmPutaway(String id) {
    final l = lineById(id);
    return l != null && l.received && !isPutawayDone(id) && !isSynced(id);
  }

  bool canSync(String id) => isPutawayDone(id) && !isSynced(id);

  bool canUndoReceive(String id) {
    final l = lineById(id);
    if (l == null || !l.received || isPutawayDone(id) || isSynced(id)) {
      return false;
    }
    // Blocked if a continuation line spawned from this one already has work.
    final child = _childOf(id);
    return child == null || (!child.received && child.lpnNbr.trim().isEmpty);
  }

  bool canRemoveLine(String id) {
    final l = lineById(id);
    return l != null &&
        !l.isOriginal &&
        !l.received &&
        !isPutawayDone(id) &&
        !isSynced(id);
  }

  NonSerialLine? _childOf(String parentId) {
    final pIdx = lines.indexWhere((l) => l.id == parentId);
    if (pIdx < 0 || pIdx + 1 >= lines.length) return null;
    final next = lines[pIdx + 1];
    return next.groupId == lines[pIdx].groupId && !next.isOriginal
        ? next
        : null;
  }

  // ---- mutations ----

  NsActionResult setLpn(String id, String lpn) {
    final l = lineById(id);
    if (l == null || !canEditLpn(id)) {
      return const NsActionResult(NsActionResultKind.notEditable);
    }
    final v = lpn.trim();
    if (v.isNotEmpty && lpnInUse(v, exceptId: id)) {
      return NsActionResult(
          NsActionResultKind.dupLpn, 'LPN $v is already on another line.');
    }
    l.lpnNbr = v;
    return NsActionResult.okResult;
  }

  /// Receive [q] units against the line. If the group still has remaining
  /// after this, a fresh continuation line is inserted right below.
  NsActionResult receiveLine(String id, int q) {
    final check = canReceiveLine(id, q);
    if (!check.ok) return check;
    final l = lineById(id)!;
    final remainingBefore = groupRemaining(l.groupId);
    l.receivedQty = q;
    l.received = true;
    l.lastError = null;
    if (q < remainingBefore) {
      _spawnContinuation(l);
    }
    return NsActionResult.okResult;
  }

  /// Accept [q] as received and write the rest of the group off as short.
  /// No continuation line.
  NsActionResult shortLine(String id, int q) {
    final l = lineById(id);
    if (l == null || !canShortLine(id)) {
      return const NsActionResult(NsActionResultKind.notEditable);
    }
    if (q < 0) {
      return const NsActionResult(NsActionResultKind.badQty);
    }
    if (q > groupRemaining(l.groupId)) {
      return const NsActionResult(NsActionResultKind.excess,
          'Short quantity exceeds what is expected.');
    }
    l.receivedQty = q;
    l.received = true;
    l.isShort = true;
    l.lastError = null;
    return NsActionResult.okResult;
  }

  void _spawnContinuation(NonSerialLine parent) {
    final siblings = lines.where((l) => l.groupId == parent.groupId).length;
    final child = NonSerialLine(
      id: '${parent.groupId}-s$siblings',
      groupId: parent.groupId,
      shipmentNbr: parent.shipmentNbr,
      item: parent.item,
      batchNbr: parent.batchNbr,
      attrA: parent.attrA,
      shippedQty: parent.shippedQty,
      lockCode: parent.lockCode,
    );
    final idx = lines.indexOf(parent);
    lines.insert(idx + 1, child);
  }

  bool undoReceiveLine(String id) {
    if (!canUndoReceive(id)) return false;
    final l = lineById(id)!;
    l.received = false;
    l.isShort = false;
    l.receivedQty = 0;
    // Drop the empty continuation line, if one was spawned.
    final child = _childOf(id);
    if (child != null) lines.remove(child);
    return true;
  }

  bool removeLine(String id) {
    if (!canRemoveLine(id)) return false;
    lines.removeWhere((l) => l.id == id);
    return true;
  }

  bool confirmPutaway(String id, String location) {
    final loc = location.trim();
    if (loc.isEmpty || !canConfirmPutaway(id)) return false;
    final l = lineById(id)!;
    l.putawayLocation = loc;
    l.putawayConfirmedAt = DateTime.now();
    return true;
  }

  bool clearPutaway(String id) {
    final l = lineById(id);
    if (l == null || isSynced(id)) return false;
    l.putawayLocation = null;
    l.putawayConfirmedAt = null;
    return true;
  }

  void markReceived(String id) {
    final l = lineById(id);
    if (l == null) return;
    l.wmsReceivedOk = true;
    l.lastError = null;
  }

  void markLocated(String id) {
    final l = lineById(id);
    if (l == null) return;
    l.wmsLocatedOk = true;
    l.lastError = null;
  }

  void setSyncError(String id, String call, String code, String message) {
    final l = lineById(id);
    if (l == null) return;
    l.lastError =
        SyncError(call: call, code: code, message: message, at: DateTime.now());
  }

  // ---- WMS request bodies ----

  Map<String, dynamic> receiveRequestBody(String id) {
    final l = lineById(id)!;
    return {
      'facility_id_code': facilityCode,
      'company_id_code': companyCode,
      'shipment_nbr': shipmentNbr,
      'container_nbr': l.lpnNbr,
      'item_list': [
        {
          'item_barcode': l.item,
          'qty': l.receivedQty.toString(),
          'batch_nbr': l.batchNbr,
          'serial_nbr_list': <String>[],
          'invn_attr_a': l.attrA,
        }
      ],
    };
  }

  Map<String, dynamic> bulkLocateRequestBody(String id) {
    final l = lineById(id)!;
    return {
      'parameters': {
        'container_nbr__in': [l.lpnNbr],
      },
      'options': {
        'location_barcode': l.putawayLocation ?? '',
        'depalletize_on_putaway_flg': false,
      },
    };
  }

  // ---- rollup ----

  ShipmentStatus get status {
    if (lines.isEmpty) return ShipmentStatus.receiving;
    final syncable = lines.where((l) => l.lpnNbr.trim().isNotEmpty).toList();
    final synced = lines.where((l) => isSynced(l.id)).length;
    if (syncable.isNotEmpty && synced == syncable.length) {
      return ShipmentStatus.synced;
    }
    if (synced > 0) return ShipmentStatus.partial;
    if (lines.any((l) => l.received)) return ShipmentStatus.putawayPending;
    return ShipmentStatus.receiving;
  }

  List<String> pendingSyncLineIds() =>
      lines.where((l) => canSync(l.id)).map((l) => l.id).toList();
}

/// File-backed persistence, one JSON document per shipment under
/// `<app documents>/nonserial_receiving_staging/`.
class NonSerialReceivingStore {
  static const folderName = 'nonserial_receiving_staging';

  Future<Directory> _folder() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$folderName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _fileNameFor(String shipmentNbr) =>
      '${shipmentNbr.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  Future<File> _fileFor(String shipmentNbr) async =>
      File('${(await _folder()).path}/${_fileNameFor(shipmentNbr)}');

  Future<NonSerialStaging?> load(String shipmentNbr) async {
    final file = await _fileFor(shipmentNbr);
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return NonSerialStaging.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(NonSerialStaging staging) async {
    final file = await _fileFor(staging.shipmentNbr);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(staging.toJson()),
      flush: true,
    );
  }

  Future<List<NonSerialStaging>> listAll() async {
    final dir = await _folder();
    if (!await dir.exists()) return [];
    final out = <NonSerialStaging>[];
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final raw = await e.readAsString();
        if (raw.trim().isEmpty) continue;
        out.add(
            NonSerialStaging.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {}
    }
    out.sort((a, b) => b.openedAt.compareTo(a.openedAt));
    return out;
  }

  Future<void> delete(String shipmentNbr) async {
    final file = await _fileFor(shipmentNbr);
    if (await file.exists()) await file.delete();
  }
}
