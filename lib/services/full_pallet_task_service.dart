import 'rwmobile_service.dart';
import 'wooden_pallet_service.dart';

/// A customer's third custom RF screen - see
/// plan quirky-shimmying-haven.md. Reuses WoodenPalletOrder from
/// wooden_pallet_service.dart directly (identical shape, same reuse Mix
/// Area Task's service already does) - only the load lookup needs its own
/// class here, since this transaction also needs shipment_nbr for the
/// Reject-email template, which WoodenPalletLoad doesn't carry.
class FullPalletLoad {
  final String loadNbr;
  final String externallyPlannedLoadNbr;
  final String shipmentNbr;
  const FullPalletLoad({
    required this.loadNbr,
    required this.externallyPlannedLoadNbr,
    required this.shipmentNbr,
  });
}

/// One SKU/Exp Date/Location group on the Full Pallet Task SKU/Pallet/Pick
/// screen (2026-08-22) - "Pallet" is the distinct count of container_nbr
/// within this group; containerNbrs is kept (not just the count) so a
/// scanned LPN can be matched to the group it belongs to and its Pick
/// count tracked, since the LPN scan step is a separate lgfapi action call
/// (packFullLpn below), not a real RF field submission - see the service
/// doc comment on that method.
class FullPalletSkuGroup {
  final String sku;
  final String productName;
  final String expDate;
  final String location;
  final String stdQty;
  final Set<String> containerNbrs;
  FullPalletSkuGroup({
    required this.sku,
    required this.productName,
    required this.expDate,
    required this.location,
    required this.stdQty,
    required this.containerNbrs,
  });
}

class FullPalletTaskService {
  final RwmobileService rw;
  FullPalletTaskService(this.rw);

  /// Same query as WoodenPalletService.fetchLoad, extended with
  /// shipment_nbr - live-confirmed 2026-08-22 the load entity's full
  /// record (no values_list is passed, so every field comes back) already
  /// includes it, just not previously mapped into a Dart field anywhere.
  Future<FullPalletLoad?> fetchLoad(String trailerNbr) async {
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
    return FullPalletLoad(
      loadNbr: loadNbr,
      externallyPlannedLoadNbr: externallyPlannedLoadNbr,
      shipmentNbr: (first['shipment_nbr'] ?? '').toString(),
    );
  }

  /// Same query as WoodenPalletService.fetchOrders.
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

  /// Task list for the order (2026-10-08 correction) - both task types
  /// together, each tagged with its taskType so the UI can show a Type
  /// column and gate the Full Pallet Task/Mix Pallet Task buttons to only
  /// the one matching whatever's selected. The original 2026-08-22 version
  /// only ran the TFP-shaped query (A-0-0-0, LPNS uom, inventory container
  /// type I - fetchTfp's own filters), so a trailer whose only open task
  /// was a Mix Pallet (TMP) one showed "No open tasks found" even while
  /// its own TMP count was > 0 - live-confirmed 2026-10-08. TMP tasks use
  /// a materially different filter set (fetchTmp's own: just
  /// pick_locn_str A-C-T-I-V-E, no uom/container-type filters), not simply
  /// a different pick_locn_str value on the same query, so this runs as
  /// two separate queries (in parallel) rather than one combined one.
  Future<List<WoodenPalletAllocation>> fetchTasks(String orderNbr) async {
    final results = await Future.wait([
      _fetchTasksOfType(
        orderNbr,
        taskType: 'TFP',
        extraFilters: const {
          'pick_locn_str': 'A-0-0-0',
          'alloc_uom_id__uom_code': 'LPNS',
          'from_inventory_id__container_id__type': 'I',
        },
      ),
      _fetchTasksOfType(
        orderNbr,
        taskType: 'TMP',
        extraFilters: const {'pick_locn_str': 'A-C-T-I-V-E'},
      ),
    ]);
    return [...results[0], ...results[1]];
  }

  /// Shared by fetchTasks' two type-specific queries - same dedupe-to-one-
  /// row-per-task_nbr logic as the original single-query version (an
  /// allocation query can return multiple rows per task if it spans
  /// several SKUs; a task's own locn/item/qty only need to be shown once
  /// in a task-picker list).
  Future<List<WoodenPalletAllocation>> _fetchTasksOfType(
    String orderNbr, {
    required String taskType,
    required Map<String, String> extraFilters,
  }) async {
    final res = await rw.lgfapiGet('/entity/allocation/', {
      'order_dtl_id__order_id__order_nbr__in': orderNbr,
      'task_id__status_id__in': '10,30',
      'status_id__lt': '90',
      ...extraFilters,
      'values_list':
          'task_id__task_nbr,pick_locn_str,from_inventory_id__item_id__code,alloc_qty',
    });
    final results = (res['results'] as List?) ?? const [];
    final seen = <String>{};
    final tasks = <WoodenPalletAllocation>[];
    for (final r in results) {
      final row = r as Map<String, dynamic>;
      final taskNbr = (row['task_id__task_nbr'] ?? '').toString();
      if (taskNbr.isEmpty || !seen.add(taskNbr)) continue;
      tasks.add(WoodenPalletAllocation(
        taskNbr: taskNbr,
        locnStr: (row['pick_locn_str'] ?? '').toString(),
        itemCode: (row['from_inventory_id__item_id__code'] ?? '').toString(),
        allocQty: (row['alloc_qty'] ?? '').toString(),
        taskType: taskType,
      ));
    }
    return tasks;
  }

  /// TMP - "Total Mixed Pallets" - distinct count of
  /// to_inventory_id__container_id__container_nbr on mixed-area
  /// allocations for the order. Query exactly as given in the spec.
  Future<int> fetchTmp(String orderNbr) async {
    final res = await rw.lgfapiGet('/entity/allocation/', {
      'order_dtl_id__order_id__order_nbr__in': orderNbr,
      'task_id__status_id__in': '10,30',
      'pick_locn_str': 'A-C-T-I-V-E',
      'status_id__lt': '90',
      'values_list':
          'task_id__task_nbr,pick_locn_str,from_inventory_id__item_id__code,alloc_qty,to_inventory_id__container_id__container_nbr',
    });
    final results = (res['results'] as List?) ?? const [];
    final containerNbrs = results
        .map((r) =>
            (r as Map<String, dynamic>)[
                    'to_inventory_id__container_id__container_nbr']
                ?.toString() ??
            '')
        .where((c) => c.isNotEmpty)
        .toSet();
    return containerNbrs.length;
  }

  /// TFP - "Total Full Pallets" - distinct count of
  /// from_inventory_id__container_id__container_nbr on full-pallet
  /// (A-0-0-0, LPNS uom, inventory container type I) allocations for the
  /// order. Query exactly as given in the spec.
  Future<int> fetchTfp(String orderNbr) async {
    final res = await rw.lgfapiGet('/entity/allocation/', {
      'order_dtl_id__order_id__order_nbr__in': orderNbr,
      'task_id__status_id__in': '10,30',
      'pick_locn_str': 'A-0-0-0',
      'alloc_uom_id__uom_code': 'LPNS',
      'status_id__lt': '90',
      'from_inventory_id__container_id__type': 'I',
      'values_list': 'from_inventory_id__container_id__container_nbr',
    });
    final results = (res['results'] as List?) ?? const [];
    final containerNbrs = results
        .map((r) =>
            (r as Map<String, dynamic>)[
                    'from_inventory_id__container_id__container_nbr']
                ?.toString() ??
            '')
        .where((c) => c.isNotEmpty)
        .toSet();
    return containerNbrs.length;
  }

  /// SKU/Pallet/Pick table for the Full Pallet Task screen (2026-08-22) -
  /// same allocation shape as fetchTfp's query (full pallets, A-0-0-0,
  /// LPNS, inventory container type I) but with the fuller values_list the
  /// spec gives for this step (item code/description/expiry/qty/location
  /// alongside the container nbr), grouped client-side by
  /// SKU+Product Name+Exp Date+Location - "Pallet" is each group's
  /// distinct container_nbr count, tracked as a Set so a later scanned LPN
  /// can be matched back to its group (see packFullLpn's doc comment).
  /// `status_id__lt: '90'` restricts this to lines not yet fully
  /// picked/packed - see fetchCompletedSkuGroups for the complementary
  /// query.
  Future<List<FullPalletSkuGroup>> fetchSkuGroups(String orderNbr) =>
      _fetchSkuGroupsByStatus(orderNbr, statusFilterKey: 'status_id__lt');

  /// Completed counterpart to fetchSkuGroups (2026-10-07) - identical
  /// query and grouping, but status_id__gte:'90' instead of
  /// status_id__lt:'90', so a line that's already been fully picked/packed
  /// on a task that still has other open lines can be shown read-only
  /// rather than silently vanishing once fetchSkuGroups' own query stops
  /// returning it. Kept as a second, separate query (per the user's
  /// explicit choice) rather than folding into fetchSkuGroups, so that
  /// method's original, spec-given pending-only filter stays untouched.
  Future<List<FullPalletSkuGroup>> fetchCompletedSkuGroups(
          String orderNbr) =>
      _fetchSkuGroupsByStatus(orderNbr, statusFilterKey: 'status_id__gte');

  Future<List<FullPalletSkuGroup>> _fetchSkuGroupsByStatus(
    String orderNbr, {
    required String statusFilterKey,
  }) async {
    final res = await rw.lgfapiGet('/entity/allocation/', {
      'order_dtl_id__order_id__order_nbr__in': orderNbr,
      'task_id__status_id__in': '10,30',
      'pick_locn_str': 'A-0-0-0',
      'alloc_uom_id__uom_code': 'LPNS',
      statusFilterKey: '90',
      'from_inventory_id__container_id__type': 'I',
      'values_list':
          'from_inventory_id__container_id__container_nbr,from_inventory_id__item_id__code,from_inventory_id__item_id__description,from_inventory_id__expiry_date,alloc_qty,pick_locn_str',
    });
    final results = (res['results'] as List?) ?? const [];
    final groups = <String, FullPalletSkuGroup>{};
    for (final r in results) {
      final row = r as Map<String, dynamic>;
      final sku = (row['from_inventory_id__item_id__code'] ?? '').toString();
      final productName =
          (row['from_inventory_id__item_id__description'] ?? '').toString();
      final expDate = (row['from_inventory_id__expiry_date'] ?? '').toString();
      final location = (row['pick_locn_str'] ?? '').toString();
      final container =
          (row['from_inventory_id__container_id__container_nbr'] ?? '')
              .toString();
      final qty = (row['alloc_qty'] ?? '').toString();
      if (sku.isEmpty) continue;
      final key = '$sku|$productName|$expDate|$location';
      final existing = groups[key];
      if (existing == null) {
        groups[key] = FullPalletSkuGroup(
          sku: sku,
          productName: productName,
          expDate: expDate,
          location: location,
          stdQty: qty,
          containerNbrs: container.isEmpty ? {} : {container},
        );
      } else if (container.isNotEmpty) {
        existing.containerNbrs.add(container);
      }
    }
    return groups.values.toList();
  }

  /// A task's own status_id (2026-08-22) - live-confirmed an in-progress
  /// task (status 30) needs "Ctrl-P: Exec Tasks in Progress" sent BEFORE
  /// its nbr is submitted, unlike a fresh/open task (status 10), which
  /// submits directly - submitting an in-progress task's nbr directly got
  /// a real "Invalid Entry". Returns null if the task can't be found
  /// (best-effort - the caller treats that the same as "not in progress",
  /// just submits directly, matching every other lookup's failure
  /// handling in this app).
  Future<int?> fetchTaskStatusId(String taskNbr) async {
    final res = await rw.lgfapiGet('/entity/task/', {'task_nbr': taskNbr});
    final results = (res['results'] as List?) ?? const [];
    if (results.isEmpty) return null;
    final raw = (results.first as Map<String, dynamic>)['status_id'];
    if (raw is int) return raw;
    return int.tryParse(raw?.toString() ?? '');
  }

  /// LPN scan action (2026-08-22) - confirmed by the user this is a
  /// distinct lgfapi action call, NOT a real RF field submission (unlike
  /// every other "enter a value" step in this app). Same lgfapiPostJson
  /// pattern as Mix Area Task's print/label/shipping call. short_flg/
  /// async_flg are hardcoded false per the given request body.
  ///
  /// [substitute] (2026-10-06) - true when the scanned LPN isn't the one
  /// originally allocated for any SKU line on this task (the operator is
  /// physically picking a different pallet than planned). Without the
  /// extra sub_validate_*_flg fields, Oracle rejects a non-allocated LPN
  /// outright ("No such IBLPN" / VALIDATION_ERROR) - setting batch/PO/
  /// shipment to false, per the user's own example request, tells Oracle
  /// to skip cross-validating the substitute's batch/PO/shipment number
  /// against what was originally allocated. Left false (the default) for
  /// an LPN that does match an allocated container, so that case keeps
  /// today's stricter validation unchanged - a genuine data problem on an
  /// allocated pallet should still surface as an error, not be silently
  /// skipped.
  ///
  /// sub_validate_expiry_date_flg is the one exception, deliberately left
  /// true even on a substitute (2026-10-07, FEFO work) - per CCI's FEFO
  /// tolerance policy (see the FEFO user guide), a substitute pallet is
  /// only a legal pick if its production/expiry date falls inside the
  /// product group's tolerance window around what was originally
  /// allocated; bypassing this check would let the operator substitute in
  /// out-of-tolerance stock. Per the user's explicit instruction, FEFO
  /// enforcement stays Oracle's own job here (the guide itself says no
  /// client-side FEFO logic is needed) - this app's only change is to stop
  /// disabling that check, not to replicate it. NOT yet live-confirmed
  /// that pack_full_lpn's own expiry validation is actually the same FEFO
  /// tolerance-window check the guide describes (as opposed to a plain
  /// exact-match check) - needs a live test substituting an
  /// out-of-tolerance LPN to confirm Oracle rejects it here the same way
  /// it does on the real Active Area Movements screen.
  ///
  /// [oblpnNumber] (2026-10-07 correction) - the task's own, already-
  /// allocated OBLPN. Defaults to [lpn] (both fields set to the scanned
  /// value), which is correct whenever the scan matches what was actually
  /// allocated - Oracle appears to have a real OBLPN record pre-created
  /// under that same container number for the normal case. Live-confirmed
  /// this does NOT hold for a substitute: a physically different pallet
  /// that was never allocated to this task has no such OBLPN record, and
  /// sending its own number as oblpn_number got "No such IBLPN" back even
  /// though the scanned container demonstrably exists (confirmed via the
  /// IBLPNS screen, status Located, correct facility/company) - the
  /// lookup that was actually failing was oblpn_number, not iblpn_number.
  /// Callers doing a substitute must pass the real, originally-allocated
  /// container number here instead, with [lpn] carrying only the scanned
  /// (different) iblpn_number.
  Future<Map<String, dynamic>> packFullLpn({
    required String facCode,
    required String compCode,
    required String lpn,
    String? oblpnNumber,
    bool substitute = false,
  }) {
    return rw.lgfapiPostJson('/pick_pack/pack_full_lpn/', {
      'async_flg': false,
      if (substitute) ...{
        'sub_validate_batch_number_flg': false,
        'sub_validate_expiry_date_flg': true,
        'sub_validate_po_number_flg': false,
        'sub_validate_shipment_number_flg': false,
      },
      'pick_list': [
        {
          'facility_id__code': facCode,
          'company_id__code': compCode,
          'iblpn_number': lpn,
          'oblpn_number': oblpnNumber ?? lpn,
          'short_flg': false,
        }
      ],
    });
  }
}
