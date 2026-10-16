import Accelerate
import CoreMedia
import CoreVideo
import EnsembleCore
import Foundation
import VideoToolbox

/// BGRA (what capture asks for now) against the camera's own bi-planar 4:2:0 video range, on the same synthetic scene.
/// Each scene is converted once to 4:2:0 (what a webcam produces), then back to BGRA (what capture hands the app), so
/// both paths start from the same camera frame. The per-frame steps are the same as `FrameAnalyzer` and the hand
/// detector in the app; the 4:2:0 versions read the luma plane and convert to RGBA only after scaling.
func runFormats() {
    let session: VTPixelTransferSession = { var s: VTPixelTransferSession?; VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s); return s! }()
    func converted(_ pb: CVPixelBuffer, to format: OSType) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, Synthetic.width, Synthetic.height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        CVBufferSetAttachment(out!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        VTPixelTransferSessionTransferImage(session, from: pb, to: out!)
        return out!
    }
    let yuv420 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let scenes = [("hand", Synthetic.frames(count: 60)), ("face only", Synthetic.frames(count: 60, face: true, hand: false)),
                  ("empty wall", Synthetic.frames(count: 60, face: false, hand: false))]
    let native = scenes.map { ($0.0, $0.1.map { converted($0, to: yuv420) }) }
    let bgra = native.map { ($0.0, $0.1.map { converted($0, to: kCVPixelFormatType_32BGRA) }) }
    let (frames, yuvFrames) = (bgra[0].1, native[0].1)

    print("Per-frame steps on the hand scene, 640x480, BGRA against 420YpCbCr8BiPlanarVideoRange")
    let target = converted(yuvFrames[0], to: kCVPixelFormatType_32BGRA)
    let convert = bench("capture's 4:2:0 to BGRA conversion (BGRA only)", n: 600) { i in VTPixelTransferSessionTransferImage(session, from: yuvFrames[i % 60], to: target) }
    let light = (bench("brightness grid, BGRA", n: 3000) { i in _ = lightBGRA(frames[i % 60]) },
                 bench("brightness grid, luma plane", n: 3000) { i in _ = lightLuma(yuvFrames[i % 60]) })
    let grid = (bench("still-head grid, BGRA", n: 1000) { i in _ = gridBGRA(frames[i % 60]) },
                bench("still-head grid, luma plane", n: 1000) { i in _ = gridLuma(yuvFrames[i % 60]) })
    var out = [UInt8](repeating: 0, count: 320 * 240 * 4)
    let face = (bench("face frame 320x240 RGBA, from BGRA", n: 1000) { i in faceBGRA(frames[i % 60], into: &out) },
                bench("face frame 320x240 RGBA, from 4:2:0", n: 1000) { i in face420(yuvFrames[i % 60], into: &out) })
    let detector = HandPoseDetector()
    let samples = (frames.map(sampleBuffer), yuvFrames.map(sampleBuffer))
    let hand = (bench("hand pose, BGRA", n: 200) { i in _ = detector.detect(samples.0[i % 60]) },
                bench("hand pose, 4:2:0", n: 200) { i in _ = detector.detect(samples.1[i % 60]) })

    // At 30 fps: conversion, still-head grid and face frame on every frame, brightness 10 times a second, hand pose on
    // every frame with a hand in view and about 8 times a second without.
    for (label, handRate) in [("hand in view", 30.0), ("no hand", 8.0)] {
        let before = 30 * (grid.0.cpuMs + face.0.cpuMs) + 10 * light.0.cpuMs + handRate * hand.0.cpuMs
        let after = 30 * (grid.1.cpuMs + face.1.cpuMs) + 10 * light.1.cpuMs + handRate * hand.1.cpuMs
        let withConversion = before + 30 * convert.cpuMs
        print(String(format: "  %@: CPU ms per second, BGRA %.2f (%.2f with the conversion), 4:2:0 %.2f: %+.1f%% (%+.1f%% if the conversion runs in the app)",
                     label as NSString, before, withConversion, after, (after / before - 1) * 100, (after / withConversion - 1) * 100))
    }

    print("Same results? Per scene, 60 frames")
    for ((name, b), (_, y)) in zip(bgra, native) {
        var poses = 0, joint = 0.0, meanDiff = 0.0, stdDiff = 0.0, gridDiff: Float = 0, pixelDiff = 0
        var outY = [UInt8](repeating: 0, count: 320 * 240 * 4)
        for (pb, py) in zip(b, y) {
            let (hb, hy) = (detector.detect(sampleBuffer(pb)), detector.detect(sampleBuffer(py)))
            let (ob, oy) = (HandClassifierAdapter.observation(from: hb, at: 0, classifier: GestureClassifier()),
                            HandClassifierAdapter.observation(from: hy, at: 0, classifier: GestureClassifier()))
            if ob.present != oy.present || ob.pose != oy.pose || ob.gate != oy.gate { poses += 1 }
            for (j, p) in hb?.points ?? [:] { if let q = hy?[j] { joint = max(joint, hypot(p.x - q.x, p.y - q.y)) } }
            let (lb, ly) = (lightBGRA(pb), lightLuma(py))
            meanDiff = max(meanDiff, abs(lb.mean - ly.mean)); stdDiff = max(stdDiff, abs(lb.std - ly.std))
            gridDiff = max(gridDiff, zip(gridBGRA(pb), gridLuma(py)).map { abs($0 - $1) }.max() ?? 0)
            faceBGRA(pb, into: &out); face420(py, into: &outY)
            pixelDiff = max(pixelDiff, zip(out, outY).map { abs(Int($0) - Int($1)) }.max() ?? 0)
        }
        let present = detector.detect(sampleBuffer(b[0])) != nil
        print(String(format: "  %-10@ hand %@, classification differs on %d of 60, joints move up to %.4f of the frame; brightness mean up to %.4f, spread up to %.4f; still-head cell up to %.2f levels; face frame byte up to %d",
                     name as NSString, (present ? "seen" : "not seen") as NSString, poses, joint, meanDiff, stdDiff, gridDiff, pixelDiff))
    }
}

private func sampleBuffer(_ pb: CVPixelBuffer) -> CMSampleBuffer {
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample)
    return sample!
}

/// `FrameAnalyzer.light`, BGRA.
private func lightBGRA(_ pb: CVPixelBuffer) -> (mean: Double, std: Double) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
    let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
    var sum = 0.0, squares = 0.0
    for r in 0..<30 {
        let row = base.advanced(by: ((r * height) / 30 + height / 60) * stride)
        for c in 0..<40 {
            let px = row.advanced(by: (((c * width) / 40) + width / 80) * 4).assumingMemoryBound(to: UInt8.self)
            let luma = (0.0722 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.2126 * Double(px[2])) / 255
            sum += luma; squares += luma * luma
        }
    }
    let mean = sum / 1200
    return (mean, max(0, squares / 1200 - mean * mean).squareRoot())
}

/// The same grid on plane 0, video range 16 to 235 stretched to 0 to 1.
private func lightLuma(_ pb: CVPixelBuffer) -> (mean: Double, std: Double) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
    var sum = 0.0, squares = 0.0
    for r in 0..<30 {
        let row = base + ((r * height) / 30 + height / 60) * stride
        for c in 0..<40 {
            let luma = min(1, max(0, (Double(row[((c * width) / 40) + width / 80]) - 16) / 219))
            sum += luma; squares += luma * luma
        }
    }
    let mean = sum / 1200
    return (mean, max(0, squares / 1200 - mean * mean).squareRoot())
}

/// `FrameAnalyzer.lumaGrid`, BGRA.
private func gridBGRA(_ pb: CVPixelBuffer) -> [Float] {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!, stride = CVPixelBufferGetBytesPerRow(pb)
    let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
    var grid = [Float](repeating: 0, count: 32 * 24)
    for r in 0..<24 {
        for sy in 0..<8 {
            let row = base.advanced(by: (r * 8 + sy) * height / 192 * stride).assumingMemoryBound(to: UInt8.self)
            for c in 0..<32 {
                var sum: UInt32 = 0
                for sx in 0..<8 {
                    let px = row + (c * 8 + sx) * width / 256 * 4
                    sum += 18 * UInt32(px[0]) + 183 * UInt32(px[1]) + 55 * UInt32(px[2])
                }
                grid[r * 32 + c] += Float(sum) / 256
            }
        }
    }
    return grid.map { $0 / 64 }
}

/// The same grid on plane 0, stretched from video range to 0 to 255.
private func gridLuma(_ pb: CVPixelBuffer) -> [Float] {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
    var grid = [Float](repeating: 0, count: 32 * 24)
    for r in 0..<24 {
        for sy in 0..<8 {
            let row = base + (r * 8 + sy) * height / 192 * stride
            for c in 0..<32 {
                var sum: UInt32 = 0
                for sx in 0..<8 { sum += UInt32(row[(c * 8 + sx) * width / 256]) }
                grid[r * 32 + c] += Float(sum)
            }
        }
    }
    return grid.map { ($0 / 64 - 16) * 255 / 219 }
}

/// `FrameAnalyzer.facePixels`: scale, then swap BGRA to RGBA.
private func faceBGRA(_ pb: CVPixelBuffer, into out: inout [UInt8]) {
    out.withUnsafeMutableBytes { scalePixels(pb, into: $0, w: 320, h: 240, rgba: true) }
}

private let yuvToRGB: vImage_YpCbCrToARGB = {
    var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
    var info = vImage_YpCbCrToARGB()
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_601_4, &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
    return info
}()

/// Scale both planes to 320x240, then convert to RGBA: the colour conversion runs on a quarter of the pixels.
private func face420(_ pb: CVPixelBuffer, into out: inout [UInt8]) {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    func plane(_ i: Int) -> vImage_Buffer {
        vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, i), height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pb, i)),
                      width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pb, i)), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, i))
    }
    var (srcY, srcC) = (plane(0), plane(1))
    var y = [UInt8](repeating: 0, count: 320 * 240), c = [UInt8](repeating: 0, count: 160 * 120 * 2)
    y.withUnsafeMutableBytes { yb in c.withUnsafeMutableBytes { cb in out.withUnsafeMutableBytes { ob in
        var dstY = vImage_Buffer(data: yb.baseAddress, height: 240, width: 320, rowBytes: 320)
        var dstC = vImage_Buffer(data: cb.baseAddress, height: 120, width: 160, rowBytes: 320)
        var dst = vImage_Buffer(data: ob.baseAddress, height: 240, width: 320, rowBytes: 320 * 4)
        vImageScale_Planar8(&srcY, &dstY, nil, vImage_Flags(kvImageNoFlags))
        vImageScale_CbCr8(&srcC, &dstC, nil, vImage_Flags(kvImageNoFlags))
        var info = yuvToRGB
        let argbToRGBA: [UInt8] = [1, 2, 3, 0]
        vImageConvert_420Yp8_CbCr8ToARGB8888(&dstY, &dstC, &dst, &info, argbToRGBA, 255, vImage_Flags(kvImageNoFlags))
    } } }
}
