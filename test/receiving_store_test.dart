import 'package:flutter_test/flutter_test.dart';
import 'package:wmsnow_redwood_v3/services/receiving_store.dart';

/// Pure-logic tests for the receiving staging model - no file IO, no
/// network. Sample shipment: one item, two LPNs (3 + 2 units).
ShipmentStaging _sample() {
  final serialRows = <Map<String, dynamic>>[
    for (final s in ['S-01', 'S-02', 'S-03'])
      {
        'original_serial_nbr': s,
        'lpn_nbr': 'LPN1',
        'ib_shipment_dtl_id__item_id__part_a': 'ITEM_A',
        'ib_shipment_dtl_id__batch_nbr': 'B-1',
        'ib_shipment_dtl_id__invn_attr_id__invn_attr_a': '10',
      },
    for (final s in ['S-04', 'S-05'])
      {
        'original_serial_nbr': s,
        'lpn_nbr': 'LPN2',
        'ib_shipment_dtl_id__item_id__part_a': 'ITEM_A',
        'ib_shipment_dtl_id__batch_nbr': 'B-3',
        'ib_shipment_dtl_id__invn_attr_id__invn_attr_a': '30',
      },
  ];
  final dtlRows = <Map<String, dynamic>>[
    {
      'id': '111',
      'item_id__part_a': 'ITEM_A',
      'batch_nbr': 'B-1',
      'invn_attr_id__invn_attr_a': '10',
      'shipped_qty': 3,
      'received_qty': 0,
    },
    {
      'id': '333',
      'item_id__part_a': 'ITEM_A',
      'batch_nbr': 'B-3',
      'invn_attr_id__invn_attr_a': '30',
      'shipped_qty': 2,
      'received_qty': 0,
    },
  ];
  return ShipmentStaging.fromApi(
    shipmentNbr: 'SLC-2026090701',
    facilityCode: 'SA_WH446_RYD',
    companyCode: 'STC',
    serialRows: serialRows,
    dtlRows: dtlRows,
  );
}

void main() {
  test('catalog builds LPN list and shipped qty per LPN', () {
    final s = _sample();
    expect(s.lpnNbrs, ['LPN1', 'LPN2']);
    expect(s.shippedQtyForLpn('LPN1'), 3);
    expect(s.shippedQtyForLpn('LPN2'), 2);
  });

  test('unknown / duplicate serial rejected', () {
    final s = _sample();
    expect(s.addScan('NOPE').kind, ScanResultKind.unknownSerial);
    expect(s.addScan('S-01').ok, isTrue);
    expect(s.addScan('S-01').kind, ScanResultKind.duplicate);
    expect(s.scannedCountForLpn('LPN1'), 1);
  });

  test('scan then Receive is a two-step, per-serial status', () {
    final s = _sample();
    s.addScan('S-01');
    expect(s.serialStatus('S-01'), SerialStatus.notReceived);
    expect(s.canReceiveSerial('S-01'), isTrue);
    expect(s.receiveSerial('S-01'), isTrue);
    expect(s.serialStatus('S-01'), SerialStatus.received);
    expect(s.receivedCountForLpn('LPN1'), 1);
    // Cannot receive twice.
    expect(s.canReceiveSerial('S-01'), isFalse);
  });

  test('putaway gated until shipped - received - short == 0', () {
    final s = _sample();
    for (final x in ['S-01', 'S-02', 'S-03']) {
      s.addScan(x);
    }
    s.receiveSerial('S-01');
    s.receiveSerial('S-02');
    expect(s.isLpnQtyComplete('LPN1'), isFalse);
    expect(s.canConfirmPutaway('LPN1'), isFalse);
    expect(s.confirmPutaway('LPN1', 'A4200100'), isFalse);

    s.receiveSerial('S-03');
    expect(s.isLpnQtyComplete('LPN1'), isTrue);
    expect(s.canConfirmPutaway('LPN1'), isTrue);
    expect(s.confirmPutaway('LPN1', 'A4200100'), isTrue);
    expect(s.serialStatus('S-01'), SerialStatus.putaway);
  });

  test('Short closes the gap so putaway unlocks', () {
    final s = _sample();
    s.addScan('S-01');
    s.receiveSerial('S-01');
    expect(s.canMarkShort('LPN1'), isTrue);
    expect(s.markShort('LPN1'), isTrue);
    expect(s.shortQtyForLpn('LPN1'), 2); // 3 shipped - 1 received
    expect(s.isLpnQtyComplete('LPN1'), isTrue);
    expect(s.isShortReceipt('LPN1'), isTrue);
    expect(s.canConfirmPutaway('LPN1'), isTrue);
    // Short can't be re-declared, and once put away it's locked.
    expect(s.canMarkShort('LPN1'), isFalse);
    s.confirmPutaway('LPN1', 'A4200100');
    expect(s.clearShort('LPN1'), isFalse);
  });

  test('Short re-checks after each Receive (no premature unlock)', () {
    final s = _sample();
    for (final x in ['S-01', 'S-02', 'S-03']) {
      s.addScan(x);
    }
    s.receiveSerial('S-01');
    // gap is 2 -> not complete
    expect(s.isLpnQtyComplete('LPN1'), isFalse);
    s.receiveSerial('S-02');
    // gap is 1 -> still not complete, Short would be 1
    expect(s.isLpnQtyComplete('LPN1'), isFalse);
    expect(s.markShort('LPN1'), isTrue);
    expect(s.shortQtyForLpn('LPN1'), 1);
    expect(s.isLpnQtyComplete('LPN1'), isTrue);
  });

  test('sync gated on putaway; not on the qty check alone', () {
    final s = _sample();
    s.addScan('S-04');
    s.addScan('S-05');
    s.receiveSerial('S-04');
    s.receiveSerial('S-05');
    expect(s.canConfirmPutaway('LPN2'), isTrue);
    expect(s.canSync('LPN2'), isFalse); // no location yet
    s.confirmPutaway('LPN2', 'A4200100');
    expect(s.canSync('LPN2'), isTrue);
    expect(s.lpnStatus('LPN2'), LpnStatus.readyForSync);
  });

  test('receive body carries only received serials, grouped', () {
    final s = _sample();
    for (final x in ['S-01', 'S-02', 'S-03']) {
      s.addScan(x);
    }
    s.receiveSerial('S-01');
    s.receiveSerial('S-02');
    s.markShort('LPN1'); // S-03 never received
    final body = s.receiveRequestBody('LPN1');
    final items = body['item_list'] as List;
    expect(items, hasLength(1));
    expect(items.first, {
      'item_barcode': 'ITEM_A',
      'qty': '2',
      'batch_nbr': 'B-1',
      'serial_nbr_list': ['S-01', 'S-02'],
      'invn_attr_a': '10',
    });
  });

  test('bulk locate body carries the confirmed location', () {
    final s = _sample();
    s.addScan('S-04');
    s.addScan('S-05');
    s.receiveSerial('S-04');
    s.receiveSerial('S-05');
    s.confirmPutaway('LPN2', 'R1-R2-RB1-Rl1');
    expect(s.bulkLocateRequestBody('LPN2'), {
      'parameters': {
        'container_nbr__in': ['LPN2']
      },
      'options': {
        'location_barcode': 'R1-R2-RB1-Rl1',
        'depalletize_on_putaway_flg': false,
      },
    });
  });

  test('sync flags drive per-serial status and shipment rollup', () {
    final s = _sample();
    for (final x in ['S-01', 'S-02', 'S-03', 'S-04', 'S-05']) {
      s.addScan(x);
      s.receiveSerial(x);
    }
    s.confirmPutaway('LPN1', 'L1');
    s.confirmPutaway('LPN2', 'L2');

    s.markReceived('LPN1');
    expect(s.isSynced('LPN1'), isFalse);
    s.markLocated('LPN1');
    expect(s.isSynced('LPN1'), isTrue);
    expect(s.serialStatus('S-01'), SerialStatus.syncedToWms);
    expect(s.wmsStatusLabel('LPN1'), 'Sync');
    expect(s.status, ShipmentStatus.partial);

    s.setSyncError('LPN2', 'receive', 'TIMEOUT', 'no response');
    expect(s.lpnStatus('LPN2'), LpnStatus.error);
    s.markReceived('LPN2');
    s.markLocated('LPN2');
    expect(s.status, ShipmentStatus.synced);
  });

  test('json round-trips including received flag and short qty', () {
    final s = _sample();
    s.addScan('S-01');
    s.addScan('S-02');
    s.receiveSerial('S-01');
    s.markShort('LPN1');
    s.confirmPutaway('LPN1', 'A4200100');
    s.markReceived('LPN1');

    final restored =
        ShipmentStaging.fromJson(Map<String, dynamic>.from(s.toJson()));
    expect(restored.shipmentNbr, s.shipmentNbr);
    expect(restored.scannedCountForLpn('LPN1'), 2);
    expect(restored.receivedCountForLpn('LPN1'), 1);
    expect(restored.shortQtyForLpn('LPN1'), 2); // 3 shipped - 1 received
    expect(restored.lpns['LPN1']!.putawayLocation, 'A4200100');
    expect(restored.lpns['LPN1']!.wmsReceivedOk, isTrue);
    expect(restored.isShortReceipt('LPN1'), isTrue);
    expect(restored.serialStatus('S-01'), SerialStatus.putaway);
  });
}
