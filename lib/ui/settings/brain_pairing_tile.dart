import 'package:flutter/material.dart';

import '../../state/app_state.dart';

/// Settings → Connections: whether the phone is paired with smabo-brain, a
/// field for an invite code from smabo-web (Devices → Add phone), and Unpair.
class BrainPairingTile extends StatefulWidget {
  const BrainPairingTile({super.key, required this.state});
  final AppState state;

  @override
  State<BrainPairingTile> createState() => _BrainPairingTileState();
}

class _BrainPairingTileState extends State<BrainPairingTile> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _pair() {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    widget.state.pairWithBrain(code);
    _code.clear();
    FocusScope.of(context).unfocus();
  }

  Future<void> _unpair() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Unpair from the brain?'),
        content: const Text('The phone forgets its token. To connect again, '
            'get a new invite code in smabo-web → Devices.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Unpair')),
        ],
      ),
    );
    if (yes == true) await widget.state.unpairBrain();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.state.pairing;
    final pending = p.invite.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(p.paired ? Icons.lock : Icons.lock_open,
                size: 16, color: p.paired ? Colors.greenAccent : Colors.white54),
            const SizedBox(width: 6),
            Expanded(
              child: Text(pending ? 'Pairing…' : p.describe(),
                  style: const TextStyle(color: Colors.white70)),
            ),
            if (p.paired)
              TextButton(onPressed: _unpair, child: const Text('Unpair')),
          ]),
          if (!p.paired)
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _code,
                  decoration: const InputDecoration(
                    labelText: 'Invite code',
                    hintText: 'ABCD-EFGH',
                    helperText: 'smabo-web → Devices → Add phone',
                  ),
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  onSubmitted: (_) => _pair(),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: pending ? null : _pair, child: const Text('Pair')),
            ]),
        ],
      ),
    );
  }
}
