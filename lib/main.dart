import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/home_pager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The robot wears the phone like a face — lock to landscape and stay awake.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  final state = AppState();
  await state.init();

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const SmaboApp(),
    ),
  );
}

class SmaboApp extends StatelessWidget {
  const SmaboApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'smabo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4FC3F7),
          secondary: Color(0xFF80DEEA),
        ),
        useMaterial3: true,
      ),
      home: const HomePager(),
    );
  }
}
