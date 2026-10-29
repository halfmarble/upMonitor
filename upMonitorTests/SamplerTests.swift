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
import Foundation

// CpuSampler.c: the counts, the two demo samplers and one real read.
extension FreeTests {
  @Suite struct SamplerTests {
    @Test func flatDemo() {
      var flat = CpuSummaryInfo()
      CpuSamplerFlatDemoInit(&flat)
      defer { free(flat.now) }
      let n = Int(flat.countLogical)
      #expect(n >= 1)
      // every CPU gets the same load (CpuSampler.c:272)
      let first = flat.now[0].load
      #expect((0..<n).allSatisfy { flat.now[$0].load == first })
      // each call stores the static load, then raises it by 0.04 * speed, back to 0 past 1 (CpuSampler.c:274-280): the
      // next call stores the raised value, or 0 after the wrap
      CpuSamplerFlatDemoUpdate(&flat, 1.0)
      let second = flat.now[0].load
      #expect(abs(second - (first + 0.04)) < 1e-12 || second == 0.0)
    }

    @Test func sineDemo() throws {
      // Only this test calls the sine demo, so its static counter (CpuSampler.c:247) starts at 0: CPU 0 gets
      // sin(3.5 * 0) / 2 + 0.5 = 0.5, and the counter then rises by 0.025 (CpuSampler.c:250-251), so CPU 1 gets
      // sin(3.5 * 0.025) / 2 + 0.5
      var sine = CpuSummaryInfo()
      CpuSamplerSineDemoInit(&sine)
      defer { free(sine.now) }
      try #require(sine.countLogical >= 2)
      #expect(sine.now[0].load == 0.5)
      #expect(abs(sine.now[1].load - (sin(3.5 * 0.025) / 2 + 0.5)) < 1e-12)
    }

    @Test func countsByGranularity() {
      // CpuSamplerGetCount (CpuSampler.c:122): 1 for granularity 0, the physical count for 1 and the logical count for 2,
      // each at least 1, and a Mac has no fewer logical CPUs than physical ones
      #expect(CpuSamplerGetCount(0) == 1)
      #expect(CpuSamplerGetCount(1) >= 1)
      #expect(CpuSamplerGetCount(2) >= CpuSamplerGetCount(1))
    }

    @Test func realReadStaysInRange() {
      // CpuSamplerInit reads once and calls CpuSamplerUpdate (CpuSampler.c:151), which stores used / total (CpuSampler.c:175),
      // a share between 0 and 1
      var info = CpuSummaryInfo()
      CpuSamplerInit(&info)
      defer { free(info.last); free(info.now) }
      let n = Int(info.countLogical)
      #expect(n >= 1)
      #expect((0..<n).allSatisfy { (0.0...1.0).contains(info.now[$0].load) })
      CpuSamplerUpdate(&info)
      #expect((0..<n).allSatisfy { (0.0...1.0).contains(info.now[$0].load) })
    }
  }
}
