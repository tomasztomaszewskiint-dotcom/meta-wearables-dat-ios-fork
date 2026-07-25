//
//  ProductLookupService.swift
//  CameraAccess
//

import Foundation

enum ProductLookupError: Error {
  case productNotFound
  case invalidResponse
}

/// Product details available from Open Food Facts for a given barcode —
/// beyond just the name, whatever nutritional/label data the product happens
/// to have on file (many fields are optional since community-submitted data
/// coverage varies a lot product to product).
struct ProductDetails {
  let name: String
  /// Nutri-Score letter grade ("a"..."e"), Open Food Facts' health rating.
  let nutriScore: String?
  /// NOVA food-processing classification (1-4, higher = more processed).
  let novaGroup: Int?
  let quantity: String?
  let ingredientsText: String?
  let energyKcal100g: Double?
  let fat100g: Double?
  let sugars100g: Double?
  let salt100g: Double?
  let proteins100g: Double?
}

/// Looks up product details by barcode using the Open Food Facts public API
/// (https://world.openfoodfacts.org), which is free and requires no API key.
final class ProductLookupService {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func lookupProduct(barcode: String) async throws -> ProductDetails {
    guard let url = URL(string: "https://world.openfoodfacts.org/api/v0/product/\(barcode).json") else {
      throw ProductLookupError.invalidResponse
    }

    let (data, response) = try await session.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
      throw ProductLookupError.invalidResponse
    }

    let decoded = try JSONDecoder().decode(OpenFoodFactsResponse.self, from: data)
    guard
      decoded.status == 1,
      let product = decoded.product,
      let name = product.productName,
      !name.isEmpty
    else {
      throw ProductLookupError.productNotFound
    }

    return ProductDetails(
      name: name,
      nutriScore: product.nutriScore,
      novaGroup: product.novaGroup,
      quantity: product.quantity,
      ingredientsText: product.ingredientsText,
      energyKcal100g: product.nutriments?.energyKcal100g,
      fat100g: product.nutriments?.fat100g,
      sugars100g: product.nutriments?.sugars100g,
      salt100g: product.nutriments?.salt100g,
      proteins100g: product.nutriments?.proteins100g
    )
  }
}

private struct OpenFoodFactsResponse: Decodable {
  let status: Int
  let product: Product?

  struct Product: Decodable {
    let productName: String?
    let nutriScore: String?
    let novaGroup: Int?
    let quantity: String?
    let ingredientsText: String?
    let nutriments: Nutriments?

    enum CodingKeys: String, CodingKey {
      case productName = "product_name"
      case nutriScore = "nutriscore_grade"
      case novaGroup = "nova_group"
      case quantity
      case ingredientsText = "ingredients_text"
      case nutriments
    }
  }

  struct Nutriments: Decodable {
    let energyKcal100g: Double?
    let fat100g: Double?
    let sugars100g: Double?
    let salt100g: Double?
    let proteins100g: Double?

    enum CodingKeys: String, CodingKey {
      case energyKcal100g = "energy-kcal_100g"
      case fat100g = "fat_100g"
      case sugars100g = "sugars_100g"
      case salt100g = "salt_100g"
      case proteins100g = "proteins_100g"
    }
  }
}
