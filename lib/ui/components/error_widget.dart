// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_svg/svg.dart';

// Project imports:
import 'package:openlib/services/annas_archieve.dart';
import 'package:openlib/ui/extensions.dart';

// ignore: must_be_immutable
class CustomErrorWidget extends StatelessWidget {
  final Object error;
  final StackTrace stackTrace;
  VoidCallback? onRefresh;

  CustomErrorWidget({
    super.key,
    required this.error,
    required this.stackTrace,
    this.onRefresh,
  });

  // ── Decode the error into a display-friendly pair ──────────────────
  // Returns (title, body, isNetworkError, showRefresh)
  ({String title, String body, bool isNetwork, bool showRefresh}) _decode() {
    if (error is AnnasException) {
      final e = error as AnnasException;
      return switch (e.type) {
        AnnasErrorType.network || AnnasErrorType.allMirrorsDown => (
            title: 'Unable to Connect',
            body: e.message.contains('socketException')
                ? 'Check your internet connection and try again.'
                : e.message,
            isNetwork: true,
            showRefresh: true,
          ),
        AnnasErrorType.cloudflareBlocked => (
            title: 'Blocked by Cloudflare',
            body: e.message,
            isNetwork: false,
            showRefresh: true,
          ),
        AnnasErrorType.cloudflareCaptcha => (
            title: 'Cloudflare Verification Required',
            body: e.message,
            isNetwork: false,
            showRefresh: true,
          ),
        AnnasErrorType.htmlStructureChanged => (
            title: 'Scraper Needs Update',
            body: e.message,
            isNetwork: false,
            showRefresh: false,
          ),
        AnnasErrorType.unknown => (
            title: 'Something Went Wrong',
            body: e.message,
            isNetwork: false,
            showRefresh: true,
          ),
      };
    }

    // Legacy / non-AnnasException path (keeps backward compatibility)
    if (error.toString().contains('socketException') ||
        error.toString().contains('SocketException')) {
      return (
        title: 'Unable to Connect',
        body: 'Check your internet connection and try again.',
        isNetwork: true,
        showRefresh: true,
      );
    }

    return (
      title: 'Something Went Wrong',
      body: error.toString(),
      isNetwork: false,
      showRefresh: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = _decode();
    final colorScheme = Theme.of(context).colorScheme;

    // ── Network / all-mirrors-down ──────────────────────────────────
    if (info.isNetwork) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 200,
            child: SvgPicture.asset('assets/no_internet.svg', width: 200),
          ),
          const SizedBox(height: 30),
          Text(
            info.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: "#4D4D4D".toColor(),
            ),
          ),
          if (info.body != 'Check your internet connection and try again.')
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(
                info.body,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Colors.black54),
              ),
            ),
          _refreshButton(colorScheme),
        ],
      );
    }

    // ── All other errors ─────────────────────────────────────────────
    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 120),
          SizedBox(
            width: 200,
            child: SvgPicture.asset('assets/error_fixing_bugs.svg', width: 200),
          ),
          const SizedBox(height: 10),
          Text(
            info.title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3CD),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFECAA)),
              ),
              padding: const EdgeInsets.all(12),
              child: Text(
                info.body,
                textAlign: TextAlign.start,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF664D03),
                ),
              ),
            ),
          ),
          if (info.showRefresh) _refreshButton(colorScheme),
          // Debug-only: collapsible stack trace
          _DebugStackTrace(stackTrace: stackTrace),
        ],
      ),
    );
  }

  Widget _refreshButton(ColorScheme colorScheme) => SizedBox(
        height: 70,
        child: FittedBox(
          fit: BoxFit.none,
          child: TextButton(
            style: TextButton.styleFrom(
              backgroundColor: colorScheme.secondary,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
            onPressed: onRefresh,
            child: const Padding(
              padding: EdgeInsets.fromLTRB(21, 9, 21, 9),
              child: Text('Try Again', style: TextStyle(color: Colors.white)),
            ),
          ),
        ),
      );
}

/// Collapsible stack trace widget shown only in debug builds.
class _DebugStackTrace extends StatefulWidget {
  final StackTrace stackTrace;
  const _DebugStackTrace({required this.stackTrace});

  @override
  State<_DebugStackTrace> createState() => _DebugStackTraceState();
}

class _DebugStackTraceState extends State<_DebugStackTrace> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // Only show in debug mode
    const bool isDebug = bool.fromEnvironment('dart.vm.product') == false;
    if (!isDebug) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: [
                Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: Colors.grey),
                const SizedBox(width: 4),
                const Text(
                  'Stack Trace (debug)',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          if (_expanded)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 6),
              decoration: BoxDecoration(
                color: const Color.fromARGB(255, 255, 186, 186),
                borderRadius: BorderRadius.circular(5),
              ),
              padding: const EdgeInsets.all(7),
              child: Text(
                widget.stackTrace.toString(),
                style: const TextStyle(fontSize: 11, color: Colors.black),
              ),
            ),
        ],
      ),
    );
  }
}
