import 'dart:io';
import 'package:crypto/crypto.dart';

class PinnedHttpOverrides extends HttpOverrides {
  final String activeIp;
  final String expectedFingerprint;

  PinnedHttpOverrides({
    required this.activeIp,
    required this.expectedFingerprint,
  });

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);

    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      // 1. Если это НЕ наш сервер (например, запрос к S3 или Google),
      // мы не вмешиваемся и блокируем соединение, если сертификат плохой.
      // (В случае S3 сертификат будет валидным и подписанным CA, так что сюда мы даже не попадем,
      // если только у Яндекса не протухнет сертификат).
      if (host != activeIp) {
        return false;
      }

      // 2. Если это НАШ сервер (совпадает IP), начинаем проверку хеша.

      // Считаем SHA-256 хеш полученного сертификата
      final receivedSha256 = sha256.convert(cert.der).toString().toUpperCase();

      // Чистим ожидаемый хеш от двоеточий
      final cleanExpected =
          expectedFingerprint.replaceAll(':', '').toUpperCase();

      // Сравниваем
      final isMatch = receivedSha256 == cleanExpected;

      if (isMatch) {
        print("✅ Secure connection to Messenger Server verified ($host)");
      } else {
        print("⚠️ SECURITY ALERT: Certificate mismatch for $host!");
        print("Expected: $cleanExpected");
        print("Got:      $receivedSha256");
      }

      return isMatch;
    };

    return client;
  }
}
