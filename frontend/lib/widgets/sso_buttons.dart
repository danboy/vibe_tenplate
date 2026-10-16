import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';

class SsoButtons extends StatelessWidget {
  final String? redirect;

  const SsoButtons({super.key, this.redirect});

  Future<void> _start(String provider) async {
    final params = {if (redirect != null) 'redirect': redirect!};
    final uri = Uri.parse('${ApiService.baseUrl}/auth/oauth/$provider/start')
        .replace(queryParameters: params.isEmpty ? null : params);
    await launchUrl(uri, webOnlyWindowName: '_self');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Divider()),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text('or continue with',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ),
            const Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _start('google'),
          icon: const Icon(Icons.circle_outlined, size: 18),
          label: const Text('Continue with Google'),
          style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _start('github'),
          icon: const Icon(Icons.code, size: 18),
          label: const Text('Continue with GitHub'),
          style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _start('gitlab'),
          icon: const Icon(Icons.merge_type, size: 18),
          label: const Text('Continue with GitLab'),
          style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12)),
        ),
      ],
    );
  }
}
