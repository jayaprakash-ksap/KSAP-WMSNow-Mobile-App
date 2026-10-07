import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// A single-line scan/entry field for the receiving screens.
///
/// On Zebra/Honeywell rugged devices DataWedge injects the scan as
/// keystrokes into the focused field (with an Enter suffix), so the plain
/// [TextField] + `onSubmitted` path is the primary one. The camera button
/// is the fallback for non-rugged devices, mirroring the app's existing
/// `_BarcodeScannerScreen` in main.dart.
class SerialScanField extends StatefulWidget {
  final String label;
  final String? hintText;
  final bool enabled;
  final bool autofocus;
  final bool clearOnSubmit;

  /// Called with the trimmed value on Enter / scan / the trailing arrow
  /// button.
  final ValueChanged<String> onSubmit;

  /// Called on every keystroke with the current trimmed text - lets a
  /// parent drive its own button from this field's value.
  final ValueChanged<String>? onChanged;

  const SerialScanField({
    super.key,
    required this.label,
    required this.onSubmit,
    this.onChanged,
    this.hintText,
    this.enabled = true,
    this.autofocus = false,
    this.clearOnSubmit = true,
  });

  @override
  State<SerialScanField> createState() => _SerialScanFieldState();
}

class _SerialScanFieldState extends State<SerialScanField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    widget.onSubmit(value);
    if (widget.clearOnSubmit) _controller.clear();
    // Keep focus so the next scan lands here without a re-tap.
    _focusNode.requestFocus();
  }

  Future<void> _scanWithCamera() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScanCameraScreen()),
    );
    if (value == null || value.trim().isEmpty) return;
    _controller.text = value.trim();
    _submit();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.deny(RegExp(r'\s')),
      ],
      onChanged: (v) => widget.onChanged?.call(v.trim()),
      onSubmitted: (_) => _submit(),
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Scan with camera',
              icon: const Icon(Icons.qr_code_scanner),
              onPressed: widget.enabled ? _scanWithCamera : null,
            ),
            IconButton(
              tooltip: 'Enter',
              icon: const Icon(Icons.subdirectory_arrow_left),
              onPressed: widget.enabled ? _submit : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the camera scanner full-screen and returns the first decoded
/// value (or null if cancelled). Shared by the receiving screens for
/// in-table LPN / location scans.
Future<String?> scanBarcode(BuildContext context) => Navigator.of(context)
    .push<String>(MaterialPageRoute(builder: (_) => const _ScanCameraScreen()));

class _ScanCameraScreen extends StatefulWidget {
  const _ScanCameraScreen();
  @override
  State<_ScanCameraScreen> createState() => _ScanCameraScreenState();
}

class _ScanCameraScreenState extends State<_ScanCameraScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final value =
        capture.barcodes.isNotEmpty ? capture.barcodes.first.rawValue : null;
    if (value == null || value.isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan barcode')),
      body: MobileScanner(onDetect: _onDetect),
    );
  }
}
