import '../config/app_config.dart';
import 'rwmobile_service.dart';
import 'wooden_pallet_service.dart';

/// A customer's second custom RF screen, "Execute Task Mix Area (new)" - see
/// plan quirky-shimmying-haven.md. Self-contained like WoodenPalletService
/// (fetchLoad/fetchOrders below are the identical two queries, duplicated
/// rather than shared, so this feature stays independently readable/
/// removable) but reuses WoodenPalletLoad/WoodenPalletOrder/
/// WoodenPalletAllocation directly, since their shape is identical to what
/// this screen needs too.
///
/// Unlike Wooden Pallet Task, there is no order-selection step here - the
/// operator picks directly from the real task-list buttons, filtered (not
/// replaced) by whichever trailer they scanned. So this service's job is
/// just "trailer -> every open task across every order on that load",
/// flattened into one list.
class MixAreaTaskService {
  final RwmobileService rw;
  MixAreaTaskService(this.rw);

  /// Same query as WoodenPalletService.fetchLoad.
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

  /// One order's open tasks (status 10/30) on ACTIVE locations - same
  /// shape as WoodenPalletService.fetchAllocations, only pick_locn_str
  /// differs ("A-C-T-I-V-E" here vs "E-M-P-T-I-ES" for Wooden Pallet
  /// Task) - passed exactly as given in the spec.
  Future<List<WoodenPalletAllocation>> _fetchAllocations(
      String orderNbr) async {
    final res = await rw.lgfapiGet('/entity/allocation/', {
      'order_dtl_id__order_id__order_nbr__in': orderNbr,
      'task_id__status_id__in': '10,30',
      'pick_locn_str': 'A-C-T-I-V-E',
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

  /// Trailer nbr -> every open task across every order on that trailer's
  /// load, flattened into one list (2026-08-21). Unlike Wooden Pallet
  /// Task's filterOrdersWithOpenTasks (which only needed to know whether
  /// each order had ANY open task), this needs every individual
  /// allocation row - they're the filter set AND the Qty-prefill source
  /// once a task is tapped. No order-selection step exists in this spec,
  /// so every order's tasks are pooled together rather than shown
  /// separately.
  Future<List<WoodenPalletAllocation>> fetchAllocationsForTrailer(
      String trailerNbr) async {
    final load = await fetchLoad(trailerNbr);
    if (load == null || load.externallyPlannedLoadNbr.isEmpty) return const [];
    final orders = await fetchOrders(load.externallyPlannedLoadNbr);
    if (orders.isEmpty) return const [];
    final allocationLists =
        await Future.wait(orders.map((o) => _fetchAllocations(o.orderNbr)));
    return allocationLists.expand((a) => a).toList();
  }

  /// print/label/shipping (2026-08-21) - the final action for this
  /// transaction, unlike Wooden Pallet Task's assign_and_load_oblpn. On
  /// lgfapiBase (JSON in, JSON out) rather than apiBase (form/XML), so
  /// this uses RwmobileService.lgfapiPostJson, not apiPostForm.
  /// facCode/compCode come from the live response headers, not hardcoded;
  /// label_designer_code/printer_name (see AppConfig.maEnhLabelDesignerCode/
  /// maEnhPrinterName) are the one literal default the spec itself
  /// hardcodes "for now" - baked in per build, not compiled into shared
  /// source, since they name a specific customer's own Label Designer
  /// template/printer.
  Future<Map<String, dynamic>> printShippingLabel({
    required String facCode,
    required String compCode,
    required String containerNbr,
  }) {
    return rw.lgfapiPostJson('/print/label/shipping', {
      'parameters': {
        'facility_id__code': facCode,
        'company_id__code': compCode,
        'container_nbr': containerNbr,
      },
      'options': {
        'label_designer_code': AppConfig.maEnhLabelDesignerCode,
        'printer_name': AppConfig.maEnhPrinterName,
        'label_count': 1,
      },
    });
  }
}
