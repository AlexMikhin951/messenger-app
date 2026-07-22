import 'package:flutter/material.dart';

import 'demo_data.dart';
import 'screens/auth_screen.dart';

void main() {
  runApp(const MessengerDemoApp());
}

class MessengerDemoApp extends StatelessWidget {
  const MessengerDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Messenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const AuthScreen(),
    );
  }
}

class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      backgroundColor: const Color(0xFFFFF3CD),
      content: const Text(
        DemoData.demoBanner,
        style: TextStyle(color: Color(0xFF664D03), fontSize: 13),
      ),
      leading: const Icon(Icons.info_outline, color: Color(0xFF664D03)),
      actions: [
        TextButton(
          onPressed: () =>
              ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

void showDemoBanner(BuildContext context) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFFFFF3CD),
        content: const Text(
          DemoData.demoBanner,
          style: TextStyle(color: Color(0xFF664D03), fontSize: 13),
        ),
        leading: const Icon(Icons.info_outline, color: Color(0xFF664D03)),
        actions: [
          TextButton(
            onPressed: () =>
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  });
}
