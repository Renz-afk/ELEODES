import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ELEODES/core/theme/app_theme.dart';
import 'package:ELEODES/features/legal/screens/terms_agreement_screen.dart';
import 'package:ELEODES/app/main_screen.dart';
import 'package:ELEODES/features/guide/screens/beginner_guide_screen.dart';
import 'package:ELEODES/features/devices/services/device_auth_service.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  String _message = 'Loading...';
  bool _loadingFailed = false;

  @override
  void initState() {
    super.initState();
    _startLoading();
  }

  Future<void> _startLoading() async {
    setState(() {
      _loadingFailed = false;
      _message = 'Loading...';
    });
    try {
      if (!mounted) return;

      final prefs = await SharedPreferences.getInstance();
      await DeviceAuthService.instance.restoreSession();

      final termsAccepted = prefs.getBool('termsAccepted') ?? false;

      // ========================================================
      // TERMS
      // ========================================================

      if (!termsAccepted) {
        _openScreen(const TermsScreen());
        return;
      }

      final guideCompleted = prefs.getBool('beginnerGuideCompleted') ?? false;
      if (!guideCompleted) {
        _openScreen(const BeginnerGuideScreen(firstLaunch: true));
        return;
      }

      // ========================================================
      // OPEN MAIN APP
      // ========================================================

      setState(() {
        _message = 'Opening ELEODES...';
      });

      if (!mounted) return;

      _openScreen(const MainScreen());
    } catch (_) {
      if (!mounted) return;

      setState(() {
        _loadingFailed = true;
        _message = 'Could not load your setup. Please try again.';
      });
    }
  }

  void _openScreen(Widget screen) {
    if (!mounted) return;

    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background(context, const Color(0xFFD4FFED)),

      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),

            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,

              children: [
                // ==================================================
                // LOGO
                // ==================================================
                SizedBox(
                  width: 180,
                  height: 180,

                  child: Image.asset(
                    'assets/images/Logo.png',

                    fit: BoxFit.contain,

                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        width: 150,
                        height: 150,

                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF1DE3AB),
                        ),

                        child: const Icon(
                          Icons.water_drop,
                          size: 80,
                          color: Colors.white,
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 25),

                // ==================================================
                // APP NAME
                // ==================================================
                Text(
                  'ELEODES',

                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 3,
                    color: AppTheme.text(context, const Color(0xFF090909)),
                  ),
                ),

                const SizedBox(height: 6),

                // ==================================================
                // TAGLINE
                // ==================================================
                Text(
                  'Every drop matters',

                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    color: AppTheme.muted(context, const Color(0xFF555555)),
                  ),
                ),

                const SizedBox(height: 40),

                // ==================================================
                // LOADING
                // ==================================================
                if (!_loadingFailed) const SizedBox(
                  width: 28,
                  height: 28,

                  child: CircularProgressIndicator(
                    strokeWidth: 3,

                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF1DE3AB),
                    ),
                  ),
                ),

                const SizedBox(height: 18),

                // ==================================================
                // MESSAGE
                // ==================================================
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),

                  child: Text(
                    _message,

                    key: ValueKey(_message),

                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.muted(context, const Color(0xFF555555)),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (_loadingFailed) ...[
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _startLoading,
                    child: const Text('Retry'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
