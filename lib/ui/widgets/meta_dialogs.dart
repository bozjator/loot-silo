import 'package:flutter/material.dart';

import '../../core/sidecar.dart';
import '../../core/type_classifier.dart';

/// Edits an author name and profile URL; known authors autocomplete.
class AuthorDialog extends StatefulWidget {
  const AuthorDialog({super.key, this.initial, this.known = const []});

  final AuthorInfo? initial;
  final List<AuthorInfo> known;

  @override
  State<AuthorDialog> createState() => _AuthorDialogState();
}

class _AuthorDialogState extends State<AuthorDialog> {
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late String _name = widget.initial?.user ?? '';

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.trim();
    if (name.isEmpty) return;
    final url = _url.text.trim();
    final initial = widget.initial;
    Navigator.of(context).pop(
      AuthorInfo(
        user: name,
        url: url.isEmpty ? null : url,
        license: initial?.user == name ? initial?.license : null,
        itchUser: initial?.user == name ? initial?.itchUser : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Author'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Autocomplete<AuthorInfo>(
              initialValue: TextEditingValue(text: _name),
              displayStringForOption: (a) => a.user,
              optionsBuilder: (v) {
                final q = v.text.toLowerCase();
                return widget.known.where(
                  (a) => q.isNotEmpty && a.user.toLowerCase().contains(q),
                );
              },
              onSelected: (a) {
                _name = a.user;
                if (a.url != null) _url.text = a.url!;
              },
              fieldViewBuilder: (context, controller, focus, onSubmit) =>
                  TextField(
                    controller: controller,
                    focusNode: focus,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Name'),
                    onChanged: (v) => _name = v,
                    onSubmitted: (_) => _submit(),
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Profile URL',
                hintText: 'https://name.itch.io/',
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

class TypesDialog extends StatefulWidget {
  const TypesDialog({super.key, required this.initial});

  final List<String> initial;

  @override
  State<TypesDialog> createState() => _TypesDialogState();
}

class _TypesDialogState extends State<TypesDialog> {
  late final _selected = [...widget.initial];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Types'),
      content: SizedBox(
        width: 400,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in AssetType.values)
              FilterChip(
                label: Text(t.id),
                selected: _selected.contains(t.id),
                onSelected: (on) => setState(
                  () => on ? _selected.add(t.id) : _selected.remove(t.id),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop([
            for (final t in AssetType.values)
              if (_selected.contains(t.id)) t.id,
          ]),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class TagsDialog extends StatefulWidget {
  const TagsDialog({super.key, required this.initial});

  final List<String> initial;

  @override
  State<TagsDialog> createState() => _TagsDialogState();
}

class _TagsDialogState extends State<TagsDialog> {
  late final _text = TextEditingController(text: widget.initial.join(', '));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final tags = <String>{
      for (final t in _text.text.split(','))
        if (t.trim().isNotEmpty) t.trim().toLowerCase(),
    }.toList()..sort();
    Navigator.of(context).pop(tags);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tags'),
      content: SizedBox(
        width: 400,
        child: TextField(
          controller: _text,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Comma-separated tags'),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// Edits a pack title; an empty field means "use the folder name".
class TitleDialog extends StatefulWidget {
  const TitleDialog({super.key, required this.initial, this.folderName});

  final String initial;
  final String? folderName;

  @override
  State<TitleDialog> createState() => _TitleDialogState();
}

class _TitleDialogState extends State<TitleDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_text.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Title'),
      content: SizedBox(
        width: 400,
        child: TextField(
          controller: _text,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Pack title',
            helperText: widget.folderName == null
                ? null
                : 'Leave empty to use the folder name (${widget.folderName})',
          ),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// Asks for a game name; known games autocomplete.
class GameNameDialog extends StatefulWidget {
  const GameNameDialog({super.key, this.known = const [], this.title});

  final List<String> known;
  final String? title;

  @override
  State<GameNameDialog> createState() => _GameNameDialogState();
}

class _GameNameDialogState extends State<GameNameDialog> {
  // Autocomplete owns the controller; keep a handle to read on submit.
  TextEditingController? _field;

  void _submit() {
    final name = _field?.text.trim() ?? '';
    if (name.isNotEmpty) Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? 'Used in game'),
      content: SizedBox(
        width: 400,
        child: Autocomplete<String>(
          optionsBuilder: (v) {
            final q = v.text.toLowerCase();
            return widget.known.where((g) => g.toLowerCase().contains(q));
          },
          fieldViewBuilder: (context, controller, focus, onSubmit) {
            _field = controller;
            return TextField(
              controller: controller,
              focusNode: focus,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Game'),
              onSubmitted: (_) => _submit(),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

/// Values from [AuthorInfoDialog]; empty strings clear a field.
typedef AuthorEdit = ({
  String url,
  String license,
  String credit,
  String attribution,
});

/// Edits an author's URL, license summary and credit wording. The name is
/// the folder name and is not edited here.
class AuthorInfoDialog extends StatefulWidget {
  const AuthorInfoDialog({super.key, required this.initial});

  final AuthorInfo initial;

  @override
  State<AuthorInfoDialog> createState() => _AuthorInfoDialogState();
}

class _AuthorInfoDialogState extends State<AuthorInfoDialog> {
  late final _url = TextEditingController(text: widget.initial.url ?? '');
  late final _license = TextEditingController(
    text: widget.initial.license ?? '',
  );
  late final _credit = TextEditingController(text: widget.initial.credit ?? '');
  late String _attribution = widget.initial.attribution ?? 'unknown';

  @override
  void dispose() {
    _url.dispose();
    _license.dispose();
    _credit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial.user),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(labelText: 'Profile URL'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _license,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'License summary',
                hintText: 'CC0 / commercial use allowed, no resale…',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _credit,
              decoration: InputDecoration(
                labelText: 'Credit as',
                hintText: widget.initial.user,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Attribution'),
                const SizedBox(width: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'required', label: Text('Required')),
                    ButtonSegment(value: 'optional', label: Text('Optional')),
                    ButtonSegment(value: 'unknown', label: Text('Unknown')),
                  ],
                  selected: {_attribution},
                  onSelectionChanged: (s) =>
                      setState(() => _attribution = s.single),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop<AuthorEdit>((
            url: _url.text,
            license: _license.text,
            credit: _credit.text,
            attribution: _attribution,
          )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
