import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markify/services/license_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LicenseStatus { unknown, loading, valid, invalid, expired }

class LicenseState {
  final LicenseStatus status;
  final String? message;
  final String? email;
  final String? licenseKey;
  final String? expiryDate;

  LicenseState({
    required this.status,
    this.message,
    this.email,
    this.licenseKey,
    this.expiryDate,
  });

  LicenseState copyWith({
    LicenseStatus? status,
    String? message,
    String? email,
    String? licenseKey,
    String? expiryDate,
  }) {
    return LicenseState(
      status: status ?? this.status,
      message: message ?? this.message,
      email: email ?? this.email,
      licenseKey: licenseKey ?? this.licenseKey,
      expiryDate: expiryDate ?? this.expiryDate,
    );
  }
}

class LicenseNotifier extends StateNotifier<LicenseState> {
   LicenseNotifier() : super(LicenseState(status: LicenseStatus.unknown)) {
    checkInitialStatus();
  }

  Future<void> checkInitialStatus() async {
    state = state.copyWith(status: LicenseStatus.loading);
    try {
      final isValid = await LicenseService.checkLicense();
      print('Initial license check result: $isValid');
      
      // Load saved info even if status is invalid for UI display or re-activation
      final prefs = await SharedPreferences.getInstance();
      final email = prefs.getString('license_email');
      final key = prefs.getString('license_key');
      final expiry = prefs.getString('license_expiry');

      state = state.copyWith(
        status: isValid ? LicenseStatus.valid : LicenseStatus.invalid,
        email: email,
        licenseKey: key,
        expiryDate: expiry,
      );
    } catch (e) {
      print('Initial license check error: $e');
      state = state.copyWith(status: LicenseStatus.invalid, message: 'Check failed: $e');
    }
  }

  Future<bool> activate(String email, String licenseKey) async {
    state = state.copyWith(status: LicenseStatus.loading, message: null);
    print('Activating license: $licenseKey for $email');
    try {
      final result = await LicenseService.validateLicense(email, licenseKey);
      print('Activation API result: $result');
      if (result['success']) {
        state = state.copyWith(
          status: LicenseStatus.valid,
          email: email,
          licenseKey: licenseKey,
          expiryDate: result['data']?['expiry_date'],
        );
        return true;
      } else {
        state = state.copyWith(
          status: LicenseStatus.invalid,
          message: result['message'],
        );
        return false;
      }
    } catch (e) {
      print('Activation error: $e');
      state = state.copyWith(
        status: LicenseStatus.invalid,
        message: 'Network error or disk space issue: $e',
      );
      return false;
    }
  }

  Future<void> logout() async {
    await LicenseService.logout();
    state = LicenseState(status: LicenseStatus.invalid);
  }
}

final licenseProvider = StateNotifierProvider<LicenseNotifier, LicenseState>((ref) {
  return LicenseNotifier();
});
