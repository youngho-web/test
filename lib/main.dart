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
  String _currentAddress = 'Loading address...'; // 주소 정보 추가
  bool _isConnected = false;

  final String _apiUrl = 'http://10.0.2.2:8000/api/sensor/';
  // API 키 없이 사용 가능한 오픈소스 지도로 변경

  late final WebViewController _controller;
  late final AnimationController _pulseController;
  late final AnimationController _statusController;
  StreamSubscription<Position>? _positionStream;
  Timer? _accuracyTimer;

  // GNSS 정확도 향상을 위한 변수들
  List<Position> _positionBuffer = [];
  final int _bufferSize = 10; // 5에서 10으로 증가 (더 많은 샘플로 정확도 향상)
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
      _initWebView(); // 웹이 아닐 때만 웹뷰 초기화
    }
    _startAccuracyMonitoring();
  }

  void _initWebView() {
    if (kIsWeb) return; // 웹에서는 웹뷰 초기화 하지 않음

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {},
          onPageStarted: (String url) {},
          onPageFinished: (String url) {
            // 지도가 로드된 후 현재 위치로 이동
            if (_position != null) {
              _updateMapLocation();
            }
          },
          onWebResourceError: (WebResourceError error) {},
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
    // 최고 정확도 설정 - 웹에서도 최대한 정밀하게
    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation, // 최고 정확도
      distanceFilter: 0, // 모든 위치 변화 감지
      timeLimit: Duration(seconds: 60), // 60초까지 기다림 (정확도 향상)
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

    // 주소 정보 가져오기
    _getAddressFromCoordinates(position.latitude, position.longitude);

    // 지도 위치 업데이트
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
              isError ? Icons.error_outline :
              isSuccess ? Icons.check_circle_outline : Icons.info_outline,
              color: Colors.white,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: isError ? Colors.red[600] :
        isSuccess ? Colors.green[600] : Colors.blue[600],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  // 좌표를 주소로 변환하는 함수 (Reverse Geocoding)
  Future<void> _getAddressFromCoordinates(double lat, double lng) async {
    try {
      setState(() {
        _currentAddress = 'Loading address...';
      });

      // OpenStreetMap Nominatim API 사용 (무료)
      final url = 'https://nominatim.openstreetmap.org/reverse?format=json&lat=$lat&lon=$lng&language=ko&addressdetails=1';

      print('주소 요청 URL: $url'); // 디버깅용

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'User-Agent': 'GNSS-Pro-Tracker/1.0',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      print('주소 API 응답 코드: ${response.statusCode}'); // 디버깅용
      print('주소 API 응답 내용: ${response.body}'); // 디버깅용

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final displayName = data['display_name'] as String?;

        if (displayName != null && mounted) {
          setState(() {
            // 주소를 간단하게 표시 (처음 100자만)
            _currentAddress = displayName.length > 100
                ? '${displayName.substring(0, 100)}...'
                : displayName;
          });
        } else {
          setState(() {
            _currentAddress = 'Address not found';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _currentAddress = 'Address lookup failed (${response.statusCode})';
          });
        }
      }
    } catch (e) {
      print('주소 변환 오류: $e'); // 디버깅용
      if (mounted) {
        setState(() {
          _currentAddress = 'Unable to get address: $e';
        });
      }
    }
  }

  String _generateVWorldMapHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Real-time GPS Map</title>
    <script src="https://cdn.jsdelivr.net/npm/ol@v8.2.0/dist/ol.js"></script>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/ol@v8.2.0/ol.css" type="text/css">
    <style>
        body { margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
        #map { width: 100%; height: 100vh; }
        .location-info {
            position: absolute;
            top: 12px;
            left: 12px;
            background: rgba(255, 255, 255, 0.95);
            padding: 12px 16px;
            border-radius: 10px;
            font-size: 13px;
            box-shadow: 0 3px 15px rgba(0,0,0,0.2);
            z-index: 1000;
            min-width: 160px;
            backdrop-filter: blur(10px);
        }
        .accuracy-indicator {
            position: absolute;
            top: 12px;
            right: 12px;
            background: rgba(33, 150, 243, 0.9);
            color: white;
            padding: 10px 14px;
            border-radius: 8px;
            font-size: 12px;
            font-weight: 600;
            z-index: 1000;
            box-shadow: 0 2px 10px rgba(0,0,0,0.15);
        }
        .info-row {
            display: flex;
            justify-content: space-between;
            margin: 4px 0;
        }
        .info-label {
            font-weight: 600;
            color: #333;
        }
        .info-value {
            color: #666;
            font-family: monospace;
            font-size: 12px;
        }
        .status-text {
            font-size: 11px;
            color: #888;
            margin-top: 6px;
            font-style: italic;
        }
        .map-attribution {
            position: absolute;
            bottom: 8px;
            right: 8px;
            background: rgba(255,255,255,0.8);
            padding: 4px 8px;
            border-radius: 4px;
            font-size: 10px;
            color: #666;
        }
    </style>
</head>
<body>
    <div id="map"></div>
    <!-- 위도/경도 정보 패널 제거 -->
    <div class="accuracy-indicator" id="accuracyInfo">
        GPS 연결 대기
    </div>
    <div class="map-attribution">
        © OpenStreetMap contributors
    </div>

    <script type="text/javascript">
        var map;
        var currentMarker;
        var accuracyCircle;
        var vectorSource;
        var isMapInitialized = false;

        // 지도 초기화 함수
        function initializeMap() {
            try {
                console.log("OpenStreetMap 지도 초기화 시작");
                
                // Vector source for markers and circles
                vectorSource = new ol.source.Vector();
                
                var vectorLayer = new ol.layer.Vector({
                    source: vectorSource,
                    style: function(feature) {
                        var type = feature.get('type');
                        if (type === 'accuracy') {
                            return new ol.style.Style({
                                fill: new ol.style.Fill({
                                    color: 'rgba(33, 150, 243, 0.15)'
                                }),
                                stroke: new ol.style.Stroke({
                                    color: feature.get('strokeColor') || 'rgba(33, 150, 243, 0.8)',
                                    width: 2
                                })
                            });
                        } else if (type === 'location') {
                            return new ol.style.Style({
                                image: new ol.style.Circle({
                                    radius: 8,
                                    fill: new ol.style.Fill({
                                        color: feature.get('fillColor') || '#2196F3'
                                    }),
                                    stroke: new ol.style.Stroke({
                                        color: '#FFFFFF',
                                        width: 3
                                    })
                                })
                            });
                        }
                    }
                });

                // 지도 생성
                map = new ol.Map({
                    target: 'map',
                    layers: [
                        // OpenStreetMap 타일 레이어
                        new ol.layer.Tile({
                            source: new ol.source.OSM()
                        }),
                        vectorLayer
                    ],
                    view: new ol.View({
                        center: ol.proj.fromLonLat([127.0276, 37.4979]), // 서울 중심
                        zoom: 15,
                        minZoom: 5,
                        maxZoom: 20
                    })
                });
                
                isMapInitialized = true;
                console.log("지도 초기화 완료");
                
                // 초기화 완료 - 정보 패널 업데이트 제거
                    
            } catch (error) {
                console.error("지도 초기화 실패:", error);
                // 에러 시에도 정보 패널 업데이트 제거
                document.getElementById('accuracyInfo').innerHTML = "연결 실패";
                document.getElementById('accuracyInfo').style.background = "rgba(244, 67, 54, 0.9)";
            }
        }

        // 위치 업데이트 함수
        function updateLocation(lat, lng, accuracy, gnssInfo, accuracyLevel) {
            if (!isMapInitialized) {
                console.log("지도가 아직 초기화되지 않음");
                return;
            }

            try {
                console.log("위치 업데이트:", lat, lng, accuracy);
                
                // 기존 마커와 정확도 원 제거
                vectorSource.clear();

                // 좌표 변환 (WGS84 -> Web Mercator)
                var coordinate = ol.proj.fromLonLat([lng, lat]);
                
                // 정확도 원 생성
                var circle = new ol.geom.Circle(coordinate, accuracy);
                var circleFeature = new ol.Feature({
                    geometry: circle,
                    type: 'accuracy',
                    strokeColor: getAccuracyColor(accuracy)
                });
                vectorSource.addFeature(circleFeature);

                // 현재 위치 마커 생성
                var point = new ol.geom.Point(coordinate);
                var pointFeature = new ol.Feature({
                    geometry: point,
                    type: 'location',
                    fillColor: getAccuracyColor(accuracy)
                });
                vectorSource.addFeature(pointFeature);

                // 지도 중심 이동 및 줌 조정
                map.getView().setCenter(coordinate);
                
                // 정확도에 따른 줌 레벨 자동 조정
                var zoomLevel;
                if (accuracy <= 5) zoomLevel = 18;      // 매우 정확함
                else if (accuracy <= 15) zoomLevel = 17; // 정확함
                else if (accuracy <= 50) zoomLevel = 16; // 보통
                else zoomLevel = 15;                     // 낮음
                
                map.getView().setZoom(zoomLevel);

                // 정확도 표시기만 업데이트 (정보 패널은 제거)
                document.getElementById('accuracyInfo').innerHTML = accuracyLevel;
                document.getElementById('accuracyInfo').style.background = getAccuracyColor(accuracy);

            } catch (error) {
                console.error("위치 업데이트 실패:", error);
                // 에러 메시지도 정확도 표시기에만 표시
                document.getElementById('accuracyInfo').innerHTML = "GPS 오류";
                document.getElementById('accuracyInfo').style.background = "#F44336";
            }
        }

        function getAccuracyColor(accuracy) {
            if (accuracy <= 3) return '#4CAF50';      // 녹색 - 매우 정확
            if (accuracy <= 10) return '#2196F3';    // 파란색 - 정확
            if (accuracy <= 20) return '#FF9800';    // 주황색 - 보통
            return '#F44336';                         // 빨간색 - 낮음
        }

        // 페이지 로드 시 지도 초기화
        window.onload = function() {
            console.log("페이지 로드 완료, 지도 초기화 시작");
            
            // OpenLayers 라이브러리 로드 확인
            if (typeof ol !== 'undefined') {
                console.log("OpenLayers 라이브러리 로드 확인됨");
                setTimeout(initializeMap, 200);
            } else {
                console.error("OpenLayers 라이브러리 로드 실패");
                // 에러 시에도 정확도 표시기에만 표시
                document.getElementById('accuracyInfo').innerHTML = "라이브러리 오류";
                document.getElementById('accuracyInfo').style.background = "#F44336";
            }
        };

        // Flutter에서 호출할 수 있도록 전역 함수로 등록
        window.updateLocation = updateLocation;
    </script>
</body>
</html>
    ''';
  }

  void _updateMapLocation() {
    if (kIsWeb || _controller == null) return; // 웹이거나 컨트롤러가 null이면 리턴

    if (_position != null) {
      final lat = _position!.latitude;
      final lng = _position!.longitude;
      final accuracy = _position!.accuracy;

      // JavaScript 함수 호출
      _controller!.runJavaScript('''
        if (window.updateLocation) {
          window.updateLocation($lat, $lng, $accuracy, "$_gnssInfo", "$_accuracyLevel");
        }
      ''');
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _statusController.dispose();
    _positionStream?.cancel();
    _accuracyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text(
          'GNSS Pro Tracker',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        actions: [
          IconButton(
            icon: AnimatedBuilder(
              animation: _pulseController,
              builder: (context, child) {
                return Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: _isConnected ? [
                      BoxShadow(
                        color: Colors.green.withOpacity(0.5 * _pulseController.value),
                        blurRadius: 8 * _pulseController.value,
                        spreadRadius: 2 * _pulseController.value,
                      ),
                    ] : null,
                  ),
                  child: Icon(
                    _isConnected ? Icons.gps_fixed : Icons.gps_not_fixed,
                    color: _isConnected ? Colors.green : Colors.grey,
                  ),
                );
              },
            ),
            onPressed: _resetLocationStream,
          ),
        ],
      ),
      body: Column(
        children: [
          // Status Header
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  _getAccuracyColor().withOpacity(0.8),
                  _getAccuracyColor().withOpacity(0.6),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: _getAccuracyColor().withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _accuracyLevel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        '${_position?.accuracy?.toStringAsFixed(1) ?? "N/A"} m',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _gnssInfo,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _status,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 12,
                  ),
                ),
                // 정확도 개선 안내 추가
                if (_position != null && _position!.accuracy > 10)
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.tips_and_updates,
                            color: Colors.white, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '정확도 향상을 위해 실외에서 1-2분 기다려주세요',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Data Cards
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  // Location Data Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.location_on,
                                  color: colorScheme.primary),
                              const SizedBox(width: 8),
                              const Text(
                                'Location Data',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildDataRow('Latitude', '${_position?.latitude?.toStringAsFixed(8) ?? "N/A"}°'),
                          _buildDataRow('Longitude', '${_position?.longitude?.toStringAsFixed(8) ?? "N/A"}°'),
                          const Divider(height: 24),
                          // 주소 정보 추가
                          _buildAddressRow('Address', _currentAddress),
                          if (_positionBuffer.length >= 3) ...[
                            const Divider(height: 24),
                            _buildDataRow('Filtered Lat', '${_filteredLatitude.toStringAsFixed(8)}°',
                                isHighlighted: true),
                            _buildDataRow('Filtered Lng', '${_filteredLongitude.toStringAsFixed(8)}°',
                                isHighlighted: true),
                          ],
                          const Divider(height: 24),
                          _buildDataRow('Altitude', '${_position?.altitude?.toStringAsFixed(1) ?? "N/A"} m'),
                          _buildDataRow('Speed', '${((_position?.speed ?? 0) * 3.6).toStringAsFixed(1)} km/h'),
                          _buildDataRow('Heading', '${_position?.heading?.toStringAsFixed(1) ?? "N/A"}°'),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Motion Sensors Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.sensors,
                                  color: colorScheme.primary),
                              const SizedBox(width: 8),
                              const Text(
                                'Motion Sensors',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildDataRow('Accel X', '${_accelerometer?.x?.toStringAsFixed(2) ?? "N/A"} m/s²'),
                          _buildDataRow('Accel Y', '${_accelerometer?.y?.toStringAsFixed(2) ?? "N/A"} m/s²'),
                          _buildDataRow('Accel Z', '${_accelerometer?.z?.toStringAsFixed(2) ?? "N/A"} m/s²'),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          onPressed: _sendEnhancedData,
                          icon: const Icon(Icons.send),
                          label: const Text('Transmit Data'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _resetLocationStream,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reset'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16),

                  // Map View Card
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(Icons.map, color: colorScheme.primary),
                              const SizedBox(width: 8),
                              const Text(
                                'Real-time GPS Map',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.check_circle, size: 12, color: Colors.green),
                                    const SizedBox(width: 4),
                                    Text(
                                      'No API Key Required',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.green.shade700,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 300,
                          child: kIsWeb
                              ? _buildWebMap() // 웹에서도 실제 지도 표시
                              : ClipRRect(
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            ),
                            child: _controller != null
                                ? WebViewWidget(controller: _controller!)
                                : _buildWebPlaceholder(),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDataRow(String label, String value, {bool isHighlighted = false}) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: colorScheme.onSurface.withOpacity(0.7),
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: isHighlighted ? colorScheme.primary : colorScheme.onSurface,
              fontSize: 14,
              fontWeight: isHighlighted ? FontWeight.w600 : FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddressRow(String label, String address) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.location_on,
                size: 16,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: colorScheme.onSurface.withOpacity(0.7),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surfaceVariant.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.outline.withOpacity(0.2),
              ),
            ),
            child: Text(
              address,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                height: 1.3,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Color _getAccuracyColor() {
    if (_position?.accuracy == null) return Colors.grey;
    if (_position!.accuracy <= 3) return Colors.green;
    if (_position!.accuracy <= 10) return Colors.blue;
    if (_position!.accuracy <= 20) return Colors.orange;
    return Colors.red;
  }

  void _resetLocationStream() {
    _positionStream?.cancel();
    _positionBuffer.clear();
    setState(() {
      _status = 'Reacquiring satellites...';
      _isConnected = false;
    });
    _startHighAccuracyLocationStream();

    // 지도 다시 로드 (웹이 아닐 때만)
    if (!kIsWeb && _controller != null) {
      _controller!.loadHtmlString(_generateVWorldMapHtml());
    }
    _showSnackBar('GPS 및 지도 재설정');
  }

  Widget _buildWebMap() {
    // 웹에서 사용할 지도 - 간단하고 확실한 방식
    final lat = _position?.latitude ?? 37.4979;
    final lng = _position?.longitude ?? 127.0276;

    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
        child: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.blue.shade100,
                Colors.blue.shade200,
                Colors.blue.shade300,
              ],
            ),
          ),
          child: Stack(
            children: [
              // 지도 격자 배경
              CustomPaint(
                size: Size.infinite,
                painter: WebMapPainter(
                  lat: lat,
                  lng: lng,
                  accuracy: _position?.accuracy ?? 0,
                  isConnected: _isConnected,
                ),
              ),

              // 지도 위 정보 오버레이
              if (_position != null)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Lat: ${lat.toStringAsFixed(6)}°',
                          style: const TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          'Lng: ${lng.toStringAsFixed(6)}°',
                          style: const TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          'Acc: ${_position!.accuracy.toStringAsFixed(1)}m',
                          style: const TextStyle(
                            fontSize: 10,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // 실제 지도 보기 버튼
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: InkWell(
                    onTap: () {
                      if (_position != null) {
                        _openExternalMap();
                      }
                    },
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          const Icon(
                            Icons.map,
                            size: 18,
                            color: Colors.white,
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Full Map',
                            style: TextStyle(
                              fontSize: 8,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // 중앙에 주소 표시 (지도가 로딩되지 않을 때)
              if (_currentAddress != 'Loading address...' && _currentAddress != 'Unable to get address')
                Positioned(
                  bottom: 50,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.95),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.location_on,
                              size: 16,
                              color: Colors.blue,
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'Current Address',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _currentAddress,
                          style: const TextStyle(
                            fontSize: 11,
                            height: 1.3,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),

              // 하단 저작권
              Positioned(
                bottom: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '© OpenStreetMap',
                    style: TextStyle(
                      fontSize: 8,
                      color: Colors.grey,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openExternalMap() {
    if (_position == null) return;

    final lat = _position!.latitude;
    final lng = _position!.longitude;
    final url = 'https://www.openstreetmap.org/?mlat=$lat&mlon=$lng&zoom=16';

    if (kIsWeb) {
      // 웹에서는 URL을 클립보드에 복사하는 것처럼 표시
      _showSnackBar('Copy this URL: $url', isSuccess: true);
      print('OpenStreetMap URL: $url'); // 개발자 콘솔에 출력
    } else {
      // 모바일에서는 좌표를 표시
      _showSnackBar('Coordinates: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}', isSuccess: true);
    }
  }

  // 웹에서 URL을 여는 함수 (dart:html 대체)
  void openUrlInNewTab(String url) {
    if (kIsWeb) {
      // Flutter Web에서 URL을 여는 안전한 방법
      _showSnackBar('Map URL: $url', isSuccess: true);
    }
  }

  void _createMapElement(double lat, double lng, int zoom) {
    // 이 함수는 더 이상 사용하지 않음
  }

  Widget _buildWebPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.blue.shade50,
            Colors.blue.shade100,
          ],
        ),
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.web,
              size: 48,
              color: Colors.blue.shade300,
            ),
            const SizedBox(height: 16),
            Text(
              'Map View Available on Mobile',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.blue.shade700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Real-time GPS tracking works on all platforms\nMap visualization requires mobile app',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.blue.shade600,
              ),
            ),
            const SizedBox(height: 16),
            // GPS 상태 표시
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.8),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isConnected ? Icons.gps_fixed : Icons.gps_not_fixed,
                        size: 16,
                        color: _isConnected ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _status,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _isConnected ? Colors.green : Colors.orange,
                        ),
                      ),
                    ],
                  ),
                  if (_position != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Lat: ${_position!.latitude.toStringAsFixed(6)}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      'Lng: ${_position!.longitude.toStringAsFixed(6)}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      'Accuracy: ${_position!.accuracy.toStringAsFixed(1)}m',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      'GPS 신호를 찾는 중...',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!_isConnected) ...[
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () {
                  _resetLocationStream();
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('GPS 재시작'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// 웹용 지도 그리기 커스텀 페인터
class WebMapPainter extends CustomPainter {
  final double lat;
  final double lng;
  final double accuracy;
  final bool isConnected;

  WebMapPainter({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.isConnected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();

    // 지도 배경 (격자 형태로 지도 느낌 연출)
    paint.color = Colors.grey.shade300;
    paint.strokeWidth = 0.5;

    // 세로 격자선
    for (int i = 0; i <= 20; i++) {
      final x = (size.width / 20) * i;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // 가로 격자선
    for (int i = 0; i <= 10; i++) {
      final y = (size.height / 10) * i;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // 지도 영역 표시 (건물/도로 블록 시뮬레이션)
    paint.color = Colors.grey.shade400;
    paint.style = PaintingStyle.fill;

    // 몇 개의 사각형으로 건물/블록 표현
    final rects = [
      Rect.fromLTWH(size.width * 0.1, size.height * 0.2, size.width * 0.15, size.height * 0.1),
      Rect.fromLTWH(size.width * 0.3, size.height * 0.1, size.width * 0.2, size.height * 0.15),
      Rect.fromLTWH(size.width * 0.6, size.height * 0.3, size.width * 0.18, size.height * 0.12),
      Rect.fromLTWH(size.width * 0.15, size.height * 0.6, size.width * 0.25, size.height * 0.2),
      Rect.fromLTWH(size.width * 0.7, size.height * 0.7, size.width * 0.15, size.height * 0.15),
    ];

    for (final rect in rects) {
      canvas.drawRect(rect, paint);
    }

    // 도로 표시
    paint.color = Colors.white;
    paint.strokeWidth = 3;

    // 메인 도로 (가로)
    canvas.drawLine(
      Offset(0, size.height * 0.4),
      Offset(size.width, size.height * 0.4),
      paint,
    );

    // 메인 도로 (세로)
    canvas.drawLine(
      Offset(size.width * 0.4, 0),
      Offset(size.width * 0.4, size.height),
      paint,
    );

    if (isConnected) {
      // GPS 위치가 있으면 마커 표시
      final centerX = size.width * 0.5;
      final centerY = size.height * 0.5;

      // 정확도 원 그리기
      paint.color = _getAccuracyColor(accuracy).withOpacity(0.2);
      paint.style = PaintingStyle.fill;
      final radius = (accuracy / 10).clamp(10.0, 50.0); // 정확도에 따른 원 크기
      canvas.drawCircle(Offset(centerX, centerY), radius, paint);

      // 정확도 원 테두리
      paint.color = _getAccuracyColor(accuracy);
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 2;
      canvas.drawCircle(Offset(centerX, centerY), radius, paint);

      // GPS 마커 (중앙점)
      paint.color = _getAccuracyColor(accuracy);
      paint.style = PaintingStyle.fill;
      canvas.drawCircle(Offset(centerX, centerY), 8, paint);

      // 마커 테두리 (흰색)
      paint.color = Colors.white;
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 3;
      canvas.drawCircle(Offset(centerX, centerY), 8, paint);
    }
  }

  Color _getAccuracyColor(double accuracy) {
    if (accuracy <= 3) return Colors.green;
    if (accuracy <= 10) return Colors.blue;
    if (accuracy <= 20) return Colors.orange;
    return Colors.red;
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}