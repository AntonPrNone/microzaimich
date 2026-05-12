import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';
import 'package:provider/provider.dart';

import '../../../core/utils/app_snackbar.dart';
import '../../../core/utils/input_formatters.dart';
import '../../../core/utils/validators.dart';
import '../../../data/repositories/auth_repository.dart';
import 'login_controller.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _phoneController = TextEditingController();
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _phoneFocusNode = FocusNode();
  late final MaskTextInputFormatter _phoneMaskFormatter;

  bool _obscurePassword = true;
  String _lastLookupPhone = '';

  @override
  void initState() {
    super.initState();
    _phoneMaskFormatter = InputMasks.phone();
    _phoneFocusNode.addListener(_handlePhoneFocusChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.read<LoginController>();

    if (_phoneController.text.isEmpty && controller.lastPhoneInput.isNotEmpty) {
      _fillPhone(controller.lastPhoneInput);
    }

    if (_passwordController.text.isEmpty &&
        controller.lastPasswordInput.isNotEmpty) {
      _passwordController.text = controller.lastPasswordInput;
    }
  }

  @override
  void dispose() {
    _phoneFocusNode
      ..removeListener(_handlePhoneFocusChange)
      ..dispose();
    _phoneController.dispose();
    _nameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _fillPhone(String rawPhone) {
    final digits = rawPhone.replaceAll(RegExp(r'\D'), '');
    final localDigits =
        digits.length == 11 && (digits.startsWith('7') || digits.startsWith('8'))
            ? digits.substring(1)
            : digits;

    _phoneMaskFormatter.clear();
    final formatted = _phoneMaskFormatter.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
        text: localDigits,
        selection: TextSelection.collapsed(offset: localDigits.length),
      ),
    );
    _phoneController.value = formatted;
  }

  void _handlePhoneFocusChange() {
    if (mounted) {
      setState(() {});
    }
    if (!_phoneFocusNode.hasFocus) {
      _autoLookup();
    }
  }

  Future<void> _autoLookup() async {
    final controller = context.read<LoginController>();
    final phone = _phoneController.text.trim();

    if (phone.isEmpty) {
      _lastLookupPhone = '';
      _nameController.clear();
      controller.resetLookup();
      return;
    }

    if (Validators.phone(phone) != null || _lastLookupPhone == phone) {
      return;
    }

    await controller.lookupPhone(phone);
    if (!mounted) {
      return;
    }

    _lastLookupPhone = phone;
    final lookup = controller.lookupResult;
    if (lookup?.user != null) {
      _nameController.text = lookup!.user!.name;
    } else {
      _nameController.clear();
    }
    setState(() {});
  }

  Future<void> _submit(LoginController controller) async {
    await _autoLookup();
    if (!mounted || !_formKey.currentState!.validate()) {
      return;
    }

    final success = await controller.submit(
      phone: _phoneController.text,
      password: _passwordController.text,
      name: _nameController.text,
    );
    if (!mounted || !success) {
      return;
    }

    showAppSnackBar('Вход выполнен успешно');
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<LoginController>(
      builder: (context, controller, _) {
        final result = controller.lookupResult;
        final user = result?.user;
        final theme = Theme.of(context);
        final viewInsets = MediaQuery.of(context).viewInsets;
        final keyboardVisible = viewInsets.bottom > 0;
        final currentPhone = _phoneController.text.trim();
        final lookupMatchesCurrentPhone =
            result != null &&
            currentPhone.isNotEmpty &&
            _lastLookupPhone == currentPhone;
        final showLookupUi =
            lookupMatchesCurrentPhone && !_phoneFocusNode.hasFocus;
        final isFirstLogin =
            showLookupUi && result.requiresPasswordSetup;
        final isNewUser = showLookupUi && !result.exists;

        if (user != null &&
            user.name.isNotEmpty &&
            _nameController.text.isEmpty) {
          _nameController.text = user.name;
        }

        final formCard = _LoginFormCard(
          formKey: _formKey,
          phoneController: _phoneController,
          nameController: _nameController,
          passwordController: _passwordController,
          phoneFocusNode: _phoneFocusNode,
          phoneMaskFormatter: _phoneMaskFormatter,
          controller: controller,
          result: showLookupUi ? result : null,
          userName: user?.name,
          isFirstLogin: isFirstLogin,
          isNewUser: isNewUser,
          compact: isNewUser || isFirstLogin,
          obscurePassword: _obscurePassword,
          onTogglePassword: () {
            setState(() {
              _obscurePassword = !_obscurePassword;
            });
          },
          onChangedPhone: () {
            if (_lastLookupPhone.isNotEmpty) {
              setState(() {
                _lastLookupPhone = '';
              });
            }
          },
          onSubmit: () => _submit(controller),
        );

        return GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: Scaffold(
            resizeToAvoidBottomInset: true,
            body: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          theme.scaffoldBackgroundColor,
                          const Color(0xFF141A20),
                          const Color(0xFF111315),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: -90,
                  left: -50,
                  child: _GlowBlob(
                    color: theme.colorScheme.primary.withValues(alpha: 0.14),
                    size: 210,
                  ),
                ),
                Positioned(
                  right: -30,
                  top: 110,
                  child: _GlowBlob(
                    color: theme.colorScheme.secondary.withValues(alpha: 0.14),
                    size: 170,
                  ),
                ),
                SafeArea(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 860;

                      if (wide) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: ConstrainedBox(
                              constraints:
                                  const BoxConstraints(maxWidth: 1020),
                              child: Row(
                                crossAxisAlignment:
                                    CrossAxisAlignment.stretch,
                                children: [
                                  const Expanded(
                                    flex: 11,
                                    child: _LoginShowcase(
                                      compact: false,
                                      tight: false,
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(flex: 9, child: formCard),
                                ],
                              ),
                            ),
                          ),
                        );
                      }

                      return ListView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          16,
                          16,
                          viewInsets.bottom + 16,
                        ),
                        children: [
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1020),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 220),
                                    reverseDuration:
                                        const Duration(milliseconds: 220),
                                    switchInCurve: Curves.easeOutCubic,
                                    switchOutCurve: Curves.easeInCubic,
                                    transitionBuilder: (child, animation) {
                                      return SizeTransition(
                                        sizeFactor: animation,
                                        axisAlignment: -1,
                                        child: FadeTransition(
                                          opacity: animation,
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: keyboardVisible
                                        ? const SizedBox.shrink(
                                            key: ValueKey('login-showcase-hidden'),
                                          )
                                        : const Column(
                                            key: ValueKey(
                                              'login-showcase-visible',
                                            ),
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              _LoginShowcase(
                                                compact: true,
                                                tight: false,
                                              ),
                                              SizedBox(height: 14),
                                            ],
                                          ),
                                  ),
                                  formCard,
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LoginShowcase extends StatelessWidget {
  const _LoginShowcase({
    required this.compact,
    required this.tight,
  });

  final bool compact;
  final bool tight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: EdgeInsets.all(tight ? 16 : (compact ? 20 : 26)),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withValues(alpha: 0.18),
            theme.colorScheme.secondary.withValues(alpha: 0.12),
            Colors.white.withValues(alpha: 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Container(
                width: compact ? 48 : 54,
                height: compact ? 48 : 54,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(Icons.shield_moon_outlined, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Личный кабинет займов',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: tight ? 10 : 14),
          Text(
            'Удобный вход и быстрый доступ к платежам, статусам и истории займа',
            style: theme.textTheme.bodyLarge,
          ),
          SizedBox(height: tight ? 12 : 16),
          const _FeatureTile(
            icon: Icons.schedule_outlined,
            title: 'График платежей',
            subtitle: 'Сроки, остаток долга и ближайшие даты в одном месте',
          ),
          if (!tight) ...[
            const SizedBox(height: 10),
            const _FeatureTile(
              icon: Icons.notifications_active_outlined,
              title: 'Напоминания',
              subtitle: 'Пени, статусы и изменения видны сразу',
            ),
          ],
        ],
      ),
    );
  }
}

class _LoginFormCard extends StatelessWidget {
  const _LoginFormCard({
    required this.formKey,
    required this.phoneController,
    required this.nameController,
    required this.passwordController,
    required this.phoneFocusNode,
    required this.phoneMaskFormatter,
    required this.controller,
    required this.result,
    required this.userName,
    required this.isFirstLogin,
    required this.isNewUser,
    required this.compact,
    required this.obscurePassword,
    required this.onTogglePassword,
    required this.onChangedPhone,
    required this.onSubmit,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController phoneController;
  final TextEditingController nameController;
  final TextEditingController passwordController;
  final FocusNode phoneFocusNode;
  final MaskTextInputFormatter phoneMaskFormatter;
  final LoginController controller;
  final AuthLookupResult? result;
  final String? userName;
  final bool isFirstLogin;
  final bool isNewUser;
  final bool compact;
  final bool obscurePassword;
  final VoidCallback onTogglePassword;
  final VoidCallback onChangedPhone;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget animatedSection({
      required Widget child,
      required String key,
    }) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        reverseDuration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return SizeTransition(
            sizeFactor: animation,
            axisAlignment: -1,
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: KeyedSubtree(
          key: ValueKey(key),
          child: child,
        ),
      );
    }

    final lookupSection = result == null
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _LookupBanner(
                title: isNewUser
                    ? 'Пользователь не найден'
                    : isFirstLogin
                    ? 'Первый вход'
                    : 'Пользователь найден',
                subtitle: isNewUser
                    ? 'Введите имя и пароль, чтобы создать профиль'
                    : isFirstLogin
                    ? 'Имя уже есть в базе, осталось задать пароль'
                    : '${userName ?? ''}, введите пароль для входа',
                tone: isNewUser
                    ? _LookupBannerTone.warning
                    : _LookupBannerTone.success,
              ),
              SizedBox(height: compact ? 10 : 12),
            ],
          );

    final showNameField = isNewUser || isFirstLogin;
    final nameSection = showNameField
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextFormField(
                  controller: nameController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Имя',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  readOnly: (userName ?? '').isNotEmpty,
                  validator: (value) {
                    if (!showNameField) {
                      return null;
                    }
                    return Validators.name(value);
                  },
                ),
              ),
              SizedBox(height: compact ? 10 : 12),
            ],
          )
        : const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 16 : 20),
        child: Form(
          key: formKey,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Вход',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                'Введите номер телефона и пароль',
                style: theme.textTheme.bodyMedium,
              ),
              SizedBox(height: compact ? 10 : 14),
              animatedSection(
                child: lookupSection,
                key:
                    'lookup-${result?.exists}-${result?.requiresPasswordSetup}-${userName ?? ''}',
              ),
              TextFormField(
                controller: phoneController,
                focusNode: phoneFocusNode,
                keyboardType: TextInputType.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d\s()+-]')),
                  phoneMaskFormatter,
                ],
                decoration: const InputDecoration(
                  labelText: 'Номер телефона',
                  prefixIcon: Icon(Icons.phone_iphone_outlined),
                ),
                onChanged: (_) => onChangedPhone(),
                validator: Validators.phone,
              ),
              SizedBox(height: compact ? 10 : 12),
              animatedSection(
                child: nameSection,
                key: showNameField ? 'name-visible' : 'name-hidden',
              ),
              TextFormField(
                controller: passwordController,
                obscureText: obscurePassword,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => onSubmit(),
                decoration: InputDecoration(
                  labelText: isFirstLogin ? 'Создайте пароль' : 'Пароль',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    onPressed: onTogglePassword,
                    icon: Icon(
                      obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                validator: (value) {
                  if ((value ?? '').trim().length < 4) {
                    return 'Минимум 4 символа';
                  }
                  return null;
                },
              ),
              if (controller.errorText != null) ...[
                SizedBox(height: compact ? 10 : 12),
                Text(
                  controller.errorText!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              SizedBox(height: compact ? 12 : 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: controller.isBusy ? null : onSubmit,
                  icon: controller.isBusy
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(
                    isFirstLogin
                        ? 'Создать пароль и войти'
                        : isNewUser
                        ? 'Создать профиль'
                        : 'Войти',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              icon,
              size: 20,
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlowBlob extends StatelessWidget {
  const _GlowBlob({
    required this.color,
    required this.size,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color,
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

enum _LookupBannerTone { success, warning }

class _LookupBanner extends StatelessWidget {
  const _LookupBanner({
    required this.title,
    required this.subtitle,
    required this.tone,
  });

  final String title;
  final String subtitle;
  final _LookupBannerTone tone;

  @override
  Widget build(BuildContext context) {
    final color = tone == _LookupBannerTone.success
        ? Theme.of(context).colorScheme.primary
        : const Color(0xFFFFC26B);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(subtitle),
        ],
      ),
    );
  }
}
