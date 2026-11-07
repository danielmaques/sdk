part of 'paywall.dart';

class _ActionFeedback extends StatefulWidget {
  const _ActionFeedback({required this.animation, required this.child});
  final String animation;
  final Widget child;
  @override
  State<_ActionFeedback> createState() => _ActionFeedbackState();
}

class _ActionFeedbackState extends State<_ActionFeedback> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final scale = widget.animation == 'shrink' && _pressed
        ? 0.96
        : widget.animation == 'grow' && _pressed
        ? 1.04
        : 1.0;
    final opacity = widget.animation == 'fade' && _pressed ? 0.55 : 1.0;
    return Listener(
      onPointerDown: (_) => setState(() => _pressed = true),
      onPointerUp: (_) => setState(() => _pressed = false),
      onPointerCancel: (_) => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: opacity,
          duration: const Duration(milliseconds: 160),
          child: widget.child,
        ),
      ),
    );
  }
}
