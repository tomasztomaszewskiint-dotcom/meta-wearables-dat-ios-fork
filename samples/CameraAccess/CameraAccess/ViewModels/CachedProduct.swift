//
//  CachedProduct.swift
//  CameraAccess
//

import Foundation
import SwiftData

/// Product details previously looked up for a barcode, cached locally so a
/// repeat scan of the same barcode resolves even without a network connection.
@Model
final class CachedProduct {
  @Attribute(.unique) var barcode: String
  var name: String
  var fetchedAt: Date
  var nutriScore: String?
  var novaGroup: Int?
  var quantity: String?
  var ingredientsText: String?
  var energyKcal100g: Double?
  var fat100g: Double?
  var sugars100g: Double?
  var salt100g: Double?
  var proteins100g: Double?

  init(barcode: String, details: ProductDetails, fetchedAt: Date) {
    self.barcode = barcode
    self.name = details.name
    self.fetchedAt = fetchedAt
    self.nutriScore = details.nutriScore
    self.novaGroup = details.novaGroup
    self.quantity = details.quantity
    self.ingredientsText = details.ingredientsText
    self.energyKcal100g = details.energyKcal100g
    self.fat100g = details.fat100g
    self.sugars100g = details.sugars100g
    self.salt100g = details.salt100g
    self.proteins100g = details.proteins100g
  }
}

extension CachedProduct {
  var details: ProductDetails {
    ProductDetails(
      name: name,
      nutriScore: nutriScore,
      novaGroup: novaGroup,
      quantity: quantity,
      ingredientsText: ingredientsText,
      energyKcal100g: energyKcal100g,
      fat100g: fat100g,
      sugars100g: sugars100g,
      salt100g: salt100g,
      proteins100g: proteins100g
    )
  }
}
