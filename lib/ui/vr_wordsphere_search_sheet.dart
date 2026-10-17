import 'package:flutter/material.dart';
import 'package:wordsphere/wordsphere.dart';

import '../utils/constants/vr_joystick_constants.dart';
import '../utils/constants/vr_joystick_translation_constants.dart';

/// Modal bottom sheet / overlay opened on a free-hand long press in Laser mode,
/// embedding [WordsphereInput] and quick VRlizate destination chips so the user
/// can trace words or navigate to any destination in VRlizate.
class VrWordsphereSearchSheet extends StatelessWidget {
  const VrWordsphereSearchSheet({
    super.key,
    required this.wordsphereController,
    required this.textController,
    required this.onQueryChanged,
    required this.onSubmitted,
    required this.onClose,
    this.destinations = VrJoystickConstants.wordsphereDestinations,
  });

  final WordsphereController wordsphereController;
  final TextEditingController textController;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClose;
  final List<String> destinations;

  @override
  Widget build(BuildContext context) {
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
            // Right column: Interactive Wordsphere radial gesture board
            Expanded(
              flex: 4,
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: WordsphereInput(
                    key: const Key(VrJoystickConstants.keyWordsphereBoard),
                    controller: wordsphereController,
                    minSize: 120.0,
                    maxSize: 320.0,
                    onTextChanged: onQueryChanged,
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
