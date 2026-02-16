import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'auth_screen.dart';

class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  String _message = "Поиск сервера в облаке...";

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    bool success = await ApiService().autoInitialize();
    if (success) {
      if (!mounted) return;
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (context) => const AuthScreen()));
    } else {
      if (mounted) {
        setState(() => _message =
            "Не удалось найти сервер.\nПроверьте интернет или Cloud Functions.");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(_message, textAlign: TextAlign.center),
            if (_message.contains("Не удалось"))
              TextButton(
                  onPressed: _initApp, child: const Text("Повторить попытку"))
          ],
        ),
      ),
    );
  }
}
