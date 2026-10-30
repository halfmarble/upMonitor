// The MIT License (MIT)

// Copyright 2026 Halfmarble LLC

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Testing
import CoreGraphics
import CoreText
import Foundation

// CpuRender into a bitmap, dark menu bar, no colour, tickWidth 4 and tickTotalWidth 6. Granularity 0 is one core bar on
// any Mac (CpuSampler.c:130), so the readings block starts the image: the disk bar is at x = 0 to 8 (CpuRenderer.c:295,
// 2 * tickWidth wide). The bitmap's first memory row is the image's top, so the row at height y is memory row 15 - y.
private struct Bitmap {
  let width: Int
  var height = 16
  let bytes: [UInt8]

  func alpha(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4 + 3] }
  func red(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4] }
  func green(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4 + 1] }
  func column(_ x: Int) -> [UInt8] { (0..<height).map { alpha(x: x, y: $0) } }   // index 0 is height 0, the bottom
}

// scale 2 draws as for a Retina display: a bitmap twice the size, its transform scaled by 2, so a point is 2 pixels
private func render(bar: Bool, stripped: Bool, width: Int, readings: CpuReadings,
                    extra: [CpuExtraReading] = [], light: Bool = false, scale: Int = 1) -> Bitmap {
  let h = 16 * scale
  let ctx = CGContext(data: nil, width: width * scale, height: h, bitsPerComponent: 8, bytesPerRow: width * scale * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
  var ticks = Ticks()
  var readings = readings
  withUnsafeMutablePointer(to: &ticks) { t in
    var info = CpuSummaryInfo()
    info.countLogical = 1
    info.countCores = 1
    info.now = t
    info.last = t
    extra.withUnsafeBufferPointer { e in
      readings.extraCount = Int32(extra.count)
      readings.extra = extra.isEmpty ? nil : e.baseAddress
      CpuRender(&info, ctx, light, 0, bar, stripped, false, 4, 6, CGFloat(width), 0, &readings)
    }
  }
  let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
  return Bitmap(width: width * scale, height: h, bytes: Array(UnsafeBufferPointer(start: data, count: width * scale * h * 4)))
}

private func readings(disk: Double) -> CpuReadings {
  var r = CpuReadings()
  r.disk = disk; r.memory = -1; r.cpu = -1; r.efficiency = -1; r.performance = -1
  return r
}

extension FreeTests {
  @Suite struct RendererDrawingTests {
    @Test(arguments: [(0.0, 0), (0.25, 4), (0.5, 8), (1.0, 16)])
    func barHeight(load: Double, rows: Int) {
      // _render_group (CpuRenderer.c:395): a background over the whole 16 pt, then a fill load*16 pt high from the bottom.
      // On a dark bar the background has alpha 0.3 (about 76) and the fill over it at least 0.606 (about 154) at load 0.25,
      // so "above 127" counts the filled rows only
      let column = render(bar: true, stripped: false, width: 60, readings: readings(disk: load)).column(1)
      #expect(column.filter { $0 > 127 }.count == rows)
      #expect(column.allSatisfy { $0 > 0 })                  // the background, whole height
      #expect(column.prefix(rows).allSatisfy { $0 > 127 })   // filled from the bottom
    }

    @Test func dashes() {
      // stripped: the bar starts at DASHED_BOTTOM 2 (CpuRenderer.c:545), so heights 0 and 1 are clear, and heights 4, 7,
      // 10 and 13 are cleared again (CpuRenderer.c:637), leaving five 2-pt dashes
      let column = render(bar: true, stripped: true, width: 60, readings: readings(disk: 1.0)).column(1)
      for y in [0, 1, 4, 7, 10, 13] { #expect(column[y] == 0, "height \(y)") }
      for y in [2, 3, 5, 6, 8, 9, 11, 12, 14, 15] { #expect(column[y] > 127, "height \(y)") }
    }

    @Test func cpuDrawnAfterGpu() {
      // gpuShown: CPU at full load is drawn at index 4 (CpuRenderReadingIndex), x = 44 to 52, filled the whole 16 pt; index
      // 2, the Neural Engine's (off: its background only), and index 3, the GPU's (not read), stay below the fill's alpha.
      // The gap after memory, x = 20 to 24 (memory's bar ends at 18, its slot at 20), stays clear
      var r = readings(disk: -1)
      r.gpuShown = true
      r.gpu = -1
      r.neuralEngine = 0
      r.cpu = 1.0
      let image = render(bar: true, stripped: false, width: 100, readings: r)
      for x in 44..<52 { #expect(image.column(x).allSatisfy { $0 > 127 }, "CPU column \(x)") }
      for x in 24..<42 { #expect(image.column(x).allSatisfy { $0 <= 127 }, "column \(x)") }
      for x in 20..<24 { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
    }

    @Test func unreadReadingsDrawNothingInDotStyle() {
      // Dot style, every reading below 0: the branch for a reading not read draws only in bar style (CpuRenderer.c:600),
      // so the disk slot, x = 0 to 6 (the dot slot is tickTotalWidth), stays transparent. The one core dot starts at
      // x = 35 (CpuRenderReadingsWidth, dot), clear of that slot
      let image = render(bar: false, stripped: false, width: 60, readings: readings(disk: -1))
      for x in 0..<6 { #expect(image.column(x).allSatisfy { $0 == 0 }, "column \(x)") }
    }

    @Test(arguments: [(Int32(1), true), (Int32(0), false)])
    func neuralEngineWideSolidBar(state: Int32, on: Bool) {
      // gpuShown, dashed: the memory bar (not read: its background only) at x = 10 to 18, the gap after memory (x = 18 to 24),
      // the Neural Engine's bar at x = 24 to 32 (index 2), the GPU's (its background only) at 34 to 42, 2 * tickWidth wide (CpuRenderReadingX, CpuRenderer.c), drawn last from DASHED_BOTTOM 2 and
      // whole, without the dashes (_render_neural_engine, CpuRenderer.c:498): on, white at 0.9 opacity (alpha about 230,
      // and red equal to alpha, as premultiplied white); off, the background alone, alpha 0.3 (about 76). The 2-pt gaps
      // before it (x = 18 to 23) and after it (x = 32, 33) stay clear
      var r = readings(disk: -1)
      r.gpuShown = true
      r.gpu = -1
      r.neuralEngine = state
      let image = render(bar: true, stripped: true, width: 100, readings: r)
      for x in 24..<32 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0, "below DASHED_BOTTOM, column \(x)")
        for y in 2..<16 {
          if on {
            #expect(abs(Int(column[y]) - 230) <= 1, "0.9 opacity, column \(x), height \(y)")
            #expect(image.red(x: x, y: y) == column[y], "white, column \(x), height \(y)")
          } else {
            #expect(column[y] > 0 && column[y] < 127, "column \(x), height \(y)")
          }
        }
      }
      for x in [18, 19, 20, 21, 22, 23, 32, 33] { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
      #expect(image.column(17)[2] > 0)   // the memory bar's background ends at x = 18
      #expect(image.column(34)[2] > 0)   // the GPU's background starts at x = 34
    }

    @Test(arguments: [(0.0, 0), (0.37, 5), (1.0, 14)])
    func neuralEngineBarByShare(share: Double, filled: Int) {
      // the same layout as above, with neuralEngineByShare (_render_neural_engine, CpuRenderer.c:515): the background over
      // the whole bar from DASHED_BOTTOM 2, then a white fill fmin(share, 1) * 14 pt high at 0.9 opacity over it.
      // Share 0 is 0 rows; 1.0 is rows 2 to 15, all filled; 0.37 is 5.18 pt: rows 2 to 6 whole, row 7 0.18 covered, rows
      // 8 to 15 the background alone. Measured (column 40 before the Neural Engine moved to index 2, height 0 upward): background 77, filled 238, and the partly
      // covered row 106: share 0 is [0, 0, 77 x 14]; 0.37 is [0, 0, 238 x 5, 106, 77 x 8]; 1.0 is [0, 0, 238 x 14]
      var r = readings(disk: -1)
      r.gpuShown = true
      r.gpu = -1
      r.neuralEngine = 0   // ignored by share
      r.neuralEngineByShare = true
      r.neuralEngineBusy = share
      let image = render(bar: true, stripped: true, width: 100, readings: r)
      for x in 24..<32 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0, "below DASHED_BOTTOM, column \(x)")
        for y in 2..<16 {
          let row = y - 2
          if row < filled {
            #expect(column[y] > 200, "filled, column \(x), height \(y): \(column[y])")
          } else if y == 7 && filled == 5 {
            #expect(column[y] > 76 && column[y] < 200, "the partly covered row, column \(x): \(column[y])")
          } else {
            #expect(column[y] > 0 && column[y] < 127, "background only, column \(x), height \(y): \(column[y])")
          }
        }
      }
      for x in [18, 19, 20, 21, 22, 23, 32, 33] { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
    }

    // the battery number's font, registered once from the app's sources: the hostless bundle has no app Resources
    private static let batteryFont: Bool = {
      let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("cpuTopBars/Micro5-Regular.ttf")
      return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    // the battery alone, in a 120-wide image: its bar at x = 0 to 8, a reading's width, drawn last from DASHED_BOTTOM 2 in
    // the dashed style and whole, without the dashes. Its digits, Micro 5 at 1 pt a pixel, 5 pt tall and 3 wide ("1" 2),
    // are centred across it on whole points, x = 2 to 5 ("1" 3 to 5), and stacked from the top a device pixel apart: in these
    // 1x bitmaps 1 pt, so two digits are 11 pt, from height 3 ("87": the 7 at 3 to 8, the 8 at 9 to 14). Columns 0, 1, 6
    // and 7 never hold a digit
    private func batteryReadings(_ charge: Double, charging: Bool = false, onAC: Bool = false) -> CpuReadings {
      var r = readings(disk: -1)
      r.batteryShown = true
      r.battery = charge
      r.batteryCharging = charging
      r.batteryOnAC = onAC
      return r
    }

    @Test func batteryFullOnTheAdapterIsWhiteWithNoNumber() {
      #expect(Self.batteryFont)
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, onAC: true))
      // the fill, white at 0.9 opacity over the background (about 238), on every row from 2 up, the dash rows included;
      // at 100 no number, so nothing is cut out and nothing stands below the bar
      for x in 0..<8 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0, "below DASHED_BOTTOM, column \(x)")
        for y in 2..<16 { #expect(column[y] > 200, "column \(x), height \(y): \(column[y])") }
        #expect(image.red(x: x, y: 8) == image.green(x: x, y: 8))
      }
      // the readings' gap after the bar: the slot ends at 10, where disk's background starts
      for x in 8..<10 { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
      #expect(image.column(10)[2] > 0)
    }

    @Test func batteryNumberIsCutOutOfTheFill() {
      #expect(Self.batteryFont)
      // 87% on the adapter: the fill to 2 + 0.87 * 14 = 14.18, so both digits stand in it and are cut out of it
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(0.87, onAC: true))
      let cut = (2..<5).flatMap { x in (3..<14).map { y in image.alpha(x: x, y: y) } }.filter { $0 == 0 }
      #expect(cut.count >= 12, "cut-out pixels: \(cut.count)")
      for x in [0, 1, 6, 7] {
        for y in 2..<14 { #expect(image.alpha(x: x, y: y) > 200, "column \(x), height \(y)") }
      }
      for x in 0..<8 { #expect(image.alpha(x: x, y: 0) == 0 && image.alpha(x: x, y: 1) == 0, "below the bar, column \(x)") }
    }

    @Test func batteryFillColourFollowsThePowerState() {
      #expect(Self.batteryFont)
      for light in [false, true] {
        let battery = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0), light: light)
        let charging = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, charging: true, onAC: true), light: light)
        let adapter = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, onAC: true), light: light)
        // on battery systemRed and charging systemGreen, both at full opacity; on the adapter the text colour at 0.9
        #expect(battery.alpha(x: 0, y: 8) == 255 && battery.red(x: 0, y: 8) > battery.green(x: 0, y: 8), "light \(light)")
        #expect(charging.alpha(x: 0, y: 8) == 255 && charging.green(x: 0, y: 8) > charging.red(x: 0, y: 8), "light \(light)")
        #expect(adapter.alpha(x: 0, y: 8) < 255 && adapter.red(x: 0, y: 8) == adapter.green(x: 0, y: 8), "light \(light)")
        #expect((adapter.red(x: 0, y: 8) > 200) == !light, "white on a dark menu bar, black on a light one")
      }
    }

    @Test(arguments: [false, true])
    func batteryNumberOverTheEmptyBarIsTheTextColour(light: Bool) {
      #expect(Self.batteryFont)
      // 20% in the solid style: the fill to height 3.2, "20" stacked from 3, its "2" at heights 9 to 14, over the
      // background alone
      let image = render(bar: true, stripped: false, width: 120, readings: batteryReadings(0.2), light: light)
      let digit = (2..<5).flatMap { x in (9..<14).map { y in (x, y) } }.filter { image.alpha(x: $0.0, y: $0.1) > 200 }
      #expect(digit.count >= 5, "the 2's pixels: \(digit.count)")
      for (x, y) in digit { #expect((image.red(x: x, y: y) > 200) == !light, "column \(x), height \(y)") }
      for x in [0, 1, 6, 7] {
        for y in 4..<16 { #expect(image.alpha(x: x, y: y) > 0 && image.alpha(x: x, y: y) < 127, "column \(x), height \(y)") }
      }
    }

    @Test(arguments: [1, 2])
    func batteryDigitsAndWifiSegmentsSitOnWholePixels(scale: Int) {
      #expect(Self.batteryFont)
      // at 1x and 2x every edge of the digits and of the segments falls on a device pixel, so no pixel of the battery's
      // or Wi-Fi's bar is a blend: each is clear, the background alone (about 77), the fill over it (about 238) or the
      // digit's text colour over the background (about 238); a half-covered pixel would read between, here 100 to 200
      // the charge 0.5 puts the fill's top on a whole point in both styles (8, and 2 + 7 = 9), as the readings' share bars
      // do not snap theirs
      var r = batteryReadings(0.5)
      r.wifiShown = true
      r.wifi = 0.5
      for stripped in [false, true] {
        let image = render(bar: true, stripped: stripped, width: 120, readings: r, scale: scale)
        for x in 0..<(18 * scale) {
          for y in 0..<(16 * scale) {
            let a = image.alpha(x: x, y: y)
            #expect(a <= 100 || a >= 200, "scale \(scale), stripped \(stripped), pixel \(x), \(y): \(a)")
          }
        }
      }
    }

    @Test func batteryNotReadDrawsOnlyTheBarBackground() {
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(-1))
      for x in 0..<8 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0)
        for y in 2..<16 { #expect(column[y] > 0 && column[y] < 127, "column \(x), height \(y): \(column[y])") }
      }
    }

    @Test(arguments: [(1.0, 5), (0.5, 3), (0.4, 2), (0.0, 1), (-1.0, 0)])
    func wifiSegmentsLightWithTheSignal(fill: Double, lit: Int) {
      // Wi-Fi alone: its bar is the first reading, x = 0 to 8. In the dashed style, from DASHED_BOTTOM 2: five segments 2 pt
      // tall, 1 pt apart, at heights 2, 5, 8, 11 and 14; ceil(fill * 5) lit from the bottom, at least one from fill 0, white
      // at 0.9 opacity over the background, the rest the background alone; the gaps and the rows below 2 clear
      var r = readings(disk: -1)
      r.wifiShown = true
      r.wifi = fill
      let image = render(bar: true, stripped: true, width: 100, readings: r)
      for x in 0..<8 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0)
        for segment in 0..<5 {
          let y = 2 + (segment * 3)
          for row in [y, y + 1] {
            if segment < lit {
              #expect(column[row] > 200, "lit, column \(x), height \(row): \(column[row])")
            } else {
              #expect(column[row] > 0 && column[row] < 127, "background, column \(x), height \(row): \(column[row])")
            }
          }
          if segment < 4 { #expect(column[y + 2] == 0, "gap, column \(x), height \(y + 2)") }
        }
      }
    }

    @Test func wifiSegmentsInTheSolidStyle() {
      // the full 16 pt: segments at heights 0, 3.5, 7, 10.5 and 14, 1.5 pt apart, each foot on a device pixel: in this 1x
      // bitmap at 0, 4, 7, 11 and 14, so rows 2, 3, 6, 9, 10 and 13 are gaps
      var r = readings(disk: -1)
      r.wifiShown = true
      r.wifi = 1.0
      let image = render(bar: true, stripped: false, width: 100, readings: r)
      for x in 0..<8 {
        let column = image.column(x)
        for y in [0, 1, 4, 5, 7, 8, 11, 12, 14, 15] { #expect(column[y] > 200, "column \(x), height \(y): \(column[y])") }
        for y in [2, 3, 6, 9, 10, 13] { #expect(column[y] == 0, "gap, column \(x), height \(y): \(column[y])") }
      }
    }

    @Test func extraReadingMarkDrawsOneRow() {
      // one extra reading, value 0.5 and mark 0.5, in a 100-wide image: its x is 100 - _extra_width (4 + 10) + 4 = 90
      // (CpuRenderer.c:317), its bar 2 * tickWidth = 8 wide. The mark is a 1-pt white line at
      // floor(bottom + 0.5 * 16) = 8 (CpuRenderer.c:676), drawn last so it is opaque
      var extra = CpuExtraReading()
      extra.value = 0.5
      extra.mark = 0.5
      let image = render(bar: true, stripped: false, width: 100, readings: readings(disk: -1), extra: [extra])
      for x in 90..<98 {
        #expect(image.alpha(x: x, y: 8) == 255, "mark row, column \(x)")
        #expect(image.alpha(x: x, y: 7) < 255, "below the mark, column \(x)")   // the fill over the background, about 188
        #expect(image.alpha(x: x, y: 9) < 255, "above the mark, column \(x)")   // the background alone, about 76
      }
      #expect(image.alpha(x: 89, y: 8) < 255)   // the mark stops at the bar's left edge
      #expect(image.alpha(x: 98, y: 8) < 255)   // and at its right edge
    }
  }
}
