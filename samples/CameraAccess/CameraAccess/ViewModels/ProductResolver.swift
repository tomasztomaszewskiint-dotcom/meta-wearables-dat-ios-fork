//
//  ProductResolver.swift
//  CameraAccess
//

import Foundation
import SwiftData

/// Outcome of resolving a barcode to product details: either found (from
/// cache or a fresh network lookup), or not identified — with the specific
/// reason, so the UI can distinguish "offline" from "genuinely unknown".
enum ProductLookupResult {
  case found(details: ProductDetails, source: Source)
  case notIdentified(reason: Reason)

  enum Source {
    case cache
    case network
  }

  enum Reason {
    case offline
    case notFound
    case error
  }
}

/// Resolves a barcode to product details by checking the local cache first,
/// then Open Food Facts, then — only if OFF doesn't have it, since it's
/// food-focused — UPCitemdb as a fallback for general merchandise. Caches
/// whichever result succeeds, from either source, under the same barcode.
@MainActor
final class ProductResolver {
  private let modelContext: ModelContext
  private let lookupService: ProductLookupService
  private let fallbackLookupService: UPCItemDBLookupService
  private let networkMonitor: NetworkMonitor

  init(
    modelContext: ModelContext,
    networkMonitor: NetworkMonitor,
    lookupService: ProductLookupService = ProductLookupService(),
    fallbackLookupService: UPCItemDBLookupService = UPCItemDBLookupService()
  ) {
    self.modelContext = modelContext
    self.networkMonitor = networkMonitor
    self.lookupService = lookupService
    self.fallbackLookupService = fallbackLookupService
  }

  func resolveProduct(barcode: String) async -> ProductLookupResult {
    if let cached = fetchCachedProduct(barcode: barcode) {
      return .found(details: cached.details, source: .cache)
    }

    guard networkMonitor.isConnected else {
      return .notIdentified(reason: .offline)
    }

    do {
      let details = try await lookupService.lookupProduct(barcode: barcode)
      cacheProduct(barcode: barcode, details: details)
      return .found(details: details, source: .network)
    } catch ProductLookupError.productNotFound {
      return await resolveFromFallback(barcode: barcode)
    } catch {
      return .notIdentified(reason: .error)
    }
  }

  private func resolveFromFallback(barcode: String) async -> ProductLookupResult {
    do {
      let details = try await fallbackLookupService.lookupProduct(barcode: barcode)
      cacheProduct(barcode: barcode, details: details)
      return .found(details: details, source: .network)
    } catch {
      return .notIdentified(reason: .notFound)
    }
  }

  private func fetchCachedProduct(barcode: String) -> CachedProduct? {
    let descriptor = FetchDescriptor<CachedProduct>(
      predicate: #Predicate { $0.barcode == barcode }
    )
    return try? modelContext.fetch(descriptor).first
  }

  private func cacheProduct(barcode: String, details: ProductDetails) {
    modelContext.insert(CachedProduct(barcode: barcode, details: details, fetchedAt: Date()))
  }
}
