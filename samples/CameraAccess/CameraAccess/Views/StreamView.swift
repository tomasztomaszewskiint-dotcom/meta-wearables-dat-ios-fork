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

            ReticleView(rect: viewModel.reticleRect)
              .animation(.easeInOut(duration: 0.25), value: viewModel.reticleRect)

            if let classification = viewModel.objectClassification {
              ObjectClassificationLabel(classification: classification, reticleRect: viewModel.reticleRect)
                .animation(.easeInOut(duration: 0.25), value: viewModel.reticleRect)
            }

            if viewModel.isTextRecognitionEnabled, let estimate = viewModel.estimatedObjectSize {
              EstimatedSizeLabel(estimate: estimate, reticleRect: viewModel.reticleRect)
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

/// A floating badge naming the general contents of the reticle (e.g.
/// "Bottle"), positioned just above it so it doesn't cover the object.
struct ObjectClassificationLabel: View {
  let classification: ObjectClassification
  let reticleRect: CGRect

  var body: some View {
    Text(classification.identifier.replacingOccurrences(of: "_", with: " ").capitalized)
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.blue.opacity(0.85))
      .clipShape(Capsule())
      .position(x: reticleRect.midX, y: reticleRect.minY - 24)
  }
}

/// Shows the rough size estimate from `DepthEstimationService`, below the
/// reticle. Explicitly labeled "estimated" — this is a DepthPro-based
/// approximation (see its FOV assumption), not a measurement.
struct EstimatedSizeLabel: View {
  let estimate: EstimatedSize
  let reticleRect: CGRect

  var body: some View {
    Text(String(format: "~%.0f × %.0f cm (estimated)", estimate.widthCm, estimate.heightCm))
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.purple.opacity(0.85))
      .clipShape(Capsule())
      .position(x: reticleRect.midX, y: reticleRect.maxY + 24)
  }
}

/// A camera-style viewfinder reticle: corner brackets marking the region
/// that `StreamSessionViewModel` restricts OCR scanning to.
struct ReticleView: View {
  let rect: CGRect

  var body: some View {
    ReticleShape()
      .stroke(Color.white, lineWidth: 3)
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
  }
}

private struct ReticleShape: Shape {
  func path(in rect: CGRect) -> Path {
    let cornerLength = min(rect.width, rect.height) * 0.15
    var path = Path()

    path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerLength))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX + cornerLength, y: rect.minY))

    path.move(to: CGPoint(x: rect.maxX - cornerLength, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cornerLength))

    path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - cornerLength, y: rect.maxY))

    path.move(to: CGPoint(x: rect.minX + cornerLength, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cornerLength))

    return path
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

/// Triggers `DepthEstimationService` for whatever's in the reticle. The
/// model ships in the app bundle (see `MLModels/`), so there's no
/// download/compile wait — just the inference time for one estimate.
struct EstimateSizeButton: View {
  var viewModel: StreamSessionViewModel

  var body: some View {
    CircleButton(icon: "arrow.up.left.and.arrow.down.right", text: nil) {
      viewModel.estimateObjectSize()
    }
    .disabled(viewModel.isEstimatingSize)
    .overlay {
      if viewModel.isEstimatingSize {
        ProgressView()
          .tint(.white)
      }
    }
    .accessibilityIdentifier("estimate_size_button")
    .overlay(alignment: .bottom) {
      if let error = viewModel.sizeEstimationError {
        Text("Estimate failed: \(error)")
          .statusLabelStyle()
          .offset(y: 40)
      }
    }
  }
}

extension Text {
  fileprivate func statusLabelStyle() -> some View {
    self
      .font(.caption2)
      .foregroundStyle(.white)
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(Color.black.opacity(0.75))
      .clipShape(Capsule())
      .fixedSize()
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

      // Only shown in text-recognition mode — an on-demand fallback for
      // sizing objects nothing else (barcode, classification) could identify.
      if viewModel.isTextRecognitionEnabled {
        EstimateSizeButton(viewModel: viewModel)
      }

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
