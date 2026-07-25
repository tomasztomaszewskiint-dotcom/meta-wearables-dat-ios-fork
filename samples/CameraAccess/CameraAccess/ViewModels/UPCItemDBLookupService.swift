//
//  UPCItemDBLookupService.swift
//  CameraAccess
//

import Foundation

/// Fallback product lookup for barcodes Open Food Facts doesn't have —
/// UPCitemdb covers general retail merchandise (electronics, household
/// goods, etc.) that OFF, being food-focused, typically lacks. Free trial
/// tier: no API key required, but capped at 100 requests/day.
final class UPCItemDBLookupService {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func lookupProduct(barcode: String) async throws -> ProductDetails {
    guard let url = URL(string: "https://api.upcitemdb.com/prod/trial/lookup?upc=\(barcode)") else {
      throw ProductLookupError.invalidResponse
    }

    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
      throw ProductLookupError.invalidResponse
    }

    let decoded = try JSONDecoder().decode(UPCItemDBResponse.self, from: data)
    guard let item = decoded.items?.first, let title = item.title, !title.isEmpty else {
      throw ProductLookupError.productNotFound
    }

    // UPCitemdb is general-merchandise metadata, not nutritional data — only
    // name/quantity are available; nutrition fields stay nil, same as when
    // Open Food Facts has a product with incomplete data.
    return ProductDetails(
      name: title,
      nutriScore: nil,
      novaGroup: nil,
      quantity: item.weight,
      ingredientsText: nil,
      energyKcal100g: nil,
      fat100g: nil,
      sugars100g: nil,
      salt100g: nil,
      proteins100g: nil
    )
  }
}

private struct UPCItemDBResponse: Decodable {
  let items: [Item]?

  struct Item: Decodable {
    let title: String?
    let weight: String?
  }
}
