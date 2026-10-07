import 'receiving_store.dart';
import 'rwmobile_service.dart';

/// lgfapi calls for the serial-driven receiving POC.
///
/// Two read calls at shipment-open (cached into [ShipmentStaging]), then
/// two write calls per LPN at Sync time - `iblpn/receive` and
/// `iblpn/bulk_locate/`. Nothing else touches the network: receiving and
/// putaway are done entirely against the cached catalog on the device.

/// How a single WMS write during Sync resolved.
enum WmsCallOutcome {
  success, // the call did what we asked
  alreadyDone, // WMS says it was already in this state (safe to treat as ok)
  error, // surfaced to the operator, retry available
}

class WmsCallResult {
  final WmsCallOutcome outcome;
  final String code;
  final String message;
  final Map<String, dynamic> raw;

  WmsCallResult(this.outcome, this.code, this.message, [this.raw = const {}]);

  bool get ok =>
      outcome == WmsCallOutcome.success ||
      outcome == WmsCallOutcome.alreadyDone;
}

class SerialReceivingService {
  final RwmobileService rw;
  SerialReceivingService(this.rw);

  // Expected-serial catalog: every row pre-resolved to its shipment line
  // via `ib_shipment_dtl_id__` chained traversal (confirmed 2026-09-08 -
  // `invn_attr_id__invn_attr_a` is not directly on ib_shipment_serial_nbr).
  static const _serialCatalogValues = 'original_serial_nbr,lpn_nbr,'
      'ib_shipment_dtl_id__item_id__part_a,'
      'ib_shipment_dtl_id__batch_nbr,'
      'ib_shipment_dtl_id__invn_attr_id__invn_attr_a';

  static const _dtlValues =
      'id,invn_attr_id__invn_attr_a,item_id__part_a,batch_nbr,'
      'shipped_qty,received_qty';

  /// Resolve which shipment an as-yet-unreceived serial belongs to. The
  /// operator scans only a serial number to begin - the shipment is never
  /// typed. Returns null when the serial is not an expected serial on any
  /// open shipment.
  Future<({String shipmentNbr, String lpnNbr})?> resolveSerial(
      String serial) async {
    final rows = await _getAllPages('/entity/ib_shipment_serial_nbr/', {
      'original_serial_nbr': serial,
      'values_list': 'ib_shipment_id__shipment_nbr,lpn_nbr',
    });
    if (rows.isEmpty) return null;
    final r = rows.first;
    final shipmentNbr = (r['ib_shipment_id__shipment_nbr'] ?? '').toString();
    if (shipmentNbr.isEmpty) return null;
    return (shipmentNbr: shipmentNbr, lpnNbr: (r['lpn_nbr'] ?? '').toString());
  }

  /// Shipment-open. Fetches the expected-serial catalog and line detail and
  /// builds a fresh staging record. Returns null when the shipment has no
  /// expected serials interfaced (nothing to receive by serial).
  Future<ShipmentStaging?> openShipment({
    required String shipmentNbr,
    required String facilityCode,
    required String companyCode,
  }) async {
    final serialRows = await _getAllPages('/entity/ib_shipment_serial_nbr/', {
      'ib_shipment_id__shipment_nbr': shipmentNbr,
      'values_list': _serialCatalogValues,
    });
    if (serialRows.isEmpty) return null;

    final dtlRows = await _getAllPages('/entity/ib_shipment_dtl/', {
      'ib_shipment_id__shipment_nbr': shipmentNbr,
      'values_list': _dtlValues,
    });

    return ShipmentStaging.fromApi(
      shipmentNbr: shipmentNbr,
      facilityCode: facilityCode,
      companyCode: companyCode,
      serialRows: serialRows,
      dtlRows: dtlRows,
    );
  }

  /// POST `entity/iblpn/receive` for one LPN.
  /// - 204 / any 2xx           -> success
  /// - 400 "LPN Already exists" -> alreadyDone (idempotency signal for a
  ///   retry after a lost response)
  /// - anything else           -> error
  Future<WmsCallResult> receiveLpn(Map<String, dynamic> body) async {
    final res = await _postJson('/entity/iblpn/receive', body);
    final status = _asInt(res['_status']);
    if (status == 0 || (status >= 200 && status < 300)) {
      return WmsCallResult(WmsCallOutcome.success, '', 'Received');
    }
    final code = (res['code'] ?? '').toString();
    final message =
        (res['message'] ?? res['_error'] ?? 'Receive failed ($status)')
            .toString();
    if (status == 400 && message.toLowerCase().contains('already exist')) {
      return WmsCallResult(WmsCallOutcome.alreadyDone, code, message, res);
    }
    return WmsCallResult(WmsCallOutcome.error, code, message, res);
  }

  /// POST `entity/iblpn/bulk_locate/` for one LPN. It always answers 200
  /// for a well-formed request, so success is `failure_count == 0 &&
  /// success_count >= 1`, not the HTTP status.
  Future<WmsCallResult> bulkLocateLpn(Map<String, dynamic> body) async {
    final res = await _postJson('/entity/iblpn/bulk_locate/', body);
    final status = _asInt(res['_status']);
    if (status != 0 && (status < 200 || status >= 300)) {
      return WmsCallResult(
        WmsCallOutcome.error,
        (res['code'] ?? '').toString(),
        (res['message'] ?? res['_error'] ?? 'Putaway failed ($status)')
            .toString(),
        res,
      );
    }
    final failure = _asInt(res['failure_count']);
    final success = _asInt(res['success_count']);
    if (failure == 0 && success >= 1) {
      return WmsCallResult(WmsCallOutcome.success, '', 'Located', res);
    }
    final detail =
        res['details']?.toString() ?? 'Putaway reported $failure failure(s)';
    return WmsCallResult(WmsCallOutcome.error, 'LOCATE_FAILED', detail, res);
  }

  /// Lost-response guard for `receive`: does the LPN already exist in WMS?
  Future<bool> lpnExists(String lpn) async {
    final res = await rw.lgfapiGet('/entity/iblpn/', {
      'container_nbr': lpn,
      'values_list': 'container_nbr',
    });
    return ((res['results'] as List?) ?? const []).isNotEmpty;
  }

  /// Lost-response guard for `bulk_locate`: is the LPN already at the
  /// location we tried to send it to?
  Future<bool> lpnIsAtLocation(String lpn, String locationBarcode) async {
    final res = await rw.lgfapiGet('/entity/iblpn/', {
      'container_nbr': lpn,
      'values_list': 'curr_location_id__barcode,status_id__code',
    });
    final results = (res['results'] as List?) ?? const [];
    if (results.isEmpty) return false;
    final row = (results.first as Map).cast<String, dynamic>();
    return (row['curr_location_id__barcode'] ?? '').toString().trim() ==
        locationBarcode.trim();
  }

  // ---- internals ----

  /// Follows lgfapi paging (`next_page`) so a shipment with more expected
  /// serials than one page still loads fully. Capped as a safety net.
  Future<List<Map<String, dynamic>>> _getAllPages(
      String path, Map<String, String> query) async {
    final out = <Map<String, dynamic>>[];
    for (var page = 1; page <= 200; page++) {
      final res = await rw.lgfapiGet(path, {...query, 'page': '$page'});
      final results = (res['results'] as List?) ?? const [];
      out.addAll(results.map((e) => (e as Map).cast<String, dynamic>()));
      if (results.isEmpty || res['next_page'] == null) break;
    }
    return out;
  }

  /// `lgfapiPostJson` plus a single 401 refresh-and-retry - the shared
  /// helper doesn't refresh the token on its own, unlike
  /// `RwmobileService._post`.
  Future<Map<String, dynamic>> _postJson(
      String path, Map<String, dynamic> body) async {
    var res = await rw.lgfapiPostJson(path, body);
    if (_asInt(res['_status']) == 401 && await rw.auth.refresh()) {
      res = await rw.lgfapiPostJson(path, body);
    }
    return res;
  }
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString().trim() ?? '') ?? fallback;
}
