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

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Rows that a build adds to the status menu, above Quit, and to the readings panel beside it, above Uptime. A class
// that adopts MenuRows registers itself with MenuRowsRegister from its +load; upMonitor makes one instance of each
// when it builds the menu and adds its rows, then a separator, and its panel rows as a section of their own. It may
// also add views to the process inspector's header, and bars to the menu bar after the CPU bar.
// Everything here runs on the main thread, +load aside.
@protocol MenuRows <NSObject>
// the rows, their titles set in attributes, the menu's own text attributes
- (NSArray<NSMenuItem*>*)menuItemsWithAttributes:(NSDictionary<NSAttributedStringKey, id>*)attributes;
@optional
// as the menu opens, frozen or not
- (void)menuWillOpen;
// while the menu is open, each time the process sampler runs (its timer, the menu opening, unfreezing, resuming
// after a pause), frozen or not; while frozen it takes no sample
- (void)menuTick;
- (void)menuDidClose;
// the panel's rows, each a title and its value (@[@"Title:", @"value"]); read whenever the panel's values are set: as
// the menu opens and then every second while it is open, frozen or not. The number may change from one read to the
// next, none included; the panel's height follows
- (NSArray<NSArray<NSString*>*>*)panelRows;
// views for the process inspector's header, made once, the first time the inspector shows a process: laid out left to
// right in this order, the last one ending at the header's right edge, each centred on the header's line; the header's
// text ends before the first
- (NSArray<NSView*>*)inspectorViews;
// each time the inspector shows a process, before its views are laid out: its pid and name, exited when it is a frozen
// row whose process has exited or whose pid now belongs to another process. A view may change its width here
- (void)inspectorShowsPid:(pid_t)pid name:(NSString*)name exited:(BOOL)exited;
// bars for the menu bar, drawn after the CPU bar in its style, each 0..1 (below 0: not read, only its background in
// bar style, nothing in Dot style); read at each tick of the graph while the bars are shown, menu open or not. All
// classes' bars together, at most CPU_RENDER_EXTRA_MAX (4), the rest not drawn; the status item widens or narrows
// when their number changes
- (NSArray<NSNumber*>*)barReadings;
// each bar's text, in the same order, shown below it while the pointer rests on it ("Title: value"); read when the
// label shows and every 0.25 s while it is shown. A missing or empty text shows no label
- (NSArray<NSString*>*)barLabels;
@end

__BEGIN_DECLS

void MenuRowsRegister(Class<MenuRows> rowsClass);

// a row that a click leaves open: it sends action to target on mouse-up (and on VoiceOver's press), drawn as a
// native row; disabled, it is grey and a click does nothing
NSMenuItem* MenuRowsStayOpenItem(NSString* title, SEL action, id target, NSDictionary<NSAttributedStringKey, id>* attributes);

__END_DECLS

NS_ASSUME_NONNULL_END
