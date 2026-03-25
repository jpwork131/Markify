import 'dart:convert';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class LicenseService {
  static const String baseUrl = 'https://markify-backend-3ylb.onrender.com';

  static Future<String> getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isWindows) {
      final windowsInfo = await deviceInfo.windowsInfo;
      return windowsInfo.deviceId; // Motherboard/System UUID
    } else if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.id;
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.identifierForVendor ?? 'ios-unknown';
    } else if (Platform.isMacOS) {
      final macInfo = await deviceInfo.macOsInfo;
      return macInfo.systemGUID ?? 'macos-unknown';
    }
    return 'unknown-device';
  }

  static Future<Map<String, dynamic>> validateLicense(String email, String licenseKey) async {
    final deviceId = await getDeviceId();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/validate-license'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'license_key': licenseKey,
          'device_id': deviceId,
        }),
      );

      final data = jsonDecode(response.body);
      if (response.statusCode == 200) {
        // Save locally
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('license_email', email);
        await prefs.setString('license_key', licenseKey);
        await prefs.setString('license_expiry', data['expiry_date']);
        await prefs.setInt('last_online_check', DateTime.now().millisecondsSinceEpoch);
        return {'success': true, 'data': data};
      } else {
        return {'success': false, 'message': data['message'] ?? 'Validation failed'};
      }
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  static Future<bool> checkLicense() async {
    final prefs = await SharedPreferences.getInstance();
    final licenseKey = prefs.getString('license_key');
    if (licenseKey == null) return false;

    final deviceId = await getDeviceId();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/check-license'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'license_key': licenseKey,
          'device_id': deviceId,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 'valid') {
          await prefs.setInt('last_online_check', DateTime.now().millisecondsSinceEpoch);
          return true;
        }
      }
    } catch (e) {
      print('Offline: Checking local cached validation...');
    }

    // fallback for offline check
    final expiry = prefs.getString('license_expiry');
    final lastCheck = prefs.getInt('last_online_check') ?? 0;
    
    if (expiry != null) {
      final expiryDate = DateTime.parse(expiry);
      final now = DateTime.now();
      
      // Strict rule: License must not be expired locally
      if (now.isAfter(expiryDate)) return false;

      // Strict rule: Must have checked online in the last 3 days
      final threeDaysAgo = now.subtract(const Duration(days: 3)).millisecondsSinceEpoch;
      if (lastCheck < threeDaysAgo) {
        print('Offline check failed: Last online check was more than 3 days ago.');
        return false;
      }
      
      return true;
    }
    return false;
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('license_email');
    await prefs.remove('license_key');
    await prefs.remove('license_expiry');
  }
}
