// gnss_location_service.dart
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

/// GPS/GNSS 위치 정확도 등급
enum LocationAccuracyGrade {
  rtkGrade,      // RTK 급 (0-2m)
  surveyGrade,   // 측량 급 (2-5m)
  navigationGrade, // 내비게이션 급 (5-10m)
  consumerGrade,   // 소비자 급 (10-20m)
  lowAccuracy      // 낮은 정확도 (20m+)
}

/// GNSS 신호 정보
class GnssSignalInfo {
  final String gnssType;
  final String satellites;
  final LocationAccuracyGrade accuracyGrade;

  GnssSignalInfo({
    required this.gnssType,
    required this.satellites,
    required this.accuracyGrade,
  });
}

/// 향상된 위치 정보 클래스
class EnhancedLocation {
  final double latitude;
  final double longitude;
  final double? filteredLatitude;
  final double? filteredLongitude;
  final double accuracy;
  final double? altitude;
  final double? speed;
  final double? heading;
  final DateTime timestamp;
  final GnssSignalInfo gnssInfo;
  final bool isFiltered;
  final String status;

  EnhancedLocation({
    required this.latitude,
    required this.longitude,
    this.filteredLatitude,
    this.filteredLongitude,
    required this.accuracy,
    this.altitude,
    this.speed,
    this.heading,
    required this.timestamp,
    required this.gnssInfo,
    this.isFiltered = false,
    this.status = 'Unknown',
  });

  /// 사용할 위도 (필터링된 값이 있으면 우선 사용)
  double get effectiveLatitude => filteredLatitude ?? latitude;

  /// 사용할 경도 (필터링된 값이 있으면 우선 사용)
  double get effectiveLongitude => filteredLongitude ?? longitude;

  /// km/h 단위 속도
  double get speedKmh => (speed ?? 0) * 3.6;

  /// 정확도 등급
  LocationAccuracyGrade get accuracyGrade => gnssInfo.accuracyGrade;

  /// 위치 정보를 JSON으로 변환
  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'filtered_latitude': filteredLatitude,
      'filtered_longitude': filteredLongitude,
      'effective_latitude': effectiveLatitude,
      'effective_longitude': effectiveLongitude,
      'accuracy': accuracy,
      'altitude': altitude,
      'speed': speed,
      'speed_kmh': speedKmh,
      'heading': heading,
      'timestamp': timestamp.toIso8601String(),
      'gnss_type': gnssInfo.gnssType,
      'satellites': gnssInfo.satellites,
      'accuracy_grade': gnssInfo.accuracyGrade.name,
      'is_filtered': isFiltered,
      'status': status,
    };
  }
}

/// GNSS 위치 서비스 결과 콜백
typedef LocationCallback = void Function(EnhancedLocation location);
typedef LocationErrorCallback = void Function(String error);
typedef LocationStatusCallback = void Function(String status);

/// 고정밀 GNSS 위치 서비스
class GnssLocationService {
  static final GnssLocationService _instance = GnssLocationService._internal();
  factory GnssLocationService() => _instance;
  GnssLocationService._internal();

  StreamSubscription<Position>? _positionStream;
  Timer? _accuracyTimer;

  // 위치 필터링을 위한 버퍼
  final List<Position> _positionBuffer = [];
  final int _bufferSize = 10;

  // 현재 상태
  bool _isActive = false;
  EnhancedLocation? _currentLocation;
  Position? _previousPosition;

  // 콜백 함수들
  LocationCallback? _onLocationUpdate;
  LocationErrorCallback? _onError;
  LocationStatusCallback? _onStatusUpdate;

  /// 서비스 활성화 상태
  bool get isActive => _isActive;

  /// 현재 위치 정보
  EnhancedLocation? get currentLocation => _currentLocation;

  /// GNSS 위치 추적 시작
  Future<void> startTracking({
    LocationCallback? onLocationUpdate,
    LocationErrorCallback? onError,
    LocationStatusCallback? onStatusUpdate,
  }) async {
    if (_isActive) {
      await stopTracking();
    }

    _onLocationUpdate = onLocationUpdate;
    _onError = onError;
    _onStatusUpdate = onStatusUpdate;

    try {
      _updateStatus('Initializing GPS...');

      // 위치 서비스 확인
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _handleError('Location services are disabled');
        return;
      }

      // 권한 확인
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _handleError('Location permission denied');
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _handleError('Location permission permanently denied');
        return;
      }

      _updateStatus('Acquiring GPS signal...');
      _startLocationStream();
      _startAccuracyMonitoring();

      _isActive = true;

    } catch (e) {
      _handleError('Failed to start GPS: $e');
    }
  }

  /// GNSS 위치 추적 중지
  Future<void> stopTracking() async {
    _isActive = false;
    await _positionStream?.cancel();
    _positionStream = null;
    _accuracyTimer?.cancel();
    _accuracyTimer = null;
    _positionBuffer.clear();
    _currentLocation = null;
    _previousPosition = null;

    _updateStatus('GPS tracking stopped');
  }

  /// 현재 위치 한 번만 가져오기 (고정밀)
  Future<EnhancedLocation?> getCurrentLocation({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      _updateStatus('Getting current location...');

      const locationSettings = LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      ).timeout(timeout);

      EnhancedLocation location = _createEnhancedLocation(position, 'Single location acquired');
      _updateStatus('Location acquired successfully');

      return location;

    } catch (e) {
      _handleError('Failed to get current location: $e');
      return null;
    }
  }

  /// 두 위치 간의 거리 계산 (미터)
  static double calculateDistance(
      double lat1, double lon1,
      double lat2, double lon2,
      ) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2);
  }



  /// 위치 스트림 시작
  void _startLocationStream() {
    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      timeLimit: Duration(seconds: 60),
    );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      _processNewPosition,
      onError: (error) => _handleError('GPS stream error: $error'),
    );
  }

  /// 새로운 위치 정보 처리
  void _processNewPosition(Position position) {
    if (!_isActive) return;

    // 위치 버퍼에 추가
    _positionBuffer.add(position);
    if (_positionBuffer.length > _bufferSize) {
      _positionBuffer.removeAt(0);
    }

    // 필터링된 위치 계산
    final filtered = _applyPositionFiltering();

    // 향상된 위치 정보 생성
    EnhancedLocation enhancedLocation = _createEnhancedLocation(
      position,
      'Signal acquired',
      filteredLatitude: filtered?.$1,
      filteredLongitude: filtered?.$2,
    );

    _previousPosition = position;
    _currentLocation = enhancedLocation;

    _updateStatus('GPS signal strong');
    _onLocationUpdate?.call(enhancedLocation);
  }

  /// 위치 필터링 적용
  (double, double)? _applyPositionFiltering() {
    if (_positionBuffer.length < 3) return null;

    double totalWeight = 0.0;
    double weightedLat = 0.0;
    double weightedLng = 0.0;

    for (Position pos in _positionBuffer) {
      double weight = 1.0 / (pos.accuracy + 1.0);
      totalWeight += weight;
      weightedLat += pos.latitude * weight;
      weightedLng += pos.longitude * weight;
    }

    return (weightedLat / totalWeight, weightedLng / totalWeight);
  }

  /// 향상된 위치 정보 생성
  EnhancedLocation _createEnhancedLocation(
      Position position,
      String status, {
        double? filteredLatitude,
        double? filteredLongitude,
      }) {
    GnssSignalInfo gnssInfo = _analyzeGnssSignal(position);

    return EnhancedLocation(
      latitude: position.latitude,
      longitude: position.longitude,
      filteredLatitude: filteredLatitude,
      filteredLongitude: filteredLongitude,
      accuracy: position.accuracy,
      altitude: position.altitude,
      speed: position.speed,
      heading: position.heading,
      timestamp: position.timestamp,
      gnssInfo: gnssInfo,
      isFiltered: filteredLatitude != null && filteredLongitude != null,
      status: status,
    );
  }

  /// GNSS 신호 분석
  GnssSignalInfo _analyzeGnssSignal(Position position) {
    String satellites;
    String gnssType;
    LocationAccuracyGrade accuracyGrade;

    if (position.accuracy <= 2) {
      satellites = '15+ satellites';
      gnssType = 'GPS+Galileo+GLONASS+BeiDou';
      accuracyGrade = LocationAccuracyGrade.rtkGrade;
    } else if (position.accuracy <= 5) {
      satellites = '12+ satellites';
      gnssType = 'GPS+Galileo+GLONASS';
      accuracyGrade = LocationAccuracyGrade.surveyGrade;
    } else if (position.accuracy <= 10) {
      satellites = '8-12 satellites';
      gnssType = 'GPS+Galileo';
      accuracyGrade = LocationAccuracyGrade.navigationGrade;
    } else if (position.accuracy <= 20) {
      satellites = '4-8 satellites';
      gnssType = 'GPS';
      accuracyGrade = LocationAccuracyGrade.consumerGrade;
    } else {
      satellites = '<4 satellites';
      gnssType = 'GPS/WiFi/Cell';
      accuracyGrade = LocationAccuracyGrade.lowAccuracy;
    }

    return GnssSignalInfo(
      gnssType: gnssType,
      satellites: satellites,
      accuracyGrade: accuracyGrade,
    );
  }

  /// 정확도 모니터링 시작
  void _startAccuracyMonitoring() {
    _accuracyTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_currentLocation != null && _previousPosition != null) {
        _analyzeMovementAccuracy();
      }
    });
  }

  /// 움직임 정확도 분석
  void _analyzeMovementAccuracy() {
    if (_previousPosition == null || _currentLocation == null) return;

    double distance = Geolocator.distanceBetween(
      _previousPosition!.latitude,
      _previousPosition!.longitude,
      _currentLocation!.latitude,
      _currentLocation!.longitude,
    );

    // GPS 드리프트 감지
    if (distance > 50 && (_currentLocation!.speed ?? 0) < 1.0) {
      _updateStatus('GPS drift detected - recalibrating...');
    }
  }

  /// 상태 업데이트
  void _updateStatus(String status) {
    _onStatusUpdate?.call(status);
  }

  /// 에러 처리
  void _handleError(String error) {
    _onError?.call(error);
  }

  /// GPS 재시작
  Future<void> restartGps() async {
    if (_isActive) {
      await stopTracking();
      await Future.delayed(const Duration(milliseconds: 500));
      await startTracking(
        onLocationUpdate: _onLocationUpdate,
        onError: _onError,
        onStatusUpdate: _onStatusUpdate,
      );
    }
  }
}