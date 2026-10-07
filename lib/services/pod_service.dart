import 'dart:math';
import 'rwmobile_service.dart';

/// One entry in the Order Nbr dropdown/search list.
class PodOrderSummary {
  final String orderNbr;
  final String custName;
  const PodOrderSummary({required this.orderNbr, required this.custName});

  @override
  String toString() => custName.isEmpty ? orderNbr : '$orderNbr — $custName';

  @override
  bool operator ==(Object other) =>
      other is PodOrderSummary && orderNbr == other.orderNbr;
  @override
  int get hashCode => orderNbr.hashCode;
}

/// One (OBLPN, item) row in the delivery checklist.
class PodOblpnLine {
  final int oblpnId;
  final String oblpnNbr;
  final String itemCode;
  final num currQty;
  const PodOblpnLine({
    required this.oblpnId,
    required this.oblpnNbr,
    required this.itemCode,
    required this.currQty,
  });
}

class PodOrderDetail {
  final String orderNbr;
  final String custName;
  final List<PodOblpnLine> lines;
  const PodOrderDetail(
      {required this.orderNbr, required this.custName, required this.lines});
}

/// Orchestrates the multi-step OCWMS lgfapi calls behind the POD screen -
/// see docs/POD Screen.pdf for the source spec. Built on RwmobileService's
/// generic lgfapiGet/lgfapiPost (2026-07-23) rather than the earlier
/// findEntity()/patchField() pair, which were shaped narrowly around the
/// single-record Truck Temp lookup and don't fit POD's list/nested-resource
/// calls.
class PodService {
  final RwmobileService rw;
  final String facCode;
  final String compCode;
  PodService(this.rw, {required this.facCode, required this.compCode});

  // Bounded concurrency for the N+1 per-container/per-OBLPN fetches below -
  // firing them one at a time would make the order LOV take as long as
  // (shipped OBLPN count) sequential round-trips.
  static const _concurrency = 8;

  Future<List<T>> _mapConcurrently<S, T>(
      List<S> items, Future<T?> Function(S) fn) async {
    if (items.isEmpty) return const [];
    final results = <T>[];
    var next = 0;
    Future<void> worker() async {
      while (next < items.length) {
        final item = items[next++];
        final r = await fn(item);
        if (r != null) results.add(r);
      }
    }

    await Future.wait(
        List.generate(min(_concurrency, items.length), (_) => worker()));
    return results;
  }

  /// Step 1-2 of the spec: every shipped OBLPN's owning order, deduped by
  /// order_nbr (many OBLPNs commonly belong to the same order).
  Future<List<PodOrderSummary>> fetchOrderLov() async {
    final containerIds = await _shippedOblpnIds();
    final summaries = await _mapConcurrently<int, PodOrderSummary>(
      containerIds,
      (id) async {
        final res = await rw.lgfapiGet('/entity/container/$id/orders/', {
          'facility_id__code': facCode,
          'company_id__code': compCode,
          'values_list': 'order_nbr,cust_name',
        });
        final results = (res['results'] as List?) ?? const [];
        if (results.isEmpty) return null;
        final first = results.first as Map<String, dynamic>;
        final orderNbr = (first['order_nbr'] ?? '').toString();
        if (orderNbr.isEmpty) return null;
        return PodOrderSummary(
            orderNbr: orderNbr,
            custName: (first['cust_name'] ?? '').toString());
      },
    );
    final byOrderNbr = <String, PodOrderSummary>{};
    for (final s in summaries) {
      byOrderNbr[s.orderNbr] = s;
    }
    final list = byOrderNbr.values.toList()
      ..sort((a, b) => a.orderNbr.compareTo(b.orderNbr));
    return list;
  }

  Future<List<int>> _shippedOblpnIds() async {
    final res = await rw.lgfapiGet('/entity/container/', {
      'type': 'O',
      'facility_id__code': facCode,
      'company_id__code': compCode,
      'status_id': '91',
      'values_list': 'id',
    });
    final results = (res['results'] as List?) ?? const [];
    return results
        .map((r) => (r as Map<String, dynamic>)['id'])
        .whereType<num>()
        .map((n) => n.toInt())
        .toList();
  }

  /// Step 3 of the spec: order id -> its OBLPNs -> each OBLPN's item lines.
  ///
  /// Deviates from the PDF's literal `values_list=id` on the oblpns call
  /// (3b) by also requesting `container_nbr` - the spec's own description
  /// ("get all the OBLPN Nbr [Container_nbr] and Ids") makes clear that's
  /// the intent, and the screen can't display an "OBLPN Nbr" column without
  /// it. Flagging here in case the real API rejects the widened
  /// values_list - drop `container_nbr` and fall back to the bare id if so.
  Future<PodOrderDetail> fetchOrderDetail(PodOrderSummary order) async {
    final hdrRes = await rw.lgfapiGet('/entity/order_hdr/', {
      'order_nbr': order.orderNbr,
    });
    final hdrResults = (hdrRes['results'] as List?) ?? const [];
    if (hdrResults.isEmpty) {
      throw Exception('Order ${order.orderNbr} not found (order_hdr).');
    }
    final orderId = (hdrResults.first as Map<String, dynamic>)['id'];

    final oblpnRes = await rw.lgfapiGet('/entity/order_hdr/$orderId/oblpns/', {
      'company_id__code': compCode,
      'status_id': '91',
      'values_list': 'id,container_nbr',
    });
    final oblpnResults = (oblpnRes['results'] as List?) ?? const [];
    final oblpns = oblpnResults
        .map((r) => r as Map<String, dynamic>)
        .where((r) => r['id'] != null)
        .map((r) => (
              id: (r['id'] as num).toInt(),
              nbr: (r['container_nbr'] ?? r['id']).toString(),
            ))
        .toList();

    final lineLists = await _mapConcurrently(oblpns, (o) async {
      final res = await rw.lgfapiGet('/entity/inventory/', {
        'container_id': '${o.id}',
        'values_list': 'item_id__code,curr_qty,container_id',
      });
      final results = (res['results'] as List?) ?? const [];
      return results
          .map((r) => r as Map<String, dynamic>)
          .map((r) => PodOblpnLine(
                oblpnId: o.id,
                oblpnNbr: o.nbr,
                itemCode: (r['item_id__code'] ?? '').toString(),
                currQty: (r['curr_qty'] ?? 0) as num,
              ))
          .toList();
    });

    return PodOrderDetail(
      orderNbr: order.orderNbr,
      custName: order.custName,
      lines: lineLists.expand((l) => l).toList(),
    );
  }

  /// Step 6: one `mark_delivered` call per unique OBLPN id. Sequential (not
  /// concurrent like the read paths above) - a delivery confirmation is a
  /// write with real WMS-side consequences, so failures should be
  /// attributable one at a time rather than raced.
  Future<Map<int, bool>> deliver(Iterable<int> oblpnIds) async {
    final results = <int, bool>{};
    for (final id in oblpnIds) {
      results[id] = await rw.lgfapiPost('/entity/oblpn/$id/mark_delivered/');
    }
    return results;
  }
}
