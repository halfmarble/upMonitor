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

// Which variant this target compiles: the build setting CPUTOPBARS_SANDBOX (YES or NO) adds CPUTOPBARS_SANDBOX_YES=1 or
// CPUTOPBARS_SANDBOX_NO=1 to GCC_PREPROCESSOR_DEFINITIONS. Every target that compiles these files must say which.

#ifndef Sandbox_h
#define Sandbox_h

#if defined(CPUTOPBARS_SANDBOX_YES) && defined(CPUTOPBARS_SANDBOX_NO)
#error "CPUTOPBARS_SANDBOX_YES and CPUTOPBARS_SANDBOX_NO are both defined"
#elif defined(CPUTOPBARS_SANDBOX_YES)
#define CPUTOPBARS_SANDBOXED 1
#elif defined(CPUTOPBARS_SANDBOX_NO)
#define CPUTOPBARS_SANDBOXED 0
#else
#error "Define CPUTOPBARS_SANDBOX_YES or CPUTOPBARS_SANDBOX_NO (the build setting CPUTOPBARS_SANDBOX)"
#endif

#endif /* Sandbox_h */
