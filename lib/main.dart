import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'point.dart'; // GNSS 모듈 - 실제 파일명에 맞게 수정하세요
import 'vworld_service.dart';

void main() {
  runApp(const VWorldGpsApp());
}

class VWorldGpsApp extends StatelessWidget {
  const VWorldGpsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VWorld GPS App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // 권한 요청
    await _requestPermissions();

    // 잠시 대기 후 메인 화면으로 이동
    await Future.delayed(const Duration(seconds: 2));

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const MapScreen()),
      );
    }
  }

  Future<void> _requestPermissions() async {
    // 위치 권한 요청
    Map<Permission, PermissionStatus> permissions = await [
      Permission.location,
      Permission.locationWhenInUse,
      Permission.locationAlways,
    ].request();

    // 권한 상태 확인
    for (var entry in permissions.entries) {
      print('Permission ${entry.key}: ${entry.value}');
    }

    // 필수 권한이 거부된 경우 사용자에게 알림
    if (permissions[Permission.location] == PermissionStatus.permanentlyDenied ||
        permissions[Permission.locationWhenInUse] == PermissionStatus.permanentlyDenied) {
      // 설정으로 이동할 수 있도록 안내
      await openAppSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.blue,
      body: const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.location_on,
              size: 80,
              color: Colors.white,
            ),
            SizedBox(height: 20),
            Text(
              'VWorld GPS',
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '고정밀 GPS 위치 서비스',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white70,
              ),
            ),
            SizedBox(height: 40),
            CircularProgressIndicator(
              color: Colors.white,
            ),
          ],
        ),
      ),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  final GnssLocationService _locationService = GnssLocationService();

  String _statusMessage = 'GPS 초기화 중...';
  String _currentAddress = '주소를 가져오는 중...';
  EnhancedLocation? _currentLocation;
  bool _isGpsActive = false;
  String _currentMapType = 'Base';

  // 지도 중심점 (초기값: 서울시청)
  LatLng _mapCenter = LatLng(37.5665, 126.9780);
  double _mapZoom = 16.0;

  // 애니메이션 컨트롤러
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _startGpsTracking();
  }

  @override
  void dispose() {
    _locationService.stopTracking();
    _pulseController.dispose();
    super.dispose();
  }

  void _initializeAnimations() {
    _pulseController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    _pulseController.repeat(reverse: true);
  }

  Future<void> _startGpsTracking() async {
    try {
      print('Starting GPS tracking...');
      setState(() {
        _statusMessage = 'GPS 초기화 중...';
      });

      // 현재 위치 먼저 가져오기
      EnhancedLocation? initialLocation = await _locationService.getCurrentLocation();

      if (initialLocation != null) {
        print('Initial location acquired: ${initialLocation.effectiveLatitude}, ${initialLocation.effectiveLongitude}');

        // 지도 중심을 현재 위치로 이동
        _mapCenter = LatLng(initialLocation.effectiveLatitude, initialLocation.effectiveLongitude);
        _mapController.move(_mapCenter, _mapZoom);

        // 초기 위치 정보 설정
        setState(() {
          _currentLocation = initialLocation;
        });

        // 주소 가져오기
        _getAddressForLocation(initialLocation.effectiveLatitude, initialLocation.effectiveLongitude);
      }

      // GPS 추적 시작
      print('Starting continuous GPS tracking...');
      await _locationService.startTracking(
        onLocationUpdate: _onLocationUpdate,
        onError: _onError,
        onStatusUpdate: _onStatusUpdate,
      );

      setState(() {
        _isGpsActive = true;
        _statusMessage = 'GPS 추적 시작됨';
      });

      print('GPS tracking started successfully');
    } catch (e) {
      print('GPS tracking start failed: $e');
      _onError('GPS 시작 실패: $e');
    }
  }

  void _onLocationUpdate(EnhancedLocation location) async {
    setState(() {
      _currentLocation = location;
    });

    // 지도 중심을 새 위치로 부드럽게 이동
    LatLng newPosition = LatLng(location.effectiveLatitude, location.effectiveLongitude);
    _mapController.move(newPosition, _mapZoom);

    // 주소 가져오기
    _getAddressForLocation(location.effectiveLatitude, location.effectiveLongitude);
  }

  void _getAddressForLocation(double latitude, double longitude) async {
    try {
      String? address = await VWorldService.getAddressFromCoordinates(latitude, longitude);
      setState(() {
        _currentAddress = address ?? '주소를 찾을 수 없습니다';
      });
    } catch (e) {
      setState(() {
        _currentAddress = '주소 검색 오류';
      });
    }
  }

  void _onError(String error) {
    setState(() {
      _statusMessage = error;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _onStatusUpdate(String status) {
    setState(() {
      _statusMessage = status;
    });
  }

  void _toggleGps() async {
    if (_isGpsActive) {
      await _locationService.stopTracking();
      setState(() {
        _isGpsActive = false;
        _statusMessage = 'GPS 정지됨';
      });
    } else {
      await _startGpsTracking();
    }
  }

  void _restartGps() async {
    await _locationService.restartGps();
    setState(() {
      _statusMessage = 'GPS 재시작 중...';
    });
  }

  void _changeMapType() {
    List<String> mapTypes = ['Base', 'Satellite', 'Hybrid', 'gray'];
    int currentIndex = mapTypes.indexOf(_currentMapType);
    int nextIndex = (currentIndex + 1) % mapTypes.length;

    setState(() {
      _currentMapType = mapTypes[nextIndex];
    });
  }

  void _centerOnCurrentLocation() {
    if (_currentLocation != null) {
      LatLng currentPos = LatLng(_currentLocation!.effectiveLatitude, _currentLocation!.effectiveLongitude);
      _mapController.move(currentPos, _mapZoom);
    }
  }

  Color _getAccuracyColor(LocationAccuracyGrade? grade) {
    switch (grade) {
      case LocationAccuracyGrade.rtkGrade:
        return Colors.green;
      case LocationAccuracyGrade.surveyGrade:
        return Colors.lightGreen;
      case LocationAccuracyGrade.navigationGrade:
        return Colors.orange;
      case LocationAccuracyGrade.consumerGrade:
        return Colors.deepOrange;
      case LocationAccuracyGrade.lowAccuracy:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _getAccuracyText(LocationAccuracyGrade? grade) {
    switch (grade) {
      case LocationAccuracyGrade.rtkGrade:
        return 'RTK급';
      case LocationAccuracyGrade.surveyGrade:
        return '측량급';
      case LocationAccuracyGrade.navigationGrade:
        return '내비급';
      case LocationAccuracyGrade.consumerGrade:
        return '소비자급';
      case LocationAccuracyGrade.lowAccuracy:
        return '저정밀';
      default:
        return '알 수 없음';
    }
  }

  String _getMapTypeDisplayName(String mapType) {
    switch (mapType) {
      case 'Base':
        return '일반지도';
      case 'Satellite':
        return '위성지도';
      case 'Hybrid':
        return '하이브리드';
      case 'gray':
        return '회색지도';
      default:
        return '일반지도';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VWorld GPS 지도'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_isGpsActive ? Icons.gps_fixed : Icons.gps_not_fixed),
            onPressed: _toggleGps,
            tooltip: _isGpsActive ? 'GPS 정지' : 'GPS 시작',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _restartGps,
            tooltip: 'GPS 재시작',
          ),
          IconButton(
            icon: const Icon(Icons.layers),
            onPressed: _changeMapType,
            tooltip: '지도 타입 변경',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Flutter Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _mapCenter,
              initialZoom: _mapZoom,
              minZoom: 6.0,
              maxZoom: 18.0,
              onMapEvent: (MapEvent mapEvent) {
                if (mapEvent is MapEventMove) {
                  _mapZoom = mapEvent.camera.zoom;
                }
              },
            ),
            children: [
              // VWorld 타일 레이어
              TileLayer(
                urlTemplate: VWorldService.getTileUrlTemplate(_currentMapType),
                userAgentPackageName: 'com.example.vworld_gps_app',
                maxZoom: 18,
                tileBuilder: (context, widget, tile) {
                  return widget;
                },
              ),

              // 현재 위치 표시
              if (_currentLocation != null) ...[
                // 정확도 원
                CircleLayer(
                  circles: [
                    CircleMarker(
                      point: LatLng(_currentLocation!.effectiveLatitude, _currentLocation!.effectiveLongitude),
                      radius: _currentLocation!.accuracy,
                      useRadiusInMeter: true,
                      color: _getAccuracyColor(_currentLocation!.accuracyGrade).withOpacity(0.2),
                      borderColor: _getAccuracyColor(_currentLocation!.accuracyGrade),
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),

                // 현재 위치 마커
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(_currentLocation!.effectiveLatitude, _currentLocation!.effectiveLongitude),
                      width: 40,
                      height: 40,
                      child: AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Transform.scale(
                            scale: _pulseAnimation.value,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.3),
                                    blurRadius: 6,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.my_location,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),

          // 지도 타입 표시
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                _getMapTypeDisplayName(_currentMapType),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),

          // 현재 위치로 이동 버튼
          Positioned(
            bottom: 200,
            right: 16,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.blue,
              onPressed: _centerOnCurrentLocation,
              child: const Icon(Icons.my_location, color: Colors.white),
            ),
          ),

          // 상태 정보 패널
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 8,
                    offset: Offset(0, -2),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 상태 표시줄
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                    decoration: BoxDecoration(
                      color: _isGpsActive ? Colors.green.shade50 : Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _isGpsActive ? Colors.green : Colors.grey,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _isGpsActive ? Icons.gps_fixed : Icons.gps_off,
                          color: _isGpsActive ? Colors.green : Colors.grey,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _statusMessage,
                            style: TextStyle(
                              color: _isGpsActive ? Colors.green.shade800 : Colors.grey.shade700,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // 위치 정보
                  if (_currentLocation != null) ...[
                    Row(
                      children: [
                        const Icon(Icons.location_on, size: 16, color: Colors.red),
                        const SizedBox(width: 4),
                        const Text('위치', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: _getAccuracyColor(_currentLocation!.accuracyGrade),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _getAccuracyText(_currentLocation!.accuracyGrade),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _currentAddress,
                      style: const TextStyle(fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '정확도: ${_currentLocation!.accuracy.toStringAsFixed(1)}m',
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                        if (_currentLocation!.speed != null)
                          Text(
                            '속도: ${_currentLocation!.speedKmh.toStringAsFixed(1)}km/h',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '좌표: ${_currentLocation!.effectiveLatitude.toStringAsFixed(6)}, ${_currentLocation!.effectiveLongitude.toStringAsFixed(6)}',
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}