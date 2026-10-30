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

// Top.c: the process sampler, run in the test runner (xctest), which is not sandboxed. Every test samples again, so each
// finds the runner's own process in the latest sample.
extension FreeTests {
  @Suite struct TopTests {
    // TopInit allocates its tables and takes the first sample (Top.c:321-355): once per process
    static let processCount = TopInit()

    private static func sample() -> Int32 {
      _ = processCount
      return TopSample()
    }

    @Test func findsItself() {
      #expect(TopTests.processCount > 0)
      // a second sample after some CPU use, so the runner has a baseline (Top.c:272-298)
      let until = Date().addingTimeInterval(0.2)
      var spin = 0.0
      while Date() < until { spin += 1 }
      #expect(TopTests.sample() > 0, "after \(spin) loops")
      // own process: the full read works (Top.c:255), so CPU and memory are known and the footprint is above 0
      let me = TopGetSample(getpid())
      #expect(me != nil)
      #expect(me?.pointee.cpu_known == 1)
      #expect(me?.pointee.mem_known == 1)
      #expect((me?.pointee.mem ?? 0) > 0)
    }

    @Test func memoryOrderIsNonIncreasing() {
      // _top_compare_mem_func (Top.c:126): known memory first, then the larger footprint first
      _ = TopTests.sample()
      TopSetOrder(TopOrderMemory)
      defer { TopSetOrder(TopOrderCpu) }
      var last = UInt64.max, ordered = true, seen = 0
      while let s = TopIterate() {
        if s.pointee.mem_known == 1 {
          if s.pointee.mem > last { ordered = false }
          last = s.pointee.mem
        }
        seen += 1
      }
      #expect(ordered)
      #expect(seen > 0)
    }

    @Test func argumentsAndUserName() {
      _ = TopTests.sample()
      // TopGetArgs (Top.c:651) reads KERN_PROCARGS2 of the runner's own process: argc is at least 1 (Top.c:693)
      let args = TopGetArgs(getpid())
      #expect((args?.pointee.args_count ?? 0) >= 1)
      // TopGetUsername (Top.c:556) is getpwuid's pw_name
      #expect(String(cString: TopGetUsername(getuid())) == NSUserName())
    }

    // Run as root, the test is skipped, not passed: root reads every process
    @Test(.disabled(if: getuid() == 0, "root reads every process")) func otherUsersProcessIsUnreadable() {
      // Process 1 (launchd) belongs to root. A user who is not root gets no task info for it (Top.c:255-259), so its CPU
      // is unknown and it counts as unreadable (Top.c:381); the sample still lists it
      _ = TopTests.sample()
      let launchd = TopGetSample(1)
      #expect(launchd != nil)
      #expect(launchd?.pointee.cpu_known == 0)
      #expect(TopUnreadableCount() > 0)
    }
  }
}
