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

// The C modules keep their state in unlocked statics and are called from one thread, so every suite is nested in this
// root and every test runs one at a time. The suites are in RendererGeometryTests.swift, RendererDrawingTests.swift,
// SamplerTests.swift, SystemInfoTests.swift and TopTests.swift.
@Suite(.serialized) struct FreeTests {}

// The variant and IOReportReader.c's pure functions. cpuTopBarsTests compiles the unsandboxed (GitHub) variant, as the
// public target does (CPUTOPBARS_SANDBOX = NO); a sandboxed build's tests would see 1. Sandbox.h's macro is a plain
// integer literal, so Swift imports it as it is through the bridging header.
extension FreeTests {
  @Suite struct VariantAndIOReportTests {
    @Test func compilesTheUnsandboxedVariant() {
      #expect(CPUTOPBARS_SANDBOXED == 0)
    }

    // Residencies of "PMP | AF BW | ANE0 RD+WR" (32 bins, "1GB/s" first), from calib/CALIBRATION.md: only the sums
    // were recorded per window, and the formula reads nothing else, so each window is the lowest bin plus one bin
    // holding the rest. Rest window 0 of "run rest": total 0, so 0 %. Flat-out window 7 of the duty-100 run: total
    // 4,828, 2,235 of it above the lowest bin, so the lowest holds 4,828 - 2,235 = 2,593 and the busy share is
    // 100 * 2,235 / 4,828 = 46.29 % (2,235 / 4,828 = 0.462925...).
    private static func window(lowest: Int64, above: Int64) -> [Int64] {
      var bins = [Int64](repeating: 0, count: 32)
      bins[0] = lowest
      bins[8] = above   // the 9 GB/s bin (the window's weighted mean was 9.056 GB/s)
      return bins
    }

    @Test func aneBusyAtRestIsZero() {
      let rest = [Int64](repeating: 0, count: 32)
      #expect(IOReportAneBusyFromResidencies(rest, 32) == 0)
    }

    @Test func aneBusyFlatOut() {
      let flat = VariantAndIOReportTests.window(lowest: 2593, above: 2235)
      let busy = IOReportAneBusyFromResidencies(flat, 32)
      #expect(abs(busy - 100.0 * 2235.0 / 4828.0) < 1e-9)
      #expect(abs(busy - 46.2925) < 1e-3)
    }

    @Test func aneBusyEdges() {
      #expect(IOReportAneBusyFromResidencies(nil, 32) == -1)
      let one: [Int64] = [5]
      #expect(IOReportAneBusyFromResidencies(one, 0) == -1)
      #expect(IOReportAneBusyFromResidencies(one, -3) == -1)
      // only the lowest bin: powered, nothing above it
      #expect(IOReportAneBusyFromResidencies(one, 1) == 0)
      // everything above the lowest bin
      let all: [Int64] = [0, 7]
      #expect(IOReportAneBusyFromResidencies(all, 2) == 100)
    }

    @Test func gpuWatts() {
      #expect(IOReportGpuWattsFromEnergy(1e9, 2) == 0.5)
      #expect(IOReportGpuWattsFromEnergy(0, 1) == 0)
      #expect(IOReportGpuWattsFromEnergy(1e9, 0) == -1)
      #expect(IOReportGpuWattsFromEnergy(1e9, -1) == -1)
      #expect(IOReportGpuWattsFromEnergy(-1, 2) == -1)
    }
  }
}
