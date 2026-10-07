import 'receiving_store.dart';
import 'serial_receiving_service.dart';

/// Result of syncing one LPN to WMS.
class LpnSyncResult {
  final bool synced;
  final String? errorCall; // "receive" | "bulk_locate"
  final String? errorMessage;

  const LpnSyncResult.ok()
      : synced = true,
        errorCall = null,
        errorMessage = null;

  const LpnSyncResult.failed(this.errorCall, this.errorMessage)
      : synced = false;
}

/// Drives the per-LPN Sync sequence and keeps the staging store in step.
///
/// Order is fixed - `receive` must land before `bulk_locate` - and the two
/// per-LPN flags (`wms_received_ok` / `wms_located_ok`) are flushed to disk
/// the instant each call is confirmed, so a crash, disconnect, or session
/// expiry mid-Sync leaves exact progress on disk and re-pressing Sync
/// resumes from the right step. Neither WMS endpoint is guaranteed
/// idempotent, so on a failure each step first checks whether the work
/// actually landed (the lost-response case) before reporting an error.
class ReceivingSync {
  final SerialReceivingService service;
  final ReceivingStore store;
  ReceivingSync(this.service, this.store);

  Future<LpnSyncResult> syncLpn(ShipmentStaging staging, String lpn) async {
    final state = staging.lpns[lpn];
    if (state == null) {
      return const LpnSyncResult.failed('receive', 'Unknown LPN');
    }

    // 1. Receive.
    if (!state.wmsReceivedOk) {
      final res = await service.receiveLpn(staging.receiveRequestBody(lpn));
      if (res.ok) {
        staging.markReceived(lpn);
        await store.save(staging);
      } else if (await service.lpnExists(lpn)) {
        // The request reached WMS even though the reply didn't.
        staging.markReceived(lpn);
        await store.save(staging);
      } else {
        staging.setSyncError(lpn, 'receive', res.code, res.message);
        await store.save(staging);
        return LpnSyncResult.failed('receive', res.message);
      }
    }

    // 2. Locate.
    if (!state.wmsLocatedOk) {
      final res =
          await service.bulkLocateLpn(staging.bulkLocateRequestBody(lpn));
      if (res.ok) {
        staging.markLocated(lpn);
        await store.save(staging);
      } else {
        final loc = state.putawayLocation ?? '';
        if (loc.isNotEmpty && await service.lpnIsAtLocation(lpn, loc)) {
          staging.markLocated(lpn);
          await store.save(staging);
        } else {
          staging.setSyncError(lpn, 'bulk_locate', res.code, res.message);
          await store.save(staging);
          return LpnSyncResult.failed('bulk_locate', res.message);
        }
      }
    }

    return const LpnSyncResult.ok();
  }
}
