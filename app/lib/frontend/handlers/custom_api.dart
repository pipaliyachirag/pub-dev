// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:client_data/package_api.dart';
import 'package:shelf/shelf.dart' as shelf;

import '../../dartdoc/backend.dart';
import '../../frontend/request_context.dart';
import '../../history/backend.dart';
import '../../package/backend.dart';
import '../../package/name_tracker.dart';
import '../../package/overrides.dart';
import '../../scorecard/backend.dart';
import '../../search/search_client.dart';
import '../../search/search_form.dart';
import '../../search/search_service.dart';
import '../../shared/configuration.dart';
import '../../shared/exceptions.dart';
import '../../shared/handlers.dart';
import '../../shared/redis_cache.dart' show cache;
import '../../shared/urls.dart' as urls;

/// Handles requests for /api/documentation/<package>
Future<shelf.Response> apiDocumentationHandler(
    shelf.Request request, String package) async {
  if (isSoftRemoved(package)) {
    return jsonResponse({}, status: 404);
  }

  final cachedData = await cache.dartdocApiSummary(package).get();
  if (cachedData != null) {
    return jsonResponse(cachedData);
  }

  final versions = await packageBackend.versionsOfPackage(package);
  if (versions.isEmpty) {
    return jsonResponse({}, status: 404);
  }

  versions.sort((a, b) => a.semanticVersion.compareTo(b.semanticVersion));
  String latestStableVersion = versions.last.version;
  for (int i = versions.length - 1; i >= 0; i--) {
    if (!versions[i].semanticVersion.isPreRelease) {
      latestStableVersion = versions[i].version;
      break;
    }
  }

  final dartdocEntries = await dartdocBackend.getEntriesForVersions(
      package, versions.map((pv) => pv.version).toList());

  final versionsData = [];
  for (int i = 0; i < versions.length; i++) {
    final entry = dartdocEntries[i];
    final hasDocumentation = entry != null && entry.hasContent;
    final status =
        entry == null ? 'awaiting' : (entry.hasContent ? 'success' : 'failed');
    versionsData.add({
      'version': versions[i].version,
      'status': status,
      'hasDocumentation': hasDocumentation,
    });
  }
  final data = {
    'name': package,
    'latestStableVersion': latestStableVersion,
    'versions': versionsData,
  };
  await cache.dartdocApiSummary(package).set(data);
  return jsonResponse(data);
}

/// Handles requests for
/// - /api/packages?compact=1
Future<shelf.Response> apiPackagesCompactListHandler(
    shelf.Request request) async {
  final packageNames = await nameTracker.getPackageNames();
  packageNames.removeWhere(isSoftRemoved);
  return jsonResponse({'packages': packageNames});
}

/// Handles request for /api/packages?page=<num>
Future<shelf.Response> apiPackagesHandler(shelf.Request request) async {
  final int pageSize = 100;
  final int page =
      extractPageFromUrlParameters(request.requestedUri.queryParameters);

  // Check that we're not at last page (abuse -1 as special index in cache)
  final lastPageCacheEntry = cache.apiPackagesListPage(-1);
  final lastPage = await lastPageCacheEntry.get();
  if (lastPage != null) {
    if (page > (lastPage['page'] as num)) {
      return jsonResponse({'message': 'no content'}, status: 400);
    }
  }

  final data = await cache.apiPackagesListPage(page).get(() async {
    final pkgPage = await packageBackend.latestPackages(
        offset: pageSize * (page - 1), limit: pageSize);
    final pageVersions =
        await packageBackend.lookupLatestVersions(pkgPage.packages);

    final packagesJson = [];

    final uri = activeConfiguration.primaryApiUri;
    for (var version in pageVersions) {
      final versionString = Uri.encodeComponent(version.version);
      final packageString = Uri.encodeComponent(version.package);

      final apiArchiveUrl = urls.pkgArchiveDownloadUrl(
          version.package, version.version,
          baseUri: uri);
      final apiPackageUrl =
          uri.resolve('/api/packages/$packageString').toString();
      final apiPackageVersionUrl = uri
          .resolve('/api/packages/$packageString/versions/$versionString')
          .toString();

      packagesJson.add({
        'name': version.package,
        'latest': {
          'version': version.version,
          'pubspec': version.pubspec.asJson,

          // TODO: We should get rid of these:
          'archive_url': apiArchiveUrl,
          'package_url': apiPackageUrl,
          'url': apiPackageVersionUrl,

          // NOTE: We do not add the following
          //    - 'new_dartdoc_url'
        },
      });
    }

    final json = <String, dynamic>{
      'next_url': null,
      'packages': packagesJson,

      // NOTE: We do not add the following:
      //     - 'pages'
      //     - 'prev_url'
    };

    if (!pkgPage.isLast) {
      json['next_url'] = '${uri.resolve('/api/packages?page=${page + 1}')}';
    } else {
      // Set the last page in cache, if not already there with a lower number.
      final lastPage = await lastPageCacheEntry.get();
      if (lastPage == null || lastPage['page'] as int > page) {
        await lastPageCacheEntry.set({'page': page});
      }
    }
    return json;
  });

  return jsonResponse(data);
}

/// Handles requests for
/// - /api/packages/<package>/metrics
Future<shelf.Response> apiPackageMetricsHandler(
    shelf.Request request, String packageName) async {
  final packageVersion = request.requestedUri.queryParameters['version'];
  final current = request.requestedUri.queryParameters.containsKey('current');
  final data = await scoreCardBackend
      .getScoreCardData(packageName, packageVersion, onlyCurrent: current);
  if (data == null) {
    return jsonResponse({}, status: 404);
  }
  final score = await packageVersionScoreHandler(request, packageName);
  final result = {
    'score': score?.toJson(),
    'scorecard': data.toJson(),
  };
  if (request.requestedUri.queryParameters.containsKey('reports')) {
    final reports = await scoreCardBackend.loadReports(
      packageName,
      data.packageVersion,
      runtimeVersion: data.runtimeVersion,
    );
    result['reports'] =
        reports.map((k, report) => MapEntry(k, report.toJson()));
  }
  return jsonResponse(result);
}

/// Handles requests for
//  - /api/packages/<package>/score
/// - /api/packages/<package>/versions/<version>/score
Future<VersionScore> packageVersionScoreHandler(
    shelf.Request request, String package,
    {String version}) async {
  return await cache.versionScore(package, version).get(() async {
    final pkg = await packageBackend.lookupPackage(package);
    if (pkg == null) {
      throw NotFoundException.resource('package "$package"');
    }
    var updated = pkg.updated;
    final card = await scoreCardBackend.getScoreCardData(package, version);
    if (card != null && card.updated.isAfter(updated)) {
      updated = card.updated;
    }
    return VersionScore(
      grantedPoints: card?.grantedPubPoints,
      maxPoints: card?.maxPubPoints,
      likeCount: pkg.likes,
      popularityScore: card?.popularityScore,
      lastUpdated: updated,
    );
  });
}

/// Handles requests for /api/history
/// NOTE: Experimental, do not rely on it.
Future<shelf.Response> apiHistoryHandler(shelf.Request request) async {
  final list = await historyBackend
      .getAll(
        packageName: request.requestedUri.queryParameters['package'],
        packageVersion: request.requestedUri.queryParameters['version'],
        limit: 25,
      )
      .toList();
  return jsonResponse({
    'results': list
        .map((h) => {
              'id': h.id,
              'package': h.packageName,
              'version': h.packageVersion,
              'timestamp': h.timestamp.toIso8601String(),
              'source': h.source,
              'eventType': h.eventType,
              'eventData': h.eventData,
              'markdown': h.formatMarkdown(),
            })
        .toList(),
  });
}

/// Handles requests for /api/search
Future<shelf.Response> apiSearchHandler(shelf.Request request) async {
  final searchForm = parseFrontendSearchForm(
    request.requestedUri.queryParameters,
    tagsPredicate: TagsPredicate.regularSearch(),
  );
  final sr = await searchClient.search(searchForm.toServiceQuery());
  final packages = sr.packages.map((ps) => {'package': ps.package}).toList();
  final hasNextPage = sr.totalCount > searchForm.pageSize + searchForm.offset;
  final result = <String, dynamic>{
    'packages': packages,
    if (sr.message != null) 'message': sr.message,
  };
  if (hasNextPage) {
    final newParams =
        Map<String, dynamic>.from(request.requestedUri.queryParameters);
    newParams['page'] = (searchForm.currentPage + 1).toString();
    final nextPageUrl =
        request.requestedUri.replace(queryParameters: newParams).toString();
    result['next'] = nextPageUrl;
  }
  return jsonResponse(result, indentJson: requestContext.indentJson);
}

/// Handles GET /api/packages/<package>/options
Future<PkgOptions> getPackageOptionsHandler(
  shelf.Request request,
  String package,
) async {
  final p = await packageBackend.lookupPackage(package);
  if (p == null) {
    throw NotFoundException.resource(package);
  }
  return PkgOptions(
    isDiscontinued: p.isDiscontinued,
    isUnlisted: p.isUnlisted,
  );
}

/// Handles PUT /api/packages/<package>/options
Future<PkgOptions> putPackageOptionsHandler(
  shelf.Request request,
  String package,
  PkgOptions options,
) async {
  await packageBackend.updateOptions(package, options);
  return await getPackageOptionsHandler(request, package);
}
