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
// the core graph, with a mark, a tint, an alert, a group and a width per bar, and a group of rows to the Settings
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
// the class's group in the Settings window, asked once, right after the app has made the menus, before the window is
// first shown: its heading, its rows and the buttons below it. The groups follow the app's "Menu bar" group, in the
// order the classes registered, each under its heading (none when settingsTitle is missing or empty). Each entry of
// settingsRows is one row, @[title, control]: the title (an NSString) on the left in the app's label font, cut at the
// control when too long, the control (an NSView) at the right, centred on the row. The class owns each control: its
// target, action, state and its own defaults key; the app only places it, and is not told of a click. The app names the
// control by its title for VoiceOver unless the control has an accessibilityLabel of its own, and draws the title dimmed
// while an NSControl is disabled (its enabled, set by the class, is followed as it changes). Make on/off
// controls with MenuRowsSettingsSwitch and choices with MenuRowsSettingsChoice, so that they look like the app's own.
// An entry that is not such a pair is skipped; with no row, there is no group and no buttons. settingsButtons are laid
// out left to right below the group, the last at its right edge. A control that hides its class's bars makes
// barReadings (and barLabels) return none while it is off, and the status item follows at the next tick of the graph
- (NSString*)settingsTitle;
- (NSArray<NSArray*>*)settingsRows;
- (NSArray<NSButton*>*)settingsButtons;
// each bar's mark, in the same order as barReadings: a share of the bar's height, 0..1 (above 1 at the top row; near 0
// on its lowest row), shown by a 1-pt line across the bar at that height, drawn over the dashes, white on a dark menu
// bar and black on a light one; 0 or below, an entry that is not a number, a missing entry or a bar not read: none.
// Nothing in Dot style. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barMarks;
// each bar's alert, in the same order as barReadings: an entry whose boolValue is YES draws a dashed bar whole, without
// the dashes, in its own colour (its tint's when it has one; a solid bar is not redrawn, and a dot does not change);
// with colour, a bar with no pace (barPaces) and no colour of its own (barColors) is painted all in its ramp's hottest
// colour instead, dashed or solid; NO, an entry that is not a number, a missing entry or a bar not read: none. Read with
// barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barAlerts;
// each bar's tint, in the same order as barReadings: above 0, the load 0..1 (above 1 as 1) whose colour and opacity the
// bar is painted in, its height still its reading; 0 or below, an entry that is not a number, a missing entry or a bar
// not read: painted by its reading. Nothing in Dot style. Read with barReadings, at each tick of the graph
- (NSArray<NSNumber*>*)barTints;
// each bar's colour, in the same order as barReadings: an NSColor paints the bar in that colour in place of its ramp
// colour, tint and pace, and of an alert's hottest colour: its fill opaque, its background, drawn also while the bar is not read,
// in that colour at a dim opacity (0.25 on a light menu bar, 0.35 on a dark one); in Dot style a read bar's dot in that
// colour. Nothing changes without colour; an entry that is not an NSColor or a missing entry: none. Read with
// barReadings, at each tick of the graph
- (NSArray<NSColor*>*)barColors;
// each bar's pace, in the same order as barReadings: above 0, how much of the bar's period has passed, a share of its
// height 0..1 (above 1 as 1); a bar above it is painted up to it in its ramp's coolest colour and above it in its
// ramp's hottest colour, a bar below it gets the stretch up to it painted dim; 0 or below, an entry that is not a
// number, a missing entry or a bar not read: none. Nothing in Dot style or without colour. Read with barReadings, at
// each tick of the graph
- (NSArray<NSNumber*>*)barPaces;
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

// a Settings row's on/off control, as the app's own: a mini switch, on or off, that sends action to target when it is
// clicked
NSSwitch* MenuRowsSettingsSwitch(BOOL on, SEL action, id target);

// a Settings row's choice, as the app's own: a segmented control with one segment per label, each segmentWidth pt
// wide, the segment at selected chosen (none when out of range), that sends action to target when a segment is chosen
NSSegmentedControl* MenuRowsSettingsChoice(NSArray<NSString*>* labels, CGFloat segmentWidth, NSInteger selected, SEL action, id target);

__END_DECLS

NS_ASSUME_NONNULL_END
