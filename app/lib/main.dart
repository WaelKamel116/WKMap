import 'package:material_ui/material_ui.dart';

import 'screens/drive_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CairoNavApp());
}

class CairoNavApp extends StatelessWidget {
  const CairoNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cairo Nav',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E5BFF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const DriveScreen(),
    );
  }
}
