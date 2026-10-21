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

// Rows that a build adds to the status menu, above Quit, and to the readings panel beside it, after the readings. A
// class that adopts MenuRows registers itself with MenuRowsRegister from its +load; upMonitor makes one instance of
// each when it builds the menu and adds its rows, then a separator, and its panel rows, any of them a heading, as a
// section of their own. It may also add views to the process inspector's header, bars to the menu bar, at the right of
// the core graph, with a mark, a tint, an alert, a group and a width per bar, and check boxes to the Preferences
// window.
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
// each panel row's heading, in the same order as panelRows: an entry whose boolValue is YES draws that row's title as
// the menu's own title is drawn, in its font and colour, centred across the panel, and no value; NO, an entry that is
// not a number or a missing entry: a plain row. Read with panelRows
- (NSArray<NSNumber*>*)panelHeadings;
// views for the process inspector's header, made once, the first time the inspector shows a process: laid out left to
// right in this order on a line of their own below the header's text, each centred on that line, which is as tall as
// the tallest; the last view, and the text above, end 20 pt short of the header's right edge, the margin the icon keeps
// at its left. A view taller than about 35 pt reaches the tabs below
- (NSArray<NSView*>*)inspectorViews;
// each time the inspector shows a process, before its views are laid out: its pid and name, exited when it is a frozen
// row whose process has exited or whose pid now belongs to another process. A view may change its width here
- (void)inspectorShowsPid:(pid_t)pid name:(NSString*)name exited:(BOOL)exited;
// bars for the menu bar, drawn right of the core graph in the CPU bar's style, each 0..1 (below 0: not read, only its
// background in bar style, nothing in Dot style); read at each tick of the graph, menu open or not, the app's own bars
// shown or not. All classes' bars together, with no limit; the status item widens with each bar, and macOS hides a
// status item that does not fit the menu bar. It widens or narrows when their number changes
- (NSArray<NSNumber*>*)barReadings;
// each bar's text, in the same order, shown below it while the pointer rests on it ("Title: value"); read when the
// label shows and every 0.25 s while it is shown. A missing or empty text shows no label
- (NSArray<NSString*>*)barLabels;
// check boxes for the Preferences window, made once: the app asks for them once, right after it has made the menus,
// before the window is first shown. The class owns each box: its title, target, action, state and its own defaults key;
// the app only places it, and is not told of a click. The app's own "Show Disk, RAM, CPU usage bars" is the first box;
// these take the places after it, two to a row, left column then right, so the first one sits to the right of the app's
// box on the same row and the later ones on rows below, in the order the classes registered and then in each array's
// order; the app gives each the font and size of its own box and fits its width. The right column starts 20 pt after
// the app's box, with about 180 pt of room, and a wider title is cut. Each row after the first adds 22 pt to the
// window's height. An entry that is not an NSButton is skipped. A box that hides its class's bars makes barReadings
// (and barLabels) return none while it is off, and the status item follows at the next tick of the graph
- (NSArray<NSButton*>*)preferenceCheckboxes;
// each bar's mark, in the same order as barReadings: a share of the bar's height, 0..1 (above 1 at the top row; near 0
// on its lowest row), shown by a 1-pt line across the bar at that height, drawn over the dashes, white on a dark menu
// bar and black on a light one; 0 or below, an entry that is not a number, a missing entry or a bar not read: none.
// Nothing in Dot style. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barMarks;
// each bar's alert, in the same order as barReadings: an entry whose boolValue is YES draws a dashed bar whole, without
// the dashes, in its own colour (its tint's when it has one; a solid bar and a dot do not change); NO, an entry that is not a number, a missing entry or a bar not read: none. Read with barReadings, at each
// tick of the graph
- (NSArray<NSNumber*>*)barAlerts;
// each bar's tint, in the same order as barReadings: above 0, the load 0..1 (above 1 as 1) whose colour and opacity the
// bar is painted in, its height still its reading; 0 or below, an entry that is not a number, a missing entry or a bar
// not read: painted by its reading. Nothing in Dot style. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barTints;
// each bar's group, in the same order as barReadings: an entry whose boolValue is YES starts a new group, drawn after a
// clear gap; a class's first bar starts one whenever bars of another class come before it. NO, an entry that is not a
// number or a missing entry: the bar continues the group before it. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barGroupStarts;
// each bar's width, in the same order as barReadings: an entry whose boolValue is YES draws the bar as wide as a core bar,
// in a core bar's slot (Dot style does not change); NO, an entry that is not a number or a missing entry: twice as wide,
// as the app's own readings. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barNarrows;
@end

__BEGIN_DECLS

void MenuRowsRegister(Class<MenuRows> rowsClass);

// a row that a click leaves open: it sends action to target on mouse-up (and on VoiceOver's press), drawn as a
// native row; disabled, it is grey and a click does nothing
NSMenuItem* MenuRowsStayOpenItem(NSString* title, SEL action, id target, NSDictionary<NSAttributedStringKey, id>* attributes);

__END_DECLS

NS_ASSUME_NONNULL_END
