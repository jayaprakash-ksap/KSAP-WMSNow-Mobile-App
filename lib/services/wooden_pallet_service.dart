import 'rwmobile_service.dart';

/// Result of the trailer -> load lookup (step 1 of the "Execute Wooden
/// Pallet Tasks" spec - see docs/OWMS User Manual_2026.pdf).
class WoodenPalletLoad {
  final String loadNbr;
  final String externallyPlannedLoadNbr;
  const WoodenPalletLoad(
      {required this.loadNbr, required this.externallyPlannedLoadNbr});
}

/// One order row returned by the load -> orders lookup (step 2).
class WoodenPalletOrder {
  final String orderNbr;
  final String custName;
  final String custPhoneNbr;
  const WoodenPalletOrder(
      {required this.orderNbr,
      required this.custName,
      required this.custPhoneNbr});
}

/// One task row returned by the order -> allocations lookup (step 3).
class WoodenPalletAllocation {
  final String taskNbr;
  final String locnStr;
  final String itemCode;
  final String allocQty;
  // 'TFP' or 'TMP' (2026-10-08) - only populated by
  // FullPalletTaskService.fetchTasks, which pulls both task types into one
  // list; left '' (unused) for Wooden Pallet Task's and Mix Area Task's
  // own allocation rows, which only ever deal with one type at a time.
  final String taskType;
  const WoodenPalletAllocation(
      {required this.taskNbr,
      required this.locnStr,
      required this.itemCode,
      required this.allocQty,
      this.taskType = ''});
}

/// Result of the final assign_and_load_oblpn call (step 5, 2026-08-15) -
/// an XML response (`<root><success>...</success><response><message>...
/// </message></response></root>`), unlike every other lgfapi call in this
/// file which returns JSON.
class WoodenPalletAssignResult {
  final bool success;
  final String message;
  const WoodenPalletAssignResult(
      {required this.success, required this.message});
}

/// Two-step lgfapi lookup behind the Wooden Pallet Task injection - see
/// plan quirky-shimmying-haven.md. Built on RwmobileService's generic
/// lgfapiGet, same as PodService. Exact query params/fields are as given by
/// the customer's spec - no facility/company filters, since none were in
/// the reference URLs.
class WoodenPalletService {
  final RwmobileService rw;
  WoodenPalletService(this.rw);

  /// Step 1: trailer nbr -> the first matching load, or null if none.
  Future<WoodenPalletLoad?> fetchLoad(String trailerNbr) async {
    final res = await rw.lgfapiGet('/entity/load/', {
      'trailer_id__trailer_nbr': trailerNbr,
    });
    final results = (res['results'] as List?) ?? const [];
    if (results.isEmpty) return null;
    final first = results.first as Map<String, dynamic>;
    final loadNbr = (first['load_nbr'] ?? '').toString();
    final externallyPlannedLoadNbr =
        (first['externally_planned_load_nbr'] ?? '').toString();
    if (loadNbr.isEmpty && externallyPlannedLoadNbr.isEmpty) return null;
    return WoodenPalletLoad(
      loadNbr: loadNbr,
      externallyPlannedLoadNbr: externallyPlannedLoadNbr,
    );
  }

  /// Step 2: externally_planned_load_nbr -> every order on that load
  /// (distinct, ordered by order_nbr - a load can span multiple orders).
  Future<List<WoodenPalletOrder>> fetchOrders(
      String externallyPlannedLoadNbr) async {
    final res = await rw.lgfapiGet('/entity/order_dtl/', {
      'externally_planned_load_nbr': externallyPlannedLoadNbr,
      'values_list':
          'order_id__order_nbr,order_id__cust_name,order_id__cust_phone_nbr',
      'ordering': 'order_id__order_nbr',
      'distinct': '1',
    });
    final results = (res['results'] as List?) ?? const [];
    return results
        .map((r) => r as Map<String, dynamic>)
        .map((r) => WoodenPalletOrder(
              orderNbr: (r['order_id__order_nbr'] ?? '').toString(),
              custName: (r['order_id__cust_name'] ?? '').toString(),
              custPhoneNbr: (r['order_id__cust_phone_nbr'] ?? '').toString(),
            ))
        .where((o) => o.orderNbr.isNotEmpty)
        .toList();
  }

  /// Drops orders that no longer have any open task (2026-08-15) -
  /// live-confirmed fetchOrders above doesn't check task status at all, so
  /// an order whose only task(s) already got packed (completed) kept
  /// showing up here even though its task table would come back empty.
  /// Reuses fetchAllocations per order (the same 10/30 filter already
  /// proven for step 3) rather than guessing a relational filter on
  /// order_dtl itself - small counts expected per load, no bounded
  /// concurrency needed the way PodService's N+1 fetches use.
  Future<List<WoodenPalletOrder>> filterOrdersWithOpenTasks(
      List<WoodenPalletOrder> orders) async {
    final allocationLists =
        await Future.wait(orders.map((o) => fetchAllocations(o.orderNbr)));
    final kept = <WoodenPalletOrder>[];
    for (var i = 0; i < orders.length; i++) {
      if (allocationLists[i].isNotEmpty) kept.add(orders[i]);
    }
    return kept;
  }

  /// Step 3: order nbr -> in-progress/open tasks (status 10/30) for it,
  /// filtered to empties locations. `values_list` extended 2026-08-15 to
  /// also pull the item code and pick quantity needed by the OBLPN/SKU/Qty
  /// step - `from_inventory_id__item_id__code` and `alloc_qty` follow the
  /// same foreign-key-prefixed naming already confirmed for
  /// `task_id__task_nbr`.
  ///
  /// `pick_locn_str`'s filter value is passed exactly as given in the spec
  /// ("E-M-P-T-I-ES") - implementing exactly as specified rather than
  /// guessing this was meant to read "EMPTIES" un-hyphenated.
  Future<List<WoodenPalletAllocation>> fetchAllocations(String orderNbr) async {
    final res = await rw.lgfapiGet('/entity/allocation/', {
      'order_dtl_id__order_id__order_nbr__in': orderNbr,
      'task_id__status_id__in': '10,30',
      'pick_locn_str': 'E-M-P-T-I-ES',
      'values_list':
          'task_id__task_nbr,pick_locn_str,from_inventory_id__item_id__code,alloc_qty',
    });
    final results = (res['results'] as List?) ?? const [];
    return results
        .map((r) => r as Map<String, dynamic>)
        .map((r) => WoodenPalletAllocation(
              taskNbr: (r['task_id__task_nbr'] ?? '').toString(),
              locnStr: (r['pick_locn_str'] ?? '').toString(),
              itemCode:
                  (r['from_inventory_id__item_id__code'] ?? '').toString(),
              allocQty: (r['alloc_qty'] ?? '').toString(),
            ))
        .where((a) => a.taskNbr.isNotEmpty || a.locnStr.isNotEmpty)
        .toList();
  }

  /// Step 5: loads the OBLPN for real (2026-08-15) - the one genuinely
  /// stateful/write call in this whole feature, everything before it has
  /// been read-only lgfapi lookups. Unlike the entity/* endpoints above,
  /// this hits `wms/api/` (not `wms/lgfapi/v10/`) with a form-urlencoded
  /// body and an XML response - see RwmobileService.apiPostForm. loadNbr
  /// comes from step 1's lookup (WoodenPalletLoad.loadNbr); facCode/compCode
  /// are the same live response-header values used throughout, not
  /// hardcoded.
  Future<WoodenPalletAssignResult> assignAndLoadOblpn({
    required String oblpnNbr,
    required String facCode,
    required String compCode,
    required String loadNbr,
  }) async {
    final body = await rw.apiPostForm('/assign_and_load_oblpn/', {
      'oblpn_nbr': oblpnNbr,
      'company_code': compCode,
      'facility_code': facCode,
      'load_nbr': loadNbr,
    });
    final successMatch =
        RegExp(r'<success>(.*?)</success>', dotAll: true).firstMatch(body);
    final messageMatch =
        RegExp(r'<message>(.*?)</message>', dotAll: true).firstMatch(body);
    return WoodenPalletAssignResult(
      success: (successMatch?.group(1) ?? '').trim().toLowerCase() == 'true',
      message: (messageMatch?.group(1) ?? body).trim(),
    );
  }
}
