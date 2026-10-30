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

// CpuRender into a bitmap, dark menu bar, no colour, tickWidth 4 and tickTotalWidth 6. Granularity 0 is one core bar on
// any Mac (CpuSampler.c:130), so the readings block starts the image: the disk bar is at x = 0 to 8 (CpuRenderer.c:295,
// 2 * tickWidth wide). The bitmap's first memory row is the image's top, so the row at height y is memory row 15 - y.
private struct Bitmap {
  let width: Int
  let height = 16
  let bytes: [UInt8]

  func alpha(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4 + 3] }
  func red(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4] }
  func green(x: Int, y: Int) -> UInt8 { bytes[(height - 1 - y) * width * 4 + x * 4 + 1] }
  func column(_ x: Int) -> [UInt8] { (0..<height).map { alpha(x: x, y: $0) } }   // index 0 is height 0, the bottom
}

private func render(bar: Bool, stripped: Bool, width: Int, readings: CpuReadings,
                    extra: [CpuExtraReading] = [], light: Bool = false) -> Bitmap {
  let h = 16
  let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
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
  return Bitmap(width: width, bytes: Array(UnsafeBufferPointer(start: data, count: width * h * 4)))
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

    // the battery alone, in a 120-wide image: its number in x = 0 to T (CPU_RENDER_BATTERY_TEXT_WIDTH, 20), then 1 pt clear,
    // and its bar at x = 21 to 29, a reading's width, drawn last from DASHED_BOTTOM 2 and whole, without the dashes
    private func batteryReadings(_ charge: Double, charging: Bool = false) -> CpuReadings {
      var r = readings(disk: -1)
      r.batteryShown = true
      r.battery = charge
      r.batteryCharging = charging
      return r
    }

    @Test func batteryNumberAndFullBar() {
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0))
      // "100" is drawn inside [0, T): some pixel there, none from x = T on up to the bar, and the number's pixels span most of
      // the width (it was measured 19.248 pt wide, right-aligned, so its left edge is within 4 columns of x = 0)
      let numberColumns = (0..<20).filter { x in image.column(x).contains { $0 > 0 } }
      #expect(!numberColumns.isEmpty)
      #expect((numberColumns.first ?? 99) <= 4 && (numberColumns.last ?? 0) >= 17, "columns \(numberColumns)")
      #expect(image.column(20).allSatisfy { $0 == 0 })
      // the bar at 100% is filled on every row from 2 up, the dash rows 4, 7, 10 and 13 included, white at 0.9 opacity over the background (about 238)
      for x in 21..<29 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0, "below DASHED_BOTTOM, column \(x)")
        for y in 2..<16 { #expect(column[y] > 200, "column \(x), height \(y): \(column[y])") }
      }
      for y in [4, 7, 10, 13] { #expect(image.alpha(x: 25, y: y) > 200, "dash row \(y)") }
      // the readings' gap after the bar: the slot ends at T + 1 + 10 = 31, where disk's background starts
      for x in 29..<31 { #expect(image.column(x).allSatisfy { $0 == 0 }, "gap column \(x)") }
      #expect(image.column(31)[2] > 0)
    }

    @Test func batteryChargingBarIsGreen() {
      let charging = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0, charging: true))
      let plain = render(bar: true, stripped: true, width: 120, readings: batteryReadings(1.0))
      // systemGreen (0.188, 0.820, 0.345) at full opacity over the bar's height: green above red; the text colour is white
      #expect(charging.alpha(x: 25, y: 8) == 255)
      #expect(charging.green(x: 25, y: 8) > charging.red(x: 25, y: 8))
      #expect(plain.red(x: 25, y: 8) == plain.green(x: 25, y: 8))
    }

    @Test func batteryNumberIsBlackOnLightMenuBar() {
      let image = render(bar: true, stripped: false, width: 120, readings: batteryReadings(0.87), light: true)
      var any = false
      for x in 0..<20 {
        for y in 0..<16 where image.alpha(x: x, y: y) > 0 {
          any = true
          #expect(image.red(x: x, y: y) == 0 && image.green(x: x, y: y) == 0, "column \(x), height \(y)")
        }
      }
      #expect(any)
    }

    @Test func batteryNotReadDrawsOnlyTheBarBackground() {
      let image = render(bar: true, stripped: true, width: 120, readings: batteryReadings(-1))
      for x in 0..<21 { #expect(image.column(x).allSatisfy { $0 == 0 }, "no number, column \(x)") }
      for x in 21..<29 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0)
        for y in 2..<16 { #expect(column[y] > 0 && column[y] < 127, "column \(x), height \(y): \(column[y])") }
      }
    }

    @Test(arguments: [(0.5, 7), (1.0, 14), (0.0, 0)])
    func wifiBarFillsToTheSignal(fill: Double, filled: Int) {
      // Wi-Fi alone: its bar is the first reading, x = 0 to 8, from DASHED_BOTTOM 2: fill * 14 rows of white at 0.9 opacity
      // over the background, the rest the background alone
      var r = readings(disk: -1)
      r.wifiShown = true
      r.wifi = fill
      let image = render(bar: true, stripped: true, width: 100, readings: r)
      for x in 0..<8 {
        let column = image.column(x)
        #expect(column[0] == 0 && column[1] == 0)
        for y in 2..<16 {
          if y - 2 < filled {
            #expect(column[y] > 200, "filled, column \(x), height \(y): \(column[y])")
          } else {
            #expect(column[y] > 0 && column[y] < 127, "background only, column \(x), height \(y): \(column[y])")
          }
        }
      }
    }

    @Test func wifiNotReadDrawsOnlyTheBackground() {
      var r = readings(disk: -1)
      r.wifiShown = true
      r.wifi = -1
      let image = render(bar: true, stripped: true, width: 100, readings: r)
      for x in 0..<8 {
        for y in 2..<16 { #expect(image.alpha(x: x, y: y) > 0 && image.alpha(x: x, y: y) < 127, "column \(x), height \(y)") }
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
