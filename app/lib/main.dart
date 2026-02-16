import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: MyApp(),
    ));

class MeasurementPoint {
  final double lat, lon, val;
  MeasurementPoint({required this.lat, required this.lon, required this.val});

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon, 'val': val};

  factory MeasurementPoint.fromJson(Map<String, dynamic> json) {
    return MeasurementPoint(
      lat: (json['lat'] ?? 0.0).toDouble(),
      lon: (json['lon'] ?? 0.0).toDouble(),
      val: (json['val'] ?? 0.0).toDouble(),
    );
  }
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final MapController _mapController = MapController();
  List<MeasurementPoint> points = [];
  double lastValue = 0.0;
  String gpsAccuracy = "Fixing GPS...";
  bool isFollowing = true;
  bool isConnected = false;

  final flutterReactiveBle = FlutterReactiveBle();
  final String targetDeviceName = "ESP32-Temp"; 
  final Uuid serviceUuid = Uuid.parse("12345678-1234-1234-1234-1234567890ab");
  final Uuid charUuid = Uuid.parse("abcd0001-1234-1234-1234-1234567890ab");

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _dataSub;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    await _requestPermissions();
    await _loadData();
    _startScan();
    Timer.periodic(const Duration(seconds: 5), (_) => _updateGpsAndPoints());
  }

  Future<void> _requestPermissions() async {
    await [Permission.location, Permission.bluetoothScan, Permission.bluetoothConnect].request();
  }

  void _startScan() {
    print("BLE: Starting scan...");
    _scanSub?.cancel();
    _scanSub = flutterReactiveBle.scanForDevices(withServices: []).listen((device) {
      if (device.name == targetDeviceName) {
        print("BLE: Target found! Connecting...");
        _scanSub?.cancel();
        _connect(device.id);
      }
    }, onError: (e) => print("Scan Error: $e"));
  }

  void _connect(String deviceId) {
    _connSub?.cancel();
    _connSub = flutterReactiveBle.connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 5), 
    ).listen((state) async {
      print("BLE: State changed to ${state.connectionState}");
      if (state.connectionState == DeviceConnectionState.connected) {
        setState(() => isConnected = true);
        await Future.delayed(const Duration(milliseconds: 1000));
        _subscribe(deviceId);
      } else if (state.connectionState == DeviceConnectionState.disconnected) {
        setState(() => isConnected = false);
        _dataSub?.cancel();
        _startScan(); 
      }
    }, onError: (e) => print("Connection Error: $e"));
  }

  void _subscribe(String deviceId) {
    _dataSub?.cancel();
    final char = QualifiedCharacteristic(
        characteristicId: charUuid, serviceId: serviceUuid, deviceId: deviceId);
    
    _dataSub = flutterReactiveBle.subscribeToCharacteristic(char).listen((data) {
      try {
        if (data.length >= 4) {
          final raw = Uint8List.fromList(data);
          final newVal = ByteData.sublistView(raw).getFloat32(0, Endian.little);
          if (mounted) setState(() => lastValue = newVal);
        }
      } catch (e) {
        print("Data parsing error: $e");
      }
    }, onError: (e) => print("Subscription Error: $e"));
  }

  Future<void> _updateGpsAndPoints() async {
    if (!isConnected) return; 
    try {
      Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (mounted) {
        setState(() {
          gpsAccuracy = "${pos.accuracy.toStringAsFixed(1)}m";
          points.add(MeasurementPoint(lat: pos.latitude, lon: pos.longitude, val: lastValue));
        });
        _saveData();
        if (isFollowing) _mapController.move(LatLng(pos.latitude, pos.longitude), _mapController.camera.zoom);
      }
    } catch (e) { print("GPS Error: $e"); }
  }

  _saveData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('points', points.map((p) => jsonEncode(p.toJson())).toList());
  }

  _loadData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getStringList('points');
      if (data != null && mounted) {
        setState(() {
          points = data.map((e) => MeasurementPoint.fromJson(jsonDecode(e))).toList();
        });
      }
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      prefs.remove('points');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(initialCenter: LatLng(40.50, 44.76), initialZoom: 15),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.ble_dosimeter',
              ),
             CircleLayer(
  circles: points.map((p) {

    Color pointColor;
    if (p.val < 21.0) {
      pointColor = Colors.greenAccent;
    } else if (p.val >= 21.0 && p.val <= 25.0) {
      pointColor = Colors.orangeAccent;
    } else {
      pointColor = Colors.redAccent;
    }

    return CircleMarker(
      point: LatLng(p.lat, p.lon),
      color: pointColor.withOpacity(0.8), 
      useRadiusInMeter: true,
      radius: 12, 
    );
  }).toList(),
),
            ],
          ),
          _buildGlassUI(),
        ],
      ),
    );
  }

  Widget _buildGlassUI() {
    return Positioned(bottom: 25, left: 15, right: 15, child: ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8), child: Container(padding: const EdgeInsets.all(20), color: Colors.black45, child: Column(mainAxisSize: MainAxisSize.min, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [_statusBadge(), Text(gpsAccuracy, style: const TextStyle(fontSize: 12, color: Colors.white54))]), const SizedBox(height: 15), Row(crossAxisAlignment: CrossAxisAlignment.end, children: [const Text("VALUE:", style: TextStyle(color: Colors.white70)), const Spacer(), Text(lastValue.toStringAsFixed(1), style: const TextStyle(fontSize: 50, fontWeight: FontWeight.bold, fontFamily: 'monospace')), const SizedBox(width: 5), const Text("UNIT", style: TextStyle(color: Colors.white24, fontSize: 14))]), const SizedBox(height: 10), Row(children: [Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.white10), onPressed: () => setState(() => isFollowing = !isFollowing), icon: Icon(isFollowing ? Icons.gps_fixed : Icons.gps_not_fixed, size: 16), label: const Text("Follow"))), const SizedBox(width: 10), Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.red.withOpacity(0.2)), onPressed: () { setState(() => points = []); _saveData(); }, icon: const Icon(Icons.delete_outline, size: 16), label: const Text("Clear")))])])))));
  }

  Widget _statusBadge() {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: isConnected ? Colors.green.withOpacity(0.2) : Colors.orange.withOpacity(0.2), borderRadius: BorderRadius.circular(10), border: Border.all(color: isConnected ? Colors.green : Colors.orange, width: 0.5)), child: Text(isConnected ? "ESP32 CONNECTED" : "SCANNING...", style: TextStyle(color: isConnected ? Colors.greenAccent : Colors.orange, fontSize: 10, fontWeight: FontWeight.bold)));
  }
}