/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCamera
import MWDATCore
import Observation
import SwiftData
import SwiftUI
import Vision

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

/// Defines the on-screen scanning reticle: a centered square that only OCR
/// scans within, in the same point space as the video container view.
enum ReticleLayout {
  static let sideFraction: CGFloat = 0.55

  static func rect(in containerSize: CGSize) -> CGRect {
    let side = min(containerSize.width, containerSize.height) * sideFraction
    return CGRect(
      x: (containerSize.width - side) / 2,
      y: (containerSize.height - side) / 2,
      width: side,
      height: side
    )
  }
}

/// A product the user tapped "Buy" on, pending confirmation in `AddToCartView`.
struct PendingPurchase: Identifiable {
  let id = UUID()
  let barcode: String
  let details: ProductDetails
}

/// ViewModel for video streaming UI. Delegates device management to DeviceSessionManager.
@Observable
@MainActor
final class StreamSessionViewModel {
  // MARK: - State

  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false
  var streamingStatus: StreamingStatus = .stopped
  var showError: Bool = false
  var errorMessage: String = ""
  var requiresDATAppUpdate: Bool = false

  var capturedPhoto: UIImage?
  var showPhotoPreview: Bool = false
  var showPhotoCaptureError: Bool = false
  var isCapturingPhoto: Bool = false

  let cartStore = CartStore()
  var pendingPurchase: PendingPurchase?
  var showCart: Bool = false

  var recognizedTexts: [RecognizedText] = []
  /// Off by default: OCR (and the dynamic reticle resizing it drives) is an
  /// opt-in feature, not something that runs automatically on every stream.
  var isTextRecognitionEnabled: Bool = false
  var detectedBarcodes: [DetectedBarcode] = []
  /// Product lookup results, keyed by barcode payload, populated as
  /// `resolveProducts` finishes resolving each detected barcode.
  var productResults: [String: ProductLookupResult] = [:]
  /// Best-guess general classification of what's inside the reticle (e.g.
  /// "bottle", "cheese"), or nil if nothing met `minClassificationConfidence`.
  var objectClassification: ObjectClassification?
  /// The current scanning reticle, in container point space. Dynamically
  /// sized/positioned to cover detected text, updated by
  /// `scheduleTextRegionDetectionIfNeeded`.
  var reticleRect: CGRect = .zero

  var hasActiveDevice: Bool { sessionManager.hasActiveDevice }
  var isDeviceSessionReady: Bool { sessionManager.isReady }

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private var stream: MWDATCamera.Stream?

  private let recognitionService = RecognitionService()
  private var recognitionStore: RecognizedTextStore?
  private let firestoreSightingService = FirestoreSightingService()
  private let networkMonitor = NetworkMonitor()
  private var productResolver: ProductResolver?
  private var barcodesBeingResolved: Set<String> = []
  private var isRecognizingText = false
  private var frameCounter = 0
  /// Run OCR roughly every 15 frames (~ every 0.6s at 24fps) — running it on
  /// every frame would overload the device and add no visible value.
  private let textRecognitionFrameInterval = 15
  /// Classifications below this confidence are treated as "unknown" and
  /// hidden, rather than showing a noisy, low-confidence guess.
  private let minClassificationConfidence: Float = 0.25
  /// Size (in points) of the video container view, kept in sync from
  /// `StreamView` so frame pixels can be mapped to/from the on-screen reticle.
  private var containerSize: CGSize = .zero

  private var isDetectingTextRegions = false
  private var regionFrameCounter = 0
  /// Cheap text-region detection runs more often than full OCR since it's
  /// much lighter (no character/language recognition), so the reticle keeps
  /// tracking text fairly responsively between the heavier OCR passes.
  private let textRegionDetectionFrameInterval = 12
  /// Region detection runs on a downscaled copy of the frame — the detector
  /// only needs to find rough text-shaped areas, not read them.
  private let textRegionDetectionMaxDimension: CGFloat = 360

  /// Candidate boxes whose center lands farther than this fraction of the
  /// container's diagonal from the confidence-weighted centroid are treated
  /// as outliers and dropped before computing the reticle's target rect.
  private let outlierDistanceFraction: CGFloat = 0.3
  /// Size changes are smoothed more heavily than position changes — a
  /// reticle that visibly "pulses" is more distracting than one that drifts.
  private let reticleSizeSmoothingFactor: CGFloat = 0.85
  private let reticlePositionSmoothingFactor: CGFloat = 0.65
  /// Hard cap on how much the (already-smoothed) reticle may move/resize in
  /// a single update, as a fraction of the smaller container dimension —
  /// guards against a single bad detection cycle causing a visible jump.
  private let maxReticleStepFraction: CGFloat = 0.12
  /// Updates smaller than this (as a fraction of the smaller container
  /// dimension) are ignored entirely, so near-zero deltas don't keep
  /// re-triggering the SwiftUI animation and reading as jitter.
  private let reticleChangeTolerance: CGFloat = 0.03

  private let maxReticleAreaFraction: CGFloat = 0.8
  /// Neither side may exceed this fraction of its container dimension —
  /// an area cap alone still allows a very wide/thin reticle to feel huge.
  private let maxReticleSideFraction: CGFloat = 0.85
  private let minReticleSideFraction: CGFloat = 0.3

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      guard status == .granted else {
        showError("Permission denied")
        return
      }
      await startSession()
    } catch {
      // Use `localizedDescription` for user-facing text — `description` is
      // always English and intended for logs.
      showError("Permission error: \(error.localizedDescription)")
    }
  }

  func stopSession() {
    stream?.stop()
  }

  /// Stops both the stream and the underlying device session. Call in test tearDown.
  func endSession() {
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    recognizedTexts = []
    detectedBarcodes = []
    productResults = [:]
    barcodesBeingResolved = []
    objectClassification = nil
    reticleRect = .zero
    sessionManager.cleanup()
  }

  func capturePhoto() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }
    isCapturingPhoto = true
    let success = stream?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  func beginPurchase(barcode: String, details: ProductDetails) {
    pendingPurchase = PendingPurchase(barcode: barcode, details: details)
  }

  /// Toggles plain-text OCR on/off. Barcode/QR detection and object
  /// classification keep running regardless — this only gates `recognizeText`
  /// and the dynamic reticle resizing that exists to aim OCR at text.
  func toggleTextRecognition() {
    isTextRecognitionEnabled.toggle()
    if !isTextRecognitionEnabled {
      recognizedTexts = []
      reticleRect = ReticleLayout.rect(in: containerSize)
    }
  }

  func configureRecognitionStore(_ modelContext: ModelContext) {
    guard recognitionStore == nil else { return }
    recognitionStore = RecognizedTextStore(modelContext: modelContext)
  }

  func configureProductResolver(_ modelContext: ModelContext) {
    guard productResolver == nil else { return }
    productResolver = ProductResolver(modelContext: modelContext, networkMonitor: networkMonitor)
  }

  func updateContainerSize(_ size: CGSize) {
    containerSize = size
    if reticleRect == .zero {
      reticleRect = ReticleLayout.rect(in: size)
    }
  }

  // MARK: - Private

  private func startSession() async {
    let deviceSession: DeviceSession
    do {
      deviceSession = try await sessionManager.getSession()
      requiresDATAppUpdate = false
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      showError(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)
      return
    } catch {
      showError("Failed to start session: \(error.localizedDescription)")
      return
    }

    guard deviceSession.state == .started else {
      showError("Device session is not ready. Please try again.")
      return
    }

    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    do {
      guard let newStream = try deviceSession.addStream(config: config) else {
        showError("Unable to create stream. Please try again.")
        return
      }
      stream = newStream
      streamingStatus = .waiting
      setupListeners(for: newStream)
      newStream.start()
    } catch {
      showError("Failed to start stream: \(error.localizedDescription)")
    }
  }

  private func setupListeners(for stream: MWDATCamera.Stream) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      Task { @MainActor in self?.handleVideoFrame(frame) }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
      stream = nil
      clearListeners()
      hasReceivedFirstFrame = false
      sessionManager.stopCurrentSession()
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
      // Dynamic reticle resizing only serves to aim OCR at text, so it only
      // runs when text recognition is enabled — otherwise the reticle stays
      // at its static default size/position.
      if isTextRecognitionEnabled {
        scheduleTextRegionDetectionIfNeeded(for: image)
      }
      scheduleTextRecognitionIfNeeded(for: image)
    }
  }

  private func scheduleTextRecognitionIfNeeded(for image: UIImage) {
    frameCounter += 1
    guard !isRecognizingText, frameCounter % textRecognitionFrameInterval == 0 else { return }
    guard let scanImage = croppedToReticle(image) else { return }

    isRecognizingText = true
    Task {
      defer { isRecognizingText = false }
      do {
        async let barcodesTask = recognitionService.detectBarcodes(in: scanImage)
        async let classificationsTask = recognitionService.classifyObject(in: scanImage)
        // Only run OCR when enabled — barcode detection and classification
        // keep running regardless, since the toggle only concerns plain text.
        let texts = isTextRecognitionEnabled ? try await recognitionService.recognizeText(in: scanImage) : []
        let (barcodes, classifications) = try await (barcodesTask, classificationsTask)

        let clusters = TextClusterer.cluster(texts)
        recognizedTexts = texts
        detectedBarcodes = barcodes
        objectClassification = classifications.first { $0.confidence >= minClassificationConfidence }
        recognitionStore?.record(clusters)
        resolveProducts(for: barcodes)
        recordSightingIfObjectKnown(clusters: clusters, barcodes: barcodes)
        recordLocalLabels(barcodes: barcodes)
      } catch {
        // Non-fatal: OCR/barcode/classification failures shouldn't interrupt the video stream.
      }
    }
  }

  /// Logs the object classification badge and any barcode/resolved-product
  /// labels currently on screen into the local `RecognizedTextEntry` log, so
  /// what's shown in the blue/green overlays also shows up in the
  /// "Recognized Text" debug tab — not just plain OCR text.
  private func recordLocalLabels(barcodes: [DetectedBarcode]) {
    if let classification = objectClassification {
      recognitionStore?.recordLabel(classification.identifier)
    }

    for barcode in barcodes {
      if VNBarcodeSymbology.productSymbologies.contains(barcode.symbology) {
        if case .found(let details, _) = productResults[barcode.payload] {
          recognitionStore?.recordLabel(details.name)
        }
      } else {
        recognitionStore?.recordLabel(barcode.payload)
      }
    }
  }

  /// Mirrors this scan cycle's recognized text/barcode to Firestore, but only
  /// when the object is actually known — either via Vision's general
  /// classification, or (a stronger signal) a barcode that resolved to a
  /// real product name, even from the offline cache. A bare piece of
  /// recognized text or an unresolved barcode is never uploaded on its own.
  private func recordSightingIfObjectKnown(clusters: [ClusteredText], barcodes: [DetectedBarcode]) {
    let resolvedProductName = barcodes.lazy.compactMap { [productResults] barcode -> String? in
      guard case .found(let details, _) = productResults[barcode.payload] else { return nil }
      return details.name
    }.first

    guard resolvedProductName != nil || objectClassification != nil else { return }

    let objectLabel = resolvedProductName ?? objectClassification!.identifier
    let objectConfidence = resolvedProductName != nil ? 1.0 : Double(objectClassification!.confidence)
    let barcode = barcodes.first
    Task {
      await firestoreSightingService.saveSighting(
        objectLabel: objectLabel,
        objectConfidence: objectConfidence,
        recognizedText: clusters.first?.text,
        barcodePayload: barcode?.payload,
        barcodeSymbology: barcode?.symbology.rawValue
      )
    }
  }

  /// Kicks off a product lookup for each newly detected product-like barcode
  /// that isn't already resolved (or being resolved) this session — see
  /// `ProductResolver` for the cache/network/fallback logic.
  private func resolveProducts(for barcodes: [DetectedBarcode]) {
    guard let productResolver else { return }

    for barcode in barcodes where VNBarcodeSymbology.productSymbologies.contains(barcode.symbology) {
      let payload = barcode.payload
      guard productResults[payload] == nil, !barcodesBeingResolved.contains(payload) else { continue }

      barcodesBeingResolved.insert(payload)
      Task {
        defer { barcodesBeingResolved.remove(payload) }
        productResults[payload] = await productResolver.resolveProduct(barcode: payload)
      }
    }
  }

  /// Cheap pass: figures out roughly where text-shaped regions are across
  /// the *whole* frame (downscaled), then grows/shrinks the reticle to cover
  /// them — capped and smoothed so it doesn't jitter or eat the whole screen.
  private func scheduleTextRegionDetectionIfNeeded(for image: UIImage) {
    guard containerSize.width > 0, containerSize.height > 0 else { return }
    regionFrameCounter += 1
    guard !isDetectingTextRegions, regionFrameCounter % textRegionDetectionFrameInterval == 0 else { return }
    guard let downscaled = downscaled(image, maxDimension: textRegionDetectionMaxDimension) else { return }

    isDetectingTextRegions = true
    let imageSize = image.size
    let currentContainerSize = containerSize
    Task {
      defer { isDetectingTextRegions = false }
      do {
        let boxes = try await recognitionService.detectTextRegions(in: downscaled)
        updateReticle(withDetectedRegions: boxes, imageSize: imageSize, containerSize: currentContainerSize)
      } catch {
        // Non-fatal: keep the previous reticle if detection fails.
      }
    }
  }

  private func updateReticle(
    withDetectedRegions candidates: [TextRegionCandidate], imageSize: CGSize, containerSize: CGSize
  ) {
    guard imageSize.width > 0, imageSize.height > 0 else { return }

    let containerCandidates = candidates.map { candidate in
      (
        rect: mapImageNormalizedRectToContainer(candidate.boundingBox, imageSize: imageSize, containerSize: containerSize),
        confidence: candidate.confidence
      )
    }
    let inlierBoxes = filteredInlierBoxes(containerCandidates, containerSize: containerSize)
    let target = union(of: inlierBoxes) ?? ReticleLayout.rect(in: containerSize)
    let clampedTarget = clampedReticle(target, containerSize: containerSize)

    guard reticleRect.width > 0, reticleRect.height > 0 else {
      reticleRect = clampedTarget
      return
    }

    let smoothed = smoothedReticle(previous: reticleRect, target: clampedTarget)
    let limited = stepLimited(from: reticleRect, to: smoothed, containerSize: containerSize)

    if isSignificantChange(from: reticleRect, to: limited, containerSize: containerSize) {
      reticleRect = limited
    }
  }

  /// Drops candidate boxes far from the confidence-weighted centroid of all
  /// candidates, so a single stray/low-confidence detection can't drag the
  /// reticle's target rect toward an unrelated part of the frame.
  private func filteredInlierBoxes(
    _ candidates: [(rect: CGRect, confidence: Float)], containerSize: CGSize
  ) -> [CGRect] {
    guard !candidates.isEmpty else { return [] }

    let totalWeight = candidates.reduce(CGFloat(0)) { $0 + CGFloat($1.confidence) }
    guard totalWeight > 0 else { return candidates.map(\.rect) }

    let weightedCenter = candidates.reduce(CGPoint.zero) { partial, candidate in
      let weight = CGFloat(candidate.confidence) / totalWeight
      return CGPoint(
        x: partial.x + candidate.rect.midX * weight,
        y: partial.y + candidate.rect.midY * weight
      )
    }

    let diagonal = (containerSize.width * containerSize.width + containerSize.height * containerSize.height).squareRoot()
    let maxDistance = diagonal * outlierDistanceFraction

    return candidates
      .filter { distance(from: CGPoint(x: $0.rect.midX, y: $0.rect.midY), to: weightedCenter) <= maxDistance }
      .map(\.rect)
  }

  private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
    let dx = a.x - b.x
    let dy = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
  }

  /// Blends toward the target rect, smoothing size more heavily than
  /// position (see `reticleSizeSmoothingFactor`/`reticlePositionSmoothingFactor`).
  private func smoothedReticle(previous: CGRect, target: CGRect) -> CGRect {
    let sizeFactor = reticleSizeSmoothingFactor
    let positionFactor = reticlePositionSmoothingFactor

    let width = previous.width * sizeFactor + target.width * (1 - sizeFactor)
    let height = previous.height * sizeFactor + target.height * (1 - sizeFactor)
    let centerX = previous.midX * positionFactor + target.midX * (1 - positionFactor)
    let centerY = previous.midY * positionFactor + target.midY * (1 - positionFactor)

    return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
  }

  /// Hard-limits how far a single update can move/resize the reticle,
  /// regardless of what smoothing produced — a backstop against visible
  /// jumps from an unusual detection cycle.
  private func stepLimited(from previous: CGRect, to target: CGRect, containerSize: CGSize) -> CGRect {
    let maxStep = min(containerSize.width, containerSize.height) * maxReticleStepFraction

    func limited(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
      let delta = to - from
      guard abs(delta) > maxStep else { return to }
      return from + (delta > 0 ? maxStep : -maxStep)
    }

    let centerX = limited(previous.midX, target.midX)
    let centerY = limited(previous.midY, target.midY)
    let width = limited(previous.width, target.width)
    let height = limited(previous.height, target.height)

    return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
  }

  private func isSignificantChange(from a: CGRect, to b: CGRect, containerSize: CGSize) -> Bool {
    let tolerance = min(containerSize.width, containerSize.height) * reticleChangeTolerance
    return abs(a.minX - b.minX) > tolerance
      || abs(a.minY - b.minY) > tolerance
      || abs(a.width - b.width) > tolerance
      || abs(a.height - b.height) > tolerance
  }

  /// Clamps a candidate reticle rect's area to `maxReticleAreaFraction` of the
  /// container (and each side to `maxReticleSideFraction`), with a floor of
  /// `minReticleSideFraction`, preserving its center.
  private func clampedReticle(_ rect: CGRect, containerSize: CGSize) -> CGRect {
    let containerArea = containerSize.width * containerSize.height
    guard containerArea > 0 else { return rect }

    let minSide = min(containerSize.width, containerSize.height) * minReticleSideFraction
    var width = max(rect.width, minSide)
    var height = max(rect.height, minSide)

    width = min(width, containerSize.width * maxReticleSideFraction)
    height = min(height, containerSize.height * maxReticleSideFraction)

    let maxArea = containerArea * maxReticleAreaFraction
    let area = width * height
    if area > maxArea {
      let scale = (maxArea / area).squareRoot()
      width *= scale
      height *= scale
    }

    width = min(width, containerSize.width)
    height = min(height, containerSize.height)

    let x = min(max(rect.midX - width / 2, 0), containerSize.width - width)
    let y = min(max(rect.midY - height / 2, 0), containerSize.height - height)

    return CGRect(x: x, y: y, width: width, height: height)
  }

  private func union(of rects: [CGRect]) -> CGRect? {
    guard var result = rects.first else { return nil }
    for rect in rects.dropFirst() { result = result.union(rect) }
    return result
  }

  /// Maps a Vision-normalized rect (origin bottom-left, relative to `imageSize`)
  /// onto the container's point space, accounting for the `.aspectRatio(.fill)`
  /// scale/crop applied when displaying the frame. Inverse of the mapping used
  /// by `croppedToReticle`.
  private func mapImageNormalizedRectToContainer(_ box: CGRect, imageSize: CGSize, containerSize: CGSize) -> CGRect {
    let imageRect = CGRect(
      x: box.minX * imageSize.width,
      y: (1 - box.maxY) * imageSize.height,
      width: box.width * imageSize.width,
      height: box.height * imageSize.height
    )

    let scale = max(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    let offsetX = (imageSize.width * scale - containerSize.width) / 2
    let offsetY = (imageSize.height * scale - containerSize.height) / 2

    return CGRect(
      x: imageRect.minX * scale - offsetX,
      y: imageRect.minY * scale - offsetY,
      width: imageRect.width * scale,
      height: imageRect.height * scale
    )
  }

  /// Crops `image` down to whatever part of it is currently visible inside
  /// the on-screen reticle, so OCR only ever sees that region. The video
  /// image fills its container via `.aspectRatio(contentMode: .fill)`, so the
  /// reticle (defined in container points) is mapped back into image points
  /// using the same fill scale, then cropped in the image's own upright
  /// coordinate space (via `draw`, so `imageOrientation` is handled for us).
  private func croppedToReticle(_ image: UIImage) -> UIImage? {
    guard containerSize.width > 0, containerSize.height > 0 else { return nil }

    let reticle = reticleRect.width > 0 && reticleRect.height > 0
      ? reticleRect
      : ReticleLayout.rect(in: containerSize)
    let imageSize = image.size
    guard imageSize.width > 0, imageSize.height > 0 else { return nil }

    let scale = max(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    let displayedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let offsetX = (displayedSize.width - containerSize.width) / 2
    let offsetY = (displayedSize.height - containerSize.height) / 2

    let cropRect = CGRect(
      x: (reticle.minX + offsetX) / scale,
      y: (reticle.minY + offsetY) / scale,
      width: reticle.width / scale,
      height: reticle.height / scale
    ).intersection(CGRect(origin: .zero, size: imageSize))

    guard cropRect.width > 0, cropRect.height > 0 else { return nil }

    let renderer = UIGraphicsImageRenderer(size: cropRect.size)
    return renderer.image { _ in
      image.draw(at: CGPoint(x: -cropRect.minX, y: -cropRect.minY))
    }
  }

  private func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
    let size = image.size
    guard size.width > 0, size.height > 0 else { return nil }

    let scale = min(1, maxDimension / max(size.width, size.height))
    guard scale < 1 else { return image }

    let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: targetSize))
    }
  }

  private func handleError(_ error: StreamError) {
    let message = error.localizedDescription
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }
}
