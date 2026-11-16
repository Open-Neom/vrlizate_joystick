import 'package:flutter/material.dart';
import 'package:vrlizate_search/vrlizate_search.dart';

import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';

/// Builder signature allowing private host applications (such as `VRlizate_app`
/// with `wordsphere`) to inject a custom radial gesture board into
/// [VrWordsphereSearchSheet] without coupling the public SDK to private packages.
typedef VrCustomSearchBoardBuilder =
    Widget Function(
      BuildContext context,
      VrSearchPadController controller,
      ValueChanged<String> onTextChanged,
    );

/// SDK-owned text-pad controller backing [VrWordsphereSearchSheet].
///
/// Works standalone over [textController] and optionally forwards word/space/clear
/// operations to a host-supplied [delegate] (e.g. `WordsphereController`).
class VrSearchPadController {
  VrSearchPadController({
    required this.textController,
    this.onBackspaceWord,
    this.onInsertSpace,
    this.onClear,
    this.onDispose,
  });

  /// Optional factory allowing private hosts to attach custom pad controllers.
  static VrSearchPadController Function(TextEditingController textController)?
  defaultFactory;

  factory VrSearchPadController.create({
    required TextEditingController textController,
  }) =>
      defaultFactory?.call(textController) ??
      VrSearchPadController(textController: textController);

  final TextEditingController textController;
  final VoidCallback? onBackspaceWord;
  final VoidCallback? onInsertSpace;
  final VoidCallback? onClear;
  final VoidCallback? onDispose;

  /// Backwards-compatible attachment slot for private host board controllers.
  Object? hostAttachment;

  void backspaceWord() {
    if (onBackspaceWord != null) {
      onBackspaceWord!();
      return;
    }
    final current = textController.text;
    if (current.isEmpty) return;
    final trimmedRight = current.replaceFirst(RegExp(r'\s+$'), '');
    final lastSpace = trimmedRight.lastIndexOf(RegExp(r'\s'));
    final updated = lastSpace == -1 ? '' : trimmedRight.substring(0, lastSpace + 1);
    textController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: updated.length),
    );
  }

  void insertSpace() {
    if (onInsertSpace != null) {
      onInsertSpace!();
      return;
    }
    final current = textController.text;
    final updated = current.endsWith(' ') || current.isEmpty
        ? current
        : '$current ';
    textController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: updated.length),
    );
  }

  void clear() {
    if (onClear != null) {
      onClear!();
      return;
    }
    textController.clear();
  }

  void dispose() {
    onDispose?.call();
  }
}

/// Modal bottom sheet / overlay opened on a free-hand long press in Laser mode,
/// combining live 3D spatial search ([VrSpatialSearchEngine] from
/// `vrlizate_search`), quick VRlizate destination chips, and an optional
/// host-injected radial gesture board (`Wordsphere` in private host builds).
class VrWordsphereSearchSheet extends StatelessWidget {
  const VrWordsphereSearchSheet({
    super.key,
    required this.wordsphereController,
    required this.textController,
    required this.onQueryChanged,
    required this.onSubmitted,
    required this.onClose,
    this.destinations = VrJoystickConstants.wordsphereDestinations,
    this.searchEngine,
    this.boardBuilder,
  });

  /// Optional host-registered radial board builder (used when [boardBuilder] is null).
  static VrCustomSearchBoardBuilder? registeredBoardBuilder;

  final VrSearchPadController wordsphereController;
  final TextEditingController textController;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClose;
  final List<String> destinations;
  final VrSpatialSearchEngine? searchEngine;
  final VrCustomSearchBoardBuilder? boardBuilder;

  @override
  Widget build(BuildContext context) {
    final activeBoardBuilder = boardBuilder ?? registeredBoardBuilder;
    final engine = searchEngine ?? VrSpatialSearchEngine();

    return Container(
      key: const Key(VrJoystickConstants.keyWordsphereSearchSheet),
      color: const Color(0xF2080D16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left column: Search query field, edit actions, and quick VRlizate destinations
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.travel_explore_rounded,
                        color: Color(0xFF00E5FF),
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          VrJoystickTranslationConstants.wordsphereSheetTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Color(0xFF80D8FF),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.9,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        onPressed: onClose,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white70,
                          size: 20,
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    VrJoystickTranslationConstants.wordsphereSheetSubtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 10.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key(
                            VrJoystickConstants.keyWordsphereSearchField,
                          ),
                          controller: textController,
                          onChanged: onQueryChanged,
                          onSubmitted: onSubmitted,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: VrJoystickTranslationConstants
                                .wordsphereSearchFieldHint,
                            hintStyle: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11.5,
                            ),
                            filled: true,
                            fillColor: const Color(0xFF101929),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 9,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                color: Color(0x5500E5FF),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                color: Color(0x4400E5FF),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.icon(
                        key: const Key(
                          VrJoystickConstants.keyWordsphereSearchSubmit,
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF00B8D4),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                        ),
                        onPressed: () => onSubmitted(textController.text),
                        icon: const Icon(Icons.send_rounded, size: 15),
                        label: const Text(
                          VrJoystickTranslationConstants.wordsphereSubmitButton,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      OutlinedButton.icon(
                        key: const Key(
                          VrJoystickConstants.keyWordsphereSearchBackspace,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: Colors.white70,
                        ),
                        onPressed: () {
                          wordsphereController.backspaceWord();
                          onQueryChanged(textController.text);
                        },
                        icon: const Icon(Icons.backspace_outlined, size: 14),
                        label: const Text(
                          VrJoystickTranslationConstants
                              .wordsphereBackspaceTooltip,
                          style: TextStyle(fontSize: 10.5),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key(
                          VrJoystickConstants.keyWordsphereSearchSpace,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: Colors.white70,
                        ),
                        onPressed: () {
                          wordsphereController.insertSpace();
                          onQueryChanged(textController.text);
                        },
                        icon: const Icon(Icons.space_bar_rounded, size: 14),
                        label: const Text(
                          VrJoystickTranslationConstants.wordsphereSpaceTooltip,
                          style: TextStyle(fontSize: 10.5),
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key(
                          VrJoystickConstants.keyWordsphereSearchClear,
                        ),
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          foregroundColor: Colors.white70,
                        ),
                        onPressed: () {
                          wordsphereController.clear();
                          onQueryChanged(textController.text);
                        },
                        icon: const Icon(Icons.delete_outline_rounded, size: 14),
                        label: const Text(
                          VrJoystickTranslationConstants.wordsphereClearTooltip,
                          style: TextStyle(fontSize: 10.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    VrJoystickTranslationConstants
                        .wordsphereQuickDestinationsLabel,
                    style: TextStyle(
                      color: Color(0xFF80D8FF),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final dest in destinations)
                            ActionChip(
                              key: Key(
                                '${VrJoystickConstants.keyWordsphereDestinationChipPrefix}$dest',
                              ),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: const Color(0xFF132238),
                              side: const BorderSide(color: Color(0x5500E5FF)),
                              label: Text(
                                dest,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              onPressed: () {
                                textController.text = dest;
                                onQueryChanged(dest);
                                onSubmitted(dest);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Right column: Host-injected radial board or SDK Spatial Search live hits
            Expanded(
              flex: 4,
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: KeyedSubtree(
                    key: const Key(VrJoystickConstants.keyWordsphereBoard),
                    child: activeBoardBuilder != null
                        ? activeBoardBuilder(
                            context,
                            wordsphereController,
                            onQueryChanged,
                          )
                        : _SdkSpatialSearchLiveBoard(
                            engine: engine,
                            textController: textController,
                            onSelect: (query) {
                              textController.text = query;
                              onQueryChanged(query);
                              onSubmitted(query);
                            },
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SdkSpatialSearchLiveBoard extends StatelessWidget {
  const _SdkSpatialSearchLiveBoard({
    required this.engine,
    required this.textController,
    required this.onSelect,
  });

  final VrSpatialSearchEngine engine;
  final TextEditingController textController;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: textController,
      builder: (context, value, _) {
        final hits = engine.search(
          VrSpatialSearchQuery(rawText: value.text, maxResults: 6),
        );
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF0E1826),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0x4400E5FF)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: ListView.separated(
              itemCount: hits.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final hit = hits[index];
                return InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => onSelect(hit.entry.title),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF14243A),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          hit.entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          hit.entry.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
