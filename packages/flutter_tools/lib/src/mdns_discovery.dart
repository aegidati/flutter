// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'base/common.dart';
import 'base/context.dart';
import 'base/io.dart';
import 'base/logger.dart';
import 'build_info.dart';
import 'device.dart';
import 'reporting/reporting.dart';

/// A wrapper around [MDnsClient] to find a Dart VM Service instance.
class MDnsVmServiceDiscovery {
  /// Creates a new [MDnsVmServiceDiscovery] object.
  ///
  /// The [_client] parameter will be defaulted to a new [MDnsClient] if null.
  MDnsVmServiceDiscovery({
    MDnsClient? mdnsClient,
    MDnsClient? preliminaryMDnsClient,
    required Logger logger,
    required Usage flutterUsage,
  })  : _client = mdnsClient ?? MDnsClient(),
        _preliminaryClient = preliminaryMDnsClient,
        _logger = logger,
        _flutterUsage = flutterUsage;

  final MDnsClient _client;

  // Used when discovering VM services with `queryForAttach` to do a preliminary
  // check for already running services so that results are not cached in _client.
  final MDnsClient? _preliminaryClient;

  final Logger _logger;
  final Usage _flutterUsage;

  @visibleForTesting
  static const String dartVmServiceName = '_dartobservatory._tcp.local';

  static MDnsVmServiceDiscovery? get instance => context.get<MDnsVmServiceDiscovery>();

  /// Executes an mDNS query for Dart VM Services.
  /// Checks for services that have already been launched.
  /// If none are found, it will listen for new services to become active
  /// and return the first it finds that match the parameters.
  ///
  /// The [applicationId] parameter may be used to specify which application
  /// to find. For Android, it refers to the package name; on iOS, it refers to
  /// the bundle ID.
  ///
  /// The [deviceVmservicePort] parameter may be used to specify which port
  /// to find.
  ///
  /// The [isNetworkDevice] parameter flags whether to get the device IP
  /// and the [ipv6] parameter flags whether to get an iPv6 address
  /// (otherwise it will get iPv4).
  ///
  /// The [timeout] parameter determines how long to continue to wait for
  /// services to become active.
  ///
  /// If [applicationId] is not null, this method will find the port and authentication code
  /// of the Dart VM Service for that application. If it cannot find a service matching
  /// that application identifier after the [timeout], it will call [throwToolExit].
  ///
  /// If [applicationId] is null and there are multiple Dart VM Services available,
  /// the user will be prompted with a list of available services with the respective
  /// app-id and device-vmservice-port to use and asked to select one.
  ///
  /// If it is null and there is only one available or it's the first found instance
  /// of Dart VM Service, it will return that instance's information regardless of
  /// what application the service instance is for.
  @visibleForTesting
  Future<MDnsVmServiceDiscoveryResult?> queryForAttach({
    String? applicationId,
    int? deviceVmservicePort,
    bool ipv6 = false,
    bool isNetworkDevice = false,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    // Poll for 5 seconds to see if there are already services running.
    // Use a new instance of MDnsClient so results don't get cached in _client.
    // If no results are found, poll for a longer duration to wait for connections.
    // If more than 1 result is found, throw an error since it can't be determined which to pick.
    // If only one is found, return it.
    final List<MDnsVmServiceDiscoveryResult> results = await _pollingVmService(
      _preliminaryClient ?? MDnsClient(),
      applicationId: applicationId,
      deviceVmservicePort: deviceVmservicePort,
      ipv6: ipv6,
      isNetworkDevice: isNetworkDevice,
      timeout: const Duration(seconds: 5),
    );
    if (results.isEmpty) {
      return firstMatchingVmService(
        _client,
        applicationId: applicationId,
        deviceVmservicePort: deviceVmservicePort,
        ipv6: ipv6,
        isNetworkDevice: isNetworkDevice,
        timeout: timeout,
      );
    } else if (results.length > 1) {
      final StringBuffer buffer = StringBuffer();
      buffer.writeln('There are multiple Dart VM Services available.');
      buffer.writeln('Rerun this command with one of the following passed in as the app-id and device-vmservice-port:');
      buffer.writeln();
      for (final MDnsVmServiceDiscoveryResult result in results) {
        buffer.writeln(
            '  flutter attach --app-id "${result.domainName.replaceAll('.$dartVmServiceName', '')}" --device-vmservice-port ${result.port}');
      }
      throwToolExit(buffer.toString());
    }
    return results.first;
  }

  /// Executes an mDNS query for Dart VM Services.
  /// Listens for new services to become active and returns the first it finds that
  /// match the parameters.
  ///
  /// The [applicationId] parameter must be set to specify which application
  /// to find. For Android, it refers to the package name; on iOS, it refers to
  /// the bundle ID.
  ///
  /// The [deviceVmservicePort] parameter must be set to specify which port
  /// to find.
  ///
  /// [applicationId] and [deviceVmservicePort] are required for launch so that
  /// if multiple flutter apps are running on different devices, it will
  /// only match with the device running the desired app.
  ///
  /// The [isNetworkDevice] parameter flags whether to get the device IP
  /// and the [ipv6] parameter flags whether to get an iPv6 address
  /// (otherwise it will get iPv4).
  ///
  /// The [timeout] parameter determines how long to continue to wait for
  /// services to become active.
  ///
  /// If a Dart VM Service matching the [applicationId] and [deviceVmservicePort]
  /// cannot be found after the [timeout], it will call [throwToolExit].
  @visibleForTesting
  Future<MDnsVmServiceDiscoveryResult?> queryForLaunch({
    required String applicationId,
    required int deviceVmservicePort,
    bool ipv6 = false,
    bool isNetworkDevice = false,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    // Query for a specific application and device port.
    return firstMatchingVmService(
      _client,
      applicationId: applicationId,
      deviceVmservicePort: deviceVmservicePort,
      ipv6: ipv6,
      isNetworkDevice: isNetworkDevice,
      timeout: timeout,
    );
  }

  /// Polls for Dart VM Services and returns the first it finds that match
  /// the [applicationId]/[deviceVmservicePort] (if applicable).
  /// Returns null if no results are found.
  @visibleForTesting
  Future<MDnsVmServiceDiscoveryResult?> firstMatchingVmService(
    MDnsClient client, {
    String? applicationId,
    int? deviceVmservicePort,
    bool ipv6 = false,
    bool isNetworkDevice = false,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final List<MDnsVmServiceDiscoveryResult> results = await _pollingVmService(
      client,
      applicationId: applicationId,
      deviceVmservicePort: deviceVmservicePort,
      ipv6: ipv6,
      isNetworkDevice: isNetworkDevice,
      timeout: timeout,
      quitOnFind: true,
    );
    if (results.isEmpty) {
      return null;
    }
    return results.first;
  }

  Future<List<MDnsVmServiceDiscoveryResult>> _pollingVmService(
    MDnsClient client, {
    String? applicationId,
    int? deviceVmservicePort,
    bool ipv6 = false,
    bool isNetworkDevice = false,
    required Duration timeout,
    bool quitOnFind = false,
  }) async {
    _logger.printTrace('Checking for advertised Dart VM Services...');
    try {
      await client.start();

      final List<MDnsVmServiceDiscoveryResult> results =
          <MDnsVmServiceDiscoveryResult>[];
      final Set<String> uniqueDomainNames = <String>{};

      // Listen for mDNS connections until timeout.
      final Stream<PtrResourceRecord> ptrResourceStream = client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(dartVmServiceName),
        timeout: timeout
      );
      await for (final PtrResourceRecord ptr in ptrResourceStream) {
        uniqueDomainNames.add(ptr.domainName);

        String? domainName;
        if (applicationId != null) {
          // If applicationId is set, only use records that match it
          if (ptr.domainName.toLowerCase().startsWith(applicationId.toLowerCase())) {
            domainName = ptr.domainName;
          } else {
            continue;
          }
        } else {
          domainName = ptr.domainName;
        }

        _logger.printTrace('Checking for available port on $domainName');
        final List<SrvResourceRecord> srvRecords = await client
          .lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(domainName),
          )
          .toList();
        if (srvRecords.isEmpty) {
          continue;
        }

        // If more than one SrvResourceRecord found, it should just be a duplicate.
        final SrvResourceRecord srvRecord = srvRecords.first;
        if (srvRecords.length > 1) {
          _logger.printWarning(
              'Unexpectedly found more than one Dart VM Service report for $domainName '
              '- using first one (${srvRecord.port}).');
        }

        // If deviceVmservicePort is set, only use records that match it
        if (deviceVmservicePort != null && srvRecord.port != deviceVmservicePort) {
          continue;
        }

        // Get the IP address of the service if using a network device.
        InternetAddress? ipAddress;
        if (isNetworkDevice) {
          List<IPAddressResourceRecord> ipAddresses = await client
            .lookup<IPAddressResourceRecord>(
              ipv6
                  ? ResourceRecordQuery.addressIPv6(srvRecord.target)
                  : ResourceRecordQuery.addressIPv4(srvRecord.target),
            )
            .toList();
          if (ipAddresses.isEmpty) {
            throwToolExit('Did not find IP for service ${srvRecord.target}.');
          }

          // Filter out link-local addresses.
          if (ipAddresses.length > 1) {
            ipAddresses = ipAddresses.where((IPAddressResourceRecord element) => !element.address.isLinkLocal).toList();
          }

          ipAddress = ipAddresses.first.address;
          if (ipAddresses.length > 1) {
            _logger.printWarning(
                'Unexpectedly found more than one IP for Dart VM Service ${srvRecord.target} '
                '- using first one ($ipAddress).');
          }
        }

        _logger.printTrace('Checking for authentication code for $domainName');
        final List<TxtResourceRecord> txt = await client
          .lookup<TxtResourceRecord>(
              ResourceRecordQuery.text(domainName),
          )
          .toList();
        if (txt == null || txt.isEmpty) {
          results.add(MDnsVmServiceDiscoveryResult(domainName, srvRecord.port, ''));
          if (quitOnFind) {
            return results;
          }
          continue;
        }
        const String authCodePrefix = 'authCode=';
        String? raw;
        for (final String record in txt.first.text.split('\n')) {
          if (record.startsWith(authCodePrefix)) {
            raw = record;
            break;
          }
        }
        if (raw == null) {
          results.add(MDnsVmServiceDiscoveryResult(domainName, srvRecord.port, ''));
          if (quitOnFind) {
            return results;
          }
          continue;
        }
        String authCode = raw.substring(authCodePrefix.length);
        // The Dart VM Service currently expects a trailing '/' as part of the
        // URI, otherwise an invalid authentication code response is given.
        if (!authCode.endsWith('/')) {
          authCode += '/';
        }

        results.add(MDnsVmServiceDiscoveryResult(
          domainName,
          srvRecord.port,
          authCode,
          ipAddress: ipAddress
        ));
        if (quitOnFind) {
          return results;
        }
      }

      // If applicationId is set and quitOnFind is true and no results matching
      // the applicationId were found but other results were found, throw an error.
      if (applicationId != null &&
          quitOnFind &&
          results.isEmpty &&
          uniqueDomainNames.isNotEmpty) {
        String message = 'Did not find a Dart VM Service advertised for $applicationId';
        if (deviceVmservicePort != null) {
          message += ' on port $deviceVmservicePort';
        }
        throwToolExit('$message.');
      }

      return results;
    } finally {
      client.stop();
    }
  }

  /// Gets Dart VM Service Uri for `flutter attach`.
  /// Executes an mDNS query and waits until a Dart VM Service is found.
  ///
  /// Differs from `getVMServiceUriForLaunch` because it can search for any available Dart VM Service.
  /// Since [applicationId] and [deviceVmservicePort] are optional, it can either look for any service
  /// or a specific service matching [applicationId]/[deviceVmservicePort].
  /// It may find more than one service, which will throw an error listing the found services.
  Future<Uri?> getVMServiceUriForAttach(
    String? applicationId,
    Device device, {
    bool usesIpv6 = false,
    int? hostVmservicePort,
    int? deviceVmservicePort,
    bool isNetworkDevice = false,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final MDnsVmServiceDiscoveryResult? result = await queryForAttach(
      applicationId: applicationId,
      deviceVmservicePort: deviceVmservicePort,
      ipv6: usesIpv6,
      isNetworkDevice: isNetworkDevice,
      timeout: timeout,
    );
    return _handleResult(
      result,
      device,
      applicationId: applicationId,
      deviceVmservicePort: deviceVmservicePort,
      hostVmservicePort: hostVmservicePort,
      usesIpv6: usesIpv6,
      isNetworkDevice: isNetworkDevice
    );
  }

  /// Gets Dart VM Service Uri for `flutter run`.
  /// Executes an mDNS query and waits until the Dart VM Service service is found.
  ///
  /// Differs from `getVMServiceUriForAttach` because it only searches for a specific service.
  /// This is enforced by [applicationId] and [deviceVmservicePort] being required.
  Future<Uri?> getVMServiceUriForLaunch(
    String applicationId,
    Device device, {
    bool usesIpv6 = false,
    int? hostVmservicePort,
    required int deviceVmservicePort,
    bool isNetworkDevice = false,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final MDnsVmServiceDiscoveryResult? result = await queryForLaunch(
      applicationId: applicationId,
      deviceVmservicePort: deviceVmservicePort,
      ipv6: usesIpv6,
      isNetworkDevice: isNetworkDevice,
      timeout: timeout,
    );
    return _handleResult(
      result,
      device,
      applicationId: applicationId,
      deviceVmservicePort: deviceVmservicePort,
      hostVmservicePort: hostVmservicePort,
      usesIpv6: usesIpv6,
      isNetworkDevice: isNetworkDevice
    );
  }

  Future<Uri?> _handleResult(
    MDnsVmServiceDiscoveryResult? result,
    Device device, {
    String? applicationId,
    int? deviceVmservicePort,
    int? hostVmservicePort,
    bool usesIpv6 = false,
    bool isNetworkDevice = false,
  }) async {
    if (result == null) {
      await _checkForIPv4LinkLocal(device);
      return null;
    }
    final String host;

    final InternetAddress? ipAddress = result.ipAddress;
    if (isNetworkDevice && ipAddress != null) {
      host = ipAddress.address;
    } else {
      host = usesIpv6
      ? InternetAddress.loopbackIPv6.address
      : InternetAddress.loopbackIPv4.address;
    }
    return buildVMServiceUri(
      device,
      host,
      result.port,
      hostVmservicePort,
      result.authCode,
      isNetworkDevice,
    );
  }

  // If there's not an ipv4 link local address in `NetworkInterfaces.list`,
  // then request user interventions with a `printError()` if possible.
  Future<void> _checkForIPv4LinkLocal(Device device) async {
    _logger.printTrace(
      'mDNS query failed. Checking for an interface with a ipv4 link local address.'
    );
    final List<NetworkInterface> interfaces = await listNetworkInterfaces(
      includeLinkLocal: true,
      type: InternetAddressType.IPv4,
    );
    if (_logger.isVerbose) {
      _logInterfaces(interfaces);
    }
    final bool hasIPv4LinkLocal = interfaces.any(
      (NetworkInterface interface) => interface.addresses.any(
        (InternetAddress address) => address.isLinkLocal,
      ),
    );
    if (hasIPv4LinkLocal) {
      _logger.printTrace('An interface with an ipv4 link local address was found.');
      return;
    }
    final TargetPlatform targetPlatform = await device.targetPlatform;
    switch (targetPlatform) {
      case TargetPlatform.ios:
        UsageEvent('ios-mdns', 'no-ipv4-link-local', flutterUsage: _flutterUsage).send();
        _logger.printError(
          'The mDNS query for an attached iOS device failed. It may '
          'be necessary to disable the "Personal Hotspot" on the device, and '
          'to ensure that the "Disable unless needed" setting is unchecked '
          'under System Preferences > Network > iPhone USB. '
          'See https://github.com/flutter/flutter/issues/46698 for details.'
        );
        break;
      case TargetPlatform.android:
      case TargetPlatform.android_arm:
      case TargetPlatform.android_arm64:
      case TargetPlatform.android_x64:
      case TargetPlatform.android_x86:
      case TargetPlatform.darwin:
      case TargetPlatform.fuchsia_arm64:
      case TargetPlatform.fuchsia_x64:
      case TargetPlatform.linux_arm64:
      case TargetPlatform.linux_x64:
      case TargetPlatform.tester:
      case TargetPlatform.web_javascript:
      case TargetPlatform.windows_x64:
        _logger.printTrace('No interface with an ipv4 link local address was found.');
        break;
    }
  }

  void _logInterfaces(List<NetworkInterface> interfaces) {
    for (final NetworkInterface interface in interfaces) {
      if (_logger.isVerbose) {
        _logger.printTrace('Found interface "${interface.name}":');
        for (final InternetAddress address in interface.addresses) {
          final String linkLocal = address.isLinkLocal ? 'link local' : '';
          _logger.printTrace('\tBound address: "${address.address}" $linkLocal');
        }
      }
    }
  }
}

class MDnsVmServiceDiscoveryResult {
  MDnsVmServiceDiscoveryResult(
    this.domainName,
    this.port,
    this.authCode, {
    this.ipAddress
  });
  final String domainName;
  final int port;
  final String authCode;
  final InternetAddress? ipAddress;
}

Future<Uri> buildVMServiceUri(
  Device device,
  String host,
  int devicePort, [
  int? hostVmservicePort,
  String? authCode,
  bool isNetworkDevice = false,
]) async {
  String path = '/';
  if (authCode != null) {
    path = authCode;
  }
  // Not having a trailing slash can cause problems in some situations.
  // Ensure that there's one present.
  if (!path.endsWith('/')) {
    path += '/';
  }
  hostVmservicePort ??= 0;

  final int? actualHostPort;
  if (isNetworkDevice) {
    // When debugging with a network device, port forwarding is not required
    // so just use the device's port.
    actualHostPort = devicePort;
  } else {
    actualHostPort = hostVmservicePort == 0 ?
    await device.portForwarder?.forward(devicePort) :
    hostVmservicePort;
  }
  return Uri(scheme: 'http', host: host, port: actualHostPort, path: path);
}
