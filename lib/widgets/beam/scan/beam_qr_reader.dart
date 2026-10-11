/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Reading a QR code's text, for every BEAM screen that scans (the home's
// Scan, BEAM Send, a name transfer): Campfire's phone camera or its desktop
// scanner dialog, behind one interface tests replace.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/global/barcode_scanner_provider.dart';
import '../../../utilities/barcode_scanner_interface.dart';
import '../../../utilities/logger.dart';
import '../../desktop/qr_code_scanner_dialog.dart';

/// Reads one QR code's text: the phone's camera, or the desktop scanner
/// dialog. Null when nothing was read (closed, or no camera permission).
abstract interface class BeamQrReader {
  Future<String?> read(BuildContext context, {required bool desktop});
}

/// The app's QR reader. Tests replace it.
final pBeamQrReader = Provider<BeamQrReader>(
  (ref) => CampfireQrReader(ref.watch(pBarcodeScanner)),
);

/// Campfire's own scanners: [scanner] on a phone (asks for the camera, and
/// offers the system settings when it was refused), the desktop dialog
/// (camera or a picture of the code) on desktop.
class CampfireQrReader implements BeamQrReader {
  const CampfireQrReader(this.scanner);

  final BarcodeScannerInterface scanner;

  @override
  Future<String?> read(BuildContext context, {required bool desktop}) async {
    try {
      if (desktop) {
        return await showDialog<String>(
          context: context,
          builder: (_) => const QrCodeScannerDialog(),
        );
      }
      return (await scanner.scan(context: context)).rawContent;
    } on PlatformException catch (e, s) {
      // Never the scanned text: it may be someone's address.
      Logging.instance.w('BEAM scan: camera refused', error: e, stackTrace: s);
      if (context.mounted) {
        await checkCamPermDeniedMobileAndOpenAppSettings(
          context,
          logging: Logging.instance,
        );
      }
      return null;
    } catch (e, s) {
      Logging.instance.w('BEAM scan: failed', error: e, stackTrace: s);
      return null;
    }
  }
}

/// The app's [BeamQrReader] ([pBeamQrReader]), looked up when a scan
/// starts, for screens that are handed their dependencies rather than
/// reading providers.
class BeamScopedQrReader implements BeamQrReader {
  const BeamScopedQrReader();

  @override
  Future<String?> read(BuildContext context, {required bool desktop}) =>
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(pBeamQrReader).read(context, desktop: desktop);
}
