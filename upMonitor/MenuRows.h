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
// when it builds the menu and adds its rows, then a separator, and its panel rows as a section of their own.
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
// the panel's rows, each a title and its value (@[@"Title:", @"value"]), the same number each time; read whenever the
// panel's values are set: as the menu opens and then every second while it is open, frozen or not
- (NSArray<NSArray<NSString*>*>*)panelRows;
@end

__BEGIN_DECLS

void MenuRowsRegister(Class<MenuRows> rowsClass);

// a row that a click leaves open: it sends action to target on mouse-up (and on VoiceOver's press), drawn as a
// native row; disabled, it is grey and a click does nothing
NSMenuItem* MenuRowsStayOpenItem(NSString* title, SEL action, id target, NSDictionary<NSAttributedStringKey, id>* attributes);

__END_DECLS

NS_ASSUME_NONNULL_END
