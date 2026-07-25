/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftUI
import Vision

struct StreamView: View {
  @Bindable var viewModel: StreamSessionViewModel
  var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          ZStack {
            Image(uiImage: videoFrame)
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .clipped()

            RecognizedTextOverlay(
              recognizedTexts: viewModel.recognizedTexts,
              reticleRect: viewModel.reticleRect
            )

            DetectedBarcodeOverlay(
              barcodes: viewModel.detectedBarcodes,
              productResults: viewModel.productResults,
              reticleRect: viewModel.reticleRect,
              onBuyTapped: { barcode, details in
                viewModel.beginPurchase(barcode: barcode, details: details)
              }
            )

            if let outline = viewModel.objectOutline {
              ObjectOutlineView(outline: outline, reticleRect: viewModel.reticleRect)
            }

            if let classification = viewModel.objectClassification {
              ObjectClassificationLabel(
                classification: classification,
                dominantColor: viewModel.objectDominantColor,
                reticleRect: viewModel.reticleRect
              )
              .animation(.easeInOut(duration: 0.25), value: viewModel.reticleRect)
            }

            if let identifyingText = viewModel.objectIdentifyingText {
              ObjectIdentifyingTextLabel(text: identifyingText, reticleRect: viewModel.reticleRect)
                .animation(.easeInOut(duration: 0.25), value: viewModel.reticleRect)
            }
          }
          .onAppear {
            viewModel.updateContainerSize(geometry.size)
          }
          .onChange(of: geometry.size) { _, newSize in
            viewModel.updateContainerSize(newSize)
          }
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        ProgressView()
          .scaleEffect(1.5)
          .foregroundStyle(.white)
      }

      // Cart summary, always visible while streaming
      VStack {
        HStack {
          Spacer()
          CartSummaryBadge(itemCount: viewModel.cartStore.items.count)
        }
        Spacer()
      }
      .padding(.all, 24)

      // Bottom controls layer

      VStack {
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      if viewModel.streamingStatus != .stopped {
        viewModel.stopSession()
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
    .sheet(item: $viewModel.pendingPurchase) { purchase in
      AddToCartView(
        barcode: purchase.barcode,
        details: purchase.details,
        cartStore: viewModel.cartStore,
        onDismiss: {
          viewModel.pendingPurchase = nil
        }
      )
    }
    .sheet(isPresented: $viewModel.showCart) {
      CartView(cartStore: viewModel.cartStore)
    }
  }
}

/// Draws a label over each piece of text detected by `RecognitionService`.
/// OCR only ever runs on the crop of the frame visible inside the reticle, so
/// Vision's normalized boxes (origin bottom-left) are relative to that crop —
/// they're mapped onto `reticleRect` here rather than the full container.
struct RecognizedTextOverlay: View {
  let recognizedTexts: [RecognizedText]
  let reticleRect: CGRect

  var body: some View {
    ForEach(recognizedTexts) { recognized in
      let box = recognized.boundingBox
      let rect = CGRect(
        x: reticleRect.minX + box.minX * reticleRect.width,
        y: reticleRect.minY + (1 - box.maxY) * reticleRect.height,
        width: box.width * reticleRect.width,
        height: box.height * reticleRect.height
      )

      Text(recognized.text)
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .frame(width: rect.width, height: rect.height, alignment: .center)
        .position(x: rect.midX, y: rect.midY)
    }
  }
}

/// Draws an outline over each barcode/QR code found by `RecognitionService`,
/// with a label below showing either the raw payload (non-product codes like
/// QR/Aztec), or — for retail barcode symbologies — the product name resolved
/// by `ProductResolver` (or an appropriate status while/if that fails).
/// Mapped onto `reticleRect` the same way recognized text is (boxes are
/// relative to the reticle crop, not the full container).
struct DetectedBarcodeOverlay: View {
  let barcodes: [DetectedBarcode]
  let productResults: [String: ProductLookupResult]
  let reticleRect: CGRect
  let onBuyTapped: (String, ProductDetails) -> Void

  var body: some View {
    ForEach(barcodes) { barcode in
      let box = barcode.boundingBox
      let rect = CGRect(
        x: reticleRect.minX + box.minX * reticleRect.width,
        y: reticleRect.minY + (1 - box.maxY) * reticleRect.height,
        width: box.width * reticleRect.width,
        height: box.height * reticleRect.height
      )

      RoundedRectangle(cornerRadius: 6)
        .stroke(borderColor(for: barcode), lineWidth: 3)
        .frame(width: rect.width, height: rect.height)
        .overlay(alignment: .bottom) {
          BarcodeLabel(barcode: barcode, result: productResults[barcode.payload], onBuyTapped: onBuyTapped)
            .offset(y: 16)
        }
        .position(x: rect.midX, y: rect.midY)
    }
  }

  private func borderColor(for barcode: DetectedBarcode) -> Color {
    guard VNBarcodeSymbology.productSymbologies.contains(barcode.symbology) else { return .green }

    switch productResults[barcode.payload] {
    case .found: return .green
    case .notIdentified(.offline): return .orange
    case .notIdentified: return .red
    case nil: return .gray
    }
  }
}

/// The name/status label under a barcode, plus — once a product is found —
/// a compact chip with Nutri-Score, quantity, and calories underneath it.
private struct BarcodeLabel: View {
  let barcode: DetectedBarcode
  let result: ProductLookupResult?
  let onBuyTapped: (String, ProductDetails) -> Void

  var body: some View {
    VStack(spacing: 4) {
      Text(primaryText)
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(primaryColor.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .fixedSize()

      if case .found(let details, _) = result {
        ProductDetailsChip(details: details)

        Button {
          onBuyTapped(barcode.payload, details)
        } label: {
          Text("Buy")
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.blue)
            .clipShape(Capsule())
        }
        .accessibilityIdentifier("buy_button")
      }
    }
  }

  private var primaryText: String {
    guard VNBarcodeSymbology.productSymbologies.contains(barcode.symbology) else {
      return barcode.payload
    }

    switch result {
    case .found(let details, let source):
      return source == .cache ? "\(details.name) (offline)" : details.name
    case .notIdentified(let reason):
      switch reason {
      case .offline: return "No internet connection"
      case .notFound: return "Unknown product"
      case .error: return "Lookup failed"
      }
    case nil:
      return "Looking up…"
    }
  }

  private var primaryColor: Color {
    guard VNBarcodeSymbology.productSymbologies.contains(barcode.symbology) else { return .green }

    switch result {
    case .found: return .green
    case .notIdentified(.offline): return .orange
    case .notIdentified: return .red
    case nil: return .gray
    }
  }
}

/// Compact row of Nutri-Score grade, quantity, and calories/100g — whichever
/// of these Open Food Facts happened to have on file for this product.
private struct ProductDetailsChip: View {
  let details: ProductDetails

  var body: some View {
    HStack(spacing: 6) {
      if let grade = details.nutriScore, let color = nutriScoreColor(grade) {
        Text(grade.uppercased())
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.white)
          .frame(width: 16, height: 16)
          .background(color)
          .clipShape(Circle())
      }
      if let quantity = details.quantity {
        Text(quantity)
          .font(.caption2)
          .foregroundStyle(.white)
      }
      if let kcal = details.energyKcal100g {
        Text("\(Int(kcal)) kcal/100g")
          .font(.caption2)
          .foregroundStyle(.white)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(Color.black.opacity(0.75))
    .clipShape(Capsule())
    .fixedSize()
  }

  private func nutriScoreColor(_ grade: String) -> Color? {
    switch grade.lowercased() {
    case "a": return .green
    case "b": return Color(red: 0.6, green: 0.8, blue: 0.2)
    case "c": return .yellow
    case "d": return .orange
    case "e": return .red
    default: return nil
    }
  }
}

/// Draws the precise outline of the foreground object found by
/// `RecognitionService.detectObjectOutline` — a real contour, not just the
/// reticle's rectangle — in a color distinct from every other overlay.
struct ObjectOutlineView: View {
  let outline: ObjectOutline
  let reticleRect: CGRect

  var body: some View {
    path
      .stroke(Color.yellow, lineWidth: 3)
  }

  /// Maps Vision's normalized path (unit square, origin bottom-left) onto
  /// the reticle's position in container space — the same convention used
  /// by `RecognizedTextOverlay`/`DetectedBarcodeOverlay`, expressed here as
  /// an affine transform instead of per-point math.
  private var path: Path {
    var transform = CGAffineTransform(scaleX: reticleRect.width, y: -reticleRect.height)
      .concatenating(CGAffineTransform(translationX: reticleRect.minX, y: reticleRect.minY + reticleRect.height))
    guard let transformed = outline.path.copy(using: &transform) else { return Path() }
    return Path(transformed)
  }
}

/// A floating badge naming the general contents of the reticle (e.g.
/// "Bottle"), positioned just above it so it doesn't cover the object.
struct ObjectClassificationLabel: View {
  let classification: ObjectClassification
  /// Approximate average color of the object — shown as a small swatch so
  /// the color signal used to re-rank classification candidates is visible,
  /// not just used invisibly behind the scenes.
  let dominantColor: Color?
  let reticleRect: CGRect

  var body: some View {
    HStack(spacing: 6) {
      if let dominantColor {
        Circle()
          .fill(dominantColor)
          .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
          .frame(width: 12, height: 12)
      }
      Text(classification.identifier.replacingOccurrences(of: "_", with: " ").capitalized)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.blue.opacity(0.85))
    .clipShape(Capsule())
    .position(x: reticleRect.midX, y: reticleRect.minY - 24)
  }
}

/// Text read directly off the object's own packaging — shown only when no
/// barcode was found for it (see `objectIdentifyingText`), as the fallback
/// identifying signal. Positioned below the reticle so it doesn't collide
/// with the classification badge above it.
struct ObjectIdentifyingTextLabel: View {
  let text: String
  let reticleRect: CGRect

  var body: some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .lineLimit(2)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.teal.opacity(0.85))
      .clipShape(Capsule())
      .frame(maxWidth: 200)
      .position(x: reticleRect.midX, y: reticleRect.maxY + 24)
  }
}


/// Item count in the (demo-only) cart, shown at all times while streaming.
/// No monetary total is shown — neither Open Food Facts nor UPCitemdb's free
/// tier reliably provides pricing, so a "value" here would be fabricated.
struct CartSummaryBadge: View {
  let itemCount: Int

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "cart.fill")
      Text("\(itemCount)")
        .font(.subheadline.weight(.bold))
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.black.opacity(0.6))
    .clipShape(Capsule())
    .animation(.easeInOut(duration: 0.2), value: itemCount)
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  var viewModel: StreamSessionViewModel

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        viewModel.stopSession()
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }
      .accessibilityIdentifier("capture_photo_button")

      // Toggles plain-text OCR; barcode/QR detection keeps running either way.
      CircleButton(icon: "text.viewfinder", text: nil) {
        viewModel.toggleTextRecognition()
      }
      .overlay(
        Circle()
          .stroke(viewModel.isTextRecognitionEnabled ? Color.green : Color.clear, lineWidth: 3)
      )
      .accessibilityIdentifier("toggle_text_recognition_button")

      // Opens the (demo-only, in-memory) cart of items tapped "Buy" on.
      CircleButton(icon: "cart.fill", text: nil) {
        viewModel.showCart = true
      }
      .overlay(alignment: .topTrailing) {
        if !viewModel.cartStore.items.isEmpty {
          Text("\(viewModel.cartStore.items.count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.red)
            .clipShape(Circle())
            .offset(x: 6, y: -6)
        }
      }
      .accessibilityIdentifier("cart_button")
    }
  }
}
