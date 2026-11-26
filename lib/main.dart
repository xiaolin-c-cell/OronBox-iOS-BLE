import 'package:flutter/material.dart';

import 'src/ui/home_page.dart';

void main() {
  runApp(const OronBoxBleApp());
}

class OronBoxBleApp extends StatelessWidget {
  const OronBoxBleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OronBox BLE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A73E8)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
