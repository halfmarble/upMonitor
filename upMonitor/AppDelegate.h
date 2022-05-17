// The MIT License (MIT)

// Copyright 2022 HalfMarble LLC

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

#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate, NSTabViewDelegate>

@property (weak) IBOutlet NSWindow *window;
@property (weak) IBOutlet NSWindow *top;

@property (weak) IBOutlet NSImageView *realDemoView;
@property (weak) IBOutlet NSImageView *sineDemoView;
@property (weak) IBOutlet NSImageView *flatDemoView;

@property (weak) IBOutlet NSButton *packageButton;
@property (weak) IBOutlet NSButton *coreButton;
@property (weak) IBOutlet NSButton *logicalButton;

@property (weak) IBOutlet NSButton *fastButton;
@property (weak) IBOutlet NSButton *normalButton;
@property (weak) IBOutlet NSButton *slowButton;

@property (weak) IBOutlet NSButton *barButton;
@property (weak) IBOutlet NSButton *dotButton;

@property (weak) IBOutlet NSButton *solidButton;
@property (weak) IBOutlet NSButton *strippedButton;

@property (weak) IBOutlet NSButton *thinButton;
@property (weak) IBOutlet NSButton *standardButton;
@property (weak) IBOutlet NSButton *thickButton;

@property (weak) IBOutlet NSButton *greyButton;
@property (weak) IBOutlet NSButton *colorButton;

@property (weak) IBOutlet NSButton *yellowButton;
@property (weak) IBOutlet NSButton *greenButton;
@property (weak) IBOutlet NSButton *blueButton;

@property (nonatomic, strong, readwrite) NSStatusItem *statusItem;

@property (weak) IBOutlet NSImageView *procAppIcon;
@property (weak) IBOutlet NSTextField *procAppName;
@property (weak) IBOutlet NSTabView *procAppView;

@property (weak) IBOutlet NSScrollView *procDescScrollView;
@property (assign) IBOutlet NSTextView *procDescTextView;

@property (weak) IBOutlet NSScrollView *procArgsEnvScrollView;
@property (assign) IBOutlet NSTextView *procArgsEnvTextView;

@property (weak) IBOutlet NSScrollView *procLsofScrollView;
@property (assign) IBOutlet NSTextView *procLsofTextView;

@property (weak) IBOutlet NSScrollView *procNmScrollView;
@property (assign) IBOutlet NSTextView *procNmTextView;

@property (weak) IBOutlet NSScrollView *procThreadsScrollView;
@property (assign) IBOutlet NSTextView *procThreadsTextView;

@end
