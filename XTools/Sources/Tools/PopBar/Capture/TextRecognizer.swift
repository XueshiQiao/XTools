import Foundation
import CoreGraphics
import Vision

/// Vision-backed OCR. Runs the recognition off the main thread and hands back the
/// text in natural reading order.
enum TextRecognizer {

    private static let log = FileLog("PopBar.OCR")

    /// How close two observations' vertical positions must be to count as the same
    /// line (normalized coordinates, so this is a fraction of image height).
    private static let sameLineTolerance: CGFloat = 0.02

    /// Runs Vision OCR OFF the main thread. Calls `completion` on the MAIN thread with
    /// the recognized text joined in reading order ("\n" between lines), or "" if nothing.
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        let width = image.width
        let height = image.height

        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()

            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([req])

            let observations = req.results ?? []
            let text = orderedText(from: observations)

            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            log.info("OCR \(width)x\(height) px -> \(text.count) chars in \(elapsedMs)ms")

            DispatchQueue.main.async { completion(text) }
        }
    }

    // MARK: - Reading order

    /// Sort observations top→bottom, then left→right within a line, and join their
    /// best candidate strings with newlines.
    ///
    /// Vision's `boundingBox` is normalized with y measured from the BOTTOM (0 at
    /// bottom, 1 at top), so "top first" means DESCENDING `maxY`.
    private static func orderedText(from observations: [VNRecognizedTextObservation]) -> String {
        let topDown = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

        // Group runs that sit on roughly the same visual line.
        var lines: [[VNRecognizedTextObservation]] = []
        var line: [VNRecognizedTextObservation] = []
        var lineTop: CGFloat = 0

        func flush() {
            guard !line.isEmpty else { return }
            // Left→right within the line.
            lines.append(line.sorted { $0.boundingBox.minX < $1.boundingBox.minX })
            line.removeAll(keepingCapacity: true)
        }

        for obs in topDown {
            if line.isEmpty {
                lineTop = obs.boundingBox.maxY
            } else if abs(obs.boundingBox.maxY - lineTop) > sameLineTolerance {
                flush()
                lineTop = obs.boundingBox.maxY
            }
            line.append(obs)
        }
        flush()

        // Join fragments WITHIN a line with a space; separate lines with newlines — so
        // multiple observations on one visual line don't each become their own line.
        return lines
            .map { row in row.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
