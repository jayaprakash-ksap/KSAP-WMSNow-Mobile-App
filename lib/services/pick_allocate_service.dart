import 'rwmobile_service.dart';

/// lgfapi lookups for the Pick And Allocate serial-driven enhancement
/// (customer POC 2).
///
/// When the operator scans a serial into the injected field on the Pick
/// And Allocate screen:
///  1. `serial_nbr_inventory` by `serial_nbr_id__serial_nbr` -> item,
///     location (+ barcode), IBLPN (container_nbr), batch, plus the
///     inventory id and container id.
///  2. `inventory/<inventory_id>` -> `status_id`; must be 0, else the
///     serial is "not in correct status".
///  3. `inventory_lock` by `containerlockxref__container_id` -> lock code
///     (display only).
/// The result then pre-fills the standard Locn / IBLPN / Qty / Serial
/// fields on the following RF screens.

enum PaLookupKind { ok, notFound, wrongStatus, error }

class PaSerialLookup {
  final PaLookupKind kind;
  final String message;

  final String serialNbr;
  final String item;
  final String locnStr;
  final String locnBarcode;
  final String iblpn;
  final String batchNbr;
  final String lockCode;

  const PaSerialLookup({
    required this.kind,
    this.message = '',
    this.serialNbr = '',
    this.item = '',
    this.locnStr = '',
    this.locnBarcode = '',
    this.iblpn = '',
    this.batchNbr = '',
    this.lockCode = '',
  });

  bool get ok => kind == PaLookupKind.ok;

  /// Identity for one-shot pre-fill guards.
  String get key => serialNbr;

  const PaSerialLookup.notFound(String serial)
      : kind = PaLookupKind.notFound,
        message = 'Serial $serial not found in inventory.',
        serialNbr = serial,
        item = '',
        locnStr = '',
        locnBarcode = '',
        iblpn = '',
        batchNbr = '',
        lockCode = '';

  const PaSerialLookup.wrongStatus(String serial)
      : kind = PaLookupKind.wrongStatus,
        message = 'Serial number not in correct status.',
        serialNbr = serial,
        item = '',
        locnStr = '',
        locnBarcode = '',
        iblpn = '',
        batchNbr = '',
        lockCode = '';

  const PaSerialLookup.failed(String msg)
      : kind = PaLookupKind.error,
        message = msg,
        serialNbr = '',
        item = '',
        locnStr = '',
        locnBarcode = '',
        iblpn = '',
        batchNbr = '',
        lockCode = '';
}

class PickAllocateService {
  final RwmobileService rw;
  PickAllocateService(this.rw);

  static const _serialValues = 'serial_nbr_id__serial_nbr,'
      'inventory_id__item_id__part_a,'
      'inventory_id__container_id__curr_location_id__locn_str,'
      'inventory_id__container_id__curr_location_id__barcode,'
      'inventory_id__container_id__container_nbr,'
      'inventory_id__batch_number_id__batch_nbr,'
      'inventory_id__container_id,'
      'inventory_id';

  Future<PaSerialLookup> lookup(String rawSerial) async {
    final serial = rawSerial.trim();
    if (serial.isEmpty) return const PaSerialLookup.failed('Empty serial.');

    try {
      final invRes = await rw.lgfapiGet('/entity/serial_nbr_inventory/', {
        'serial_nbr_id__serial_nbr': serial,
        'values_list': _serialValues,
      });
      final rows = (invRes['results'] as List?) ?? const [];
      if (rows.isEmpty) return PaSerialLookup.notFound(serial);
      final r = (rows.first as Map).cast<String, dynamic>();

      final inventoryId = _str(r['inventory_id']);
      final containerId = _str(r['inventory_id__container_id']);

      // Status check.
      if (inventoryId.isNotEmpty) {
        final statusRes = await rw.lgfapiGet('/entity/inventory/$inventoryId');
        final rec = _firstRecord(statusRes);
        if (_asInt(rec['status_id'], fallback: -1) != 0) {
          return PaSerialLookup.wrongStatus(serial);
        }
      }

      // Lock code (display only) - absent if the container isn't locked.
      var lockCode = '';
      if (containerId.isNotEmpty) {
        final lockRes = await rw.lgfapiGet('/entity/inventory_lock/', {
          'containerlockxref__container_id': containerId,
          'values_list': 'lock_code',
        });
        final lockRows = (lockRes['results'] as List?) ?? const [];
        if (lockRows.isNotEmpty) {
          lockCode = _str((lockRows.first as Map)['lock_code']);
        }
      }

      return PaSerialLookup(
        kind: PaLookupKind.ok,
        serialNbr: _str(r['serial_nbr_id__serial_nbr'], fallback: serial),
        item: _str(r['inventory_id__item_id__part_a']),
        locnStr:
            _str(r['inventory_id__container_id__curr_location_id__locn_str']),
        locnBarcode:
            _str(r['inventory_id__container_id__curr_location_id__barcode']),
        iblpn: _str(r['inventory_id__container_id__container_nbr']),
        batchNbr: _str(r['inventory_id__batch_number_id__batch_nbr']),
        lockCode: lockCode,
      );
    } catch (e) {
      return PaSerialLookup.failed('Lookup failed: $e');
    }
  }

  static Map<String, dynamic> _firstRecord(Map<String, dynamic> data) {
    final results = data['results'];
    if (results is List && results.isNotEmpty) {
      return (results.first as Map).cast<String, dynamic>();
    }
    return data;
  }
}

String _str(Object? v, {String fallback = ''}) {
  if (v == null) return fallback;
  final s = v.toString().trim();
  return s.isEmpty ? fallback : s;
}

int _asInt(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v?.toString().trim() ?? '') ?? fallback;
}
