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

// CpuRenderer.c's layout functions, all with tickWidth 4 and tickTotalWidth 6. Every expected value is worked out from
// the function named in the comment beside it.
extension FreeTests {
  @Suite struct RendererGeometryTests {
    @Test func readingsSlotAndWidth() {
      // _readings_slot (CpuRenderer.c:144): bar tickTotalWidth + tickWidth = 10, dot tickTotalWidth = 6
      #expect(CpuRenderReadingsSlot(true, 4, 6) == 10)
      #expect(CpuRenderReadingsSlot(false, 4, 6) == 6)
      // CpuRenderReadingsWidth (CpuRenderer.c:301): 5 slots + (dot 1) + gap 4 + (split) split gap + extras
      #expect(CpuRenderReadingsWidth(true, 4, 6, 0, 0, nil) == 54)   // 5*10 + 0 + 4
      #expect(CpuRenderReadingsWidth(false, 4, 6, 0, 0, nil) == 35)  // 5*6 + 1 + 4
      #expect(CpuRenderReadingsWidth(true, 4, 6, 2, 0, nil) == 58)   // 54 + _split_gap(bar) = 0 + 4
      #expect(CpuRenderReadingsWidth(false, 4, 6, 2, 0, nil) == 40)  // 35 + _split_gap(dot) = 1 + 4
    }

    @Test func extraWidthGroupsAndNarrow() {
      // _extra_width (CpuRenderer.c:223): gap 4 + the slots + a group gap 4 per group start after the first + (dot 1)
      var extras = [CpuExtraReading](repeating: CpuExtraReading(), count: 2)
      #expect(extras.withUnsafeBufferPointer { CpuRenderExtraWidth(true, 4, 6, 2, $0.baseAddress) } == 24)  // 4 + 10 + 10
      extras[1].groupStart = true
      #expect(extras.withUnsafeBufferPointer { CpuRenderExtraWidth(true, 4, 6, 2, $0.baseAddress) } == 28)  // 24 + 4
      extras[1].groupStart = false
      extras[1].narrow = true
      #expect(extras.withUnsafeBufferPointer { CpuRenderExtraWidth(true, 4, 6, 2, $0.baseAddress) } == 20)  // 4 + 10 + 6
      #expect(CpuRenderExtraWidth(true, 4, 6, 0, nil) == 0)    // n > 0 is false (CpuRenderer.c:226)
      #expect(CpuRenderExtraWidth(true, 4, 6, -3, nil) == 0)   // _extra_count (CpuRenderer.c:154) turns -3 into 0
    }

    @Test func coreSlotThinsPast24() {
      // CpuRenderCoreSlot (CpuRenderer.c:309): up to 24 bars the full slot; past it max(1 + (6-4), min(6, floor(24*6/count)))
      #expect(CpuRenderCoreSlot(true, 4, 6, 24) == 6)
      #expect(CpuRenderCoreSlot(true, 4, 6, 30) == 4)    // floor(144/30) = 4
      #expect(CpuRenderCoreSlot(true, 4, 6, 48) == 3)    // floor(144/48) = 3
      #expect(CpuRenderCoreSlot(true, 4, 6, 100) == 3)   // floor(144/100) = 1, raised to the floor 1 + 2
      #expect(CpuRenderCoreSlot(false, 4, 6, 100) == 6)  // dots keep their slot (CpuRenderer.c:311)
      // CpuRenderCoreWidth (CpuRenderer.c:319): tickWidth in a full slot, else the slot less the gap (6-4)
      #expect(CpuRenderCoreWidth(true, 4, 6, 10) == 4)
      #expect(CpuRenderCoreWidth(true, 4, 6, 30) == 2)   // 4 - 2
    }

    @Test func coreXAndBack() {
      // CpuRenderCoreX (CpuRenderer.c:325): start + index*slot + (index past the split) split gap + readings slot
      #expect(CpuRenderCoreX(true, 4, 6, 54, 0, 8, 3) == 72)   // 54 + 3*6
      #expect(CpuRenderCoreX(true, 4, 6, 44, 2, 8, 2) == 70)   // 44 + 2*6 + (0 + 4) + 10
      // CpuRenderCoreAtX (CpuRenderer.c:331): the rightmost bar starting at or left of x, if x is inside its slot
      #expect(CpuRenderCoreAtX(true, 4, 6, 54, 0, 8, 72) == 3)
      #expect(CpuRenderCoreAtX(true, 4, 6, 54, 0, 8, 53.9) == -1)               // left of bar 0 (x = 54)
      #expect(CpuRenderCoreAtX(true, 4, 6, 54, 0, 8, 54 + 48 + 100) == 7)       // the last bar has no right end
      #expect(CpuRenderCoreAtX(true, 4, 6, 44, 2, 8, 69.9) == -1)               // between bar 1's slot (50..56) and bar 2 (70)
      #expect(CpuRenderCoreAtX(true, 4, 6, 44, 2, 8, 70) == 2)
    }

    @Test func readingXAndGraphSpan() {
      // CpuRenderReadingX (CpuRenderer.c:272), the five readings: index * slot
      #expect(CpuRenderReadingX(true, 4, 6, 100, 0, 8, 0, nil, 2) == 20)
      // split after 2 bars: the E-cores' reading at _efficiency_x (CpuRenderer.c:239) = 3*10 + 0 + 4
      #expect(CpuRenderReadingX(true, 4, 6, 100, 2, 8, 0, nil, 3) == 34)
      // the P-cores' reading: 34 + slot 10 + 2 bars * 6 + split gap 4
      #expect(CpuRenderReadingX(true, 4, 6, 100, 2, 8, 0, nil, 4) == 60)
      // extra readings: imageWidth - _extra_width + gap 4 + the slots before it; an index past the last gives the last one's
      let extras = [CpuExtraReading](repeating: CpuExtraReading(), count: 2)
      extras.withUnsafeBufferPointer { e in
        #expect(CpuRenderReadingX(true, 4, 6, 200, 0, 8, 2, e.baseAddress, 5) == 180)  // 200 - 24 + 4
        #expect(CpuRenderReadingX(true, 4, 6, 200, 0, 8, 2, e.baseAddress, 6) == 190)  // 180 + 10
        #expect(CpuRenderReadingX(true, 4, 6, 200, 0, 8, 2, e.baseAddress, 9) == 190)  // clamped to the last (CpuRenderer.c:288)
      }
      // CpuRenderGraphSpan (CpuRenderer.c:345)
      var start: CGFloat = 0, end: CGFloat = 0
      CpuRenderGraphSpan(true, 4, 6, 100, true, 0, 0, nil, &start, &end)
      #expect(start == 54 && end == 100)   // the readings' width, no extras
      CpuRenderGraphSpan(true, 4, 6, 100, true, 2, 0, nil, &start, &end)
      #expect(start == 44)                 // _efficiency_x 34 + slot 10
      CpuRenderGraphSpan(true, 4, 6, 100, false, 0, 0, nil, &start, &end)
      #expect(start == 0)                  // no readings: the graph starts at x = 0
    }

    @Test func efficiencyBars() {
      // CpuRenderEfficiencyBars (CpuRenderer.c:244); granularity 0 is one bar (CpuSampler.c:130), under 2 gives 0
      #expect(CpuRenderEfficiencyBars(0, 8, "EEEEPPPP") == 0)
      let n = Int(CpuSamplerGetCount(2))
      #expect(n >= 2)
      // one bar per logical CPU: one E then P's gives efficiency 1 and group 1; P first gives efficiency 0
      let split = "E" + String(repeating: "P", count: n - 1)
      #expect(CpuRenderEfficiencyBars(2, natural_t(n), split) == 1)
      let flipped = "P" + String(repeating: "E", count: n - 1)
      #expect(CpuRenderEfficiencyBars(2, natural_t(n), flipped) == 0)
      #expect(CpuRenderEfficiencyBars(2, natural_t(n), nil) == 0)   // kinds NULL (CpuRenderer.c:248)
    }
  }
}
