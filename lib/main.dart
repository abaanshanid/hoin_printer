import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:barcode/barcode.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide TextSpan;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const LabelPrinterApp());
}

// ============================================================================
// BACKGROUND THREAD WORKER (Excel Parsing)
// ============================================================================
Map<String, Map<String, String>> parseExcelInIsolate(Uint8List bytes) {
  var excel = Excel.decodeBytes(bytes);
  Map<String, Map<String, String>> newInventory = {};

  for (var table in excel.tables.keys) {
    for (var row in excel.tables[table]?.rows ?? []) {
      if (row.length > 2 && row[2] != null) {
        String id = row[2]!.value.toString().trim();
        if (id.toLowerCase() == 'sku' || id.toLowerCase() == 'barcode') continue;

        newInventory[id] = {
          "id": id,
          "name": row.length > 1 && row[1] != null ? row[1]!.value.toString() : "Unknown Name",
          "sku": row.length > 0 && row[0] != null ? row[0]!.value.toString() : "NO-ALU",
          "price": row.length > 4 && row[4] != null ? row[4]!.value.toString() : "0.00",
          // Safely checks the 6th column (Index 5) for Was Price
          "was_price": row.length > 5 && row[5] != null && row[5]!.value.toString().trim().isNotEmpty
              ? row[5]!.value.toString().trim()
              : "0.00",
        };
      }
    }
  }
  return newInventory;
}
// ============================================================================

class LabelPrinterApp extends StatelessWidget {
  const LabelPrinterApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Universal PDT Station',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blueGrey,
        useMaterial3: true,
      ),
      home: const PermissionSplashScreen(),
    );
  }
}

// ============================================================================
// PERMISSION SPLASH SCREEN
// ============================================================================
class PermissionSplashScreen extends StatefulWidget {
  const PermissionSplashScreen({Key? key}) : super(key: key);

  @override
  State<PermissionSplashScreen> createState() => _PermissionSplashScreenState();
}

class _PermissionSplashScreenState extends State<PermissionSplashScreen> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _checkExistingPermissions();
  }

  Future<void> _checkExistingPermissions() async {
    bool btScan = await Permission.bluetoothScan.isGranted;
    bool btConnect = await Permission.bluetoothConnect.isGranted;
    bool location = await Permission.location.isGranted;

    // If Android 12+, btScan and btConnect are enough.
    // If Android 11 or older, Location is used.
    if ((btScan && btConnect) || location) {
      _navigateToHome();
    } else {
      setState(() => _checking = false);
    }
  }

  Future<void> _requestPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    bool btScan = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    bool btConnect = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    bool location = statuses[Permission.location]?.isGranted ?? false;

    if ((btScan && btConnect) || location) {
      _navigateToHome();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Hardware permissions required to use scanner."),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  void _navigateToHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => const LabelPrinterHomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blueGrey.shade900,
      body: Center(
        child: _checking
            ? const CircularProgressIndicator(color: Colors.white)
            : Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security, size: 80, color: Colors.white),
              const SizedBox(height: 24),
              const Text(
                "Setup Required",
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text(
                "This PDT requires Bluetooth and Location permissions to scan for and connect to your thermal printer hardware.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white70, height: 1.5),
              ),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _requestPermissions,
                icon: const Icon(Icons.check_circle_outline),
                label: const Text("Grant Permissions", style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(55),
                  foregroundColor: Colors.blueGrey.shade900,
                  backgroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
// ============================================================================

class LabelPrinterHomePage extends StatefulWidget {
  const LabelPrinterHomePage({Key? key}) : super(key: key);

  @override
  State<LabelPrinterHomePage> createState() => _LabelPrinterHomePageState();
}

class _LabelPrinterHomePageState extends State<LabelPrinterHomePage> {
  static const platform = MethodChannel('com.example.printer/bluetooth');

  List<Map<dynamic, dynamic>> _devices = [];
  Map<dynamic, dynamic>? _selectedDevice;
  bool _connected = false;
  bool _isScanning = false;
  bool _isLoadingDatabase = false;

  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();

  Map<String, String>? _scannedItem;
  int _quantity = 1;

  String _labelFormat = 'was-now';
  String _labelSize = '76x51';

  Map<String, Map<String, String>> _inventory = {};

  @override
  void initState() {
    super.initState();
    platform.setMethodCallHandler(_handleNativeMethodCall);

    _autoLoadSavedDatabase();

    _startInAppScan();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inputFocusNode.requestFocus();
    });
  }

  Future<dynamic> _handleNativeMethodCall(MethodCall call) async {
    if (call.method == "onDeviceFound") {
      final device = Map<dynamic, dynamic>.from(call.arguments);
      setState(() {
        if (!_devices.any((d) => d['address'] == device['address'])) {
          _devices.add(device);
        }
      });
    } else if (call.method == "onScanFinished") {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _startInAppScan() async {
    if (_isScanning) return;
    setState(() { _isScanning = true; _devices = []; _selectedDevice = null; });
    try {
      await platform.invokeMethod('startInAppScan');
    } on PlatformException catch (e) {
      debugPrint("Scan error: ${e.message}");
      setState(() => _isScanning = false);
    }
  }

  Future<void> _connectToPrinter() async {
    if (_selectedDevice == null) return;
    try {
      final bool success = await platform.invokeMethod('connectInApp', {'address': _selectedDevice!['address']});
      setState(() { _connected = success; });
    } catch (e) { debugPrint("Connection fail: $e"); }
  }

  Future<void> _disconnectPrinter() async {
    await platform.invokeMethod('disconnectInApp');
    setState(() { _connected = false; _selectedDevice = null; });
  }

  Future<void> _autoLoadSavedDatabase() async {
    setState(() => _isLoadingDatabase = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasSavedDb = prefs.getBool('has_saved_db') ?? false;

      if (hasSavedDb) {
        final directory = await getApplicationDocumentsDirectory();
        final file = File('${directory.path}/internal_inventory.xlsx');

        if (await file.exists()) {
          var bytes = await file.readAsBytes();
          Map<String, Map<String, String>> parsedData = await compute(parseExcelInIsolate, bytes);

          setState(() {
            _inventory = parsedData;
          });

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text("Auto-loaded ${_inventory.length} items from internal storage!", style: const TextStyle(color: Colors.white)),
                backgroundColor: Colors.blueGrey
            ));
          }
        }
      }
    } catch (e) {
      debugPrint("Failed to auto-load database: $e");
    } finally {
      setState(() => _isLoadingDatabase = false);
    }
  }

  Future<void> _loadExcelDatabase() async {
    setState(() => _isLoadingDatabase = true);

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );

      if (result != null) {
        Uint8List? bytes = result.files.single.bytes;

        if (bytes == null) {
          File pickedFile = File(result.files.single.path!);
          bytes = pickedFile.readAsBytesSync();
        }

        final directory = await getApplicationDocumentsDirectory();
        final internalFile = File('${directory.path}/internal_inventory.xlsx');
        await internalFile.writeAsBytes(bytes);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('has_saved_db', true);

        Map<String, Map<String, String>> parsedData = await compute(parseExcelInIsolate, bytes);

        setState(() {
          _inventory = parsedData;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text("Successfully saved and loaded ${_inventory.length} items!", style: const TextStyle(color: Colors.white)),
              backgroundColor: Colors.green
          ));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Failed to parse Excel file: $e", style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.red
        ));
      }
    } finally {
      setState(() => _isLoadingDatabase = false);
    }
  }

  void _handleItemLookup(String value) {
    final cleanCode = value.trim();
    if (cleanCode.isEmpty) return;
    setState(() {
      if (_inventory.containsKey(cleanCode)) {
        _scannedItem = _inventory[cleanCode];
      } else {
        _scannedItem = {"id": cleanCode, "name": "Item Not Found in DB", "sku": "N/A", "price": "0.00", "was_price": "0.00"};
      }
      _quantity = 1;
    });
    _inputController.clear();
    _inputFocusNode.requestFocus();
  }

  Future<void> _generateAndPrintGraphics() async {
    if (!_connected || _scannedItem == null) return;

    final int labelWidth = _labelSize == '76x51' ? 576 : (_labelSize == '50x38' ? 400 : 480);
    final int labelHeight = _labelSize == '76x51' ? 408 : (_labelSize == '50x38' ? 304 : 232);
    final int widthMm = _labelSize == '76x51' ? 76 : (_labelSize == '50x38' ? 50 : 60);
    final int heightMm = _labelSize == '76x51' ? 51 : (_labelSize == '50x38' ? 38 : 29);
    final int gapMm = _labelSize == '76x51' ? 3 : 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    final bgPaint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, labelWidth.toDouble(), labelHeight.toDouble()), bgPaint);

    final linePaint = Paint()..color = Colors.black..strokeWidth = 2.0;
    final crossPaint = Paint()..color = Colors.black..strokeWidth = 1.5;

    // ====================================================================
    // 76x51 MM STANDARD LABEL
    // ====================================================================
    if (_labelSize == '76x51') {
      if (_labelFormat == 'was-now') {
        _drawCenteredText(canvas, _scannedItem!['sku']!, 40, labelWidth, fontSize: 24, fontWeight: FontWeight.bold);
        _drawCenteredText(canvas, _scannedItem!['name']!, 80, labelWidth, fontSize: 22);
        canvas.drawLine(const Offset(20, 125), const Offset(556, 125), linePaint);

        _drawLeftText(canvas, "WAS  -", 130, 145, fontSize: 24);
        _drawCenteredText(canvas, "QR ${_scannedItem!['was_price']}", 145, labelWidth, fontSize: 24);
        _drawRightText(canvas, "قبل", labelWidth - 150, 145, fontSize: 24);

        _drawDashedLine(canvas, const Offset(35, 135), const Offset(541, 175), crossPaint);
        _drawDashedLine(canvas, const Offset(35, 175), const Offset(541, 135), crossPaint);

        canvas.drawLine(const Offset(20, 190), const Offset(556, 190), linePaint);

        _drawLeftText(canvas, "NOW  -", 130, 210, fontSize: 24);
        _drawCenteredText(canvas, "QR ${_scannedItem!['price']}", 205, labelWidth, fontSize: 36, fontWeight: FontWeight.bold);
        _drawRightText(canvas, "بعد", labelWidth - 150, 210, fontSize: 24);

        canvas.drawLine(const Offset(20, 260), const Offset(556, 260), linePaint);

        _drawCenteredText(canvas, "SKU: ${_scannedItem!['id']}", 270, labelWidth, fontSize: 18);
        _drawRealBarcode(canvas, _scannedItem!['id']!, 295, labelWidth, 60);
      } else {
        _drawCenteredText(canvas, _scannedItem!['sku']!, 50, labelWidth, fontSize: 24, fontWeight: FontWeight.bold);
        _drawCenteredText(canvas, _scannedItem!['name']!, 100, labelWidth, fontSize: 22);
        canvas.drawLine(const Offset(20, 145), const Offset(556, 145), linePaint);
        _drawCenteredText(canvas, "QR ${_scannedItem!['price']}", 170, labelWidth, fontSize: 40, fontWeight: FontWeight.bold);
        canvas.drawLine(const Offset(20, 235), const Offset(556, 235), linePaint);

        _drawCenteredText(canvas, "SKU: ${_scannedItem!['id']}", 245, labelWidth, fontSize: 18);
        _drawRealBarcode(canvas, _scannedItem!['id']!, 275, labelWidth, 60);
      }
    }
    // ====================================================================
    // 50x38 MM MEDIUM LABEL
    // ====================================================================
    else if (_labelSize == '50x38') {
      if (_labelFormat == 'was-now') {
        _drawCenteredText(canvas, _scannedItem!['sku']!, 15, labelWidth, fontSize: 18, fontWeight: FontWeight.bold);
        _drawCenteredText(canvas, _scannedItem!['name']!, 45, labelWidth, fontSize: 14);
        canvas.drawLine(const Offset(15, 70), const Offset(385, 70), linePaint);

        _drawLeftText(canvas, "WAS  -", 70, 80, fontSize: 14);
        _drawCenteredText(canvas, "QR ${_scannedItem!['was_price']}", 80, labelWidth, fontSize: 14);
        _drawRightText(canvas, "قبل", labelWidth - 80, 75, fontSize: 18, fontWeight: FontWeight.bold);

        _drawDashedLine(canvas, const Offset(15, 76), const Offset(385, 96), crossPaint);
        _drawDashedLine(canvas, const Offset(15, 96), const Offset(385, 76), crossPaint);

        canvas.drawLine(const Offset(15, 105), const Offset(385, 105), linePaint);

        _drawLeftText(canvas, "NOW  -", 70, 115, fontSize: 14);
        _drawCenteredText(canvas, "QR ${_scannedItem!['price']}", 110, labelWidth, fontSize: 24, fontWeight: FontWeight.bold);
        _drawRightText(canvas, "بعد", labelWidth - 80, 110, fontSize: 18, fontWeight: FontWeight.bold);

        canvas.drawLine(const Offset(15, 150), const Offset(385, 150), linePaint);

        _drawCenteredText(canvas, "SKU: ${_scannedItem!['id']}", 165, labelWidth, fontSize: 14);
        _drawRealBarcode(canvas, _scannedItem!['id']!, 190, labelWidth, 50);
      } else {
        _drawCenteredText(canvas, _scannedItem!['sku']!, 15, labelWidth, fontSize: 18, fontWeight: FontWeight.bold);
        _drawCenteredText(canvas, _scannedItem!['name']!, 45, labelWidth, fontSize: 14);
        canvas.drawLine(const Offset(15, 75), const Offset(385, 75), linePaint);

        _drawCenteredText(canvas, "QR ${_scannedItem!['price']}", 105, labelWidth, fontSize: 32, fontWeight: FontWeight.bold);
        canvas.drawLine(const Offset(15, 155), const Offset(385, 155), linePaint);

        _drawCenteredText(canvas, "SKU: ${_scannedItem!['id']}", 170, labelWidth, fontSize: 14);
        _drawRealBarcode(canvas, _scannedItem!['id']!, 195, labelWidth, 50);
      }
    }
    // ====================================================================
    // 60x29 MM SMALL LABEL
    // ====================================================================
    else {
      if (_labelFormat == 'was-now') {
        _drawCenteredText(canvas, _scannedItem!['sku']!, 10, labelWidth, fontSize: 16, fontWeight: FontWeight.bold);
        _drawCenteredText(canvas, _scannedItem!['name']!, 35, labelWidth, fontSize: 14);
        canvas.drawLine(const Offset(10, 55), const Offset(470, 55), linePaint);

        _drawLeftText(canvas, "WAS  -", 90, 62, fontSize: 14);
        _drawCenteredText(canvas, "QR ${_scannedItem!['was_price']}", 62, labelWidth, fontSize: 14);
        _drawRightText(canvas, "قبل", labelWidth - 100, 58, fontSize: 18, fontWeight: FontWeight.bold);

        _drawDashedLine(canvas, const Offset(15, 58), const Offset(465, 78), crossPaint);
        _drawDashedLine(canvas, const Offset(15, 78), const Offset(465, 58), crossPaint);

        canvas.drawLine(const Offset(10, 84), const Offset(470, 84), linePaint);

        _drawLeftText(canvas, "NOW  -", 90, 95, fontSize: 14);
        _drawCenteredText(canvas, "QR ${_scannedItem!['price']}", 90, labelWidth, fontSize: 22, fontWeight: FontWeight.bold);
        _drawRightText(canvas, "بعد", labelWidth - 100, 91, fontSize: 18, fontWeight: FontWeight.bold);

        canvas.drawLine(const Offset(10, 130), const Offset(470, 130), linePaint);

        _drawCenteredText(canvas, "SKU: ${_scannedItem!['id']}", 135, labelWidth, fontSize: 12);
        _drawRealBarcode(canvas, _scannedItem!['id']!, 155, labelWidth, 40);
      } else {
        _drawCenteredText(canvas, _scannedItem!['sku']!, 10, labelWidth, fontSize: 16, fontWeight: FontWeight.bold);
        _drawCenteredText(canvas, _scannedItem!['name']!, 35, labelWidth, fontSize: 14);
        canvas.drawLine(const Offset(10, 55), const Offset(470, 55), linePaint);

        _drawCenteredText(canvas, "QR ${_scannedItem!['price']}", 75, labelWidth, fontSize: 28, fontWeight: FontWeight.bold);
        canvas.drawLine(const Offset(10, 120), const Offset(470, 120), linePaint);

        _drawCenteredText(canvas, "SKU: ${_scannedItem!['id']}", 130, labelWidth, fontSize: 12);
        _drawRealBarcode(canvas, _scannedItem!['id']!, 150, labelWidth, 45);
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(labelWidth, labelHeight);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);

    if (byteData != null) {
      final Uint8List rgbaBytes = byteData.buffer.asUint8List();
      final Uint8List monoBytes = _convertTo1BitDitheredRaster(rgbaBytes, labelWidth, labelHeight);

      try {
        await platform.invokeMethod('printBitmapTSPL', {
          'bytes': monoBytes,
          'width': labelWidth,
          'height': labelHeight,
          'widthMm': widthMm,
          'heightMm': heightMm,
          'gapMm': gapMm,
          'qty': _quantity
        });
      } on PlatformException catch (e) {
        debugPrint("Print call crashed: ${e.message}");
      }
    }
  }

  Uint8List _convertTo1BitDitheredRaster(Uint8List rgba, int w, int h) {
    int bytesPerLine = (w + 7) ~/ 8;
    Uint8List result = Uint8List(bytesPerLine * h);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int rgbaIdx = (y * w + x) * 4;
        int r = rgba[rgbaIdx];
        int g = rgba[rgbaIdx + 1];
        int b = rgba[rgbaIdx + 2];

        double luminance = 0.299 * r + 0.587 * g + 0.114 * b;

        if (luminance >= 180) {
          int byteIdx = (y * bytesPerLine) + (x ~/ 8);
          int bitIdx = 7 - (x % 8);
          result[byteIdx] |= (1 << bitIdx);
        }
      }
    }
    return result;
  }

  void _drawCenteredText(Canvas canvas, String text, double y, int layoutWidth, {double fontSize = 20, FontWeight fontWeight = FontWeight.normal}) {
    final textPainter = TextPainter(
      text: TextSpan(style: TextStyle(color: Colors.black, fontSize: fontSize, fontWeight: fontWeight), text: text),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset((layoutWidth - textPainter.width) / 2, y));
  }

  void _drawLeftText(Canvas canvas, String text, double x, double y, {double fontSize = 20}) {
    final textPainter = TextPainter(
      text: TextSpan(style: TextStyle(color: Colors.black, fontSize: fontSize), text: text),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset(x, y));
  }

  void _drawRightText(Canvas canvas, String text, double xRight, double y, {double fontSize = 20, FontWeight fontWeight = FontWeight.normal}) {
    final textPainter = TextPainter(
      text: TextSpan(style: TextStyle(color: Colors.black, fontSize: fontSize, fontWeight: fontWeight), text: text),
      textDirection: TextDirection.rtl,
    )..layout();
    textPainter.paint(canvas, Offset(xRight - textPainter.width, y));
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint, {double dashWidth = 6.0, double dashSpace = 4.0}) {
    double dx = p2.dx - p1.dx;
    double dy = p2.dy - p1.dy;
    double magnitude = Offset(dx, dy).distance;

    if (magnitude == 0) return;

    double dirX = dx / magnitude;
    double dirY = dy / magnitude;
    double start = 0.0;

    while (start < magnitude) {
      double end = start + dashWidth;
      if (end > magnitude) end = magnitude;
      canvas.drawLine(
          Offset(p1.dx + dirX * start, p1.dy + dirY * start),
          Offset(p1.dx + dirX * end, p1.dy + dirY * end),
          paint
      );
      start += dashWidth + dashSpace;
    }
  }

  void _drawRealBarcode(Canvas canvas, String code, double y, int layoutWidth, double height) {
    final bc = Barcode.code128();
    double barcodeWidth = 320;
    double startX = (layoutWidth - barcodeWidth) / 2;
    final recipe = bc.make(code, width: barcodeWidth, height: height, drawText: false);
    final barPaint = Paint()..color = Colors.black;

    for (var elem in recipe) {
      if (elem is BarcodeBar) {
        if (elem.black) {
          canvas.drawRect(
            Rect.fromLTWH(startX + elem.left, y + elem.top, elem.width, elem.height),
            barPaint,
          );
        }
      }
    }

    final textPainter = TextPainter(
      text: TextSpan(
          style: const TextStyle(fontFamily: 'monospace', fontSize: 14, letterSpacing: 4, color: Colors.black),
          text: code
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(canvas, Offset((layoutWidth - textPainter.width) / 2, y + height + 4));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth Label Printer'),
        actions: [
          _isLoadingDatabase
              ? const Padding(padding: EdgeInsets.symmetric(horizontal: 16.0), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
              : IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: "Load Excel Database",
            onPressed: _loadExcelDatabase,
          ),
          Icon(Icons.circle, color: _connected ? Colors.green : Colors.red),
          const SizedBox(width: 15),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButton<Map<dynamic, dynamic>>(
                        isExpanded: true,
                        hint: Text(_isScanning ? "Scanning layout..." : 'Select Discovered Printer'),
                        value: _selectedDevice,
                        items: _devices.map((device) {
                          return DropdownMenuItem<Map<dynamic, dynamic>>(
                              value: device, child: Text("${device['name']} (${device['address']})")
                          );
                        }).toList(),
                        onChanged: _connected ? null : (device) => setState(() => _selectedDevice = device),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      onPressed: _connected ? null : _startInAppScan,
                      icon: _isScanning ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _selectedDevice == null ? null : (_connected ? _disconnectPrinter : _connectToPrinter),
                      style: ElevatedButton.styleFrom(backgroundColor: _connected ? Colors.red.shade100 : Colors.green.shade100),
                      child: Text(_connected ? 'Disconnect' : 'Connect'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _inputController,
              focusNode: _inputFocusNode,
              decoration: const InputDecoration(labelText: 'Scan Barcode or Enter Serial Manually', prefixIcon: Icon(Icons.qr_code_scanner), border: OutlineInputBorder()),
              onSubmitted: _handleItemLookup,
            ),
            const SizedBox(height: 16),
            _scannedItem == null
                ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 40.0),
              child: Center(child: Text("Ready for barcode or serial entry...")),
            )
                : Card(
              color: Colors.blueGrey.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("ITEM DETAILS", style: Theme.of(context).textTheme.titleSmall),
                    const Divider(),
                    Text(_scannedItem!['name']!, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text("Serial/ID: ${_scannedItem!['id']}", style: const TextStyle(fontSize: 16)),
                    Text("SKU Number: ${_scannedItem!['sku']}", style: const TextStyle(fontSize: 16)),
                    Text("Price: QR ${_scannedItem!['price']}", style: const TextStyle(fontSize: 18, color: Colors.blueGrey)),
                    const SizedBox(height: 24),
                    DropdownButtonFormField<String>(
                      value: _labelFormat,
                      decoration: const InputDecoration(labelText: 'Select Print Format', border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
                      items: const [
                        DropdownMenuItem(value: 'normal', child: Text('Normal (Standard Price)')),
                        DropdownMenuItem(value: 'was-now', child: Text('Was-Now (Discounted Format)')),
                      ],
                      onChanged: (value) => setState(() { _labelFormat = value!; }),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: _labelSize,
                      decoration: const InputDecoration(labelText: 'Select Label Size', border: OutlineInputBorder(), filled: true, fillColor: Colors.white),
                      items: const [
                        DropdownMenuItem(value: '76x51', child: Text('76x51 mm (Large)')),
                        DropdownMenuItem(value: '60x29', child: Text('60x29 mm (Small)')),
                        DropdownMenuItem(value: '50x38', child: Text('50x38 mm (Medium)')),
                      ],
                      onChanged: (value) => setState(() { _labelSize = value!; }),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(onPressed: _quantity > 1 ? () => setState(() => _quantity--) : null, icon: const Icon(Icons.remove)),
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 24.0), child: Text("$_quantity", style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
                        IconButton.filledTonal(onPressed: () => setState(() => _quantity++), icon: const Icon(Icons.add)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _connected ? _generateAndPrintGraphics : null,
                      icon: const Icon(Icons.print),
                      label: const Text('PRINT LABELS', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50), backgroundColor: Colors.blueGrey, foregroundColor: Colors.white),
                    )
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}