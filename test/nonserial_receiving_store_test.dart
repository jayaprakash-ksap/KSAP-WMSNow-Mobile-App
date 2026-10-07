import 'package:flutter_test/flutter_test.dart';
import 'package:wmsnow_redwood_v3/services/nonserial_receiving_store.dart';

/// Sample shipment SLC-2026090904: 3 lines, one item, 3 batches / LPNs,
/// shipped 4 / 6 / 2 (as floats, like the real API).
NonSerialStaging _sample() {
  final dtl = <Map<String, dynamic>>[
    {
      'id': 'L1',
      'ib_shipment_id__shipment_nbr': 'SLC-2026090904',
      'container_nbr': 'LPN1',
      'item_id__part_a': 'IT1',
      'batch_nbr': 'LOT1',
      'invn_attr_id__invn_attr_a': '10',
      'lpn_lock_code': '',
      'shipped_qty': 4.0,
      'received_qty': 0.0,
    },
    {
      'id': 'L2',
      'ib_shipment_id__shipment_nbr': 'SLC-2026090904',
      'container_nbr': 'LPN2',
      'item_id__part_a': 'IT1',
      'batch_nbr': 'LOT2',
      'invn_attr_id__invn_attr_a': '20',
      'lpn_lock_code': '',
      'shipped_qty': 6.0,
      'received_qty': 0.0,
    },
    {
      'id': 'L3',
      'ib_shipment_id__shipment_nbr': 'SLC-2026090904',
      'container_nbr': 'LPN3',
      'item_id__part_a': 'IT1',
      'batch_nbr': 'LOT3',
      'invn_attr_id__invn_attr_a': '30',
      'lpn_lock_code': '',
      'shipped_qty': 2.0,
      'received_qty': 0.0,
    },
  ];
  return NonSerialStaging.fromApi(
    shipmentNbr: 'SLC-2026090904',
    facilityCode: 'SA_WH446_RYD',
    companyCode: 'STC',
    dtlRows: dtl,
  );
}

void main() {
  test('float shipped_qty parses to whole units; lines carry API values', () {
    final s = _sample();
    expect(s.lines.map((l) => l.id).toList(), ['L1', 'L2', 'L3']);
    expect(s.lineById('L1')!.shippedQty, 4);
    expect(s.lineById('L2')!.shippedQty, 6);
    expect(s.lineById('L1')!.lpnNbr, 'LPN1');
    expect(s.groupRemaining('L1'), 4);
  });

  test('full receive: no continuation line, line ready for putaway', () {
    final s = _sample();
    expect(s.receiveLine('L1', 4).ok, isTrue);
    expect(s.lines.length, 3); // no split
    expect(s.lineStatus('L1'), SerialStatus.received);
    expect(s.canConfirmPutaway('L1'), isTrue);
    expect(s.groupRemaining('L1'), 0);
  });

  test('partial receive spawns a continuation line for the remainder', () {
    final s = _sample();
    expect(s.receiveLine('L1', 3).ok, isTrue);
    expect(s.lines.length, 4);
    final child = s.lines[1]; // inserted right after L1
    expect(child.groupId, 'L1');
    expect(child.isOriginal, isFalse);
    expect(child.lpnNbr, '');
    expect(child.shippedQty, 4);
    expect(s.groupRemaining('L1'), 1); // 4 - 3
    expect(s.canConfirmPutaway('L1'), isTrue); // original line can be put away
    expect(s.canEditLpn(child.id), isTrue);
  });

  test('continuation line needs a fresh, unique LPN before Receive', () {
    final s = _sample();
    s.receiveLine('L1', 3);
    final child = s.lines[1];
    expect(s.canReceiveLine(child.id, 1).kind, NsActionResultKind.noLpn);
    expect(s.setLpn(child.id, 'LPN2').kind, NsActionResultKind.dupLpn); // taken
    expect(s.setLpn(child.id, 'LPN1-B').ok, isTrue);
    expect(s.receiveLine(child.id, 1).ok, isTrue);
    expect(s.groupRemaining('L1'), 0);
    expect(s.lines.length, 4); // 1 == remaining, so no further split
  });

  test('excess against Item+Batch is blocked (2.3)', () {
    final s = _sample();
    final r = s.receiveLine('L1', 5); // shipped 4
    expect(r.kind, NsActionResultKind.excess);
    expect(s.lineById('L1')!.received, isFalse);
  });

  test('excess blocked across a split group too', () {
    final s = _sample();
    s.receiveLine('L1', 3);
    final child = s.lines[1];
    s.setLpn(child.id, 'LPN1-B');
    expect(s.receiveLine(child.id, 2).kind, NsActionResultKind.excess); // only 1 left
  });

  test('Short accepts the entered qty and writes the rest off, no split', () {
    final s = _sample();
    expect(s.canShortLine('L2'), isTrue);
    expect(s.shortLine('L2', 4).ok, isTrue); // shipped 6, short 2
    expect(s.lines.length, 3);
    expect(s.lineById('L2')!.isShort, isTrue);
    expect(s.groupIsShort('L2'), isTrue);
    expect(s.groupRemaining('L2'), 0);
    expect(s.canConfirmPutaway('L2'), isTrue);
  });

  test('putaway then sync gates', () {
    final s = _sample();
    s.receiveLine('L3', 2);
    expect(s.canSync('L3'), isFalse);
    expect(s.confirmPutaway('L3', 'A4200100'), isTrue);
    expect(s.canSync('L3'), isTrue);
    expect(s.lineStatus('L3'), SerialStatus.putaway);

    s.markReceived('L3');
    expect(s.isSynced('L3'), isFalse);
    s.markLocated('L3');
    expect(s.isSynced('L3'), isTrue);
    expect(s.lineStatus('L3'), SerialStatus.syncedToWms);
  });

  test('receive request body: qty as string, empty serial list', () {
    final s = _sample();
    s.receiveLine('L1', 3);
    final body = s.receiveRequestBody('L1');
    expect(body['container_nbr'], 'LPN1');
    expect(body['shipment_nbr'], 'SLC-2026090904');
    expect((body['item_list'] as List).first, {
      'item_barcode': 'IT1',
      'qty': '3',
      'batch_nbr': 'LOT1',
      'serial_nbr_list': <String>[],
      'invn_attr_a': '10',
    });
  });

  test('bulk locate body carries the confirmed location', () {
    final s = _sample();
    s.receiveLine('L3', 2);
    s.confirmPutaway('L3', 'WH2-A42-001-00');
    expect(s.bulkLocateRequestBody('L3'), {
      'parameters': {
        'container_nbr__in': ['LPN3']
      },
      'options': {
        'location_barcode': 'WH2-A42-001-00',
        'depalletize_on_putaway_flg': false,
      },
    });
  });

  test('undo receive removes an empty continuation line', () {
    final s = _sample();
    s.receiveLine('L1', 3);
    expect(s.lines.length, 4);
    expect(s.undoReceiveLine('L1'), isTrue);
    expect(s.lines.length, 3);
    expect(s.lineById('L1')!.received, isFalse);
  });

  test('shipment status rollup', () {
    final s = _sample();
    for (final id in ['L1', 'L2', 'L3']) {
      final l = s.lineById(id)!;
      s.receiveLine(id, l.shippedQty);
      s.confirmPutaway(id, 'LOC');
    }
    expect(s.status, ShipmentStatus.putawayPending);
    s.markReceived('L1');
    s.markLocated('L1');
    expect(s.status, ShipmentStatus.partial);
    for (final id in ['L2', 'L3']) {
      s.markReceived(id);
      s.markLocated(id);
    }
    expect(s.status, ShipmentStatus.synced);
  });

  test('json round-trips including split lines and flags', () {
    final s = _sample();
    s.receiveLine('L1', 3);
    s.setLpn(s.lines[1].id, 'LPN1-B');
    s.confirmPutaway('L1', 'A4200100');
    s.markReceived('L1');

    final restored = NonSerialStaging.fromJson(
        Map<String, dynamic>.from(s.toJson()));
    expect(restored.lines.length, 4);
    expect(restored.lineById('L1')!.receivedQty, 3);
    expect(restored.lineById('L1')!.putawayLocation, 'A4200100');
    expect(restored.lineById('L1')!.wmsReceivedOk, isTrue);
    expect(restored.lines[1].lpnNbr, 'LPN1-B');
    expect(restored.groupRemaining('L1'), 1);
  });
}
