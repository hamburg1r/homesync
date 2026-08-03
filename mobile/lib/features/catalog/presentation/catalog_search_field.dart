import 'package:flutter/material.dart';

class CatalogSearchField extends StatefulWidget {
  const CatalogSearchField({
    super.key,
    required this.query,
    required this.onChanged,
  });

  final String query;
  final ValueChanged<String> onChanged;

  @override
  State<CatalogSearchField> createState() => _CatalogSearchFieldState();
}

class _CatalogSearchFieldState extends State<CatalogSearchField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.query);
  }

  @override
  void didUpdateWidget(covariant CatalogSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _controller.text) {
      _controller.text = widget.query;
      _controller.selection = TextSelection.collapsed(
        offset: widget.query.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      decoration: InputDecoration(
        hintText: 'Search title or tags',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                onPressed: () {
                  _controller.clear();
                  widget.onChanged('');
                  setState(() {});
                },
                icon: const Icon(Icons.clear),
              ),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (value) {
        widget.onChanged(value);
        setState(() {});
      },
    );
  }
}
