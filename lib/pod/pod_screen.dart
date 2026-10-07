import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import '../config/app_config.dart';
import '../services/pod_service.dart';
import '../services/rwmobile_service.dart';
import '../services/upload_service.dart';

/// Proof of Delivery - a bespoke screen (not RF-driven, unlike every other
/// screen in this app) backed directly by OCWMS lgfapi calls. Reached via a
/// synthetic entry spliced into the real WMS main menu (see main.dart's
/// _MenuView) rather than the RF protocol - see docs/POD Screen.pdf for the
/// source spec and pod_service.dart for the call orchestration.
class PodScreen extends StatefulWidget {
  final RwmobileService rw;
  final String facCode;
  final String compCode;
  const PodScreen({
    super.key,
    required this.rw,
    required this.facCode,
    required this.compCode,
  });

  @override
  State<PodScreen> createState() => _PodScreenState();
}

class _PodScreenState extends State<PodScreen> {
  late final PodService _pod =
      PodService(widget.rw, facCode: widget.facCode, compCode: widget.compCode);

  final _orderController = TextEditingController();
  final _orderFocusNode = FocusNode();
  bool _showOrderDropdown = false;

  List<PodOrderSummary>? _orderLov;
  bool _loadingLov = false;
  PodOrderSummary? _selectedOrder;

  bool _loadingDetail = false;
  PodOrderDetail? _detail;
  String? _errorText;

  // Checkbox state is keyed by OBLPN id, not by row - mark_delivered is an
  // OBLPN-level action, so an OBLPN with multiple item lines is one
  // checkable unit even though each of its lines renders its own checkbox
  // (checking any one line checks all its siblings, which is the correct
  // behavior here rather than an ambiguous partial-OBLPN selection).
  final Set<int> _checked = {};
  bool _selectAll = false;

  final _signatureBoundaryKey = GlobalKey();
  List<Offset?> _strokePoints = [];
  bool _delivering = false;

  @override
  void initState() {
    super.initState();
    // Only OPENS the dropdown (2026-09-26) - closing it used to be driven
    // by this same listener's focus-loss branch on a 150ms delay, racing
    // against whichever tap/drag caused that focus loss to also finish its
    // own gesture in time. That race was lost two different ways: clicking
    // a list item (a tap outside the TextField, so focus is lost the
    // instant the mouse goes down) sometimes lost the race to its own
    // onTap on desktop; dragging the scrollbar - a press-and-hold gesture
    // that routinely runs past 150ms - always lost it, so the list closed
    // mid-drag. Closing is now handled by _buildOrderPicker's TapRegion
    // instead, which has no timing dependency at all.
    _orderFocusNode.addListener(() {
      if (_orderFocusNode.hasFocus) {
        setState(() => _showOrderDropdown = true);
        _ensureOrderLov();
      }
    });
  }

  @override
  void dispose() {
    _orderController.dispose();
    _orderFocusNode.dispose();
    super.dispose();
  }

  Future<void> _ensureOrderLov() async {
    if (_orderLov != null || _loadingLov) return;
    setState(() => _loadingLov = true);
    try {
      final lov = await _pod.fetchOrderLov();
      if (!mounted) return;
      setState(() {
        _orderLov = lov;
        _loadingLov = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLov = false;
        _errorText = 'Failed to load orders: $e';
      });
    }
  }

  List<PodOrderSummary> get _filteredOrders {
    final lov = _orderLov ?? const <PodOrderSummary>[];
    final q = _orderController.text.trim().toLowerCase();
    if (q.isEmpty) return lov;
    return lov
        .where((o) =>
            o.orderNbr.toLowerCase().contains(q) ||
            o.custName.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _submitOrder() async {
    final order = _selectedOrder;
    if (order == null) return;
    setState(() {
      _loadingDetail = true;
      _detail = null;
      _checked.clear();
      _selectAll = false;
      _strokePoints = [];
      _errorText = null;
    });
    try {
      final detail = await _pod.fetchOrderDetail(order);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loadingDetail = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDetail = false;
        _errorText = 'Failed to load order detail: $e';
      });
    }
  }

  void _toggleSelectAll(bool? value) {
    final detail = _detail;
    if (detail == null) return;
    setState(() {
      _selectAll = value ?? false;
      _checked.clear();
      if (_selectAll) {
        _checked.addAll(detail.lines.map((l) => l.oblpnId));
      }
    });
  }

  void _toggleLine(PodOblpnLine line, bool? value) {
    setState(() {
      if (value ?? false) {
        _checked.add(line.oblpnId);
      } else {
        _checked.remove(line.oblpnId);
      }
      final allIds = _detail?.lines.map((l) => l.oblpnId).toSet() ?? {};
      _selectAll = allIds.isNotEmpty && allIds.every(_checked.contains);
    });
  }

  bool get _hasSignature => _strokePoints.isNotEmpty;

  Future<void> _deliver() async {
    if (_checked.isEmpty || !_hasSignature || _delivering) return;
    setState(() {
      _delivering = true;
      _errorText = null;
    });
    final attempted = _checked.toSet();
    final results = await _pod.deliver(attempted);
    final failed =
        results.entries.where((e) => !e.value).map((e) => e.key).toSet();
    if (failed.isEmpty) {
      await _persistSignature(_detail!.orderNbr);
    }
    if (!mounted) return;
    setState(() {
      _delivering = false;
      // Keep only the failed ones checked, so the operator can see exactly
      // what still needs retrying; succeeded rows uncheck themselves.
      _checked
        ..clear()
        ..addAll(failed);
      _selectAll = false;
      if (failed.isEmpty) _strokePoints = [];
    });
    final succeeded = attempted.length - failed.length;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(failed.isEmpty ? 'Delivered' : 'Partially delivered'),
        content: Text(failed.isEmpty
            ? '$succeeded of ${attempted.length} OBLPN(s) marked delivered.'
            : '$succeeded of ${attempted.length} OBLPN(s) marked delivered. '
                '${failed.length} failed - still checked above, retry when ready.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
    // 2026-07-23: once every checked OBLPN is confirmed delivered, drop back
    // to the same blank state the screen opens in - order picker only, no
    // stale header/list/signature left over. `_orderLov` is cleared too
    // (not just the selection) so the next dropdown open re-fetches fresh -
    // the order just delivered should no longer show up once its OBLPNs are
    // off status_id 91.
    if (failed.isEmpty && mounted) {
      setState(() {
        _selectedOrder = null;
        _orderController.clear();
        _detail = null;
        _checked.clear();
        _selectAll = false;
        _strokePoints = [];
        _orderLov = null;
      });
    }
  }

  /// The delivery confirmation itself already succeeded by the time this
  /// runs, so failures here are surfaced via SnackBar rather than blocking
  /// the Delivered dialog - but they ARE surfaced (2026-07-23 fix): every
  /// exit path used to fail silently (in particular, a null `boundary` just
  /// `return`ed with no exception at all, so the try/catch never even saw
  /// it), which is why signatures were disappearing with no visible error.
  Future<void> _persistSignature(String orderNbr) async {
    String? failureReason;
    String? savedPath;
    var uploaded = false;
    try {
      // Let any in-flight frame actually commit before capturing - toImage()
      // on a boundary mid-layout/paint can throw.
      await SchedulerBinding.instance.endOfFrame;
      final boundary = _signatureBoundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        failureReason = 'signature area was not on screen';
      } else {
        final image = await boundary.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) {
          failureReason = 'could not encode signature as PNG';
        } else {
          final docsDir = await getApplicationDocumentsDirectory();
          final folder =
              Directory('${docsDir.path}/${AppConfig.camFolderName}');
          if (!await folder.exists()) await folder.create(recursive: true);
          final safeOrder = orderNbr.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
          final ts = DateTime.now().millisecondsSinceEpoch;
          final destPath = '${folder.path}/POD_${safeOrder}_$ts.png';
          // .buffer.asUint8List() alone views the WHOLE underlying buffer,
          // not just this ByteData's own offset/length - bounding it
          // explicitly avoids writing stray bytes if they ever differ.
          final bytes = byteData.buffer
              .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
          await File(destPath).writeAsBytes(bytes);
          savedPath = destPath;
          // Best-effort auto-upload (2026-07-23, see UploadService) - only
          // deletes the local copy once the receiver confirms it, so an
          // unconfigured/unreachable server just leaves it queued for
          // Captured Files' "Sync Now" to pick up later.
          final uploadConfig = await AppConfig.loadUploadServer();
          if (uploadConfig.isConfigured &&
              await UploadService.tryUpload(File(destPath), uploadConfig)) {
            await File(destPath).delete();
            uploaded = true;
          }
        }
      }
    } catch (e) {
      failureReason = '$e';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(savedPath == null
          ? 'Signature NOT saved: ${failureReason ?? 'unknown error'}'
          : uploaded
              ? 'Signature saved and uploaded.'
              : 'Signature saved locally (upload pending): $savedPath'),
      duration: const Duration(seconds: 4),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(title: const Text('Proof of Delivery')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildOrderPicker(),
            if (_errorText != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_errorText!,
                    style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),
            if (detail != null)
              Expanded(child: _buildOrderDetail(detail))
            else if (_loadingDetail)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else
              const Expanded(
                  child:
                      Center(child: Text('Select an order and tap Submit.'))),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderPicker() {
    // Closes the dropdown only on a tap genuinely outside this whole region
    // (field + list) - no timer, so a click-and-drag on the scrollbar or a
    // click on a list item is never mistaken for "tapped away," however
    // long the gesture takes.
    return TapRegion(
      onTapOutside: (_) {
        if (_showOrderDropdown) setState(() => _showOrderDropdown = false);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _orderController,
            focusNode: _orderFocusNode,
            decoration: InputDecoration(
              labelText: 'Order Nbr',
              border: const OutlineInputBorder(),
              suffixIcon: _loadingLov
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : const Icon(Icons.search),
            ),
            onChanged: (text) => setState(() {
              if (_selectedOrder != null && text != _selectedOrder!.orderNbr) {
                _selectedOrder = null;
              }
            }),
          ),
          if (_showOrderDropdown)
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor)),
              child: _loadingLov && _orderLov == null
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()))
                  : _filteredOrders.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('No matching orders'))
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: _filteredOrders.length,
                          itemBuilder: (context, i) {
                            final o = _filteredOrders[i];
                            return ListTile(
                              title: Text(o.orderNbr),
                              subtitle:
                                  o.custName.isEmpty ? null : Text(o.custName),
                              selected: _selectedOrder == o,
                              onTap: () {
                                setState(() {
                                  _selectedOrder = o;
                                  // Just the order number (2026-09-26), not
                                  // the "orderNbr — custName" display
                                  // string toString() builds - that
                                  // composite text can't round-trip through
                                  // _filteredOrders' per-field .contains()
                                  // check, so reopening the dropdown after
                                  // a selection was showing "No matching
                                  // orders" for the very order just picked.
                                  _orderController.text = o.orderNbr;
                                  _showOrderDropdown = false;
                                });
                                _orderFocusNode.unfocus();
                              },
                            );
                          },
                        ),
            ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed:
                _selectedOrder == null || _loadingDetail ? null : _submitOrder,
            child: _loadingDetail
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Submit'),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderDetail(PodOrderDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Order: ${detail.orderNbr}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                if (detail.custName.isNotEmpty)
                  Text('Customer: ${detail.custName}'),
              ],
            ),
          ),
        ),
        Row(
          children: [
            Checkbox(value: _selectAll, onChanged: _toggleSelectAll),
            const Text('Select All'),
          ],
        ),
        Expanded(
          child: detail.lines.isEmpty
              ? const Center(child: Text('No OBLPN lines for this order.'))
              : ListView.builder(
                  itemCount: detail.lines.length,
                  itemBuilder: (context, i) {
                    final line = detail.lines[i];
                    return CheckboxListTile(
                      value: _checked.contains(line.oblpnId),
                      onChanged: (v) => _toggleLine(line, v),
                      title: Text('OBLPN ${line.oblpnNbr}'),
                      subtitle:
                          Text('Item ${line.itemCode} • Qty ${line.currQty}'),
                    );
                  },
                ),
        ),
        const SizedBox(height: 4),
        const Text('Customer Signature',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        RepaintBoundary(
          key: _signatureBoundaryKey,
          child: Container(
            height: 160,
            decoration:
                BoxDecoration(border: Border.all(color: Colors.black26)),
            child: ClipRect(
              child: _SignaturePad(
                points: _strokePoints,
                onChanged: (pts) => setState(() => _strokePoints = pts),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _strokePoints.isEmpty
                ? null
                : () => setState(() => _strokePoints = []),
            child: const Text('Clear'),
          ),
        ),
        const SizedBox(height: 4),
        ElevatedButton(
          onPressed: (_checked.isEmpty || !_hasSignature || _delivering)
              ? null
              : _deliver,
          child: _delivering
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Deliver'),
        ),
      ],
    );
  }
}

class _SignaturePad extends StatelessWidget {
  final List<Offset?> points;
  final ValueChanged<List<Offset?>> onChanged;
  const _SignaturePad({required this.points, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (details) {
        final box = context.findRenderObject() as RenderBox;
        final local = box.globalToLocal(details.globalPosition);
        onChanged([...points, local]);
      },
      onPanEnd: (_) => onChanged([...points, null]),
      child: CustomPaint(
        painter: _SignaturePainter(points),
        size: Size.infinite,
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<Offset?> points;
  _SignaturePainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = Colors.white);
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      if (p1 != null && p2 != null) canvas.drawLine(p1, p2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) =>
      oldDelegate.points != points;
}
