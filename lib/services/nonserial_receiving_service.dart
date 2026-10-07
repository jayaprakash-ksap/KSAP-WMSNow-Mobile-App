import 'nonserial_receiving_store.dart';
import 'rwmobile_service.dart';

/// lgfapi read call for scenario 2.2. The operator supplies only the
/// Shipment Nbr; every line of the shipment comes back from
/// `ib_shipment_dtl` (Item, Batch, Attr-A, LPN, lock code, shipped/received
/// qty). Nothing is written here - the WMS writes reuse
/// `SerialReceivingService.receiveLpn` / `bulkLocateLpn` at Sync time (see
/// NonSerialSync).
class NonSerialReceivingService {
  final RwmobileService rw;
  NonSerialReceivingService(this.rw);

  static const _dtlValues = 'ib_shipment_id__shipment_nbr,container_nbr,'
      'item_id__part_a,batch_nbr,invn_attr_id__invn_attr_a,'
      'lpn_lock_code,shipped_qty,received_qty,id';

  Future<NonSerialStaging?> openShipment({
    required String shipmentNbr,
    required String facilityCode,
    required String companyCode,
  }) async {
    final rows = await _getAllPages('/entity/ib_shipment_dtl/', {
      'ib_shipment_id__shipment_nbr': shipmentNbr,
      'values_list': _dtlValues,
    });
    if (rows.isEmpty) return null;
    return NonSerialStaging.fromApi(
      shipmentNbr: shipmentNbr,
      facilityCode: facilityCode,
      companyCode: companyCode,
      dtlRows: rows,
    );
  }

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
}
