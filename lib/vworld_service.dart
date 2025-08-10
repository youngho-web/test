import 'package:http/http.dart' as http;
import 'dart:convert';

class VWorldService {
  static const String _baseUrl = 'http://api.vworld.kr/req';
  static const String _webApiKey = '54269896-365E-3E09-A1F1-FD152D97E020';
  static const String _appApiKey = 'D30C2FFE-EA88-30E9-BBB9-71EED5A2DE15';

  /// VWorld 타일 서버 URL 템플릿 반환
  static String getTileUrlTemplate(String mapType) {
    switch (mapType) {
      case 'Base':
        return 'http://api.vworld.kr/req/wmts/1.0.0/$_webApiKey/Base/{z}/{y}/{x}.png';
      case 'Satellite':
        return 'http://api.vworld.kr/req/wmts/1.0.0/$_webApiKey/Satellite/{z}/{y}/{x}.jpeg';
      case 'Hybrid':
        return 'http://api.vworld.kr/req/wmts/1.0.0/$_webApiKey/Hybrid/{z}/{y}/{x}.png';
      case 'gray':
        return 'http://api.vworld.kr/req/wmts/1.0.0/$_webApiKey/gray/{z}/{y}/{x}.png';
      default:
        return 'http://api.vworld.kr/req/wmts/1.0.0/$_webApiKey/Base/{z}/{y}/{x}.png';
    }
  }

  /// 좌표를 주소로 변환 (Reverse Geocoding)
  static Future<String?> getAddressFromCoordinates(double latitude, double longitude) async {
    try {
      final String url = '$_baseUrl/address'
          '?service=address'
          '&request=getAddress'
          '&version=2.0'
          '&crs=epsg:4326'
          '&point=$longitude,$latitude'
          '&format=json'
          '&type=both'
          '&zipcode=true'
          '&simple=false'
          '&key=$_webApiKey';

      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(response.body);

        if (data['response']['status'] == 'OK' && data['response']['result'].isNotEmpty) {
          final result = data['response']['result'][0];
          final structure = result['structure'];
          final land = result['land'];

          String address = '';

          // 도로명 주소 우선 사용
          if (structure != null && structure['level4L'] != null) {
            address = '${structure['level1']} ${structure['level2']} ${structure['level3']} ${structure['level4L']}';
            if (structure['detail'] != null) {
              address += ' ${structure['detail']}';
            }
          }
          // 지번 주소 사용
          else if (land != null && land['number1'] != null) {
            address = '${land['level1']} ${land['level2']} ${land['level3']} ${land['level4A']}';
            if (land['number1'] != null) {
              address += ' ${land['number1']}';
              if (land['number2'] != null && land['number2'] != '') {
                address += '-${land['number2']}';
              }
            }
          }

          return address.isNotEmpty ? address : '주소를 찾을 수 없습니다';
        }
      }
    } catch (e) {
      print('주소 검색 오류: $e');
    }

    return null;
  }
}

