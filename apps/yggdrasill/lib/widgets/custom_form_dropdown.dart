import 'package:flutter/material.dart';

class CustomFormDropdown<T> extends StatefulWidget {
  final T? value;
  final List<T> items;
  final String Function(T) itemLabelBuilder;
  final ValueChanged<T> onChanged;
  final String label;
  final String? placeholder;

  const CustomFormDropdown({
    Key? key,
    required this.value,
    required this.items,
    required this.itemLabelBuilder,
    required this.onChanged,
    required this.label,
    this.placeholder,
  }) : super(key: key);

  @override
  State<CustomFormDropdown<T>> createState() => _CustomFormDropdownState<T>();
}

class _CustomFormDropdownState<T> extends State<CustomFormDropdown<T>> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _isOpen = false;

  void _toggleDropdown() {
    if (_isOpen) {
      _closeDropdown();
    } else {
      _openDropdown();
    }
  }

  void _openDropdown() {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closeDropdown,
              child: const SizedBox.shrink(),
            ),
          ),
          Positioned(
            width: size.width,
            child: CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              // Offset reduced to 4 to be tighter
              offset: Offset(0, size.height + 4),
              child: Material(
                elevation: 8,
                color: const Color(0xFF232326),
                // Added clipBehavior to prevent children from bleeding over rounded corners
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF3A3F44)),
                ),
                shadowColor: Colors.black.withOpacity(0.5),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.builder(
                    // Removed vertical padding so highlight fills the corners (clipped by Material)
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: widget.items.length,
                    itemBuilder: (context, index) {
                      final item = widget.items[index];
                      final isSelected = item == widget.value;
                      return InkWell(
                        onTap: () {
                          widget.onChanged(item);
                          _closeDropdown();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: isSelected
                              ? BoxDecoration(
                                  color: const Color(0xFF33A373).withOpacity(0.15),
                                  border: const Border(
                                    left: BorderSide(color: Color(0xFF33A373), width: 3),
                                  ),
                                )
                              : null,
                          child: Text(
                            widget.itemLabelBuilder(item),
                            style: TextStyle(
                              color: isSelected ? const Color(0xFF33A373) : const Color(0xFFEAF2F2),
                              fontSize: 15,
                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
    setState(() => _isOpen = true);
  }

  void _closeDropdown() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) {
      setState(() => _isOpen = false);
    }
  }

  @override
  void dispose() {
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: InkWell(
        onTap: _toggleDropdown,
        borderRadius: BorderRadius.circular(8),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: widget.label,
            labelStyle: const TextStyle(color: Color(0xFF9FB3B3), fontSize: 14),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: const Color(0xFF3A3F44).withOpacity(0.6)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: _isOpen ? const Color(0xFF33A373) : const Color(0xFF3A3F44).withOpacity(0.6)),
            ),
            filled: true,
            fillColor: const Color(0xFF15171C),
            suffixIcon: Icon(
              _isOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: const Color(0xFF9FB3B3),
            ),
          ),
          child: Text(
            widget.value != null ? widget.itemLabelBuilder(widget.value!) : (widget.placeholder ?? ''),
            style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 15),
          ),
        ),
      ),
    );
  }
}
