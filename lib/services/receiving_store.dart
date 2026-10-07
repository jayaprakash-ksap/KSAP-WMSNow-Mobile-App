import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// On-device staging store for the serial-driven receiving POC.
///
/// The whole point of this feature is that receiving and putaway happen
/// entirely on the device - nothing is posted to WMS until the operator
/// presses Sync on a fully-received, put-away LPN. Between "open shipment"
/// and "synced" the device is the only place the receiving data exists, so
/// it is persisted as one JSON document per shipment
/// (`<app documents>/receiving_staging/<shipment_nbr>.json`) and flushed
/// after every scan, every putaway confirmation, and every individual WMS
/// call. A session timeout, network drop, or app kill therefore leaves the
/// exact per-LPN progress on disk; re-opening the shipment and pressing
/// Sync again resumes per LPN from wherever it stopped.
///
/// No database: the data is one shipment's worth of serials, so it is
/// loaded whole and summed in Dart. If cross-shipment reporting or
/// concurrent multi-operator receiving is ever needed, swap the file IO in
/// [ReceivingStore] for sqflite behind the same method signatures.

/// One expected serial for the shipment, already resolved to its shipment
/// line via the `ib_shipment_dtl_id__` chained-traversal query at
/// shipment-open. This is the catalog every serial scan is validated
/// against - a scan that is not in here is not an expected serial.
class ExpectedSerial {
  final String serialNbr;
  final String lpnNbr;
  final String item;
  final String batchNbr;
  final String attrA; // invn_attr_a, shown as "Line Nbr"

  const ExpectedSerial({
    required this.serialNbr,
    required this.lpnNbr,
    required this.item,
    required this.batchNbr,
    required this.attrA,
  });

  factory ExpectedSerial.fromJson(Map<String, dynamic> j) => ExpectedSerial(
        serialNbr: (j['serial_nbr'] ?? '').toString(),
        lpnNbr: (j['lpn_nbr'] ?? '').toString(),
        item: (j['item'] ?? '').toString(),
        batchNbr: (j['batch_nbr'] ?? '').toString(),
        attrA: (j['attr_a'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'serial_nbr': serialNbr,
        'lpn_nbr': lpnNbr,
        'item': item,
        'batch_nbr': batchNbr,
        'attr_a': attrA,
      };

  /// Build from one row of
  /// `entity/ib_shipment_serial_nbr/?...&values_list=original_serial_nbr,
  /// lpn_nbr,ib_shipment_dtl_id__item_id__part_a,
  /// ib_shipment_dtl_id__batch_nbr,
  /// ib_shipment_dtl_id__invn_attr_id__invn_attr_a`.
  factory ExpectedSerial.fromApiRow(Map<String, dynamic> r) => ExpectedSerial(
        serialNbr: (r['original_serial_nbr'] ?? '').toString(),
        lpnNbr: (r['lpn_nbr'] ?? '').toString(),
        item: (r['ib_shipment_dtl_id__item_id__part_a'] ?? '').toString(),
        batchNbr: (r['ib_shipment_dtl_id__batch_nbr'] ?? '').toString(),
        attrA: (r['ib_shipment_dtl_id__invn_attr_id__invn_attr_a'] ?? '')
            .toString(),
      );
}

/// One shipment line (`ib_shipment_dtl`), keyed in the store by [attrA].
/// Used as the secondary excess-qty guard and for the "n of m" display -
/// the expected-serial catalog is the primary control.
class LineDetail {
  final String dtlId;
  final String item;
  final String batchNbr;
  final String attrA;
  final int shippedQty;
  final int receivedQty; // already received in WMS before this session

  const LineDetail({
    required this.dtlId,
    required this.item,
    required this.batchNbr,
    required this.attrA,
    required this.shippedQty,
    required this.receivedQty,
  });

  int get remainingQty {
    final r = shippedQty - receivedQty;
    return r < 0 ? 0 : r;
  }

  factory LineDetail.fromJson(Map<String, dynamic> j) => LineDetail(
        dtlId: (j['dtl_id'] ?? '').toString(),
        item: (j['item'] ?? '').toString(),
        batchNbr: (j['batch_nbr'] ?? '').toString(),
        attrA: (j['attr_a'] ?? '').toString(),
        shippedQty: _asInt(j['shipped_qty']),
        receivedQty: _asInt(j['received_qty']),
      );

  Map<String, dynamic> toJson() => {
        'dtl_id': dtlId,
        'item': item,
        'batch_nbr': batchNbr,
        'attr_a': attrA,
        'shipped_qty': shippedQty,
        'received_qty': receivedQty,
      };

  factory LineDetail.fromApiRow(Map<String, dynamic> r) => LineDetail(
        dtlId: (r['id'] ?? '').toString(),
        item: (r['item_id__part_a'] ?? '').toString(),
        batchNbr: (r['batch_nbr'] ?? '').toString(),
        attrA: (r['invn_attr_id__invn_attr_a'] ?? '').toString(),
        shippedQty: _asInt(r['shipped_qty']),
        receivedQty: _asInt(r['received_qty']),
      );
}

/// One serial the operator has scanned this session. The line attributes
/// are copied from the matched [ExpectedSerial] at scan time so putaway and
/// sync never need to re-join.
///
/// [received] is the per-serial receive step: a scan lands here as "Not
/// Received"; pressing Receive on its row flips [received] true. Only
/// received serials go into the `iblpn/receive` request.
class ScannedSerial {
  final String serialNbr;
  final String lpnNbr;
  final String item;
  final String batchNbr;
  final String attrA;
  final int qty; // always 1 for a scanned serial
  final DateTime scannedAt;
  bool received;

  ScannedSerial({
    required this.serialNbr,
    required this.lpnNbr,
    required this.item,
    required this.batchNbr,
    required this.attrA,
    this.qty = 1,
    required this.scannedAt,
    this.received = false,
  });

  factory ScannedSerial.fromJson(Map<String, dynamic> j) => ScannedSerial(
        serialNbr: (j['serial_nbr'] ?? '').toString(),
        lpnNbr: (j['lpn_nbr'] ?? '').toString(),
        item: (j['item'] ?? '').toString(),
        batchNbr: (j['batch_nbr'] ?? '').toString(),
        attrA: (j['attr_a'] ?? '').toString(),
        qty: _asInt(j['qty'], fallback: 1),
        scannedAt: DateTime.tryParse((j['scanned_at'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        received: j['received'] == true,
      );

  Map<String, dynamic> toJson() => {
        'serial_nbr': serialNbr,
        'lpn_nbr': lpnNbr,
        'item': item,
        'batch_nbr': batchNbr,
        'attr_a': attrA,
        'qty': qty,
        'scanned_at': scannedAt.toIso8601String(),
        'received': received,
      };
}

/// The last failed WMS call for an LPN, kept so the row can show why and
/// the operator can retry.
class SyncError {
  final String call; // "receive" | "bulk_locate"
  final String code;
  final String message;
  final DateTime at;

  const SyncError({
    required this.call,
    required this.code,
    required this.message,
    required this.at,
  });

  factory SyncError.fromJson(Map<String, dynamic> j) => SyncError(
        call: (j['call'] ?? '').toString(),
        code: (j['code'] ?? '').toString(),
        message: (j['message'] ?? '').toString(),
        at: DateTime.tryParse((j['at'] ?? '').toString()) ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );

  Map<String, dynamic> toJson() => {
        'call': call,
        'code': code,
        'message': message,
        'at': at.toIso8601String(),
      };
}

/// Mutable per-LPN state. The received count and the "all qty accounted
/// for" check are derived from the scans, so only the operator's declared
/// short quantity and the putaway/WMS outcomes are persisted here.
class LpnState {
  /// Units the operator has declared short for this LPN (0 = none). Set by
  /// the Short button to exactly close the remaining gap at that moment:
  /// `shortQty = shippedQty - receivedCount`.
  int shortQty;
  String? putawayLocation;
  DateTime? putawayConfirmedAt;
  bool wmsReceivedOk;
  bool wmsLocatedOk;
  SyncError? lastError;

  LpnState({
    this.shortQty = 0,
    this.putawayLocation,
    this.putawayConfirmedAt,
    this.wmsReceivedOk = false,
    this.wmsLocatedOk = false,
    this.lastError,
  });

  factory LpnState.fromJson(Map<String, dynamic> j) => LpnState(
        shortQty: _asInt(j['short_qty']),
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
        'short_qty': shortQty,
        'putaway_location': putawayLocation,
        'putaway_confirmed_at': putawayConfirmedAt?.toIso8601String(),
        'wms_received_ok': wmsReceivedOk,
        'wms_located_ok': wmsLocatedOk,
        'last_error': lastError?.toJson(),
      };
}

/// Overall lifecycle of one staged shipment.
enum ShipmentStatus { receiving, putawayPending, partial, synced }

/// Per-LPN status shown in the receiving/putaway list.
enum LpnStatus {
  receiving, // not every unit received / accounted for yet
  readyForPutaway, // qty complete (received + short == shipped), no location
  readyForSync, // putaway location confirmed, not yet synced to WMS
  syncing,
  synced, // receive + bulk_locate both confirmed by WMS
  error, // a WMS call failed - retry available
}

/// Status of one scanned serial row in the table.
enum SerialStatus {
  notReceived, // scanned, Receive not pressed
  received, // Receive pressed on this row
  putaway, // its LPN's putaway location is confirmed
  syncedToWms, // its LPN is synced to WMS
}

extension SerialStatusLabel on SerialStatus {
  String get label => switch (this) {
        SerialStatus.notReceived => 'Not Received',
        SerialStatus.received => 'Received',
        SerialStatus.putaway => 'Putaway',
        SerialStatus.syncedToWms => 'Synced to WMS',
      };
}

/// Outcome of [ShipmentStaging.addScan].
enum ScanResultKind { added, unknownSerial, duplicate, alreadySynced }

class ScanResult {
  final ScanResultKind kind;
  final String message;
  final ScannedSerial? scan;
  const ScanResult(this.kind, this.message, [this.scan]);
  bool get ok => kind == ScanResultKind.added;
}

/// One item+batch+attrA group within an LPN, ready to drop into the
/// `iblpn/receive` request's `item_list`.
class ReceiveItemGroup {
  final String item;
  final String batchNbr;
  final String attrA;
  final List<String> serialNbrs;
  const ReceiveItemGroup({
    required this.item,
    required this.batchNbr,
    required this.attrA,
    required this.serialNbrs,
  });

  Map<String, dynamic> toItemListEntry() => {
        'item_barcode': item,
        'qty': serialNbrs.length.toString(),
        'batch_nbr': batchNbr,
        'serial_nbr_list': serialNbrs,
        'invn_attr_a': attrA,
      };
}

/// The staged state for one shipment - the in-memory form of
/// `receiving_staging/<shipment_nbr>.json`.
class ShipmentStaging {
  final String shipmentNbr;
  final String facilityCode;
  final String companyCode;
  final DateTime openedAt;

  final List<ExpectedSerial> expectedSerials;
  final Map<String, LineDetail> lines; // keyed by attrA
  final List<ScannedSerial> scans;
  final Map<String, LpnState> lpns; // keyed by lpn_nbr

  ShipmentStaging({
    required this.shipmentNbr,
    required this.facilityCode,
    required this.companyCode,
    required this.openedAt,
    required this.expectedSerials,
    required this.lines,
    required this.scans,
    required this.lpns,
  });

  /// Build a fresh staging record from the two shipment-open API results.
  /// [serialRows] are `results` from the expected-serial catalog query;
  /// [dtlRows] are `results` from the `ib_shipment_dtl` query.
  factory ShipmentStaging.fromApi({
    required String shipmentNbr,
    required String facilityCode,
    required String companyCode,
    required List<Map<String, dynamic>> serialRows,
    required List<Map<String, dynamic>> dtlRows,
  }) {
    final expected = serialRows
        .map(ExpectedSerial.fromApiRow)
        .where((e) => e.serialNbr.isNotEmpty)
        .toList();

    final lines = <String, LineDetail>{};
    for (final row in dtlRows) {
      final line = LineDetail.fromApiRow(row);
      if (line.attrA.isNotEmpty) lines[line.attrA] = line;
    }

    final lpns = <String, LpnState>{};
    for (final e in expected) {
      if (e.lpnNbr.isNotEmpty) lpns.putIfAbsent(e.lpnNbr, () => LpnState());
    }

    return ShipmentStaging(
      shipmentNbr: shipmentNbr,
      facilityCode: facilityCode,
      companyCode: companyCode,
      openedAt: DateTime.now(),
      expectedSerials: expected,
      lines: lines,
      scans: [],
      lpns: lpns,
    );
  }

  factory ShipmentStaging.fromJson(Map<String, dynamic> j) {
    final lines = <String, LineDetail>{};
    (j['lines'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      lines[k] = LineDetail.fromJson(v as Map<String, dynamic>);
    });
    final lpns = <String, LpnState>{};
    (j['lpns'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
      lpns[k] = LpnState.fromJson(v as Map<String, dynamic>);
    });
    return ShipmentStaging(
      shipmentNbr: (j['shipment_nbr'] ?? '').toString(),
      facilityCode: (j['facility_code'] ?? '').toString(),
      companyCode: (j['company_code'] ?? '').toString(),
      openedAt: DateTime.tryParse((j['opened_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      expectedSerials: (j['expected_serials'] as List? ?? [])
          .map((e) => ExpectedSerial.fromJson(e as Map<String, dynamic>))
          .toList(),
      lines: lines,
      scans: (j['scans'] as List? ?? [])
          .map((e) => ScannedSerial.fromJson(e as Map<String, dynamic>))
          .toList(),
      lpns: lpns,
    );
  }

  Map<String, dynamic> toJson() => {
        'shipment_nbr': shipmentNbr,
        'facility_code': facilityCode,
        'company_code': companyCode,
        'opened_at': openedAt.toIso8601String(),
        'status': status.name,
        'expected_serials': expectedSerials.map((e) => e.toJson()).toList(),
        'lines': lines.map((k, v) => MapEntry(k, v.toJson())),
        'scans': scans.map((e) => e.toJson()).toList(),
        'lpns': lpns.map((k, v) => MapEntry(k, v.toJson())),
      };

  // ---- derived views ----

  /// LPNs in a stable, catalog order (first-seen in the expected-serial
  /// list), not hash order.
  List<String> get lpnNbrs {
    final seen = <String>[];
    for (final e in expectedSerials) {
      if (e.lpnNbr.isNotEmpty && !seen.contains(e.lpnNbr)) seen.add(e.lpnNbr);
    }
    return seen;
  }

  /// Expected units for an LPN = sum of `shipped_qty` across its distinct
  /// lines (attr_a). Falls back to the count of expected serials for the
  /// LPN when line detail is missing.
  int shippedQtyForLpn(String lpn) {
    final attrs = <String>{
      for (final e in expectedSerials.where((e) => e.lpnNbr == lpn)) e.attrA
    };
    if (attrs.isNotEmpty && attrs.every((a) => lines.containsKey(a))) {
      return attrs.fold(0, (sum, a) => sum + lines[a]!.shippedQty);
    }
    return expectedSerials.where((e) => e.lpnNbr == lpn).length;
  }

  int expectedCountForLpn(String lpn) =>
      expectedSerials.where((e) => e.lpnNbr == lpn).length;

  /// Serials scanned for the LPN (received or not).
  int scannedCountForLpn(String lpn) =>
      scans.where((s) => s.lpnNbr == lpn).length;

  /// Serials the operator has pressed Receive on for the LPN.
  int receivedCountForLpn(String lpn) =>
      scans.where((s) => s.lpnNbr == lpn && s.received).length;

  int shortQtyForLpn(String lpn) => lpns[lpn]?.shortQty ?? 0;

  List<ExpectedSerial> expectedForLpn(String lpn) =>
      expectedSerials.where((e) => e.lpnNbr == lpn).toList();

  List<ScannedSerial> scansForLpn(String lpn) =>
      scans.where((s) => s.lpnNbr == lpn).toList();

  ScannedSerial? scanFor(String serialNbr) {
    for (final s in scans) {
      if (s.serialNbr == serialNbr) return s;
    }
    return null;
  }

  bool hasScan(String serialNbr) => scanFor(serialNbr) != null;

  /// The core gate: every shipped unit for the LPN is accounted for, as
  /// received or as declared short. `shipped_qty - received_qty - short_qty
  /// == 0`. Re-checked after every Receive and after Short.
  bool isLpnQtyComplete(String lpn) {
    final shipped = shippedQtyForLpn(lpn);
    if (shipped <= 0) return false;
    return shipped - receivedCountForLpn(lpn) - shortQtyForLpn(lpn) == 0;
  }

  bool isShortReceipt(String lpn) => shortQtyForLpn(lpn) > 0;

  bool isPutawayDone(String lpn) =>
      (lpns[lpn]?.putawayLocation ?? '').isNotEmpty;

  bool isSynced(String lpn) {
    final s = lpns[lpn];
    return s != null && s.wmsReceivedOk && s.wmsLocatedOk;
  }

  // ---- per-row / per-LPN button gates ----

  /// Receive: enabled while a scanned serial is still "Not Received" and
  /// its LPN hasn't moved on to putaway/sync.
  bool canReceiveSerial(String serialNbr) {
    final s = scanFor(serialNbr);
    if (s == null || s.received) return false;
    return !isPutawayDone(s.lpnNbr) && !isSynced(s.lpnNbr);
  }

  /// Undo Receive: enabled while received, LPN not put away/synced, and no
  /// short declared against it.
  bool canUndoReceive(String serialNbr) {
    final s = scanFor(serialNbr);
    if (s == null || !s.received) return false;
    return !isPutawayDone(s.lpnNbr) &&
        !isSynced(s.lpnNbr) &&
        shortQtyForLpn(s.lpnNbr) == 0;
  }

  /// Remove Serial: allowed while the LPN is still editable (not put away /
  /// synced), and not a received serial locked in by a declared short.
  bool canRemoveScan(String serialNbr) {
    final s = scanFor(serialNbr);
    if (s == null) return false;
    if (isPutawayDone(s.lpnNbr) || isSynced(s.lpnNbr)) return false;
    return !(s.received && shortQtyForLpn(s.lpnNbr) > 0);
  }

  /// Short: offered while the LPN still has an open gap (some received,
  /// fewer than shipped), no short declared yet, and putaway not locked in.
  bool canMarkShort(String lpn) {
    final received = receivedCountForLpn(lpn);
    final shipped = shippedQtyForLpn(lpn);
    return received >= 1 &&
        received < shipped &&
        shortQtyForLpn(lpn) == 0 &&
        !isPutawayDone(lpn) &&
        !isSynced(lpn);
  }

  /// Putaway: enabled once status = Received for the LPN and every unit is
  /// accounted for (received + short == shipped).
  bool canConfirmPutaway(String lpn) =>
      isLpnQtyComplete(lpn) && !isPutawayDone(lpn) && !isSynced(lpn);

  /// Sync: enabled once status = Putaway (location confirmed) and not yet
  /// synced.
  bool canSync(String lpn) => isPutawayDone(lpn) && !isSynced(lpn);

  /// Status of one scanned serial row.
  SerialStatus serialStatus(String serialNbr) {
    final s = scanFor(serialNbr);
    if (s == null) return SerialStatus.notReceived;
    if (isSynced(s.lpnNbr)) return SerialStatus.syncedToWms;
    if (isPutawayDone(s.lpnNbr)) return SerialStatus.putaway;
    if (s.received) return SerialStatus.received;
    return SerialStatus.notReceived;
  }

  LpnStatus lpnStatus(String lpn) {
    if (isSynced(lpn)) return LpnStatus.synced;
    if ((lpns[lpn]?.lastError) != null) return LpnStatus.error;
    if (isPutawayDone(lpn)) return LpnStatus.readyForSync;
    if (isLpnQtyComplete(lpn)) return LpnStatus.readyForPutaway;
    return LpnStatus.receiving;
  }

  /// "WMS Status" column: Sync once both WMS calls have landed, else Non
  /// Sync.
  String wmsStatusLabel(String lpn) => isSynced(lpn) ? 'Sync' : 'Non Sync';

  ShipmentStatus get status {
    final all = lpnNbrs;
    if (all.isEmpty) return ShipmentStatus.receiving;
    final syncedCount = all.where(isSynced).length;
    if (syncedCount == all.length) return ShipmentStatus.synced;
    if (syncedCount > 0) return ShipmentStatus.partial;
    if (all.any(isLpnQtyComplete)) return ShipmentStatus.putawayPending;
    return ShipmentStatus.receiving;
  }

  /// LPNs whose Sync the operator can trigger right now.
  List<String> pendingSyncLpns() => lpnNbrs.where(canSync).toList();

  /// Group an LPN's *received* serials by item+batch+attrA for the
  /// `iblpn/receive` request body. A short LPN sends only what was actually
  /// received.
  List<ReceiveItemGroup> receiveItemGroups(String lpn) {
    final groups = <String, ReceiveItemGroup>{};
    final order = <String>[];
    for (final s in scansForLpn(lpn).where((s) => s.received)) {
      final key = '${s.item}|${s.batchNbr}|${s.attrA}';
      final existing = groups[key];
      if (existing == null) {
        groups[key] = ReceiveItemGroup(
          item: s.item,
          batchNbr: s.batchNbr,
          attrA: s.attrA,
          serialNbrs: [s.serialNbr],
        );
        order.add(key);
      } else {
        existing.serialNbrs.add(s.serialNbr);
      }
    }
    return [for (final k in order) groups[k]!];
  }

  /// Full `iblpn/receive` request body for one LPN.
  Map<String, dynamic> receiveRequestBody(String lpn) => {
        'facility_id_code': facilityCode,
        'company_id_code': companyCode,
        'shipment_nbr': shipmentNbr,
        'container_nbr': lpn,
        'item_list':
            receiveItemGroups(lpn).map((g) => g.toItemListEntry()).toList(),
      };

  /// Full `iblpn/bulk_locate/` request body for one LPN.
  Map<String, dynamic> bulkLocateRequestBody(String lpn) => {
        'parameters': {
          'container_nbr__in': [lpn],
        },
        'options': {
          'location_barcode': lpns[lpn]?.putawayLocation ?? '',
          'depalletize_on_putaway_flg': false,
        },
      };

  // ---- mutations (caller persists via ReceivingStore.save afterwards) ----

  /// Validate and record a scanned serial against the expected catalog.
  ScanResult addScan(String rawSerial) {
    final serial = rawSerial.trim();
    if (serial.isEmpty) {
      return const ScanResult(ScanResultKind.unknownSerial, 'Empty scan');
    }
    if (hasScan(serial)) {
      return ScanResult(
          ScanResultKind.duplicate, 'Serial $serial already scanned');
    }
    ExpectedSerial? match;
    for (final e in expectedSerials) {
      if (e.serialNbr == serial) {
        match = e;
        break;
      }
    }
    if (match == null) {
      return ScanResult(ScanResultKind.unknownSerial,
          'Serial $serial is not expected on shipment $shipmentNbr');
    }
    if (isSynced(match.lpnNbr)) {
      return ScanResult(ScanResultKind.alreadySynced,
          'LPN ${match.lpnNbr} is already synced to WMS');
    }
    final scan = ScannedSerial(
      serialNbr: match.serialNbr,
      lpnNbr: match.lpnNbr,
      item: match.item,
      batchNbr: match.batchNbr,
      attrA: match.attrA,
      scannedAt: DateTime.now(),
    );
    scans.add(scan);
    return ScanResult(ScanResultKind.added, 'Added ${match.serialNbr}', scan);
  }

  /// Press Receive on one scanned serial's row.
  bool receiveSerial(String serialNbr) {
    if (!canReceiveSerial(serialNbr)) return false;
    scanFor(serialNbr)!.received = true;
    return true;
  }

  /// Undo Receive on a row (operator correction), while the LPN is still
  /// editable and no short has been declared against it.
  bool unreceiveSerial(String serialNbr) {
    final s = scanFor(serialNbr);
    if (s == null || !s.received) return false;
    if (isPutawayDone(s.lpnNbr) || isSynced(s.lpnNbr)) return false;
    if (shortQtyForLpn(s.lpnNbr) > 0) return false;
    s.received = false;
    return true;
  }

  /// Remove a scanned serial entirely (operator correction) while the LPN
  /// is still editable.
  bool removeScan(String serialNbr) {
    final s = scanFor(serialNbr);
    if (s == null) return false;
    if (isPutawayDone(s.lpnNbr) || isSynced(s.lpnNbr)) return false;
    if (s.received && shortQtyForLpn(s.lpnNbr) > 0) return false;
    scans.removeWhere((x) => x.serialNbr == serialNbr);
    return true;
  }

  /// Declare the LPN short: close the remaining gap exactly, so
  /// `shipped_qty - received_qty - short_qty == 0`.
  bool markShort(String lpn) {
    if (!canMarkShort(lpn)) return false;
    final gap = shippedQtyForLpn(lpn) - receivedCountForLpn(lpn);
    if (gap <= 0) return false;
    (lpns[lpn] ??= LpnState()).shortQty = gap;
    return true;
  }

  /// Undo a declared short while the LPN is still editable.
  bool clearShort(String lpn) {
    final s = lpns[lpn];
    if (s == null || isPutawayDone(lpn) || isSynced(lpn)) return false;
    s.shortQty = 0;
    return true;
  }

  bool confirmPutaway(String lpn, String location) {
    final loc = location.trim();
    if (loc.isEmpty) return false;
    if (!canConfirmPutaway(lpn)) return false;
    final s = lpns[lpn] ??= LpnState();
    s.putawayLocation = loc;
    s.putawayConfirmedAt = DateTime.now();
    return true;
  }

  bool clearPutaway(String lpn) {
    final s = lpns[lpn];
    if (s == null || isSynced(lpn)) return false;
    s.putawayLocation = null;
    s.putawayConfirmedAt = null;
    return true;
  }

  void markReceived(String lpn) {
    final s = lpns[lpn] ??= LpnState();
    s.wmsReceivedOk = true;
    s.lastError = null;
  }

  void markLocated(String lpn) {
    final s = lpns[lpn] ??= LpnState();
    s.wmsLocatedOk = true;
    s.lastError = null;
  }

  void setSyncError(String lpn, String call, String code, String message) {
    final s = lpns[lpn] ??= LpnState();
    s.lastError = SyncError(
      call: call,
      code: code,
      message: message,
      at: DateTime.now(),
    );
  }

  void clearSyncError(String lpn) => lpns[lpn]?.lastError = null;
}

int _asInt(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString().trim() ?? '') ?? fallback;
}

/// File-backed persistence for [ShipmentStaging]. One JSON document per
/// shipment under `<app documents>/receiving_staging/`.
class ReceivingStore {
  static const folderName = 'receiving_staging';

  Future<Directory> _folder() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$folderName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// A shipment_nbr can contain characters that are illegal in a filename
  /// on some platforms (`/`, `:`), so slugify for the on-disk name while
  /// keeping the real number inside the JSON.
  String _fileNameFor(String shipmentNbr) {
    final slug = shipmentNbr.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '$slug.json';
  }

  Future<File> _fileFor(String shipmentNbr) async {
    final dir = await _folder();
    return File('${dir.path}/${_fileNameFor(shipmentNbr)}');
  }

  Future<ShipmentStaging?> load(String shipmentNbr) async {
    final file = await _fileFor(shipmentNbr);
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return ShipmentStaging.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Write the whole document. Called after every scan, putaway
  /// confirmation, and WMS call, so a crash or disconnect never loses more
  /// than the action in flight.
  Future<void> save(ShipmentStaging staging) async {
    final file = await _fileFor(staging.shipmentNbr);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(staging.toJson()),
      flush: true,
    );
  }

  /// Every staged shipment currently on the device, newest first - the
  /// "resume an in-progress shipment" list.
  Future<List<ShipmentStaging>> listAll() async {
    final dir = await _folder();
    if (!await dir.exists()) return [];
    final out = <ShipmentStaging>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        if (raw.trim().isEmpty) continue;
        out.add(
            ShipmentStaging.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {
        // Skip an unreadable/corrupt file rather than failing the list.
      }
    }
    out.sort((a, b) => b.openedAt.compareTo(a.openedAt));
    return out;
  }

  Future<void> delete(String shipmentNbr) async {
    final file = await _fileFor(shipmentNbr);
    if (await file.exists()) await file.delete();
  }
}
