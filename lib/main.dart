import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;

// webview_flutter 핵심 라이브러리 - 웹이 아닐 때만 import
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SensorApp());
}

class SensorApp extends StatelessWidget {
  const SensorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GNSS Pro Tracker',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            elevation: 2,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: const SensorHomePage(),
    );
  }
}

class SensorHomePage extends StatefulWidget {
  const SensorHomePage({super.key});

  @override
  _SensorHomePageState createState() => _SensorHomePageState();
}

class _SensorHomePageState extends State<SensorHomePage>
    with TickerProviderStateMixin {
  Position? _position;
  Position? _previousPosition;
  AccelerometerEvent? _accelerometer;
  String _status = 'Initializing...';
  String _gnssInfo = 'GNSS: Acquiring signal...';
  String _accuracyLevel = 'Standard';
  String _currentAddress = 'Loading address...';
  bool _isConnected = false;

  final String _apiUrl = 'http://10.0.2.2:8000/api/sensor/';

  // 브이월드 API 키 (웹용과 앱용 구분)
  final String _vworldWebApiKey = '54269896-365E-3E09-A1F1-FD152D97E020';
  final String _vworldAppApiKey = 'D30C2FFE-EA88-30E9-BBB9-71EED5A2DE15';

  late final WebViewController _controller;
  late final AnimationController _pulseController;
  late final AnimationController _statusController;
  StreamSubscription<Position>? _positionStream;
  Timer? _accuracyTimer;

  // GNSS 정확도 향상을 위한 변수들
  List<Position> _positionBuffer = [];
  final int _bufferSize = 5;
  double _filteredLatitude = 0.0;
  double _filteredLongitude = 0.0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
    _statusController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _requestLocationPermission();
    _listenToSensors();
    if (!kIsWeb) {
      _initWebView();
    }
    _startAccuracyMonitoring();
  }

  void _initWebView() {
    if (kIsWeb) return;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {},
          onPageStarted: (String url) {},
          onPageFinished: (String url) {
            if (_position != null) {
              _updateMapLocation();
            }
          },
          onWebResourceError: (WebResourceError error) {
            print('WebView error: $error');
          },
          onNavigationRequest: (NavigationRequest request) {
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadHtmlString(_generateVWorldMapHtml());
  }

  Future<void> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        setState(() {
          _status = 'Location services disabled';
          _isConnected = false;
        });
      }
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          setState(() {
            _status = 'Location permission denied';
            _isConnected = false;
          });
        }
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        setState(() {
          _status = 'Permission permanently denied';
          _isConnected = false;
        });
      }
      return;
    }

    _startHighAccuracyLocationStream();
  }

  void _startHighAccuracyLocationStream() {
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      timeLimit: Duration(seconds: 30),
    );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      _processNewPosition(position);
    });
  }

  void _processNewPosition(Position position) {
    if (!mounted) return;

    _positionBuffer.add(position);
    if (_positionBuffer.length > _bufferSize) {
      _positionBuffer.removeAt(0);
    }

    _applyPositionFiltering();

    setState(() {
      _previousPosition = _position;
      _position = position;
      _isConnected = true;
      _status = 'Signal acquired';
      _updateGnssInfo(position);
      _updateAccuracyLevel(position);
    });

    // 브이월드로 주소 정보 가져오기
    _getAddressFromVWorld(position.latitude, position.longitude);
    _updateMapLocation();
    _statusController.forward();
  }

  void _applyPositionFiltering() {
    if (_positionBuffer.isEmpty) return;

    double totalWeight = 0.0;
    double weightedLat = 0.0;
    double weightedLng = 0.0;

    for (Position pos in _positionBuffer) {
      double weight = 1.0 / (pos.accuracy + 1.0);
      totalWeight += weight;
      weightedLat += pos.latitude * weight;
      weightedLng += pos.longitude * weight;
    }

    _filteredLatitude = weightedLat / totalWeight;
    _filteredLongitude = weightedLng / totalWeight;
  }

  void _updateGnssInfo(Position position) {
    String satellites = 'N/A';
    String gnssType = 'Multi-GNSS';

    if (position.accuracy <= 3) {
      satellites = '12+ satellites';
      gnssType = 'GPS+Galileo+GLONASS';
    } else if (position.accuracy <= 5) {
      satellites = '8-12 satellites';
      gnssType = 'GPS+Galileo';
    } else if (position.accuracy <= 10) {
      satellites = '4-8 satellites';
      gnssType = 'GPS';
    } else {
      satellites = '<4 satellites';
      gnssType = 'GPS/WiFi/Cell';
    }

    _gnssInfo = '$gnssType • $satellites';
  }

  void _updateAccuracyLevel(Position position) {
    if (position.accuracy <= 2) {
      _accuracyLevel = 'RTK Grade';
    } else if (position.accuracy <= 5) {
      _accuracyLevel = 'Survey Grade';
    } else if (position.accuracy <= 10) {
      _accuracyLevel = 'Navigation Grade';
    } else if (position.accuracy <= 20) {
      _accuracyLevel = 'Consumer Grade';
    } else {
      _accuracyLevel = 'Low Accuracy';
    }
  }

  void _startAccuracyMonitoring() {
    _accuracyTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_position != null && _previousPosition != null) {
        _analyzeMovementAccuracy();
      }
    });
  }

  void _analyzeMovementAccuracy() {
    if (_previousPosition == null || _position == null) return;

    double distance = Geolocator.distanceBetween(
      _previousPosition!.latitude,
      _previousPosition!.longitude,
      _position!.latitude,
      _position!.longitude,
    );

    if (distance > 50 && _position!.speed < 1.0) {
      if (mounted) {
        setState(() {
          _status = 'GPS drift detected';
        });
      }
    }
  }

  void _listenToSensors() {
    accelerometerEvents.listen((AccelerometerEvent event) {
      if (mounted) setState(() => _accelerometer = event);
    });
  }

  Future<void> _sendEnhancedData() async {
    if (_position == null || _accelerometer == null) {
      _showSnackBar('No sensor data available', isError: true);
      return;
    }

    double sendLatitude = _positionBuffer.length >= 3 ? _filteredLatitude : _position!.latitude;
    double sendLongitude = _positionBuffer.length >= 3 ? _filteredLongitude : _position!.longitude;

    final enhancedData = {
      'latitude': sendLatitude,
      'longitude': sendLongitude,
      'raw_latitude': _position!.latitude,
      'raw_longitude': _position!.longitude,
      'speed': _position!.speed,
      'accuracy': _position!.accuracy,
      'altitude': _position!.altitude,
      'heading': _position!.heading,
      'speed_accuracy': _position!.speedAccuracy,
      'altitude_accuracy': _position!.altitudeAccuracy,
      'heading_accuracy': _position!.headingAccuracy,
      'accel_x': _accelerometer!.x,
      'accel_y': _accelerometer!.y,
      'accel_z': _accelerometer!.z,
      'timestamp': _position!.timestamp.toIso8601String(),
      'accuracy_level': _accuracyLevel,
      'gnss_info': _gnssInfo,
      'filtered': _positionBuffer.length >= 3,
    };

    try {
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(enhancedData),
      );

      if (response.statusCode == 201) {
        _showSnackBar('Data transmitted successfully', isSuccess: true);
        setState(() => _status = 'Data transmitted');
      } else {
        _showSnackBar('Transmission failed (${response.statusCode})', isError: true);
      }
    } catch (e) {
      _showSnackBar('Network error occurred', isError: true);
    }
  }

  void _showSnackBar(String message, {bool isError = false, bool isSuccess = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError
                  ? Icons.error_outline
                  : isSuccess
                  ? Icons.check_circle_outline
                  : Icons.info_outline,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: isError
            ? Colors.red[600]
            : isSuccess
            ? Colors.green[600]
            : Colors.blue[600],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // 브이월드 지오코딩 API를 사용한 주소 변환
  Future<void> _getAddressFromVWorld(double lat, double lng) async {
    try {
      setState(() {
        _currentAddress = 'Loading address...';
      });

      // 플랫폼에 따른 API 키 선택
      final apiKey = kIsWeb ? _vworldWebApiKey : _vworldAppApiKey;

      // 브이월드 역지오코딩 API 호출
      final url = 'https://api.vworld.kr/req/address'
          '?service=address'
          '&request=getAddress'
          '&version=2.0'
          '&crs=epsg:4326'
          '&point=${lng},${lat}'
          '&format=json'
          '&type=both'
          '&zipcode=true'
          '&simple=false'
          '&key=$apiKey';

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'GNSS-Pro-Tracker/1.0',
        },
      ).timeout(const Duration(seconds: 10));

      print('VWorld API 응답 코드: ${response.statusCode}');
      print('VWorld API 응답: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['response']['status'] == 'OK' &&
            data['response']['result'] != null) {
          final results = data['response']['result'] as List;
          if (results.isNotEmpty && mounted) {
            final result = results[0];

            // 도로명 주소 우선 사용
            if (result['structure']['level0'] != null) {
              String address = _buildVWorldAddress(result['structure']);

              if (address.isNotEmpty) {
                setState(() {
                  _currentAddress = address;
                });
                return;
              }
            }

            // 지번 주소 사용 (백업)
            final text = result['text'] as String?;
            if (text != null && mounted) {
              setState(() {
                _currentAddress = text;
              });
              return;
            }
          }
        }
      }

      // 브이월드 API 실패 시 기본 좌표 표시
      if (mounted) {
        setState(() {
          _currentAddress = 'Coordinates: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
        });
      }
    } catch (e) {
      print('VWorld API 오류: $e');
      if (mounted) {
        setState(() {
          _currentAddress = 'Location: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}';
        });
      }
    }
  }

  // 브이월드 주소 구조체를 한국식 주소로 변환
  String _buildVWorldAddress(Map<String, dynamic> structure) {
    List<String> parts = [];

    // 시/도
    if (structure['level1'] != null) {
      parts.add(structure['level1']);
    }

    // 시/군/구
    if (structure['level2'] != null) {
      parts.add(structure['level2']);
    }

    // 읍/면/동
    if (structure['level4L'] != null) {
      parts.add(structure['level4L']);
    } else if (structure['level4A'] != null) {
      parts.add(structure['level4A']);
    }

    // 리
    if (structure['level5'] != null) {
      parts.add(structure['level5']);
    }

    // 도로명
    if (structure['detail'] != null) {
      parts.add(structure['detail']);
    }

    return parts.join(' ');
  }

  void _updateMapLocation() {
    if (_position == null || kIsWeb) return;

    double lat = _positionBuffer.length >= 3 ? _filteredLatitude : _position!.latitude;
    double lng = _positionBuffer.length >= 3 ? _filteredLongitude : _position!.longitude;

    try {
      _controller.runJavaScript('''
        updateLocation(${lat}, ${lng}, ${_position!.accuracy}, "${_gnssInfo}", "${_accuracyLevel}");
      ''').catchError((error) {
        print('VWorld 위치 업데이트 실패: $error');
      });
    } catch (e) {
      print('VWorld 위치 업데이트 실패: $e');
    }
  }

  String _generateVWorldMapHtml() {
    final apiKey = kIsWeb ? _vworldWebApiKey : _vworldAppApiKey;

    // HTML을 StringBuffer로 안전하게 생성
    final buffer = StringBuffer();
    buffer.write('<!DOCTYPE html><html><head>');
    buffer.write('<meta charset="utf-8">');
    buffer.write('<meta name="viewport" content="width=device-width, initial-scale=1.0">');
    buffer.write('<title>VWorld GPS Map</title>');
    buffer.write('<script type="text/javascript" src="https://map.vworld.kr/js/vworldMapInit.js.do?version=2.0&apiKey=$apiKey"></script>');
    buffer.write('<style>');
    buffer.write('body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }');
    buffer.write('#vworldMap { width: 100%; height: 100vh; }');
    buffer.write('.accuracy-indicator { position: absolute; top: 12px; right: 12px; background: rgba(33, 150, 243, 0.9); color: white; padding: 10px 14px; border-radius: 8px; font-size: 12px; font-weight: 600; z-index: 1000; box-shadow: 0 2px 10px rgba(0,0,0,0.15); }');
    buffer.write('.vworld-attribution { position: absolute; bottom: 8px; right: 8px; background: rgba(255,255,255,0.8); padding: 4px 8px; border-radius: 4px; font-size: 10px; color: #666; }');
    buffer.write('.map-controls { position: absolute; bottom: 50px; right: 12px; z-index: 1000; }');
    buffer.write('.control-btn { display: block; width: 40px; height: 40px; background: white; border: 1px solid #ccc; border-radius: 4px; margin-bottom: 4px; cursor: pointer; text-align: center; line-height: 38px; font-size: 16px; box-shadow: 0 2px 5px rgba(0,0,0,0.2); transition: background-color 0.2s; }');
    buffer.write('.control-btn:hover { background-color: #f0f0f0; }');
    buffer.write('.location-info { position: absolute; top: 12px; left: 12px; background: rgba(255, 255, 255, 0.95); padding: 12px 16px; border-radius: 10px; font-size: 13px; box-shadow: 0 3px 15px rgba(0,0,0,0.2); z-index: 1000; min-width: 160px; backdrop-filter: blur(10px); max-width: 250px; }');
    buffer.write('.info-row { display: flex; justify-content: space-between; margin: 4px 0; }');
    buffer.write('.info-label { font-weight: 600; color: #333; }');
    buffer.write('.info-value { color: #666; font-family: monospace; font-size: 12px; }');
    buffer.write('.backup-info { background: #f5f5f5; border-radius: 5px; font-family: monospace; font-size: 12px; padding: 10px; margin-top: 15px; }');
    buffer.write('</style></head><body>');
    buffer.write('<div id="vworldMap"></div>');
    buffer.write('<div class="location-info" id="locationInfo" style="display: none;">');
    buffer.write('<div class="info-row"><span class="info-label">위도:</span><span class="info-value" id="latValue">-</span></div>');
    buffer.write('<div class="info-row"><span class="info-label">경도:</span><span class="info-value" id="lngValue">-</span></div>');
    buffer.write('<div class="info-row"><span class="info-label">정확도:</span><span class="info-value" id="accValue">-</span></div>');
    buffer.write('</div>');
    buffer.write('<div class="accuracy-indicator" id="accuracyInfo">VWorld 지도 로딩중...</div>');
    buffer.write('<div class="map-controls">');
    buffer.write('<button class="control-btn" onclick="changeMapType(\'satellite\')" title="위성지도">🛰️</button>');
    buffer.write('<button class="control-btn" onclick="changeMapType(\'base\')" title="기본지도">🗺️</button>');
    buffer.write('<button class="control-btn" onclick="changeMapType(\'hybrid\')" title="하이브리드">🔄</button>');
    buffer.write('</div>');
    buffer.write('<div class="vworld-attribution">© VWorld (국토교통부)</div>');

    // JavaScript를 문자열로 직접 추가
    buffer.write('<script type="text/javascript">');
    buffer.write('var vworldMap, currentMarker, accuracyCircle, isMapInitialized = false, currentMapType = "base";');

    // VWorld 지도 초기화 함수
    buffer.write('function initializeVWorldMap() {');
    buffer.write('  console.log("VWorld 지도 초기화 시작");');
    buffer.write('  if (typeof vworld !== "undefined") {');
    buffer.write('    vworldMap = new vworld.Maps({ target: "vworldMap", center: new vworld.LonLat(127.0276, 37.4979), zoom: 15, apiKey: "$apiKey" });');
    buffer.write('    var baseLayer = new vworld.Layers.Base({ type: vworld.Layers.Base.TYPE.BASE });');
    buffer.write('    vworldMap.addLayer(baseLayer);');
    buffer.write('    vworldMap.on("loadend", function() { console.log("VWorld 지도 로드 완료"); isMapInitialized = true; document.getElementById("accuracyInfo").innerHTML = "VWorld 연결 완료"; document.getElementById("accuracyInfo").style.background = "rgba(76, 175, 80, 0.9)"; });');
    buffer.write('    console.log("VWorld 지도 초기화 완료");');
    buffer.write('  } else {');
    buffer.write('    console.error("VWorld 라이브러리 로드 실패");');
    buffer.write('    document.getElementById("accuracyInfo").innerHTML = "VWorld 연결 실패";');
    buffer.write('    document.getElementById("accuracyInfo").style.background = "rgba(244, 67, 54, 0.9)";');
    buffer.write('    initializeBackupMap();');
    buffer.write('  }');
    buffer.write('}');

    // 백업 지도 함수
    buffer.write('function initializeBackupMap() {');
    buffer.write('  console.log("백업 지도 초기화");');
    buffer.write('  var mapContainer = document.getElementById("vworldMap");');
    buffer.write('  mapContainer.innerHTML = "<div style=\\"width: 100%; height: 100%; background: linear-gradient(135deg, #e3f2fd, #bbdefb); display: flex; align-items: center; justify-content: center; flex-direction: column;\\"><div style=\\"background: white; padding: 20px; border-radius: 10px; text-align: center; box-shadow: 0 4px 10px rgba(0,0,0,0.1);\\"><h3 style=\\"margin: 0 0 10px 0; color: #1976d2;\\">🗺️ VWorld 지도</h3><p style=\\"margin: 0; color: #666; font-size: 14px;\\">한국 국토교통부 공식 지도 서비스<br>실시간 GPS 추적 활성화됨</p><div id=\\"backupGpsInfo\\" class=\\"backup-info\\">GPS 연결 대기중...</div></div></div>";');
    buffer.write('  isMapInitialized = true;');
    buffer.write('}');

    // 지도 타입 변경 함수
    buffer.write('function changeMapType(type) {');
    buffer.write('  if (!isMapInitialized || !vworldMap) return;');
    buffer.write('  vworldMap.getLayers().forEach(function(layer) { if (layer instanceof vworld.Layers.Base) { vworldMap.removeLayer(layer); } });');
    buffer.write('  var newLayer;');
    buffer.write('  if (type === "satellite") { newLayer = new vworld.Layers.Base({ type: vworld.Layers.Base.TYPE.SATELLITE }); }');
    buffer.write('  else if (type === "hybrid") { newLayer = new vworld.Layers.Base({ type: vworld.Layers.Base.TYPE.HYBRID }); }');
    buffer.write('  else { newLayer = new vworld.Layers.Base({ type: vworld.Layers.Base.TYPE.BASE }); }');
    buffer.write('  vworldMap.addLayer(newLayer);');
    buffer.write('  currentMapType = type;');
    buffer.write('  console.log("지도 타입 변경:", type);');
    buffer.write('}');

    // 위치 업데이트 함수
    buffer.write('function updateLocation(lat, lng, accuracy, gnssInfo, accuracyLevel) {');
    buffer.write('  console.log("위치 업데이트:", lat, lng, accuracy);');
    buffer.write('  if (vworldMap && isMapInitialized) { updateVWorldLocation(lat, lng, accuracy, gnssInfo, accuracyLevel); }');
    buffer.write('  else { updateBackupLocation(lat, lng, accuracy, gnssInfo, accuracyLevel); }');
    buffer.write('  document.getElementById("accuracyInfo").innerHTML = accuracyLevel + " (" + accuracy.toFixed(1) + "m)";');
    buffer.write('  document.getElementById("accuracyInfo").style.background = getAccuracyColor(accuracy);');
    buffer.write('  document.getElementById("latValue").innerHTML = lat.toFixed(6) + "°";');
    buffer.write('  document.getElementById("lngValue").innerHTML = lng.toFixed(6) + "°";');
    buffer.write('  document.getElementById("accValue").innerHTML = accuracy.toFixed(1) + "m";');
    buffer.write('  document.getElementById("locationInfo").style.display = "block";');
    buffer.write('}');

    // VWorld 위치 업데이트 함수
    buffer.write('function updateVWorldLocation(lat, lng, accuracy, gnssInfo, accuracyLevel) {');
    buffer.write('  if (currentMarker) { vworldMap.removeOverlay(currentMarker); }');
    buffer.write('  if (accuracyCircle) { vworldMap.removeOverlay(accuracyCircle); }');
    buffer.write('  var position = new vworld.LonLat(lng, lat);');
    buffer.write('  accuracyCircle = new vworld.Overlays.Circle({ center: position, radius: accuracy, strokeColor: getAccuracyColor(accuracy), strokeWidth: 2, fillColor: getAccuracyColor(accuracy), fillOpacity: 0.2 });');
    buffer.write('  vworldMap.addOverlay(accuracyCircle);');
    buffer.write('  currentMarker = new vworld.Overlays.Marker({ position: position });');
    buffer.write('  vworldMap.addOverlay(currentMarker);');
    buffer.write('  vworldMap.setCenter(position);');
    buffer.write('  var zoomLevel = accuracy <= 5 ? 18 : accuracy <= 15 ? 17 : accuracy <= 50 ? 16 : 15;');
    buffer.write('  vworldMap.setZoom(zoomLevel);');
    buffer.write('}');

    // 백업 위치 업데이트 함수
    buffer.write('function updateBackupLocation(lat, lng, accuracy, gnssInfo, accuracyLevel) {');
    buffer.write('  var gpsInfo = document.getElementById("backupGpsInfo");');
    buffer.write('  if (gpsInfo) {');
    buffer.write('    var info = "위도: " + lat.toFixed(6) + "°<br>경도: " + lng.toFixed(6) + "°<br>정확도: " + accuracy.toFixed(1) + "m<br>등급: " + accuracyLevel + "<br>상태: " + gnssInfo;');
    buffer.write('    gpsInfo.innerHTML = info;');
    buffer.write('    gpsInfo.style.color = accuracy <= 10 ? "#2e7d32" : accuracy <= 20 ? "#f57c00" : "#d32f2f";');
    buffer.write('  }');
    buffer.write('}');

    // 정확도 색상 함수
    buffer.write('function getAccuracyColor(accuracy) {');
    buffer.write('  if (accuracy <= 3) return "#4CAF50";');
    buffer.write('  if (accuracy <= 10) return "#2196F3";');
    buffer.write('  if (accuracy <= 20) return "#FF9800";');
    buffer.write('  return "#F44336";');
    buffer.write('}');

    // 초기화
    buffer.write('window.onload = function() {');
    buffer.write('  console.log("페이지 로드 완료, VWorld 지도 초기화 시작");');
    buffer.write('  setTimeout(function() { if (typeof vworld !== "undefined") { initializeVWorldMap(); } else { initializeBackupMap(); } }, 500);');
    buffer.write('};');

    buffer.write('window.updateLocation = updateLocation;');
    buffer.write('</script></body></html>');

    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GNSS Pro Tracker'),
      ),
      body: Column(
        children: [
          Expanded(
            child: !kIsWeb && _position != null
                ? WebViewWidget(controller: _controller)
                : const Center(child: Text('Map not available on web')),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Status: $_status'),
                Text('Address: $_currentAddress'),
                Text('GNSS Info: $_gnssInfo'),
                Text('Accuracy: $_accuracyLevel'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _sendEnhancedData,
                  child: const Text('Send Data'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _statusController.dispose();
    _positionStream?.cancel();
    _accuracyTimer?.cancel();
    super.dispose();
  }
}