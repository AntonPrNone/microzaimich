import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';

class InputMasks {
  const InputMasks._();

  static MaskTextInputFormatter phone({String? initialText}) {
    return MaskTextInputFormatter(
      mask: '+7 (###) ###-##-##',
      filter: {'#': RegExp(r'\d')},
      initialText: initialText,
    );
  }
}
