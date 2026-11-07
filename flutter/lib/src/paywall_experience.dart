part of 'paywall.dart';

class _PaywallExperienceWebView extends StatefulWidget {
  const _PaywallExperienceWebView({
    required this.url,
    required this.height,
    required this.fallback,
    super.key,
  });

  final Uri url;
  final double height;
  final Widget? fallback;

  @override
  State<_PaywallExperienceWebView> createState() =>
      _PaywallExperienceWebViewState();
}

class _PaywallExperienceWebViewState extends State<_PaywallExperienceWebView> {
  MethodChannel? _statusChannel;
  bool _loading = true;
  bool _failed = false;

  void _onPlatformViewCreated(int viewId) {
    final channel = MethodChannel('app.pushify/paywall-web/$viewId');
    _statusChannel?.setMethodCallHandler(null);
    _statusChannel = channel;
    channel.setMethodCallHandler((call) async {
      if (!mounted) return;
      _applyWebViewStatus(call.method);
    });
    channel.invokeMethod<String>('ready').then((status) {
      if (mounted && status != null) {
        setState(() => _applyWebViewStatus(status));
      }
    });
  }

  void _applyWebViewStatus(String status) {
    if (status == 'loaded') {
      _loading = false;
      _failed = false;
    } else if (status == 'failed') {
      _loading = false;
      _failed = true;
    }
  }

  @override
  void dispose() {
    _statusChannel?.setMethodCallHandler(null);
    _statusChannel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final view = Platform.isAndroid
        ? AndroidView(
            viewType: 'app.pushify/paywall-web',
            creationParams: {'url': widget.url.toString()},
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _onPlatformViewCreated,
          )
        : UiKitView(
            viewType: 'app.pushify/paywall-web',
            creationParams: {'url': widget.url.toString()},
            creationParamsCodec: const StandardMessageCodec(),
            layoutDirection: TextDirection.ltr,
            onPlatformViewCreated: _onPlatformViewCreated,
          );
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            view,
            if (_loading || _failed)
              Positioned.fill(
                child:
                    widget.fallback ??
                    ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: _failed
                            ? Semantics(
                                label: 'Interactive experience unavailable',
                                child: Icon(
                                  Icons.web_asset_off_outlined,
                                  color: Colors.white70,
                                ),
                              )
                            : const CircularProgressIndicator(
                                color: Colors.white,
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
