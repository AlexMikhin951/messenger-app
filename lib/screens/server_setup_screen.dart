import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/server_bootstrap_provider.dart';
import 'auth_screen.dart';
import 'contacts_screen.dart';

class ServerSetupScreen extends ConsumerStatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  ConsumerState<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends ConsumerState<ServerSetupScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(serverBootstrapProvider.notifier).bootstrap(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = ref.watch(serverBootstrapProvider);

    ref.listen<BootstrapState>(serverBootstrapProvider, (previous, next) {
      if (next.status == BootstrapStatus.authenticated) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const ContactsScreen()),
        );
      } else if (next.status == BootstrapStatus.needsAuth) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const AuthScreen()),
        );
      }
    });

    final isRetry = bootstrap.status == BootstrapStatus.failed;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!isRetry)
                const CircularProgressIndicator()
              else
                const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
              const SizedBox(height: 24),
              Text(
                bootstrap.message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: isRetry ? Colors.red : Colors.grey.shade700,
                ),
              ),
              if (isRetry) ...[
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () =>
                      ref.read(serverBootstrapProvider.notifier).bootstrap(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить попытку'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
