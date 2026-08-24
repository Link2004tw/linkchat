import 'dart:async';

import 'package:clerk_auth/clerk_auth.dart' as clerk;
import 'package:clerk_flutter/clerk_flutter.dart';
import 'package:flutter/material.dart';

import '../services/google_oauth_callback.dart';
import '../services/google_sign_in_flow.dart';

/// Email + password auth for platforms where Clerk's SSO webview is
/// unavailable (Linux desktop: there is no Linux `WebViewPlatform`, so the
/// Google button in the prebuilt widget crashes). Google OAuth is still
/// offered on desktop via the system browser + a local callback server (see
/// [GoogleOAuthCallback]); the in-app webview is only avoided.
///
/// Uses the same public `attemptSignIn` / `attemptSignUp` API as the
/// prebuilt [ClerkAuthentication] widget, minus the OAuth panel. Errors
/// surface through the existing [ClerkErrorListener] snackbar, just like the
/// prebuilt UI.
class EmailAuthScreen extends StatefulWidget {
  const EmailAuthScreen({super.key});

  @override
  State<EmailAuthScreen> createState() => _EmailAuthScreenState();
}

class _EmailAuthScreenState extends State<EmailAuthScreen> {
  final TextEditingController _identifier = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _code = TextEditingController();
  // Extra inputs for the Google sign-up continuation step.
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _firstName = TextEditingController();
  final TextEditingController _lastName = TextEditingController();

  bool _isSignUp = false;
  bool _needsEmailCode = false;
  bool _busy = false;
  bool _legalAccepted = false;

  /// Fields a Google sign-up still owes (e.g. username); the form collapses
  /// to collect just those fields instead of assuming which are missing.
  List<clerk.Field> _missingFields = const <clerk.Field>[];

  /// True while finishing an OAuth sign-up that still owes required fields.
  bool get _oauthContinuation => _missingFields.isNotEmpty;

  @override
  void dispose() {
    GoogleOAuthCallback.cancelPending();
    _identifier.dispose();
    _username.dispose();
    _password.dispose();
    _confirm.dispose();
    _code.dispose();
    _phone.dispose();
    _firstName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  /// The controller backing [field]'s input, or null when the field has no
  /// text input (e.g. a checkbox or a non-editable strategy field).
  TextEditingController? _controllerFor(clerk.Field field) => switch (field) {
        clerk.Field.username => _username,
        clerk.Field.emailAddress => _identifier,
        clerk.Field.phoneNumber => _phone,
        clerk.Field.firstName => _firstName,
        clerk.Field.lastName => _lastName,
        clerk.Field.password => _password,
        _ => null,
      };

  /// Whether [field] can be collected through this form.
  bool _isEditableField(clerk.Field field) {
    switch (field) {
      case clerk.Field.username:
      case clerk.Field.emailAddress:
      case clerk.Field.phoneNumber:
      case clerk.Field.firstName:
      case clerk.Field.lastName:
      case clerk.Field.password:
      case clerk.Field.legalAccepted:
        return true;
      default:
        return false;
    }
  }

  /// Human-readable label for [field] ("email address" → "Email address").
  String _fieldLabel(clerk.Field field) {
    final title = field.title;
    if (title.isEmpty) return title;
    return title[0].toUpperCase() + title.substring(1);
  }

  /// One input widget per missing field for the Google sign-up
  /// continuation step. Uneditable strategy fields are skipped.
  List<Widget> _buildMissingFieldInputs(ClerkAuthState auth) {
    final inputs = <Widget>[];
    for (final field in _missingFields) {
      if (!_isEditableField(field)) continue;
      if (field == clerk.Field.legalAccepted) {
        inputs.add(
          CheckboxListTile(
            value: _legalAccepted,
            onChanged: _busy
                ? null
                : (value) => setState(() => _legalAccepted = value ?? false),
            title: const Text('I agree to the Terms & Privacy Policy'),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
        );
        inputs.add(const SizedBox(height: 4));
        continue;
      }

      final controller = _controllerFor(field);
      if (controller == null) continue;
      inputs.add(
        TextField(
          controller: controller,
          autocorrect: false,
          obscureText: field == clerk.Field.password,
          keyboardType: switch (field) {
            clerk.Field.emailAddress => TextInputType.emailAddress,
            clerk.Field.phoneNumber => TextInputType.phone,
            _ => null,
          },
          decoration: InputDecoration(labelText: _fieldLabel(field)),
          onSubmitted: (_) => _submit(auth),
        ),
      );
      inputs.add(const SizedBox(height: 12));
    }
    if (inputs.isEmpty) {
      inputs.add(
        Text(
          'Some additional information is required. Please try again or sign in instead.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return inputs;
  }

  Future<void> _submit(ClerkAuthState auth) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    // Email-verification step (only reached when the instance requires it).
    if (_needsEmailCode) {
      final code = _code.text.trim();
      if (code.isEmpty) {
        auth.handleError(
          clerk.ClerkError.clientAppError(
            message: 'Enter the verification code from your email.',
          ),
        );
        return;
      }
      setState(() => _busy = true);
      await auth.safelyCall(
        context,
        () => _isSignUp
            ? auth.attemptSignUp(
                strategy: clerk.Strategy.emailCode,
                code: code,
              )
            : auth.attemptSignIn(
                strategy: clerk.Strategy.emailCode,
                code: code,
              ),
      );
      if (mounted) setState(() => _busy = false);
      return;
    }

    // On sign-in the identifier may be a username or an email address (Clerk
    // resolves either); sign-up always needs a real email for verification.
    final identifier = _identifier.text.trim();
    final password = _password.text;
    final username = _username.text.trim();

    // Google already supplied identity (verified email); the sign-up only
    // needs the fields it is still missing, whatever those are.
    if (_isSignUp && _oauthContinuation) {
      for (final field in _missingFields) {
        if (!_isEditableField(field)) continue;
        if (field == clerk.Field.legalAccepted) {
          if (!_legalAccepted) {
            auth.handleError(
              clerk.ClerkError.clientAppError(
                message: 'Please accept the terms to continue.',
              ),
            );
            return;
          }
          continue;
        }
        final controller = _controllerFor(field);
        if (controller != null && controller.text.trim().isEmpty) {
          auth.handleError(
            clerk.ClerkError.clientAppError(
              message: 'Enter your ${field.title}.',
            ),
          );
          return;
        }
      }
      setState(() => _busy = true);
      await auth.safelyCall(
        context,
        () async {
          await auth.attemptSignUp(
            username: _missingFields.contains(clerk.Field.username)
                ? _username.text.trim()
                : null,
            emailAddress: _missingFields.contains(clerk.Field.emailAddress)
                ? _identifier.text.trim()
                : null,
            phoneNumber: _missingFields.contains(clerk.Field.phoneNumber)
                ? _phone.text.trim()
                : null,
            firstName: _missingFields.contains(clerk.Field.firstName)
                ? _firstName.text.trim()
                : null,
            lastName: _missingFields.contains(clerk.Field.lastName)
                ? _lastName.text.trim()
                : null,
            password: _missingFields.contains(clerk.Field.password)
                ? _password.text
                : null,
            legalAccepted:
                _missingFields.contains(clerk.Field.legalAccepted)
                    ? _legalAccepted
                    : null,
          );
          if (!auth.isSignedIn && mounted) {
            auth.handleError(
              clerk.ClerkError.clientAppError(
                message: 'Google sign-up didn\'t complete. Please try again.',
              ),
            );
          }
        },
      );
      if (mounted) setState(() => _busy = false);
      return;
    }

    if (identifier.isEmpty) {
      auth.handleError(
        clerk.ClerkError.clientAppError(
          message: _isSignUp
              ? 'Enter your email address.'
              : 'Enter your username or email.',
        ),
      );
      return;
    }

    if (_isSignUp && username.isEmpty) {
      auth.handleError(
        clerk.ClerkError.clientAppError(message: 'Enter a username.'),
      );
      return;
    }

    if (_isSignUp) {
      final passwordError = auth.checkPassword(password, _confirm.text, context);
      if (passwordError != null) {
        auth.handleError(
          clerk.ClerkError.clientAppError(message: passwordError),
        );
        return;
      }
    }

    setState(() => _busy = true);
    await auth.safelyCall(
      context,
      () async {
        if (_isSignUp) {
          await auth.attemptSignUp(
            emailAddress: identifier,
            username: username,
            password: password,
            passwordConfirmation: _confirm.text,
          );
          final signUp = auth.signUp;
          if (signUp != null && signUp.unverified(clerk.Field.emailAddress)) {
            // Instance requires email verification → send the code, then
            // switch to the code-entry step.
            await auth.attemptSignUp(strategy: clerk.Strategy.emailCode);
            if (mounted) setState(() => _needsEmailCode = true);
          }
        } else {
          await auth.attemptSignIn(
            strategy: clerk.Strategy.password,
            identifier: identifier,
            password: password,
          );
          if (!auth.isSignedIn && auth.signIn?.needsFactor == true) {
            if (auth.signIn?.needsSecondFactor == true ||
                auth.signIn?.needsClientTrust == true) {
              // Clerk wants an email-code verification to complete the sign-in
              // (second factor / client trust). Mirror the sign-up flow: send
              // the code, then switch to the code-entry step.
              await auth.attemptSignIn(strategy: clerk.Strategy.emailCode);
              if (mounted) setState(() => _needsEmailCode = true);
            } else {
              auth.handleError(
                clerk.ClerkError.clientAppError(
                  message: 'Sign-in didn\'t complete. Please try again.',
                ),
              );
            }
          }
        }
      },
    );
    if (mounted) setState(() => _busy = false);
  }

  /// Google OAuth: delegates the per-platform handshake to
  /// [completeGoogleOAuth]; this screen only owns the busy spinner and the
  /// transition into the missing-fields continuation form.
  Future<void> _googleSignIn(ClerkAuthState auth) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await completeGoogleOAuth(
        context,
        auth: auth,
        onMissingFields: (fields) {
          if (!mounted) return;
          setState(() {
            _isSignUp = true;
            _needsEmailCode = false;
            _missingFields = fields;
          });
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggleMode() {
    GoogleOAuthCallback.cancelPending();
    setState(() {
      _isSignUp = !_isSignUp;
      _needsEmailCode = false;
      _missingFields = const <clerk.Field>[];
      _legalAccepted = false;
      _username.clear();
      _confirm.clear();
      _code.clear();
    });
  }

  Future<void> _resendCode(ClerkAuthState auth) async {
    if (_busy) return;
    setState(() => _busy = true);
    await auth.safelyCall(
      context,
      () => auth.resendCode(clerk.Strategy.emailCode),
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ClerkAuth.of(context);
    final theme = Theme.of(context);

    final title = _needsEmailCode
        ? 'Verify your email'
        : _isSignUp
            ? 'Create account'
            : 'Sign in';

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.forum_rounded,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 16),
                    if (_needsEmailCode) ...[
                      Text(
                        'We sent a code to ${_identifier.text.trim()}. Enter it below.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _code,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Verification code',
                        ),
                        onSubmitted: (_) => _submit(auth),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : () => _submit(auth),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Verify'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _resendCode(auth),
                        child: const Text('Resend code'),
                      ),
                    ] else if (_oauthContinuation) ...[
                      // Google sign-up that still owes required fields:
                      // render one input per missing field.
                      Text(
                        'A few more details to finish creating your account:',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      ..._buildMissingFieldInputs(auth),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : () => _submit(auth),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Create account'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _toggleMode,
                        child: const Text('Already have an account? Sign in'),
                      ),
                    ] else ...[
                      if (_isSignUp) ...[
                        TextField(
                          controller: _username,
                          autocorrect: false,
                          decoration: const InputDecoration(
                            labelText: 'Username',
                          ),
                          onSubmitted: (_) => _submit(auth),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: _identifier,
                        autocorrect: false,
                        decoration: InputDecoration(
                          // Username or email on sign-in; sign-up must
                          // collect a real email for verification.
                          labelText:
                              _isSignUp ? 'Email address' : 'Username or email',
                        ),
                        onSubmitted: (_) => _submit(auth),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Password',
                        ),
                        onSubmitted: (_) => _submit(auth),
                      ),
                      if (_isSignUp) ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _confirm,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: 'Confirm password',
                          ),
                          onSubmitted: (_) => _submit(auth),
                        ),
                      ],
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _busy ? null : () => _submit(auth),
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_isSignUp ? 'Create account' : 'Sign in'),
                      ),
                      // Google OAuth runs without an in-app webview on every
                      // platform (desktop: system browser + local callback
                      // server; web: same-origin popup). Android uses the
                      // prebuilt ClerkAuthentication widget, which already
                      // ships its own Google button.
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              'or',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: _busy ? null : () => _googleSignIn(auth),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          side: BorderSide(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Stylized Google "G" (Material Icons has no
                            // brand glyph).
                            Container(
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: theme.colorScheme.surfaceContainerHighest,
                              ),
                              child: Text(
                                'G',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _busy ? 'Opening browser…' : 'Continue with Google',
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _toggleMode,
                        child: Text(
                          _isSignUp
                              ? 'Already have an account? Sign in'
                              : 'New here? Create an account',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
