import 'nonserial_receiving_store.dart';
import 'receiving_sync.dart' show LpnSyncResult;
import 'serial_receiving_service.dart';

/// Per-line Sync for scenario 2.2 - identical shape to [ReceivingSync] but
/// keyed on a non-serial line (its own LPN, qty and putaway location).
/// `receive` must land before `bulk_locate`; both per-line flags are
/// flushed the instant each call is confirmed so a crash/disconnect
/// mid-Sync resumes cleanly. Neither endpoint is idempotent, so a failure
/// first checks whether the work actually landed.
class NonSerialSync {
  final SerialReceivingService service;
  final NonSerialReceivingStore store;
  NonSerialSync(this.service, this.store);

  Future<LpnSyncResult> syncLine(
      NonSerialStaging staging, String lineId) async {
    final l = staging.lineById(lineId);
    if (l == null) {
      return const LpnSyncResult.failed('receive', 'Unknown line');
    }

    if (!l.wmsReceivedOk) {
      final res = await service.receiveLpn(staging.receiveRequestBody(lineId));
      if (res.ok) {
        staging.markReceived(lineId);
        await store.save(staging);
      } else if (await service.lpnExists(l.lpnNbr)) {
        staging.markReceived(lineId);
        await store.save(staging);
      } else {
        staging.setSyncError(lineId, 'receive', res.code, res.message);
        await store.save(staging);
        return LpnSyncResult.failed('receive', res.message);
      }
    }

    if (!l.wmsLocatedOk) {
      final res =
          await service.bulkLocateLpn(staging.bulkLocateRequestBody(lineId));
      if (res.ok) {
        staging.markLocated(lineId);
        await store.save(staging);
      } else {
        final loc = l.putawayLocation ?? '';
        if (loc.isNotEmpty && await service.lpnIsAtLocation(l.lpnNbr, loc)) {
          staging.markLocated(lineId);
          await store.save(staging);
        } else {
          staging.setSyncError(lineId, 'bulk_locate', res.code, res.message);
          await store.save(staging);
          return LpnSyncResult.failed('bulk_locate', res.message);
        }
      }
    }

    return const LpnSyncResult.ok();
  }
}
