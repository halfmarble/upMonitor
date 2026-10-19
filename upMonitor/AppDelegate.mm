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

#import <ServiceManagement/ServiceManagement.h>
#import <Security/Authorization.h>
#import <sys/sysctl.h>
#import <libproc.h>
#import <pwd.h>
#import <sys/types.h>
#import <unistd.h>
#import <getopt.h>
#import <stdlib.h>
#import <ctype.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "AppDelegate.h"

#import "CpuSampler.h"
#import "CpuRenderer.h"
#import "Top.h"
#import "SystemInfo.h"
#import "MenuRows.h"

#pragma mark Constants

#define TOP_COUNT                   (15)
#define TOP_REFRESH_RATE            (2.5)   // s between process samples, whatever the Refresh setting

//   32 space bar  3.333984
// 8201 thin space 1.669922
// 8202 hair space 0.837891
#define SPACE_THIN                  (8202)
#define NAME_STR_SPACE_TARGET       (150.0)
#define CPU_STR_SPACE_TARGET        (50.0)

#define MENU_ICON_SIZE              (14.0)
#define TOP_ICON_SIZE               (48.0)
#define MENU_FONT_NAME              @"Helvetica"
#define MENU_TITLE_FONT_NAME        @"Verdana"

#define SYSTEM_ICONS_RSRC           "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"
#define APP_DEFAULT_ICON_NAME       "GenericApplicationIcon.icns"
#define PROCESS_DEFAULT_ICON_NAME   "ExecutableBinaryIcon.icns"

static NSString* GranularityKey = @"GranularityKey";
static NSString* RefreshKey = @"RefreshKey";
static NSString* StyleKey = @"StyleKey";
static NSString* TickLineKey = @"TickLineKey";
static NSString* TickWidthKey = @"TickWidthKey";
static NSString* AppearanceKey = @"AppearanceKey";
static NSString* ThemeKey = @"ThemeKey";
static NSString* ShowBarsKey = @"ShowBarsKey";

#pragma mark - C APIs

static void stringFree(CFAllocatorRef allocator, const void *value)
{
  NSString* string = (__bridge NSString*)value;
  CFBridgingRelease((__bridge CFTypeRef _Nullable)(string));
}

static const void* stringRetain(CFAllocatorRef allocator, const void *value)
{
  NSString* string = (__bridge NSString*)value;
  return CFBridgingRetain(string);
}

static Boolean stringEqual(const void *value1, const void *value2)
{
  NSString* string1 = (__bridge NSString*)value1;
  NSString* string2 = (__bridge NSString*)value2;
  return [string1 isEqualToString:string2];
}

// macOS 27 hides menu item images unless an item asks for them
static void ShowMenuItemImage(NSMenuItem* item)
{
  item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
}

// With Reduce Transparency on, the status menu's glass can be drawn as an opaque near-black, and
// the generic process icons disappear into it. Paint the menu's content in the menu bar's own Dark
// Mode grey instead. Menus have no public background setting, so this looks for the open menu's
// glass view; when it is not there, the menu stays as the system draws it.

// sRGB, the menu bar's grey in Dark Mode with Reduce Transparency
static const CGFloat MENU_DARK_GREY = 32.0/255.0;

// the first glass view in the window, breadth-first from its frame view
static NSGlassEffectView* FindGlassEffectView(NSWindow* window)
{
  NSView* root = window.contentView.superview ?: window.contentView;
  if (root == nil)
  {
    return nil;
  }
  NSMutableArray<NSView*>* queue = [NSMutableArray arrayWithObject:root];
  while (queue.count > 0)
  {
    NSView* view = queue[0];
    [queue removeObjectAtIndex:0];
    if ([view isKindOfClass:[NSGlassEffectView class]])
    {
      return (NSGlassEffectView*)view;
    }
    [queue addObjectsFromArray:view.subviews];
  }
  return nil;
}

// Reduce Transparency on and Increase Contrast off: a menu in Dark Mode is then painted MENU_DARK_GREY
static bool PaintsMenusGrey(void)
{
  NSWorkspace* workspace = [NSWorkspace sharedWorkspace];
  return workspace.accessibilityDisplayShouldReduceTransparency && !workspace.accessibilityDisplayShouldIncreaseContrast;
}

static bool IsDarkAqua(NSAppearance* appearance)
{
  NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
  return [name isEqualToString:NSAppearanceNameDarkAqua];
}

static void PaintGlassGrey(NSGlassEffectView* glass)
{
  NSView* content = glass.contentView;
  content.wantsLayer = YES;
  content.layer.backgroundColor = [NSColor colorWithSRGBRed:MENU_DARK_GREY green:MENU_DARK_GREY blue:MENU_DARK_GREY alpha:1.0].CGColor;
  content.layer.cornerRadius = glass.cornerRadius;
  content.layer.masksToBounds = YES;
}

static void PaintOpenMenuBackground(void)
{
  if (!PaintsMenusGrey())
  {
    return;
  }

  static bool loggedNoWindow = false;
  static bool loggedNoGlass = false;
  bool found = false;
  for (NSWindow* window in [NSApp windows])
  {
    if (!window.isVisible || ![NSStringFromClass([window class]) containsString:@"Menu"])
    {
      continue;
    }
    found = true;

    if (!IsDarkAqua(window.effectiveAppearance))
    {
      continue;
    }

    NSGlassEffectView* glass = FindGlassEffectView(window);
    if (glass == nil)
    {
      if (!loggedNoGlass)
      {
        loggedNoGlass = true;
        NSLog(@"menu window %@ has no glass view: the menu keeps the system's background", NSStringFromClass([window class]));
      }
      continue;
    }

    PaintGlassGrey(glass);
  }

  if (!found && !loggedNoWindow)
  {
    loggedNoWindow = true;
    NSLog(@"no visible menu window: the menu keeps the system's background");
  }
}

#pragma mark - Row tooltips while frozen

// A process row's helper text shows only while the menu is frozen (otherwise the row has moved before
// the text can be read), in a box of its own left of the menu and level with the row, so that it never
// covers the rows. AppKit places a menu item's toolTip itself, so the rows carry the text in
// representedObject instead, and the box is a panel of our own.

#define ROW_TIP_DELAY               (0.4)   // s on a row before its text shows
#define ROW_TIP_GAP                 (6.0)   // pt between the box and the menu
#define ROW_TIP_MAX_WIDTH           (400.0)
#define BAR_TIP_DELAY               (1.0)   // s on a menu-bar reading before its label shows
#define BAR_TIP_WATCH               (0.25)  // s between looks at the pointer while a label is armed or shown
#define BAR_TIP_GAP                 (4.0)   // pt between the menu bar and the label

// the item's row on screen, NSZeroRect when the window's row views do not match the menu: top first,
// they are the menu's shown items in order, separators included
static NSRect MenuRowScreenRect(NSWindow* window, NSMenu* menu, NSMenuItem* item)
{
  NSView* root = window.contentView.superview ?: window.contentView;
  if (root == nil)
  {
    return NSZeroRect;
  }
  NSMutableArray<NSView*>* rows = [NSMutableArray array];
  NSMutableArray<NSView*>* stack = [NSMutableArray arrayWithObject:root];
  while (stack.count > 0)
  {
    NSView* view = [stack lastObject];
    [stack removeLastObject];
    if ([NSStringFromClass([view class]) hasSuffix:@"MenuItemView"])
    {
      [rows addObject:view];
      continue;
    }
    [stack addObjectsFromArray:view.subviews];
  }
  [rows sortUsingComparator:^NSComparisonResult(NSView* a, NSView* b) {
    CGFloat ya = NSMaxY([a convertRect:a.bounds toView:nil]);
    CGFloat yb = NSMaxY([b convertRect:b.bounds toView:nil]);
    return (ya > yb) ? NSOrderedAscending : ((ya < yb) ? NSOrderedDescending : NSOrderedSame);
  }];

  NSMutableArray<NSMenuItem*>* shown = [NSMutableArray array];
  for (NSMenuItem* each in menu.itemArray)
  {
    if (!each.hidden)
    {
      [shown addObject:each];
    }
  }
  NSUInteger index = [shown indexOfObjectIdenticalTo:item];
  if ((rows.count != shown.count) || (index == NSNotFound))
  {
    return NSZeroRect;
  }
  NSView* row = rows[index];
  return [window convertRectToScreen:[row convertRect:row.bounds toView:nil]];
}

// the open menu's window, recognised by the item's row (MenuRowScreenRect), which goes to *row when row is not NULL;
// nil when the menu is not on screen or its rows do not match it
static NSWindow* OpenMenuWindow(NSMenu* menu, NSMenuItem* item, NSRect* row)
{
  for (NSWindow* each in [NSApp windows])
  {
    if (each.isVisible && [NSStringFromClass([each class]) containsString:@"Menu"])
    {
      NSRect rect = MenuRowScreenRect(each, menu, item);
      if (!NSIsEmptyRect(rect))
      {
        if (row != NULL)
        {
          *row = rect;
        }
        return each;
      }
    }
  }
  return nil;
}

#pragma mark - The readings panel beside the menu

// While the status menu is open, a panel beside it shows how full the startup volume is, memory, overall CPU and
// uptime, all read on this Mac. It is placed left of the menu, level with its top, or right of it when there is no
// room on the left; it updates every second, frozen too, and closes with the menu. The disk row is read when the menu
// opens and then every 10 s: each read asks another process for the volume's purgeable space. With the menu closed
// and the menu bar's bars on, the graph's timer reads it every 60 s instead.

#define INFO_REFRESH                (1.0)   // s between updates
#define DISK_REFRESH                (10.0)  // s between disk reads while the menu stays open
#define MENUBAR_DISK_REFRESH        (60.0)  // s between disk reads for the menu bar's disk bar
#define READINGS_TICKS              (2.0)   // Refresh intervals between reads of overall CPU and memory, for the bars and the panel
#define INFO_RETRY_DELAY            (0.1)   // s before a second look for the menu's window
#define INFO_ROW_HEIGHT             (22.0)  // pt, 2 pt shorter than a native row (a menu grows 24 pt with one, measured)
#define INFO_INSET                  (14.0)  // pt left and right, as a title-only row
#define INFO_COLUMN_GAP             (24.0)  // pt at least between a label and its value
#define INFO_VERTICAL_INSET         (5.0)
#define INFO_CORNER_RADIUS          (8.0)
#define INFO_SEPARATOR_HEIGHT       (11.0)  // pt, as a native menu separator (a menu grows 11 pt with one, measured)

// one decimal, none when the rounded value is whole, with the locale's separator: "9.8", "16", "9,8"
static NSString* OneDecimal(double value, NSLocale* locale)
{
  double rounded = round(value * 10.0) / 10.0;
  if (rounded == floor(rounded))
  {
    return [[NSString alloc] initWithFormat:@"%.0f" locale:locale, rounded];
  }
  return [[NSString alloc] initWithFormat:@"%.1f" locale:locale, rounded];
}

// memory, 1024-based as Activity Monitor shows it: "9.8 GB", "16 GB"
static NSString* GiBText(uint64_t bytes, NSLocale* locale)
{
  return [NSString stringWithFormat:@"%@ GB", OneDecimal((double)bytes / 1073741824.0, locale)];
}

// disk, 1000-based as Finder shows it: whole GB below 1000 GB ("412 GB"), else TB ("1.2 TB", "2 TB")
static NSString* GBText(uint64_t bytes, NSLocale* locale)
{
  double gb = round((double)bytes / 1e9);
  if (gb < 1000.0)
  {
    return [[NSString alloc] initWithFormat:@"%.0f GB" locale:locale, gb];
  }
  return [NSString stringWithFormat:@"%@ TB", OneDecimal((double)bytes / 1e12, locale)];
}

// "57%": part of whole as a whole percentage, 0% to 100%; "—" when whole is 0
static NSString* PercentText(uint64_t part, uint64_t whole, NSLocale* locale)
{
  if (whole == 0)
  {
    return @"—";
  }
  long percent = MIN(MAX(lround(100.0 * (double)part / (double)whole), 0L), 100L);
  return [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, percent];
}

// "16GB Memory usage:": a row's title led by its whole, written without a space ("16 GB" -> "16GB")
static NSString* TotalTitle(NSString* wholeText, NSString* name)
{
  return [NSString stringWithFormat:@"%@ %@", [wholeText stringByReplacingOccurrencesOfString:@" " withString:@""], name];
}

// "3d 4h 27m"; under a day "4h 27m", under an hour "27m"
static NSString* UptimeText(long seconds)
{
  if (seconds < 0)
  {
    return @"unknown";
  }
  long days = seconds / 86400;
  long hours = (seconds % 86400) / 3600;
  long minutes = (seconds % 3600) / 60;
  if (days > 0)
  {
    return [NSString stringWithFormat:@"%ldd %ldh %ldm", days, hours, minutes];
  }
  if (hours > 0)
  {
    return [NSString stringWithFormat:@"%ldh %ldm", hours, minutes];
  }
  return [NSString stringWithFormat:@"%ldm", minutes];
}

#pragma mark - Rows that leave the menu open (Freeze)

// A click on a native menu item closes the menu; a click on an item's view does not, and sends no action. So
// these rows are views drawn like the native rows of 24 pt: with an image, the image at x 15 and the title at
// x 36; without one, the title at x 14, as Quit's; the title 4 pt up, and when highlighted the system's selection
// material, inset 5 pt with a corner radius of 7, under the title and image in the selected text colour. A title
// too wide for the row is drawn in smaller type. The item keeps its title, image and action: the action is what
// enables it, and so lets it highlight. Return on it does nothing (mouse only). After a click AppKit removes the
// highlight until the pointer moves. A disabled row is drawn grey, as a native one, with no selection, and a click on
// it does nothing.

#define STAY_OPEN_ROW_HEIGHT        (24.0)

static bool IsLight(NSAppearance* appearance);
static double RefreshInterval(void);
static double TopInterval(void);

@interface StayOpenMenuItem : NSMenuItem
{
  bool loggedNoTarget;  // a missing target is logged once per row
}
- (BOOL)actInPlace;
@end

@implementation StayOpenMenuItem

// a click on the row, or VoiceOver's press: the item's action, with the menu left open
- (BOOL)actInPlace
{
  if (!self.isEnabled)
  {
    return NO;
  }
  BOOL sent = [NSApp sendAction:self.action to:self.target from:self];
  if (!sent && !loggedNoTarget)
  {
    loggedNoTarget = true;
    // the action, not the title: a row's title can be private
    NSLog(@"the row's action %@ found no target", NSStringFromSelector(self.action));
  }
  return sent;
}

// a press on a menu item with a view would close the menu and send nothing
- (BOOL)accessibilityPerformPress
{
  return [self actInPlace];
}

// a native item reports its enabled state to accessibility; an item with a view reports enabled even when disabled
- (BOOL)isAccessibilityEnabled
{
  return self.isEnabled;
}

@end

@interface StayOpenRowView : NSView
{
  NSVisualEffectView* selection;
  NSImageView* icon;                  // nil for an item without an image
  NSTextField* label;
  NSAttributedString* fittedTitle;    // the title the label last showed, and the room it was fitted to
  CGFloat fittedRoom;
}
- (instancetype)initWithItem:(NSMenuItem*)item;
@end

@implementation StayOpenRowView

- (instancetype)initWithItem:(NSMenuItem*)item
{
  // the menu widens the view to its own width
  self = [super initWithFrame:NSMakeRect(0, 0, 100.0, STAY_OPEN_ROW_HEIGHT)];
  if (self != nil)
  {
    self.autoresizingMask = NSViewWidthSizable;

    selection = [[NSVisualEffectView alloc] initWithFrame:NSInsetRect(self.bounds, 5.0, 0.0)];
    selection.material = NSVisualEffectMaterialSelection;
    selection.state = NSVisualEffectStateActive;
    selection.emphasized = YES;
    selection.wantsLayer = YES;
    selection.layer.cornerRadius = 7.0;
    selection.layer.masksToBounds = YES;
    selection.autoresizingMask = NSViewWidthSizable;
    selection.hidden = YES;
    [self addSubview:selection];

    CGFloat x = 14.0;
    if (item.image != nil)
    {
      icon = [NSImageView imageViewWithImage:item.image];
      icon.frame = NSMakeRect(15.0, 4.0, 16.0, 16.0);
      // the check mark at its own size, centred, as the native row draws it
      icon.imageScaling = NSImageScaleNone;
      [self addSubview:icon];
      x = 36.0;
    }

    label = [NSTextField labelWithAttributedString:item.attributedTitle];
    label.frame = NSMakeRect(x, 4.0, NSWidth(self.bounds) - x - 6.0, 16.0);
    label.autoresizingMask = NSViewWidthSizable;
    [self addSubview:label];

    // VoiceOver reads the item itself (its title, and StayOpenMenuItem's press), as for a native item; the item's
    // accessibility children would otherwise be these cells
    icon.cell.accessibilityElement = NO;
    label.cell.accessibilityElement = NO;
  }
  return self;
}

// the item's title in the label, in smaller type when it is wider than the row's room
- (void)fitTitle:(NSMenuItem*)item
{
  NSAttributedString* title = item.attributedTitle;
  CGFloat room = NSWidth(label.frame);
  if ((title == nil) || (title.length == 0) || ([title isEqualToAttributedString:fittedTitle] && (room == fittedRoom)))
  {
    return;
  }
  fittedTitle = [title copy];
  fittedRoom = room;
  label.attributedStringValue = title;
  NSFont* font = [title attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
  CGFloat width = [label sizeThatFits:NSMakeSize(CGFLOAT_MAX, NSHeight(label.frame))].width;
  if ((font == nil) || (width <= room) || (width <= 0.0))
  {
    return;
  }
  // from the size that would fit if the width scaled with it, down in tenths of a point until it fits
  CGFloat size = floor(font.pointSize * room / width * 10.0) / 10.0;
  for (; size >= 6.0; size -= 0.1)
  {
    NSFont* smallerFont = [NSFont fontWithDescriptor:font.fontDescriptor size:size];
    if (smallerFont == nil)
    {
      return;
    }
    NSMutableAttributedString* smaller = [title mutableCopy];
    [smaller addAttribute:NSFontAttributeName value:smallerFont range:NSMakeRange(0, smaller.length)];
    label.attributedStringValue = smaller;
    if ([label sizeThatFits:NSMakeSize(CGFLOAT_MAX, NSHeight(label.frame))].width <= room)
    {
      return;
    }
  }
}

- (void)viewWillDraw
{
  NSMenuItem* item = self.enclosingMenuItem;
  bool enabled = item.isEnabled;
  bool highlighted = enabled && item.isHighlighted;
  selection.hidden = !highlighted;
  [self fitTitle:item];
  // disabled: the grey AppKit gives a native disabled row's title, secondary in Dark and tertiary in Light
  NSColor* disabledColor = IsLight(self.effectiveAppearance) ? [NSColor tertiaryLabelColor] : [NSColor secondaryLabelColor];
  NSColor* color = !enabled ? disabledColor : (highlighted ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor]);
  label.textColor = color;
  if (icon != nil)
  {
    icon.contentTintColor = color;
    // as high as the image and centred in the row, as the native row's image view is: the blank 16 x 16 at y 4, the
    // check 16 x 11 at y 6.5
    NSImage* image = item.image;
    CGFloat height = MIN(image.size.height, 16.0);
    icon.frame = NSMakeRect(15.0, (STAY_OPEN_ROW_HEIGHT - height)/2.0, 16.0, height);
    icon.image = image;
  }
  [super viewWillDraw];
}

// taken here, so that the menu does not act on it
- (void)mouseDown:(NSEvent*)event
{
}

- (void)mouseUp:(NSEvent*)event
{
  // a press that ends on another row has moved the highlight there
  NSMenuItem* item = self.enclosingMenuItem;
  if (item.isHighlighted && [item isKindOfClass:[StayOpenMenuItem class]])
  {
    [(StayOpenMenuItem*)item actInPlace];
  }
}

@end

#pragma mark - Rows a build adds

// made on the first call, not by an initializer: a class registers from +load, which runs before this file's static initializers
static NSMutableArray<Class>* menuRowsClasses = nil;

// one instance of each registered class, made in setupMenus; a menu item's target is weak, so this keeps them alive
static NSMutableArray<id<MenuRows>>* menuRows = nil;

void MenuRowsRegister(Class<MenuRows> rowsClass)
{
  if (menuRowsClasses == nil)
  {
    menuRowsClasses = [[NSMutableArray alloc] init];
  }
  [menuRowsClasses addObject:rowsClass];
}

NSMenuItem* MenuRowsStayOpenItem(NSString* title, SEL action, id target, NSDictionary<NSAttributedStringKey, id>* attributes)
{
  NSMenuItem* item = [[StayOpenMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  [item setTarget:target];
  [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributes]];
  // a view, so that a click leaves the menu open
  [item setView:[[StayOpenRowView alloc] initWithItem:item]];
  return item;
}

#pragma mark - Process icons

typedef NS_ENUM(NSInteger, ProcessIconRule)
{
  ProcessIconRuleOwn,       // its own app, or a nested bundle that declares an icon
  ProcessIconRuleAncestor,  // the nearest ancestor with its own icon (launchd skipped)
  ProcessIconRuleBundle,    // the app bundle it runs inside
  ProcessIconRuleGeneric,   // the generic executable icon
};

// One decision per pid: the menu row, its tooltip and the inspector all come from it.
@interface ProcessIconDecision : NSObject
@property (nonatomic, copy) NSString* path;         // executable path, nil when proc_pidpath fails
@property (nonatomic, strong) NSImage* image;       // full size
@property (nonatomic, strong) NSImage* menuImage;   // MENU_ICON_SIZE copy
@property (nonatomic, assign) ProcessIconRule rule;
@property (nonatomic, assign) BOOL helper;          // shown with ↳
@property (nonatomic, copy) NSString* tooltip;      // nil unless helper
@property (nonatomic, copy) NSString* helperLine;   // the inspector's "Helper of:" line, nil unless helper
@end

@implementation ProcessIconDecision
@end

static NSString* ProcessPath(pid_t pid)
{
  char buffer[PROC_PIDPATHINFO_MAXSIZE];
  if (proc_pidpath(pid, buffer, sizeof(buffer)) <= 0)
  {
    return nil;
  }
  return [NSString stringWithUTF8String:buffer];
}

// the start time of the process now running as pid, in microseconds; 0 when the pid has exited or is a
// zombie. sysctl(KERN_PROC_PID) gives it for every user's processes (proc_pidinfo only for the user's own)
static uint64_t ProcessStartTime(pid_t pid)
{
  struct kinfo_proc kinfo;
  size_t length = sizeof(kinfo);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
  // for a pid that has already exited, sysctl succeeds but returns no data (length 0)
  if ((sysctl(mib, 4, &kinfo, &length, NULL, 0) != 0) || (length != sizeof(kinfo)) || (kinfo.kp_proc.p_stat == SZOMB))
  {
    return 0;
  }
  return ((uint64_t)kinfo.kp_proc.p_starttime.tv_sec * USEC_PER_SEC) + (uint64_t)kinfo.kp_proc.p_starttime.tv_usec;
}

// the outermost .app in the path, nil when there is none
static NSString* OuterApp(NSString* path)
{
  NSRange range = [path rangeOfString:@".app/"];
  if (range.location == NSNotFound)
  {
    return nil;
  }
  return [path substringToIndex:range.location + 4];
}

// the bundle whose icon is the process's own icon, nil when it has none
static NSString* OwnIconBundle(NSString* path)
{
  if (path == nil)
  {
    return nil;
  }
  NSString* bundle = nil;
  NSRange range = [path rangeOfString:@"/Contents/MacOS/" options:NSBackwardsSearch];
  if (range.location != NSNotFound)
  {
    bundle = [path substringToIndex:range.location];
  }
  else
  {
    // an executable directly in a .app directory (no Contents/MacOS)
    NSString* dir = [path stringByDeletingLastPathComponent];
    if ([dir hasSuffix:@".app"])
    {
      bundle = dir;
    }
  }
  if (bundle == nil)
  {
    return nil;
  }
  NSString* outer = OuterApp(path);
  if ([bundle hasSuffix:@".app"] && (outer != nil))
  {
    if ([bundle isEqualToString:outer])
    {
      // a top-level app: its icon is whatever LaunchServices shows
      return bundle;
    }
    if ([bundle isEqualToString:[[outer stringByAppendingPathComponent:@"Wrapper"] stringByAppendingPathComponent:[bundle lastPathComponent]]])
    {
      // an iOS app, <outer>.app/Wrapper/<inner>.app: the outer app's icon
      return outer;
    }
  }
  NSDictionary* info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Contents/Info.plist"]];
  if ((info[@"CFBundleIconFile"] != nil) || (info[@"CFBundleIconName"] != nil))
  {
    // a nested bundle that declares an icon
    return bundle;
  }
  return nil;
}

// decodes text from the kernel as UTF-8, and never fails: the kernel cuts names at a byte limit, so
// a name can end in part of a UTF-8 character, which is dropped; text that Foundation still refuses
// as UTF-8 is decoded as Mac OS Roman, which maps every byte (some invalid bytes Foundation accepts,
// showing U+FFFD)
static NSString* SampleText(const char* name)
{
  if (name == NULL)
  {
    return @"";
  }
  const unsigned char* bytes = (const unsigned char*)name;
  NSUInteger length = strlen(name);
  NSString* text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
  if (text != nil)
  {
    return text;
  }
  // the last character's first byte: back over up to 3 continuation bytes (10xxxxxx) to a byte that
  // can start a UTF-8 character (0xC2-0xF4)
  NSUInteger first = length;
  while ((first > 0) && (length - first < 3) && ((bytes[first-1] & 0xC0) == 0x80))
  {
    first--;
  }
  if ((first > 0) && (bytes[first-1] >= 0xC2) && (bytes[first-1] <= 0xF4))
  {
    first--;
    NSUInteger needed = (bytes[first] >= 0xF0) ? 4 : ((bytes[first] >= 0xE0) ? 3 : 2);
    if (length - first < needed)
    {
      text = [[NSString alloc] initWithBytes:bytes length:first encoding:NSUTF8StringEncoding];
    }
  }
  if (text == nil)
  {
    text = [[NSString alloc] initWithBytes:bytes length:length encoding:NSMacOSRomanStringEncoding];
  }
  return (text != nil) ? text : @"";
}

static NSString* SampleName(pid_t pid)
{
  TopProcessSample_t* sample = TopGetSample(pid);
  return (sample != NULL) ? SampleText(sample->name) : nil;
}

static ProcessIconDecision* DecideProcessIcon(pid_t pid, NSString* path)
{
  ProcessIconDecision* decision = [[ProcessIconDecision alloc] init];
  decision.path = path;
  TopProcessSample_t* sample = TopGetSample(pid);
  pid_t ppid = (sample != NULL) ? sample->ppid : 0;
  NSString* name = (sample != NULL) ? SampleText(sample->name) : @"?";

  // the spawn chain from the topmost ancestor below launchd down to the process, and the nearest
  // ancestor with its own icon
  NSMutableArray<NSString*>* chain = [NSMutableArray arrayWithObject:name];
  NSString* ancestorBundle = nil;
  NSString* ancestorName = nil;
  pid_t p = ppid;
  for (int depth=0; (p > 1) && (depth < 64); depth++)
  {
    TopProcessSample_t* ancestor = TopGetSample(p);
    if (ancestor == NULL)
    {
      break;
    }
    NSString* ancestorSampleName = SampleText(ancestor->name);
    [chain insertObject:ancestorSampleName atIndex:0];
    if (ancestorBundle == nil)
    {
      ancestorBundle = OwnIconBundle(ProcessPath(p));
      if (ancestorBundle != nil)
      {
        ancestorName = ancestorSampleName;
      }
    }
    p = ancestor->ppid;
  }

  NSString* iconFile = OwnIconBundle(path);
  NSString* app = nil;
  if (iconFile != nil)
  {
    decision.rule = ProcessIconRuleOwn;
  }
  else if (ancestorBundle != nil)
  {
    decision.rule = ProcessIconRuleAncestor;
    iconFile = ancestorBundle;
  }
  else if ((path != nil) && ((app = OuterApp(path)) != nil))
  {
    decision.rule = ProcessIconRuleBundle;
    iconFile = app;
  }
  else
  {
    decision.rule = ProcessIconRuleGeneric;
  }

  NSImage* image = nil;
  if (iconFile != nil)
  {
    image = [[NSWorkspace sharedWorkspace] iconForFile:iconFile];
  }
  else
  {
    static NSImage* genericIcon = nil;
    if (genericIcon == nil)
    {
      genericIcon = [[NSWorkspace sharedWorkspace] iconForContentType:UTTypeUnixExecutable];
    }
    image = genericIcon;
  }
  decision.image = [image copy];
  decision.menuImage = [image copy];
  [decision.menuImage setSize:NSMakeSize(MENU_ICON_SIZE, MENU_ICON_SIZE)];

  // ↳: an ancestor other than launchd and kernel_task, or the icon of the app bundle it runs inside
  bool spawned = (pid > 1) && (ppid > 1);
  bool inside = (pid > 1) && (decision.rule == ProcessIconRuleBundle);
  decision.helper = spawned || inside;
  if (spawned)
  {
    NSString* of = (ancestorName != nil) ? ancestorName : SampleName(ppid);
    NSString* chainText = [chain componentsJoinedByString:@" → "];
    decision.tooltip = [NSString stringWithFormat:@"Helper of %@\n%@", (of != nil) ? of : @"?", chainText];
    decision.helperLine = [NSString stringWithFormat:@"Helper of: %@", chainText];
  }
  else if (inside)
  {
    NSString* appName = [[app lastPathComponent] stringByDeletingPathExtension];
    decision.tooltip = [NSString stringWithFormat:@"Helper of %@\n%@ runs inside %@", appName, name, [app lastPathComponent]];
    decision.helperLine = [NSString stringWithFormat:@"Helper of: %@ (runs inside %@)", appName, app];
  }
  return decision;
}

#pragma mark -

@implementation AppDelegate

static CpuSummaryInfo cpu_info;
static CpuSummaryInfo cpu_sine_demo_info;
static CpuSummaryInfo cpu_flat_demo_info;

static NSMenu* menu = nil;

static NSTimer* timerCPU = nil;

static NSTimer* timerTop = nil;
static TopProcessSample_t topProcceses[TOP_COUNT];
static NSMenuItem* topMenus[TOP_COUNT];
static NSMutableDictionary<NSString*, NSString*>* topNameCache = nil; // padded names, by display text
static CFMutableDictionaryRef topCpuHashTable;
static NSMutableDictionary<NSNumber*, ProcessIconDecision*>* topIconCache = nil; // by pid

static bool refreshTop = false;
static bool menuIsOpen = false;            // from menuWillOpen: to menuDidClose:
// the last sample is the baseline taken at the unfreeze, whose CPU% averages over the freeze: the rows wait for the
// next one (updateMenuTop)
static bool baselineOnly = false;
static bool topListValid = false;
static int topCount = 0;
static int topOthersCount = 0;            // other users' processes at the last sample, whose CPU cannot be read
static NSMenuItem* othersItem = nil;      // the row below the process rows that counts them
static NSTimeInterval lastTopSample = 0.0;
#define TOP_MIN_INTERVAL (0.25)

// The graph and the process samples pause while nothing can be seen: the displays asleep, the Mac going to sleep,
// or another user's session in front. Each has its own flag; the timers run again once all are clear (updatePause).
static bool screensAsleep = false;
static bool systemAsleep = false;
static bool sessionInactive = false;
static bool paused = false;

// Freeze (an item in the status menu whose check mark is its image): while frozen the rows keep what they
// showed, nothing is sampled for them; the menu-bar CPU graph keeps moving.
// frozenStarts holds each row's process start time, read when Freeze was chosen (0 = already gone).
static bool frozen = false;
static NSMutableDictionary<NSNumber*, NSNumber*>* frozenStarts = nil; // by pid
static NSImage* freezeOffImage = nil;       // Freeze's image when not frozen: blank, the size of the menu icons
static NSImage* freezeOnImage = nil;        // and while frozen: a check mark
static NSMenuItem* freezeItem = nil;        // always shown, so the readings panel finds the open menu by it

static NSPanel* rowTip = nil;               // the helper text box, left of the menu (frozen only)
static NSTextField* rowTipText = nil;
static NSMenuItem* rowTipItem = nil;        // the row whose text shows, or is about to
static NSRect rowTipRow;                    // that row on screen, and the menu's window, while its text shows
static NSWindow* rowTipMenuWindow = nil;

static NSPanel* infoPanel = nil;            // the readings beside the menu (see "The readings panel beside the menu")
static NSGlassEffectView* infoGlass = nil;  // its background
static NSArray<NSTextField*>* infoLabels = nil;
static NSArray<NSTextField*>* infoValues = nil;
static NSArray<NSBox*>* infoSeparators = nil; // menu-style lines, one above each row of infoSeparatorRows
static NSIndexSet* infoSeparatorRows = nil; // the first row of each section after the readings (Uptime: the last)
static NSTimer* infoTimer = nil;            // while the menu is open
static bool infoPlaced = false;             // the panel was placed in this opening
static bool infoRetried = false;            // the menu's window was looked for a second time in this opening
static bool infoSideDecided = false;        // its side is decided once per opening,
static bool infoOnLeft = true;
static CGFloat infoWidth = 0.0;             // and it only widens within one
static NSWindow* infoMenuWindow = nil;      // the menu's window it is placed beside
static NSUInteger infoGeneration = 0;       // bumped when the menu closes: a disk read for an earlier opening is not shown
static bool diskReadInFlight = false;
static NSTimeInterval lastDiskRead = 0.0;   // when the last disk read started, system uptime
static NSTimeInterval lastDiskAttempt = 0.0; // when the last disk read started, never reset: a failing read is retried once a minute
static double diskFraction = -1.0;          // how full the volume was at the last reading, 0..1, -1 before the first
static NSString* diskText = nil;            // the last reading of the startup volume, nil before the first
static NSString* diskTitle = nil;           // its title, with the volume's size ("995GB Disk usage:")
static NSTimeInterval lastReadings = 0.0;   // when overall CPU and memory were last read, system uptime; 0: read soon
static double readingsCpu = -1.0;           // overall CPU over the 1 s before it (after a reset, one tick), 0..1, -1 before the first
static bool readingsMemory = false;         // memory could be read, as these two bytes
static uint64_t readingsMemoryUsed = 0;
static uint64_t readingsMemoryTotal = 0;

static CGFloat tickHeight = 16.0;
static CGFloat tickWidth = 3.0;
static CGFloat tickSpaceWidth = 1.0;
static CGFloat tickTotalWidth = 0.0;
static CGFloat imageWidth = 0.0;
static CGFloat graphWidth = 0.0;     // the core graph alone, as the sine and flat previews draw it: imageWidth without the bars
static CGFloat drawWidth = 3.0;      // the width each bar or dot is drawn: the bar width, 4 for the one package bar, 3 for dots

static int granularity = 0;

static bool bar = true;

static bool stripped = true;

static bool colored = false;
static int theme = THEME_YELLOW;

static bool showBars = true;         // the disk, memory and CPU bars left of the graph

static float speed = 1.0f;

static NSDictionary* attributesStandard = nil;
static NSDictionary* attributesGrey = nil;
static NSDictionary* attributesWhite = nil;

static double spaceWidth = 0.0;

static NSNumber *current_process_pid = nil;

// The inspector's man page tool runs on a background queue. Every selection bumps
// inspectGeneration, and a result that belongs to an older selection is dropped. Main thread only.
static NSUInteger inspectGeneration = 0;
static NSMutableSet<NSTask*>* runningTasks = nil;
#define TOOL_OUTPUT_MAX (1024*1024) // characters shown; laying out tens of MB blocks the main thread for seconds

- (void)runTool:(NSString*)tool arguments:(NSArray<NSString*>*)arguments withStderr:(BOOL)withStderr done:(void (^)(NSString* output))done
{
  NSUInteger generation = inspectGeneration;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSTask *task = [[NSTask alloc] init];
    [task setExecutableURL:[NSURL fileURLWithPath:tool]];
    [task setArguments:arguments];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:(withStderr ? pipe : [NSFileHandle fileHandleWithNullDevice])];

    NSString *output = nil;
    if ([task launchAndReturnError:nil])
    {
      @synchronized (runningTasks)
      {
        [runningTasks addObject:task];
      }
      // read everything BEFORE waiting: a tool whose output fills the pipe never exits while nobody reads
      NSData *data = [[pipe fileHandleForReading] readDataToEndOfFileAndReturnError:nil];
      [task waitUntilExit];
      if (data == nil)
      {
        data = [NSData data];
      }
      @synchronized (runningTasks)
      {
        [runningTasks removeObject:task];
      }
      output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (output == nil)
      {
        output = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
      }
      if ([output length] > TOOL_OUTPUT_MAX)
      {
        NSRange cut = [output rangeOfComposedCharacterSequenceAtIndex:TOOL_OUTPUT_MAX];
        output = [[output substringToIndex:cut.location] stringByAppendingFormat:@"\n\n... (truncated: %lu characters in total)\n", (unsigned long)[output length]];
      }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      if (generation == inspectGeneration)
      {
        done(output);
      }
    });
  });
}

- (void)stopInspectorTools
{
  @synchronized (runningTasks)
  {
    for (NSTask *task in runningTasks)
    {
      if ([task isRunning])
      {
        [task terminate];
      }
    }
  }
}

- (void)launchAppAt:(NSString*)path with:(NSArray<NSString *> *)arguments
{
  NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
  [configuration setArguments:arguments];
  [configuration setPromptsUserIfNeeded:YES];
  [configuration setAddsToRecentItems:NO];
  [configuration setActivates:YES];
  [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:path] configuration:configuration completionHandler:^(NSRunningApplication* app, NSError* error)
  {
    if (error)
    {
      NSLog(@"launchAppAt error: %@", error.localizedDescription);
    }
  }];
}

- (void)updateRendererParameters
{
  double tickSpace = tickWidth;
  natural_t count = CpuSamplerGetCount(granularity);
  if (bar == NO)
  {
    tickSpace = 7.0;
  }
  else if (count == 1)
  {
    tickSpace = 4.0;
  }
  tickTotalWidth = tickSpace + tickSpaceWidth;
  drawWidth = !bar ? 3.0 : ((count == 1) ? 4.0 : tickWidth);
  imageWidth = count * tickTotalWidth;
  if (bar == NO)
  {
    imageWidth += 1.0;
  }
  graphWidth = imageWidth;
  if (showBars)
  {
    imageWidth += CpuRenderReadingsWidth(bar, drawWidth, tickTotalWidth);
  }
}

- (void)updateUI
{
  [self.packageButton setState:NSControlStateValueOff];
  [self.coreButton setState:NSControlStateValueOff];
  [self.logicalButton setState:NSControlStateValueOff];
  
  [self.barButton setState:NSControlStateValueOff];
  [self.dotButton setState:NSControlStateValueOff];
  
  [self.solidButton setState:NSControlStateValueOff];
  [self.strippedButton setState:NSControlStateValueOff];
  
  [self.thinButton setState:NSControlStateValueOff];
  [self.standardButton setState:NSControlStateValueOff];
  [self.thickButton setState:NSControlStateValueOff];
  
  [self.fastButton setState:NSControlStateValueOff];
  [self.normalButton setState:NSControlStateValueOff];
  [self.slowButton setState:NSControlStateValueOff];
  
  [self.greyButton setState:NSControlStateValueOff];
  [self.colorButton setState:NSControlStateValueOff];
  
  [self.yellowButton setState:NSControlStateValueOff];
  [self.greenButton setState:NSControlStateValueOff];
  [self.blueButton setState:NSControlStateValueOff];

  [self.showBarsButton setState:showBars ? NSControlStateValueOn : NSControlStateValueOff];
    
  if (granularity == 0)
  {
    [self.packageButton setState:NSControlStateValueOn];

    [self.thinButton setEnabled:NO];
    [self.standardButton setEnabled:NO];
    [self.thickButton setEnabled:NO];
  }
  else if (granularity == 1)
  {
    [self.coreButton setState:NSControlStateValueOn];
    
    if (bar)
    {
      [self.thinButton setEnabled:YES];
      [self.standardButton setEnabled:YES];
      [self.thickButton setEnabled:YES];
    }
  }
  else
  {
    [self.logicalButton setState:NSControlStateValueOn];

    [self.thinButton setEnabled:YES];
    [self.standardButton setEnabled:YES];
    [self.thickButton setEnabled:YES];
  }
  
  if (bar)
  {
    [self.barButton setState:NSControlStateValueOn];
    [self.dotButton setState:NSControlStateValueOff];

    [self.solidButton setEnabled:YES];
    [self.strippedButton setEnabled:YES];
    if (granularity != 0)
    {
      [self.thinButton setEnabled:YES];
      [self.standardButton setEnabled:YES];
      [self.thickButton setEnabled:YES];
    }
    
    [self.greyButton setEnabled:YES];
  }
  else
  {
    colored = true;
    
    [self.barButton setState:NSControlStateValueOff];
    [self.dotButton setState:NSControlStateValueOn];

    [self.solidButton setEnabled:NO];
    [self.strippedButton setEnabled:NO];
    [self.thinButton setEnabled:NO];
    [self.standardButton setEnabled:NO];
    [self.thickButton setEnabled:NO];

    [self.greyButton setEnabled:NO];
  }
  
  if (!stripped)
  {
    [self.solidButton setState:NSControlStateValueOn];
  }
  else
  {
    [self.strippedButton setState:NSControlStateValueOn];
  }
  
  if (tickWidth == 1.0)
  {
    [self.thinButton setState:NSControlStateValueOn];
  }
  else if (tickWidth == 2.0)
  {
    [self.standardButton setState:NSControlStateValueOn];
  }
  else
  {
    [self.thickButton setState:NSControlStateValueOn];
  }
  
  if (speed == 1.0)
  {
    [self.fastButton setState:NSControlStateValueOn];
  }
  else if (speed == 2.0)
  {
    [self.normalButton setState:NSControlStateValueOn];
  }
  else
  {
    [self.slowButton setState:NSControlStateValueOn];
  }
  
  if (!colored)
  {
    [self.greyButton setState:NSControlStateValueOn];

    [self.yellowButton setEnabled:NO];
    [self.greenButton setEnabled:NO];
    [self.blueButton setEnabled:NO];
  }
  else
  {
    [self.colorButton setState:NSControlStateValueOn];

    [self.yellowButton setEnabled:YES];
    [self.greenButton setEnabled:YES];
    [self.blueButton setEnabled:YES];
  }
  
  if (theme == THEME_GREEN)
  {
    [self.greenButton setState:NSControlStateValueOn];
  }
  else if (theme == THEME_BLUE)
  {
    [self.blueButton setState:NSControlStateValueOn];
  }
  else
  {
    [self.yellowButton setState:NSControlStateValueOn];
  }
}

- (int)getSpacesCountFor:(NSMutableString*)string width:(CGFloat)target
{
  CGFloat test_width = [string sizeWithAttributes:attributesGrey].width;
  CGFloat room = target - test_width;
  int count = (int)round(room / spaceWidth);
  //printf("  spaces %d\n", spaces);

  CGFloat actualLeft = test_width + ((count-1) * spaceWidth);
  CGFloat diffLeft = fabs(target-actualLeft);
  //printf("  diffLeft %f %f\n", diffLeft, actualLeft);
  CGFloat actual = test_width + (count * spaceWidth);
  CGFloat diff = fabs(target-actual);
  //printf("  diff %f %f\n", diff, actual);
  CGFloat actualRight = test_width + ((count+1) * spaceWidth);
  CGFloat diffRight = fabs(target-actualRight);
  //printf("  diffRight %f %f\n", diffRight, actualRight);
  
  if (diffLeft < diffRight)
  {
    if (diffLeft < diff)
    {
      count--;
    }
  }
  else
  {
    if (diffRight < diff)
    {
      count++;
    }
  }
  return count;
}

#define SIZE_DOTS 4
#define SIZE_SPACES 4096
static unichar dots[] = {'.', '.', '.', '.', '\0'};
static unichar spaces[SIZE_SPACES];
static BOOL spaces_init = NO;

- (NSString*)getStringForCpu:(double)cpu width:(CGFloat)target
{
  if (cpu > 999.0)
  {
    cpu = 999.0;
  }
  
  NSMutableString* string = nil;
  const void* key = NULL;
  int integer = round(cpu * 10.0);
  if (cpu <= 10.0)
  {
    key = (const void *)(uintptr_t)integer;
    if (key == NULL)
    {
      key = (const void*)0xffffffff;
    }
  }
  if ((key==NULL) || !CFDictionaryContainsKey(topCpuHashTable, key))
  {
    string = [NSMutableString stringWithFormat:@"%6.1f%%", ((double)integer/10.0)];
    int count = [self getSpacesCountFor:string width:target];
    [string insertString:[NSString stringWithCharacters:&spaces[0] length:count] atIndex:0];
    
    if (key != NULL)
    {
      CFDictionarySetValue(topCpuHashTable, key, (__bridge const void *)(string));
    }
  }
  if (key != NULL)
  {
    return (NSString*)CFDictionaryGetValue(topCpuHashTable, key);
  }
  else
  {
    return string;
  }
  //return [NSString stringWithFormat:@"%--s %*c %6.1f%%", name, spaces, SPACE_THIN, cpu];
}

- (NSString*)getStringForName:(NSString*)name width:(CGFloat)target
{
  // keyed by the text shown, so a process that exec'd shows its new name
  NSString* padded = topNameCache[name];
  if (padded == nil)
  {
    NSMutableString* string = [NSMutableString stringWithString:name];
    int count = [self getSpacesCountFor:string width:target];
    if (count <= 0)
    {
      // whole characters: an emoji is two UTF-16 units, and an accent can be a unit of its own;
      // at least SIZE_DOTS units go, and a short name can go entirely
      NSUInteger before = [string length];
      while (([string length] > 0) && (before - [string length] < SIZE_DOTS))
      {
        [string deleteCharactersInRange:[string rangeOfComposedCharacterSequenceAtIndex:[string length]-1]];
      }
      [string insertString:[NSString stringWithCharacters:&dots[0] length:SIZE_DOTS] atIndex:[string length]];
      while ((count <= 0) && ([string length] >= SIZE_DOTS))
      {
        [string deleteCharactersInRange:[string rangeOfComposedCharacterSequenceAtIndex:[string length]-SIZE_DOTS]];
        count = [self getSpacesCountFor:string width:target];
      }
      if (count < 0)
      {
        // only when the dots alone are wider than the target
        count = 0;
      }
    }

    size_t length = [string length];
    if (length > SIZE_SPACES)
    {
      length = SIZE_SPACES;
    }
    [string insertString:[NSString stringWithCharacters:&spaces[0] length:count] atIndex:length];

    padded = string;
    topNameCache[name] = padded;
  }
  return padded;
  //return [NSString stringWithFormat:@"%--s %*c %6.1f%%", name, spaces, SPACE_THIN, cpu];
}

// Decided once per pid, and again when the pid runs another executable. Not redone when the process
// is reparented (to launchd, when its parent exits) or when a reused pid runs the same executable.
- (ProcessIconDecision*)decisionForPid:(pid_t)pid
{
  NSNumber* key = [NSNumber numberWithInt:pid];
  NSString* path = ProcessPath(pid);
  ProcessIconDecision* decision = topIconCache[key];
  if ((decision == nil) || !((decision.path == path) || [decision.path isEqualToString:path]))
  {
    decision = DecideProcessIcon(pid, path);
    topIconCache[key] = decision;
  }
  return decision;
}

// drops the decisions of pids that are gone; call after every TopSample
- (void)pruneIconCache
{
  for (NSNumber* key in [topIconCache allKeys])
  {
    if (TopGetSample([key intValue]) == NULL)
    {
      [topIconCache removeObjectForKey:key];
    }
  }
}

- (void)updateMenuTopFor:(NSMenuItem*)item name:(char*)name pid:(pid_t)pid cpu:(double)cpu width:(CGFloat)target
{
  ProcessIconDecision* decision = [self decisionForPid:pid];
  NSString* shownName = [NSString stringWithFormat:@"%@%@", (decision.helper ? @"↳ " : @""), SampleText(name)];
  NSString* stringName = [self getStringForName:shownName width:target];
  NSString* stringCpu = [self getStringForCpu:cpu width:CPU_STR_SPACE_TARGET];
  [item setTitle: [NSString stringWithFormat:@"%@ %@", stringName, stringCpu]];
  
  NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:[item title] attributes:attributesGrey];
  [title setAttributes:attributesWhite range:NSMakeRange([stringName length], [stringCpu length]+1)];

  
  [item setAttributedTitle:title];
  [item setImage:decision.menuImage];
  // shown by showRowTip while frozen, never as the item's toolTip
  [item setRepresentedObject:decision.tooltip];
  
  //NSSize size = [[item title] sizeWithAttributes:attributesGrey];
  //return size.width;
}

// the text of the row that counts other users' processes; "" when there are none
static NSString* OthersRowText(int count)
{
  if (count <= 0)
  {
    return @"";
  }
  return (count == 1) ? @"1 other user's process: CPU not readable" : [NSString stringWithFormat:@"%d other users' processes: CPU not readable", count];
}

// the row's title: grey, and in smaller type when its text at four digits would be wider than a process row, so that
// a count gaining a digit never resizes the menu
- (NSAttributedString*)othersTitle:(int)count
{
  NSString* text = OthersRowText(count);
  CGFloat room = NAME_STR_SPACE_TARGET + spaceWidth + CPU_STR_SPACE_TARGET;
  CGFloat widest = [OthersRowText(MAX(count, 1000)) sizeWithAttributes:attributesStandard].width;
  if (widest <= room)
  {
    return [[NSAttributedString alloc] initWithString:text attributes:attributesStandard];
  }
  static bool logged = false;
  if (!logged)
  {
    logged = true;
    NSLog(@"the row counting other users' processes is %.1f pt wide at four digits, wider than a process row's %.1f pt: it is set in smaller type", widest, room);
  }
  NSFont* font = attributesStandard[NSFontAttributeName];
  CGFloat size = floor(font.pointSize * room / widest * 10.0) / 10.0;
  NSMutableDictionary* smaller = [attributesStandard mutableCopy];
  while (size > 1.0)
  {
    smaller[NSFontAttributeName] = [NSFont fontWithDescriptor:font.fontDescriptor size:size];
    if ([OthersRowText(MAX(count, 1000)) sizeWithAttributes:smaller].width <= room)
    {
      break;
    }
    size -= 0.1;
  }
  return [[NSAttributedString alloc] initWithString:text attributes:smaller];
}

- (void)updateMenuTop
{
  if (baselineOnly)
  {
    return;
  }
  for (int i=0; i<TOP_COUNT; i++)
  {
    //NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    //NSString *fullPath = [ws fullPathForApplication:[path lastPathComponent]];
    //NSImage *appIcon = [ws iconForFileType:NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
    
    if (i >= topCount)
    {
      [topMenus[i] setHidden:YES];
      continue;
    }
    TopProcessSample_t* sample = &topProcceses[i];
    [self updateMenuTopFor:topMenus[i] name:sample->name pid:sample->pid cpu:sample->cpu width:NAME_STR_SPACE_TARGET];
    [topMenus[i] setTag:sample->pid];
    [topMenus[i] setHidden:NO];
  }

  [othersItem setAttributedTitle:[self othersTitle:topOthersCount]];
  [othersItem setHidden:(topOthersCount <= 0)];
  
  [menu update];
}

- (void)setupMenus
{
  if (!spaces_init)
  {
    spaces_init = YES;
    for (int i=0; i<SIZE_SPACES; i++)
    {
      spaces[i] = SPACE_THIN;
    }
  }
  
  attributesStandard = @{
    NSFontAttributeName: [NSFont fontWithName:MENU_FONT_NAME size:MENU_ICON_SIZE-2],
  };
  
  attributesGrey = @{
    NSFontAttributeName: [NSFont fontWithName:MENU_FONT_NAME size:MENU_ICON_SIZE-2],
    NSForegroundColorAttributeName: [NSColor controlTextColor]
  };
  
  attributesWhite = @{
    NSFontAttributeName: [NSFont fontWithName:MENU_FONT_NAME size:MENU_ICON_SIZE-2],
    NSForegroundColorAttributeName: [NSColor controlTextColor],
  };
  
  unichar unicodeSpace[1] = {SPACE_THIN};
  spaceWidth = [[NSString stringWithCharacters:unicodeSpace length:1] sizeWithAttributes:attributesStandard].width;
  
  NSDictionary* attributesThin = @{
    NSFontAttributeName: [NSFont fontWithName:MENU_FONT_NAME size:1.0],
  };
  
  NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
  paragraphStyle.alignment = NSTextAlignmentCenter;
  NSDictionary* attributesStandardCenter = @{
    NSFontAttributeName: [NSFont fontWithName:MENU_TITLE_FONT_NAME size:MENU_ICON_SIZE-3],
    NSParagraphStyleAttributeName: paragraphStyle,
    NSForegroundColorAttributeName: [NSColor systemRedColor]
  };
  
  menu = [[NSMenu alloc] init];
  [menu setDelegate:self];
  
  {
    NSMenuItem* item = [menu addItemWithTitle:@" " action:nil keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesThin]];
    item = [menu addItemWithTitle:@"TOP USER CPU PROCESSES" action:nil keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandardCenter]];
    for (int i=0; i<TOP_COUNT; i++)
    {
      topMenus[i] = [menu addItemWithTitle:@"" action:@selector(selectPid:) keyEquivalent:@""];
      ShowMenuItemImage(topMenus[i]);
    }
    // below the rows: how many other users' processes have no CPU figure (updateMenuTop)
    othersItem = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    [othersItem setEnabled:NO];
    [othersItem setHidden:YES];
  }
  
  [menu addItem:[NSMenuItem separatorItem]];

//  {
//    NSMenuItem* item = [menu addItemWithTitle:@"Process Explorer" action:@selector(processExplorer:) keyEquivalent:@""];
//    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
//    //NSImage* appIcon = [NSImage imageNamed:@"NSRevealFreestandingTemplate"];
//    //NSImage* appIcon = [NSImage imageNamed:@"NSQuickLookTemplate"];
//    //NSLog(@"appIcon: %@", appIcon);
//    //[appIcon setSize:NSMakeSize(MENU_ICON_SIZE-2.0, MENU_ICON_SIZE-2.0)];
//    //[item setImage:appIcon];
//  }
//
//  [menu addItem:[NSMenuItem separatorItem]];

  {
    NSMenuItem* item = [menu addItemWithTitle:@"Launch \"Activity Monitor\"" action:@selector(launchActivityMonitor:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    NSImage* appIcon = [[NSWorkspace sharedWorkspace] iconForFile:[NSString stringWithFormat:@"/System/Applications/Utilities/Activity Monitor.app"]];
    [appIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:appIcon];
    ShowMenuItemImage(item);
  }

  [menu addItem:[NSMenuItem separatorItem]];

  {
    // the check mark shows in the icon column while frozen (toggleFreeze:), a blank image there otherwise, so
    // "Freeze" lines up with the other titles and nothing moves when it is toggled (the item's state would add a
    // check column and shift every row); off at every launch
    CGFloat side = MENU_ICON_SIZE+2.0;
    freezeOffImage = [NSImage imageWithSize:NSMakeSize(side, side) flipped:NO drawingHandler:^BOOL(NSRect rect) { return YES; }];
    // configured as AppKit draws it in a native row, which StayOpenRowView copies: 13 pt, small scale
    freezeOnImage = [[NSImage imageWithSystemSymbolName:@"checkmark" accessibilityDescription:@"Frozen"]
                     imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13.0 weight:NSFontWeightSemibold
                                                                                                    scale:NSImageSymbolScaleSmall]];
    NSMenuItem* item = [[StayOpenMenuItem alloc] initWithTitle:@"Freeze" action:@selector(toggleFreeze:) keyEquivalent:@""];
    [menu addItem:item];
    freezeItem = item;
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    [item setImage:freezeOffImage];
    ShowMenuItemImage(item);
    // a view, so that a click leaves the menu open
    [item setView:[[StayOpenRowView alloc] initWithItem:item]];
  }

  {
    NSMenuItem* item = [menu addItemWithTitle:@"Open upMonitor Preferences..." action:@selector(openPreferences:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    //NSImage* appIcon = [NSImage imageNamed:@"AppIcon"];
    NSImage* appIcon = [NSImage imageNamed:@"NSPreferencesGeneral"];
    [appIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:appIcon];
    ShowMenuItemImage(item);
  }

  [menu addItem:[NSMenuItem separatorItem]];

  menuRows = [[NSMutableArray alloc] init];
  for (Class rowsClass in menuRowsClasses)
  {
    id<MenuRows> rows = [[rowsClass alloc] init];
    [menuRows addObject:rows];
    NSArray<NSMenuItem*>* items = [rows menuItemsWithAttributes:attributesStandard];
    for (NSMenuItem* item in items)
    {
      [menu addItem:item];
    }
    if ([items count] > 0)
    {
      [menu addItem:[NSMenuItem separatorItem]];
    }
  }

  {
    NSMenuItem* item = [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
  }
  
  self.statusItem.menu = menu;
}

// light or dark as an appearance resolves to Aqua or Dark Aqua, whatever its variant (vibrant, high contrast)
static bool IsLight(NSAppearance* appearance)
{
  NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
  return ![name isEqualToString:NSAppearanceNameDarkAqua];
}

- (void)renderMenubarWithLight:(BOOL)light readings:(const CpuReadings*)readings
{
  CpuSamplerUpdate(&cpu_info);
  static NSImage* image = nil;
  {
    image = self.statusItem.button.image;
    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, tickHeight)];
    }
    else
    {
      if ([image size].width != imageWidth)
      {
        image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, tickHeight)];
      }
    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, imageWidth, theme, readings);
    }
    [image unlockFocus];
  }
  self.statusItem.button.image = image;
  [self updateBarTips:(readings != NULL)];
}

// a tooltip-style label under each reading's bar (or dot) in the status item: disk, memory, CPU, worded as the panel's
// rows. On macOS 27 no tooltip showed on the status item when tried (a tooltip rect was never asked for its text), but
// the pointer reaches the button, so the label is the app's own panel. updateBarTips: records where the readings are
// after each render; the pointer's entry and moves start a watch timer that follows the pointer while it is on the
// item, since no exit was delivered either, and a reading under it arms the label (BAR_TIP_DELAY)
static NSPanel* NewTipPanel(NSTextField* __strong * label);
static void SetTipText(NSPanel* panel, NSTextField* label, NSString* text);
static NSRect barTipLayout = {{-1.0, -1.0}, {-1.0, -1.0}}; // x: the image's left in the button, width: a slot; none: -1
static NSInteger barTipIndex = -1;          // the reading under the pointer, armed or shown: 0 disk, 1 memory, 2 CPU, -1 none
static NSPanel* barTip = nil;
static NSTextField* barTipText = nil;
static NSTimer* barTipWatch = nil;

- (void)updateBarTips:(BOOL)shown
{
  NSStatusBarButton* button = self.statusItem.button;
  static NSTrackingArea* tracking = nil;
  if (tracking == nil)
  {
    tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect) owner:self userInfo:nil];
    [button addTrackingArea:tracking];
  }
  NSRect layout = NSMakeRect(-1.0, -1.0, -1.0, -1.0);
  if (shown)
  {
    NSRect bounds = button.bounds;
    layout = NSMakeRect(round(NSMidX(bounds) - imageWidth/2.0), NSMinY(bounds), CpuRenderReadingsSlot(bar, drawWidth, tickTotalWidth), NSHeight(bounds));
  }
  if (!NSEqualRects(layout, barTipLayout))
  {
    barTipLayout = layout;
    [self hideBarTip];
  }
}

// the reading under the pointer, from where it is now: 0 disk, 1 memory, 2 CPU; -1 on the item but on none of them;
// -2 off the item, or no readings shown
- (NSInteger)barTipIndexNow
{
  NSStatusBarButton* button = self.statusItem.button;
  if ((barTipLayout.size.width <= 0.0) || (button.window == nil))
  {
    return -2;
  }
  NSPoint p = [button convertPoint:[button.window convertPointFromScreen:[NSEvent mouseLocation]] fromView:nil];
  if (!NSPointInRect(p, button.bounds))
  {
    return -2;
  }
  CGFloat x = p.x - barTipLayout.origin.x;
  if ((x < 0.0) || (x >= 3.0*barTipLayout.size.width))
  {
    return -1;
  }
  return (NSInteger)floor(x / barTipLayout.size.width);
}

// a reading's text, as its panel row: "995GB Disk usage: 72%"
- (NSString*)barTipTextAt:(NSInteger)index
{
  NSArray<NSArray<NSString*>*>* rows = [self readingRows];
  if ((index < 0) || (index >= (NSInteger)rows.count))
  {
    return @"";
  }
  return [NSString stringWithFormat:@"%@ %@", rows[index][0], rows[index][1]];
}

// follows the pointer: off the item (or the menu open), everything stops; on it, the watch runs; another reading, or
// none, hides the label and arms the new one; the same one keeps the label, laid out again only when its text changed
- (void)trackBarTip
{
  NSInteger index = menuIsOpen ? -2 : [self barTipIndexNow];
  if (index == -2)
  {
    [self hideBarTip];
    return;
  }
  if (barTipWatch == nil)
  {
    barTipWatch = [NSTimer timerWithTimeInterval:BAR_TIP_WATCH target:self selector:@selector(watchBarTip:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:barTipWatch forMode:NSRunLoopCommonModes];
  }
  if (index != barTipIndex)
  {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showBarTip) object:nil];
    [barTip orderOut:nil];
    barTipIndex = index;
    if (index >= 0)
    {
      [self performSelector:@selector(showBarTip) withObject:nil afterDelay:BAR_TIP_DELAY inModes:@[NSRunLoopCommonModes]];
    }
  }
  else if ((index >= 0) && barTip.isVisible && ![[self barTipTextAt:index] isEqualToString:barTipText.stringValue])
  {
    [self showBarTip];
  }
}

- (void)watchBarTip:(NSTimer*)timer
{
  [self trackBarTip];
}

- (void)mouseEntered:(NSEvent*)event
{
  [self trackBarTip];
}

- (void)mouseMoved:(NSEvent*)event
{
  [self trackBarTip];
}

- (void)mouseExited:(NSEvent*)event
{
  [self hideBarTip];
}

// the label below the menu bar, centred under its reading, kept on screen; not when the pointer has left that reading
// since it was armed (the watch hides and re-arms at its next look)
- (void)showBarTip
{
  NSStatusBarButton* button = self.statusItem.button;
  if (menuIsOpen || (barTipIndex < 0) || (button.window == nil) || ([self barTipIndexNow] != barTipIndex))
  {
    return;
  }
  if (barTip == nil)
  {
    barTip = NewTipPanel(&barTipText);
  }
  SetTipText(barTip, barTipText, [self barTipTextAt:barTipIndex]);
  NSRect slot = NSMakeRect(barTipLayout.origin.x + barTipIndex*barTipLayout.size.width, barTipLayout.origin.y, barTipLayout.size.width, barTipLayout.size.height);
  NSRect onScreen = [button.window convertRectToScreen:[button convertRect:slot toView:nil]];
  NSRect item = button.window.frame;
  NSRect frame = barTip.frame;
  NSRect visible = (button.window.screen ?: [NSScreen mainScreen]).frame;
  frame.origin.x = round(NSMidX(onScreen) - NSWidth(frame)/2.0);
  frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)), NSMaxX(visible) - NSWidth(frame));
  frame.origin.y = NSMinY(item) - BAR_TIP_GAP - NSHeight(frame);
  [barTip setFrame:frame display:YES];
  [barTip orderFrontRegardless];
}

- (void)hideBarTip
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showBarTip) object:nil];
  [barTipWatch invalidate];
  barTipWatch = nil;
  barTipIndex = -1;
  [barTip orderOut:nil];
}

- (void)renderPrefsRealWithLight:(BOOL)light readings:(const CpuReadings*)readings
{
  [self.realDemoView setBoundsSize:NSMakeSize(imageWidth, tickHeight)];
  [self.realDemoView setFrameSize:NSMakeSize(imageWidth, tickHeight)];
  NSRect imgFrame = [self.realDemoView frame];
  [self.realDemoView setFrameOrigin:NSMakePoint((int)((([self.window frame].size.width-imageWidth)/2.0)-135.0), imgFrame.origin.y)];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, tickHeight)];
    }
//    else
//    {
//      image = self.realDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, imageWidth, theme, readings);
    }
    [image unlockFocus];
  }
  self.realDemoView.image = image;
}

- (void)renderPrefsSinWithLight:(BOOL)light
{
  CpuSamplerSineDemoUpdate(&cpu_sine_demo_info, speed);

  [self.sineDemoView setBoundsSize:NSMakeSize(graphWidth, tickHeight)];
  [self.sineDemoView setFrameSize:NSMakeSize(graphWidth, tickHeight)];
  NSRect imgFrame = [self.sineDemoView frame];
  [self.sineDemoView setFrameOrigin:NSMakePoint((int)(([self.window frame].size.width-graphWidth)/2.0), imgFrame.origin.y)];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(graphWidth, tickHeight)];
    }
//    else
//    {
//      image = self.sineDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_sine_demo_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, graphWidth, theme, NULL);
    }
    [image unlockFocus];
  }
  self.sineDemoView.image = image;
}

- (void)renderPrefsFlatWithLight:(BOOL)light
{
  CpuSamplerFlatDemoUpdate(&cpu_flat_demo_info, speed);
  
  [self.flatDemoView setBoundsSize:NSMakeSize(graphWidth, tickHeight)];
  [self.flatDemoView setFrameSize:NSMakeSize(graphWidth, tickHeight)];
  NSRect imgFrame = [self.flatDemoView frame];
  [self.flatDemoView setFrameOrigin:NSMakePoint((int)((([self.window frame].size.width-graphWidth)/2.0)+125.0), imgFrame.origin.y)];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(graphWidth, tickHeight)];
    }
//    else
//    {
//      image = self.flatDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_flat_demo_info, ctx, light, granularity, bar, stripped, colored, drawWidth, tickTotalWidth, graphWidth, theme, NULL);
    }
    [image unlockFocus];
  }
  self.flatDemoView.image = image;
}

- (void)updateCPU:(id)sender
{
  // overall CPU, menu open or not, so that its window is full the moment the menu opens
  SystemInfoCpuTick();
  // overall CPU and memory, for the bars and the panel, every READINGS_TICKS ticks, half a tick early, so that a tick
  // firing a little late does not put the read off by a whole tick; while CPU cannot be read yet (fewer than two
  // samples, after a reset) both keep their last reading and are tried again on the next tick
  if (([[NSProcessInfo processInfo] systemUptime] - lastReadings) >= ((READINGS_TICKS - 0.5)*RefreshInterval()))
  {
    double cpu = SystemInfoCpuBusy(NULL);
    if (cpu >= 0.0)
    {
      readingsCpu = cpu;
      readingsMemory = SystemInfoMemory(&readingsMemoryUsed, &readingsMemoryTotal);
      lastReadings = [[NSProcessInfo processInfo] systemUptime];
    }
  }

  [self updateRendererParameters];

  // one set of readings per tick, for the menu bar and the real-time preview; CPU or memory that cannot be read is -1,
  // and its bar shows only its background (no dot in Dot style); the disk keeps its last reading, -1 before the first
  CpuReadings readings = {-1.0, -1.0, diskFraction};
  if (showBars)
  {
    readings.cpu = readingsCpu;
    if (readingsMemory && (readingsMemoryTotal > 0))
    {
      readings.memory = MIN((double)readingsMemoryUsed / (double)readingsMemoryTotal, 1.0);
    }
    // half a tick early, so that a tick firing a little late does not put the read off by a whole tick
    if (([[NSProcessInfo processInfo] systemUptime] - lastDiskAttempt) >= (MENUBAR_DISK_REFRESH - 0.5*RefreshInterval()))
    {
      [self readDisk];
    }
  }
  const CpuReadings* shown = showBars ? &readings : NULL;
  
  // the menu bar's appearance need not be the app's: the graph takes the status item's, the previews their window's
  [self renderMenubarWithLight:IsLight(self.statusItem.button.effectiveAppearance) readings:shown];
  if ([self.window isVisible])
  {
    bool light = IsLight(self.window.effectiveAppearance);
    [self renderPrefsRealWithLight:light readings:shown];
    [self renderPrefsSinWithLight:light];
    [self renderPrefsFlatWithLight:light];
  }
}

//static int _task_extmod_info_for_pid(pid_t pid, struct task_extmod_info *info)
//{
//  task_name_t task;
//  kern_return_t kr = task_name_for_pid(mach_task_self(), pid, &task);
//  if (kr != KERN_SUCCESS)
//  {
//    return kr;
//  }
//  else
//  {
//    memset(info, 0, sizeof(struct task_extmod_info));
//    mach_msg_type_number_t count = TASK_EXTMOD_INFO_COUNT;
//    kr = task_info(task, TASK_EXTMOD_INFO, (task_info_t)info, &count);
//    mach_port_deallocate(mach_task_self(), task);
//    if (kr != KERN_SUCCESS)
//    {
//      return kr;
//    }
//  }
//  return 0;
//}

// Samples on every tick, with the menu closed too (about 1-2 ms), so that the CPU% always covers the
// last interval and the list is current the moment the menu opens. Nothing is sampled while frozen.
- (void)updateTop:(id)sender
{
  // the rows a build adds run under Freeze too
  if (menuIsOpen)
  {
    for (id<MenuRows> rows in menuRows)
    {
      if ([rows respondsToSelector:@selector(menuTick)])
      {
        [rows menuTick];
      }
    }
  }

  if (frozen)
  {
    return;
  }

  TopSample();
  lastTopSample = [[NSProcessInfo processInfo] systemUptime];
  topListValid = true;
  baselineOnly = false;
  [self pruneIconCache];

  [self collectTopList];

  if (refreshTop)
  {
    [self updateMenuTop];
  }
}

- (void)collectTopList
{
  int counter = 0;
  const TopProcessSample_t *psample = TopIterate();
  while ((psample != NULL) && (counter < TOP_COUNT))
  {
    // other users' processes have no CPU figure in the sandbox and are not ranked
    if (psample->cpu_known != 0)
    {
      topProcceses[counter++] = *psample;
    }
    psample = TopIterate();
  }
  topCount = counter;
  topOthersCount = TopUnreadableCount();
}

- (void)setupStatusItem
{
  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  [self updateCPU:nil];
}

- (void)removeUserDefaults
{
    NSUserDefaults * userDefaults = [NSUserDefaults standardUserDefaults];
    NSDictionary * dict = [userDefaults dictionaryRepresentation];
    for (id key in dict) {
        [userDefaults removeObjectForKey:key];
    }
    [userDefaults synchronize];
}

// the refresh interval the Preferences offer: 0.1, 0.2 or 0.5 s; any other stored value counts as 0.5, the default
static double RefreshInterval(void)
{
  double interval = [[NSUserDefaults standardUserDefaults] doubleForKey:RefreshKey];
  return ((interval == 0.1) || (interval == 0.2)) ? interval : 0.5;
}

// the process sample's interval: 2.5 s, whatever the Refresh setting, with the menu open or closed
static double TopInterval(void)
{
  return TOP_REFRESH_RATE;
}

- (void)setupPreferences
{
#if 0
  [self removeUserDefaults];
#endif
  
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{GranularityKey:@2}];
  // 2 frames a second by default: each frame costs AppKit far more than it costs to draw
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{RefreshKey:@0.5}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{StyleKey:@1}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{TickLineKey:@1}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{TickWidthKey:@3.0}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{AppearanceKey:@1}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{ThemeKey:@2}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{ShowBarsKey:@YES}];

  granularity = (int)[[NSUserDefaults standardUserDefaults] integerForKey:GranularityKey];
  speed = 10.0 * RefreshInterval();
  bar = [[NSUserDefaults standardUserDefaults] boolForKey:StyleKey];
  stripped = [[NSUserDefaults standardUserDefaults] boolForKey:TickLineKey];
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  colored = [[NSUserDefaults standardUserDefaults] boolForKey:AppearanceKey];
  theme = (int)[[NSUserDefaults standardUserDefaults] integerForKey:ThemeKey];
  showBars = [[NSUserDefaults standardUserDefaults] boolForKey:ShowBarsKey];

  [self updateRendererParameters];
  [self updateUI];
  [self updateLoginButton];

  // the build number, raised on every build by scripts/raise-build-number.sh
  NSString* build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
  [self.buildLabel setStringValue:[NSString stringWithFormat:@"b%@", build]];
}

// both timers, at launch and after a pause; none while paused (nothing can be seen: updatePause starts them again)
- (void)setupTimers
{
  // the overall CPU's window starts again, so that it never spans a pause, and CPU and memory are read again soon
  SystemInfoCpuReset();
  lastReadings = 0.0;
  [self startGraphTimer];
  [self startTopTimer:TopInterval()];
}

// (re)starts the graph's timer at the Refresh interval, none while paused; a Refresh change restarts only this one, so
// that the process sample, the overall CPU's window and the readings carry on at their own rates
- (void)startGraphTimer
{
  [timerCPU invalidate];
  timerCPU = nil;
  if (paused)
  {
    return;
  }

  // common modes: they fire while the menu is open (event tracking) and under a modal panel too. A tolerance of a
  // tenth of the interval lets macOS group their wakeups with others'.
  double interval = RefreshInterval();
  timerCPU = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(updateCPU:) userInfo:nil repeats:YES];
  timerCPU.tolerance = 0.1 * interval;
  [[NSRunLoop mainRunLoop] addTimer:timerCPU forMode:NSRunLoopCommonModes];
}

// (re)starts the process sample's timer at its interval (TopInterval), its next sample in delay s
- (void)startTopTimer:(NSTimeInterval)delay
{
  [timerTop invalidate];
  timerTop = nil;
  if (paused)
  {
    return;
  }
  double interval = TopInterval();
  timerTop = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(updateTop:) userInfo:nil repeats:YES];
  timerTop.tolerance = 0.1 * interval;
  [timerTop setFireDate:[NSDate dateWithTimeIntervalSinceNow:delay]];
  [[NSRunLoop mainRunLoop] addTimer:timerTop forMode:NSRunLoopCommonModes];
}

// the delay to the next process sample: one interval after the last sample (now if that is past), or the timer's own
// next sample when that comes sooner (the soon one after a pause or an unfreeze)
static NSTimeInterval TopDelay(void)
{
  NSTimeInterval delay = MAX(0.0, lastTopSample + TopInterval() - [[NSProcessInfo processInfo] systemUptime]);
  if (timerTop != nil)
  {
    delay = MIN(delay, MAX(0.0, [[timerTop fireDate] timeIntervalSinceNow]));
  }
  return delay;
}

- (void)workspaceChanged:(NSNotification*)notification
{
  NSString* name = notification.name;
  if ([name isEqualToString:NSWorkspaceScreensDidSleepNotification])
  {
    screensAsleep = true;
  }
  else if ([name isEqualToString:NSWorkspaceScreensDidWakeNotification])
  {
    // the displays are on, so the Mac is awake too
    screensAsleep = false;
    systemAsleep = false;
  }
  else if ([name isEqualToString:NSWorkspaceWillSleepNotification])
  {
    systemAsleep = true;
  }
  else if ([name isEqualToString:NSWorkspaceDidWakeNotification])
  {
    systemAsleep = false;
  }
  else if ([name isEqualToString:NSWorkspaceSessionDidResignActiveNotification])
  {
    sessionInactive = true;
  }
  else if ([name isEqualToString:NSWorkspaceSessionDidBecomeActiveNotification])
  {
    // this session is in front, so its displays are on and the Mac is awake: a wake missed while it was not in
    // front cannot keep the graph paused
    screensAsleep = false;
    systemAsleep = false;
    sessionInactive = false;
  }
  [self updatePause];
}

// stops the timers when nothing can be seen, and starts them again when something can
- (void)updatePause
{
  bool pause = screensAsleep || systemAsleep || sessionInactive;
  if (pause == paused)
  {
    return;
  }
  paused = pause; // first: setupTimers makes no timers while paused
  if (paused)
  {
    [timerCPU invalidate];
    timerCPU = nil;
    [timerTop invalidate];
    timerTop = nil;
    NSLog(@"paused: nothing can be seen (screens asleep %d, system asleep %d, session inactive %d)", screensAsleep, systemAsleep, sessionInactive);
  }
  else
  {
    // the first readings after the pause would average over all of it: take them now as the new baselines
    CpuSamplerUpdate(&cpu_info);
    [self updateTop:nil];
    [self setupTimers];
    // and the next process sample soon, so that an open menu does not show the pause's average for a whole interval
    [self startTopTimer:MIN(TOP_MIN_INTERVAL, TopInterval())];
    NSLog(@"running again");
  }
}

- (void)fillDescForProcess:(NSString*)name tab:(NSTabViewItem*)descriptionTab
{
  // "--": a process name starting with '-' must not be read as an option
  [self runTool:@"/usr/bin/man" arguments:@[@"-P", @"col -bx", @"--", name] withStderr:NO done:^(NSString* output) {
    if ([output length] > 0)
    {
      [self.procDescTextView setString:[NSString stringWithFormat:@"\n%@", output]];
      [self.procAppView removeTabViewItem:descriptionTab];
      [self.procAppView insertTabViewItem:descriptionTab atIndex:0];
    }
    else
    {
      [self.procAppView removeTabViewItem:descriptionTab];
    }
  }];
}

- (BOOL)fillArgsEnvForProcess:(TopProcessInfo_t*) info
{
  BOOL found = NO;

  if (info->args_count > 0)
  {
    NSString *output = [NSString stringWithFormat:@"\nCOMMAND:\n\n%@\n\n\nARGUMENTS: (%d)\n\n%@\n\nENVIRONMENT: (%d)\n\n%@\n",
                        SampleText(info->command), info->args_count, SampleText(info->args_info), info->envs_count, SampleText(info->envs_info)];
    [self.procArgsEnvTextView setString:output];
    found = YES;
  }
  else
  {
    NSString *output = [NSString stringWithFormat:@"\nCOMMAND:\n%s\n\n\nARGUMENTS: (%d)\n\n%s\n\nENVIRONMENT: (%d)\n\n%s\n",
                        "", 0, "", 0, ""];
    [self.procArgsEnvTextView setString:output];
  }
  
  return found;
}

#pragma mark - Public APIs

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
  srandom((int)time(NULL)^getpid());

  runningTasks = [NSMutableSet set];

  {
    {
      CFDictionaryValueCallBacks tableCallbacks = { 0, stringRetain, stringFree, NULL, stringEqual };
      topCpuHashTable = CFDictionaryCreateMutable(NULL, 0, NULL, &tableCallbacks);
    }
    topNameCache = [NSMutableDictionary dictionary];
    topIconCache = [NSMutableDictionary dictionary];
    frozenStarts = [NSMutableDictionary dictionary];

    CpuRenderInit();
    CpuSamplerInit(&cpu_info);
    CpuSamplerSineDemoInit(&cpu_sine_demo_info);
    CpuSamplerFlatDemoInit(&cpu_flat_demo_info);
    TopInit(); // takes the first sample: the CPU baseline
    lastTopSample = [[NSProcessInfo processInfo] systemUptime];

    [self setupPreferences];
    [self setupStatusItem];
    [self setupMenus];

    // pause while nothing can be seen (updatePause)
    NSNotificationCenter* workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    for (NSNotificationName name in @[NSWorkspaceScreensDidSleepNotification, NSWorkspaceScreensDidWakeNotification,
                                      NSWorkspaceWillSleepNotification, NSWorkspaceDidWakeNotification,
                                      NSWorkspaceSessionDidResignActiveNotification, NSWorkspaceSessionDidBecomeActiveNotification])
    {
      [workspaceCenter addObserver:self selector:@selector(workspaceChanged:) name:name object:nil];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(preferencesBecameKey:)
                                                 name:NSWindowDidBecomeKeyNotification object:self.window];
    [self setupTimers];

    // the readings panel's disk row has a value the first time the menu opens
    [self readDisk];

    // room for the inspector's "Helper of:" line
    [self.procAppName setUsesSingleLineMode:NO];
    [self.procAppName setMaximumNumberOfLines:2];
  }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
  //[[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)openPreferences:(id)sender
{
  [NSApp activateIgnoringOtherApps:YES];
  
  [self updateLoginButton];
  [self.window center];
  [self.window orderFrontRegardless];
  [self.window makeKeyWindow];
}

- (void)processExplorer:(id)sender
{
  NSLog(@"processExplorer");
}

- (void)selectPid:(id)sender
{
  static NSTabViewItem* descriptionTab = nil;
  if (descriptionTab == nil)
  {
    descriptionTab = [self.procAppView tabViewItemAtIndex:0];
  }
    
  NSMenuItem* menu = sender;

  pid_t pid = (pid_t)[menu tag];
  TopProcessSample_t* sample = TopGetSample(pid);
  if (sample == NULL)
  {
    // the process exited after the menu was filled
    return;
  }

  // a frozen row whose process has exited, or whose pid now belongs to another process (its start time
  // differs from the one read at the freeze): show what the row recorded and run no tool on the pid
  uint64_t frozenStart = [frozenStarts[[NSNumber numberWithInt:pid]] unsignedLongLongValue];
  bool exited = frozen && ((frozenStart == 0) || (ProcessStartTime(pid) != frozenStart));

  inspectGeneration++;
  [self stopInspectorTools];
  current_process_pid = exited ? nil : [NSNumber numberWithInt:pid];

  ProcessIconDecision* decision = exited ? topIconCache[[NSNumber numberWithInt:pid]] : [self decisionForPid:pid];
  NSImage *icon = [decision.image copy];
  [icon setSize:NSMakeSize(TOP_ICON_SIZE, TOP_ICON_SIZE)];
  [self.procAppIcon setImage:icon];

  TopProcessInfo_t* info = exited ? NULL : TopGetArgs(pid);
  NSString* name = exited ? SampleText(sample->name) : SampleText(info->name);
  
  char bits_str[40] = "00000000 00000000 00000000 00000000";
  uint32_t flags = sample->flags;
  for (int i=0; i<8; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[34-i] = '1';
    }
  }
  for (int i=8; i<16; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[33-i] = '1';
    }
  }
  for (int i=16; i<24; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[32-i] = '1';
    }
  }
  for (int i=24; i<32; i++)
  {
    if ((flags>>i) & 0b1)
    {
      bits_str[31-i] = '1';
    }
  }
  bits_str[36] = '\0';
  
  char const *status_str = NULL;
  switch(sample->status)
  {
    case SIDL: status_str = "SIDL"; break;
    case SRUN: status_str = "SRUN"; break;
    case SSLEEP: status_str = "SSLEEP"; break;
    case SSTOP: status_str = "SSTOP"; break;
    case SZOMB: status_str = "SZOMB"; break;
    default: status_str = "?"; break;
  }

  NSString* line = [NSString stringWithFormat:@"%@%@, pid:%d, ppid:%d, prio:%d, stat:%d (%s), flags:%d (%s)",
                    SampleText(sample->name), (exited ? @" (exited)" : @""), sample->pid, sample->ppid, sample->tprio, sample->status, status_str, sample->flags, bits_str];
  if (decision.helper)
  {
    line = [line stringByAppendingFormat:@"\n%@", decision.helperLine];
  }
  [self.procAppName setStringValue:line];
  // the window is resizable: keep the field's current x, width and vertical center
  NSRect frame = [self.procAppName frame];
  CGFloat midY = NSMidY(frame);
  frame.size.height = decision.helper ? 32.0 : 16.0;
  frame.origin.y = midY - (frame.size.height / 2.0);
  [self.procAppName setFrame:frame];

  NSString* live = exited ? @"\nN/A (exited)" : @"\npreparing...";
  [self.procDescTextView setString:@"\npreparing..."];
  [self.procArgsEnvTextView setString:live];

  //if ([self.top isVisible] == NO)
  {
    [NSApp activateIgnoringOtherApps:YES];
    [self.top center];
    [self.top orderFrontRegardless];
    [self.top makeKeyWindow];
  }
  
  [self.procAppView selectFirstTabViewItem:self];

  if (!exited)
  {
    [self fillArgsEnvForProcess:info];
  }
  [self fillDescForProcess:name tab:descriptionTab];
}

// Freeze keeps the rows as they were when it was chosen, so that they can be examined
- (void)toggleFreeze:(NSMenuItem*)sender
{
  [self hideRowTip];
  frozen = !frozen;
  [sender setImage:(frozen ? freezeOnImage : freezeOffImage)];
  // the row is a view (StayOpenRowView), which draws the item's image
  [sender.view setNeedsDisplay:YES];
  [frozenStarts removeAllObjects];
  if (frozen)
  {
    // the menu stays open, and its rows keep what they show
    refreshTop = false;
    for (int i=0; i<TOP_COUNT; i++)
    {
      if (![topMenus[i] isHidden])
      {
        pid_t pid = (pid_t)[topMenus[i] tag];
        frozenStarts[[NSNumber numberWithInt:pid]] = [NSNumber numberWithUnsignedLongLong:ProcessStartTime(pid)];
      }
    }
  }
  else
  {
    // the next sample would average the CPU% over the whole freeze: take one now as the new baseline. It is never
    // shown: refreshTop is false while frozen, and baselineOnly holds the rows until the next sample
    [self updateTop:nil];
    baselineOnly = true;
    if (menuIsOpen)
    {
      // as at an opening: the rows refresh from the next sample, taken soon
      refreshTop = true;
      [self startTopTimer:MIN(TOP_MIN_INTERVAL, TopInterval())];
    }
    else
    {
      [self startTopTimer:TopInterval()];
    }
  }
}

- (void)launchActivityMonitor:(id)sender
{
  NSString *appPath = @"/System/Applications/Utilities/Activity Monitor.app";
  [self launchAppAt:appPath with:@[]];
}

- (IBAction)packageButtonClicked:(id)sender
{
  granularity = 0;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  [[NSUserDefaults standardUserDefaults] setDouble:granularity forKey:GranularityKey];

  [self updateUI];
}

- (IBAction)coreButtonClicked:(id)sender
{
  granularity = 1;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  [[NSUserDefaults standardUserDefaults] setDouble:granularity forKey:GranularityKey];

  [self updateUI];
}

- (IBAction)logicalButtonClicked:(id)sender
{
  granularity = 2;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  [[NSUserDefaults standardUserDefaults] setDouble:granularity forKey:GranularityKey];
  
  [self updateUI];
}

- (IBAction)fastButtonClicked:(id)sender
{
  speed = 1.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.1 forKey:RefreshKey];

  [self updateUI];
  [self startGraphTimer];
}

- (IBAction)normalButtonClicked:(id)sender
{
  speed = 2.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.2 forKey:RefreshKey];

  [self updateUI];
  [self startGraphTimer];
}

- (IBAction)slowButtonClicked:(id)sender
{
  speed = 5.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.5 forKey:RefreshKey];

  [self updateUI];
  [self startGraphTimer];
}

- (IBAction)barButtonClicked:(id)sender
{
  bar = true;
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  colored = [[NSUserDefaults standardUserDefaults] boolForKey:AppearanceKey];
  [[NSUserDefaults standardUserDefaults] setBool:bar forKey:StyleKey];

  [self updateUI];
}

- (IBAction)dotButtonClicked:(id)sender
{
  bar = false;
  colored = false;
  [[NSUserDefaults standardUserDefaults] setBool:bar forKey:StyleKey];

  [self updateUI];
}

- (IBAction)solidButtonClicked:(id)sender
{
  stripped = false;
  [[NSUserDefaults standardUserDefaults] setBool:stripped forKey:TickLineKey];
  
  [self updateUI];
}

- (IBAction)strippedButtonClicked:(id)sender
{
  stripped = true;
  [[NSUserDefaults standardUserDefaults] setBool:stripped forKey:TickLineKey];
  
  [self updateUI];
}

- (IBAction)thinButtonClicked:(id)sender
{
  tickWidth = 1.0;
  [[NSUserDefaults standardUserDefaults] setDouble:tickWidth forKey:TickWidthKey];
  
  [self updateUI];
}

- (IBAction)standardButtonClicked:(id)sender
{
  tickWidth = 2.0;
  [[NSUserDefaults standardUserDefaults] setDouble:tickWidth forKey:TickWidthKey];
  
  [self updateUI];
}

- (IBAction)thickButtonClicked:(id)sender
{
  tickWidth = 3.0;
  [[NSUserDefaults standardUserDefaults] setDouble:tickWidth forKey:TickWidthKey];
  
  [self updateUI];
}

- (IBAction)greyButtonClicked:(id)sender
{
  colored = false;
  [[NSUserDefaults standardUserDefaults] setBool:colored forKey:AppearanceKey];
  
  [self updateUI];
}

- (IBAction)colorButtonClicked:(id)sender
{
  colored = true;
  [[NSUserDefaults standardUserDefaults] setBool:colored forKey:AppearanceKey];
  
  [self updateUI];
}

- (IBAction)yellow:(id)sender
{
  theme = THEME_YELLOW;

  [self.yellowButton setState:NSControlStateValueOn];
  [self.greenButton setState:NSControlStateValueOff];
  [self.blueButton setState:NSControlStateValueOff];

  [[NSUserDefaults standardUserDefaults] setDouble:theme forKey:ThemeKey];
}

- (IBAction)green:(id)sender
{
  theme = THEME_GREEN;
  
  [self.yellowButton setState:NSControlStateValueOff];
  [self.greenButton setState:NSControlStateValueOn];
  [self.blueButton setState:NSControlStateValueOff];

  [[NSUserDefaults standardUserDefaults] setDouble:theme forKey:ThemeKey];
}

- (IBAction)blue:(id)sender
{
  theme = THEME_BLUE;
  
  [self.yellowButton setState:NSControlStateValueOff];
  [self.greenButton setState:NSControlStateValueOff];
  [self.blueButton setState:NSControlStateValueOn];

  [[NSUserDefaults standardUserDefaults] setDouble:theme forKey:ThemeKey];
}

- (IBAction)showBarsButtonClicked:(id)sender
{
  showBars = (self.showBarsButton.state == NSControlStateValueOn);
  [[NSUserDefaults standardUserDefaults] setBool:showBars forKey:ShowBarsKey];
  [self updateRendererParameters];
  [self updateUI];
}

// Launch at login: macOS keeps the setting (System Settings, Login Items), so the checkbox shows what macOS
// reports.
- (void)updateLoginButton
{
  [self.loginButton setState:([SMAppService mainAppService].status == SMAppServiceStatusEnabled) ? NSControlStateValueOn : NSControlStateValueOff];
}

- (IBAction)loginButtonClicked:(id)sender
{
  SMAppService* service = [SMAppService mainAppService];
  BOOL on = (self.loginButton.state == NSControlStateValueOn);
  NSError* error = nil;
  BOOL ok = on ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
  if (!ok)
  {
    NSLog(@"launch at login: %@ failed: %@ %ld, status %ld", on ? @"register" : @"unregister", error.domain, (long)error.code, (long)service.status);
  }
  if (on && (service.status == SMAppServiceStatusRequiresApproval))
  {
    // registered, but the user turned it off in System Settings: show them where to allow it
    [SMAppService openSystemSettingsLoginItems];
  }
  [self updateLoginButton];
}

- (void)preferencesBecameKey:(NSNotification*)notification
{
  // the setting may have changed in System Settings while Preferences was open
  [self updateLoginButton];
}

// TODO: implement (using SMJobBless ?)
- (IBAction)killButtonClicked:(id)sender
{
  pid_t pid = [current_process_pid intValue];
  if (pid > 0)
  {
// Does not work! - needs priviledged action
//    NSString *appPath = @"/bin/kill";
//    NSArray<NSString *> *arguments = [NSArray arrayWithObjects:@"-9", [NSString stringWithFormat:@"%d", pid], nil];
//    NSTask *task = [[NSTask alloc] init];
//    [task setLaunchPath:appPath];
//    [task setArguments:arguments];
//    [task launch];
//    [task terminate];
  }
}

- (void)menuWillOpen:(NSMenu *)menu
{
  menuIsOpen = true;
  [self hideBarTip];
  if (paused)
  {
    // the menu is open, so something can be seen: a wake was missed
    NSLog(@"menu opened while paused (screens asleep %d, system asleep %d, session inactive %d): running again", screensAsleep, systemAsleep, sessionInactive);
    screensAsleep = false;
    systemAsleep = false;
    sessionInactive = false;
    [self updatePause];
  }

  // frozen too
  for (id<MenuRows> rows in menuRows)
  {
    if ([rows respondsToSelector:@selector(menuWillOpen)])
    {
      [rows menuWillOpen];
    }
  }

  // frozen: the rows keep what they showed, and no sample runs
  if (!frozen)
  {
    refreshTop = true;

    // take a fresh sample, unless the timer has just taken one: a very short interval gives noisy CPU%
    if (!topListValid || (([[NSProcessInfo processInfo] systemUptime] - lastTopSample) >= TOP_MIN_INTERVAL))
    {
      [self updateTop:nil];
      // the next sample a whole interval after this one, so that its CPU% never covers a shorter window
      [self startTopTimer:TopInterval()];
    }
    else
    {
      [self updateMenuTop];
      // the next sample an interval after the last, or at the timer's own fire when that comes sooner (TopDelay)
      [self startTopTimer:TopDelay()];
    }
  }
  else
  {
    // frozen: no sample, but the rows a build adds tick at the process sample's interval
    [self startTopTimer:TopInterval()];
  }

  // the menu's window is new on every opening; paint it once it is on screen
  [self performSelector:@selector(paintMenuBackground) withObject:nil afterDelay:0 inModes:@[NSRunLoopCommonModes]];

  // the readings panel, frozen too: placed once the menu's window is on screen, then updated every second
  infoPlaced = false;
  infoRetried = false;
  infoSideDecided = false;
  infoWidth = 0.0;
  [self performSelector:@selector(showInfoPanel) withObject:nil afterDelay:0 inModes:@[NSRunLoopCommonModes]];
  [self readDisk];
  [infoTimer invalidate];
  infoTimer = [NSTimer timerWithTimeInterval:INFO_REFRESH target:self selector:@selector(updateInfoPanel:) userInfo:nil repeats:YES];
  infoTimer.tolerance = 0.1 * INFO_REFRESH;
  [[NSRunLoop mainRunLoop] addTimer:infoTimer forMode:NSRunLoopCommonModes];
}

- (void)paintMenuBackground
{
  PaintOpenMenuBackground();
}

- (void)menuDidClose:(NSMenu *)menu
{
  // the menu can close before its deferred paint runs
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(paintMenuBackground) object:nil];

  menuIsOpen = false;
  refreshTop = false;
  // the next sample an interval after the last, or at the timer's own fire when that comes sooner (TopDelay)
  [self startTopTimer:TopDelay()];
  [self hideRowTip];
  [self hideInfoPanel];

  for (id<MenuRows> rows in menuRows)
  {
    if ([rows respondsToSelector:@selector(menuDidClose)])
    {
      [rows menuDidClose];
    }
  }
}

// while frozen, a row with helper text shows it after ROW_TIP_DELAY on the row
- (void)menu:(NSMenu*)aMenu willHighlightItem:(NSMenuItem*)item
{
  // the same row again: its text is showing, or about to
  if ((item != nil) && (item == rowTipItem))
  {
    return;
  }
  [self hideRowTip];
  if (frozen && [item.representedObject isKindOfClass:[NSString class]])
  {
    rowTipItem = item;
    [self performSelector:@selector(showRowTip) withObject:nil afterDelay:ROW_TIP_DELAY inModes:@[NSRunLoopCommonModes]];
  }
}

// a tooltip-style box: a borderless panel at help level in the tooltip material, its label in the tooltip font
static NSPanel* NewTipPanel(NSTextField* __strong * label)
{
  NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 100, 20) styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel) backing:NSBackingStoreBuffered defer:YES];
  panel.level = CGWindowLevelForKey(kCGHelpWindowLevelKey);
  panel.ignoresMouseEvents = YES;
  panel.hidesOnDeactivate = NO;
  panel.hasShadow = YES;
  panel.opaque = NO;
  panel.backgroundColor = [NSColor clearColor];
  panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorFullScreenAuxiliary;
  NSVisualEffectView* background = [[NSVisualEffectView alloc] init];
  background.material = NSVisualEffectMaterialToolTip;
  background.state = NSVisualEffectStateActive;
  background.wantsLayer = YES;
  background.layer.cornerRadius = 5.0;
  background.layer.masksToBounds = YES;
  panel.contentView = background;
  *label = [NSTextField wrappingLabelWithString:@""];
  (*label).font = [NSFont toolTipsFontOfSize:0];
  [background addSubview:*label];
  return panel;
}

// the box's text, the box sized to it at its present origin
static void SetTipText(NSPanel* panel, NSTextField* label, NSString* text)
{
  label.stringValue = text;
  NSSize size = [label sizeThatFits:NSMakeSize(ROW_TIP_MAX_WIDTH, CGFLOAT_MAX)];
  size = NSMakeSize(ceil(size.width), ceil(size.height));
  label.frame = NSMakeRect(6.0, 4.0, size.width, size.height);
  NSRect frame = panel.frame;
  [panel setFrame:NSMakeRect(NSMinX(frame), NSMaxY(frame) - (size.height + 8.0), size.width + 12.0, size.height + 8.0) display:panel.isVisible];
}

- (void)showRowTip
{
  NSMenuItem* item = rowTipItem;
  if (!frozen || ![item.representedObject isKindOfClass:[NSString class]])
  {
    return;
  }

  NSRect row = NSZeroRect;
  NSWindow* window = OpenMenuWindow(menu, item, &row);
  if (window == nil)
  {
    static bool logged = false;
    if (!logged)
    {
      logged = true;
      NSLog(@"the open menu's rows were not found: no helper text shown");
    }
    return;
  }

  if (rowTip == nil)
  {
    rowTip = NewTipPanel(&rowTipText);
  }

  SetTipText(rowTip, rowTipText, item.representedObject);
  rowTipRow = row;
  rowTipMenuWindow = window;
  [self placeRowTip];
  [rowTip orderFrontRegardless];
}

// left of the menu, level with its row; where the readings panel is on that side and level with the box too, left of
// the panel instead; kept on screen, even when that means covering the menu or the panel
- (void)placeRowTip
{
  NSRect frame = rowTip.frame;
  NSScreen* screen = rowTipMenuWindow.screen ?: [NSScreen mainScreen];
  NSRect visible = screen.visibleFrame;
  frame.origin.y = NSMidY(rowTipRow) - NSHeight(frame)/2.0;
  frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)), NSMaxY(visible) - NSHeight(frame));
  frame.origin.x = NSMinX(rowTipMenuWindow.frame) - ROW_TIP_GAP - NSWidth(frame);
  if (infoPlaced && infoOnLeft && infoPanel.isVisible)
  {
    NSRect panel = infoPanel.frame;
    if ((NSMinY(frame) < NSMaxY(panel)) && (NSMaxY(frame) > NSMinY(panel)))
    {
      frame.origin.x = NSMinX(panel) - ROW_TIP_GAP - NSWidth(frame);
    }
  }
  frame.origin.x = MAX(frame.origin.x, NSMinX(visible));
  [rowTip setFrame:frame display:YES];
}

- (void)hideRowTip
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showRowTip) object:nil];
  rowTipItem = nil;
  rowTipMenuWindow = nil;
  [rowTip orderOut:nil];
}

#pragma mark - The readings panel beside the menu

- (void)makeInfoPanel
{
  infoPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel) backing:NSBackingStoreBuffered defer:YES];
  infoPanel.level = CGWindowLevelForKey(kCGPopUpMenuWindowLevelKey);
  infoPanel.ignoresMouseEvents = YES;
  infoPanel.hidesOnDeactivate = NO;
  infoPanel.hasShadow = YES;
  infoPanel.opaque = NO;
  infoPanel.backgroundColor = [NSColor clearColor];
  infoPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorFullScreenAuxiliary;
  // glass as the menu's, shaped and painted like it at each opening (matchInfoPanelToMenu:)
  infoGlass = [[NSGlassEffectView alloc] init];
  infoGlass.cornerRadius = INFO_CORNER_RADIUS;
  NSView* background = [[NSView alloc] init];
  background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  background.accessibilityRole = NSAccessibilityGroupRole;
  background.accessibilityLabel = @"Readings";
  infoGlass.contentView = background;
  infoPanel.contentView = infoGlass;

  NSFont* font = [NSFont fontWithName:MENU_FONT_NAME size:MENU_ICON_SIZE-2];
  NSMutableArray<NSTextField*>* labels = [NSMutableArray array];
  NSMutableArray<NSTextField*>* values = [NSMutableArray array];
  NSMutableIndexSet* starts = [NSMutableIndexSet indexSet];
  NSArray<NSArray<NSString*>*>* rows = [self infoRowsWithStarts:starts];
  for (NSArray<NSString*>* row in rows)
  {
    NSTextField* label = [NSTextField labelWithString:row[0]];
    label.font = font;
    label.textColor = [NSColor labelColor];
    [background addSubview:label];
    [labels addObject:label];
    NSTextField* value = [NSTextField labelWithString:@""];
    value.font = font;
    value.textColor = [NSColor labelColor];
    value.alignment = NSTextAlignmentRight;
    [background addSubview:value];
    [values addObject:value];
  }
  infoLabels = labels;
  infoValues = values;

  NSMutableArray<NSBox*>* separators = [NSMutableArray array];
  for (NSUInteger i=0; i<starts.count; i++)
  {
    NSBox* separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    [background addSubview:separator];
    [separators addObject:separator];
  }
  infoSeparators = separators;
  infoSeparatorRows = starts;
}

// the menu's look, read at each opening since the settings can change in between: its appearance (the menu bar's,
// which need not be the app's), its glass's shape, style and tint, and the grey it is painted with Reduce
// Transparency in Dark Mode (PaintOpenMenuBackground)
- (void)matchInfoPanelToMenu:(NSWindow*)window
{
  infoPanel.appearance = window.effectiveAppearance;
  NSGlassEffectView* menuGlass = FindGlassEffectView(window);
  if (menuGlass != nil)
  {
    infoGlass.cornerRadius = menuGlass.cornerRadius;
    infoGlass.style = menuGlass.style;
    infoGlass.tintColor = menuGlass.tintColor;
  }
  if (PaintsMenusGrey() && IsDarkAqua(window.effectiveAppearance))
  {
    PaintGlassGrey(infoGlass);
  }
  else if (infoGlass.contentView.layer != nil)
  {
    infoGlass.contentView.layer.backgroundColor = NULL;
  }
}

- (void)showInfoPanel
{
  NSWindow* window = OpenMenuWindow(menu, freezeItem, NULL);
  if (window == nil)
  {
    if (!infoRetried)
    {
      infoRetried = true;
      [self performSelector:@selector(showInfoPanel) withObject:nil afterDelay:INFO_RETRY_DELAY inModes:@[NSRunLoopCommonModes]];
      return;
    }
    static bool logged = false;
    if (!logged)
    {
      logged = true;
      NSLog(@"the open menu's window was not found: no readings panel shown");
    }
    return;
  }

  if (infoPanel == nil)
  {
    [self makeInfoPanel];
  }
  [self matchInfoPanelToMenu:window];
  infoMenuWindow = window;
  infoPlaced = true;
  [self applyInfoValues];
  [infoPanel orderFrontRegardless];
}

- (void)updateInfoPanel:(id)sender
{
  if (!infoPlaced)
  {
    return;
  }
  // half a tick early, so that a tick firing a little late does not put the read off by a whole second
  if (([[NSProcessInfo processInfo] systemUptime] - lastDiskRead) >= (DISK_REFRESH - 0.5*INFO_REFRESH))
  {
    [self readDisk];
  }
  [self applyInfoValues];
}

// the three readings as shown, each its title and value: disk, memory, CPU; CPU and memory are their last reading
// (updateCPU:), the disk row the last reading of readDisk
- (NSArray<NSArray<NSString*>*>*)readingRows
{
  NSLocale* locale = [NSLocale currentLocale];

  double busy = readingsCpu;
  NSString* cpu = (busy < 0.0) ? @"—" : [[NSString alloc] initWithFormat:@"%ld%%" locale:locale, lround(busy * 100.0)];

  NSString* memoryTitle = @"Memory usage:";
  NSString* memoryUsed = @"—";
  if (readingsMemory)
  {
    memoryTitle = TotalTitle(GiBText(readingsMemoryTotal, locale), @"Memory usage:");
    memoryUsed = PercentText(readingsMemoryUsed, readingsMemoryTotal, locale);
  }

  return @[@[diskTitle ?: @"Disk usage:", diskText ?: @"—"], @[memoryTitle, memoryUsed], @[@"CPU:", cpu]];
}

// the panel's rows as shown: the readings, then each MenuRows' panel rows as a section of their own, then uptime,
// read now, a section too; starts, when given, gets the first row of each section after the readings
- (NSArray<NSArray<NSString*>*>*)infoRowsWithStarts:(NSMutableIndexSet*)starts
{
  NSMutableArray<NSArray<NSString*>*>* rows = [[self readingRows] mutableCopy];
  for (id<MenuRows> menuRow in menuRows)
  {
    NSArray<NSArray<NSString*>*>* section = [menuRow respondsToSelector:@selector(panelRows)] ? [menuRow panelRows] : nil;
    if (section.count > 0)
    {
      [starts addIndex:rows.count];
      [rows addObjectsFromArray:section];
    }
  }
  [starts addIndex:rows.count];
  [rows addObject:@[@"Uptime:", UptimeText(SystemInfoUptimeSeconds())]];
  return rows;
}

// sets the values, then sizes and places the panel: left of the menu and level with its top, or right of it when the
// left has no room; kept on screen, even when that means covering the menu. The side is decided once per opening and
// the panel only widens within one, so a row tip placed left of it stays clear of it.
- (void)applyInfoValues
{
  if (!infoPlaced || (infoPanel == nil))
  {
    return;
  }

  NSArray<NSArray<NSString*>*>* rows = [self infoRowsWithStarts:nil];
  NSUInteger count = MIN(rows.count, infoValues.count);
  CGFloat labelWidth = 0.0;
  CGFloat valueWidth = 0.0;
  for (NSUInteger i=0; i<count; i++)
  {
    infoLabels[i].stringValue = rows[i][0];
    infoValues[i].stringValue = rows[i][1];
    [infoValues[i] sizeToFit];
    [infoLabels[i] sizeToFit];
    labelWidth = MAX(labelWidth, NSWidth(infoLabels[i].frame));
    valueWidth = MAX(valueWidth, NSWidth(infoValues[i].frame));
  }
  CGFloat width = ceil(INFO_INSET + labelWidth + INFO_COLUMN_GAP + valueWidth + INFO_INSET);
  bool widened = (width > infoWidth);
  width = MAX(width, infoWidth);
  infoWidth = width;
  CGFloat height = (CGFloat)infoValues.count * INFO_ROW_HEIGHT + (CGFloat)infoSeparators.count * INFO_SEPARATOR_HEIGHT + 2.0 * INFO_VERTICAL_INSET;

  for (NSUInteger i=0; i<count; i++)
  {
    // below the separators of the sections that start at this row or above it
    CGFloat gaps = (CGFloat)[infoSeparatorRows countOfIndexesInRange:NSMakeRange(0, i + 1)];
    CGFloat y = height - INFO_VERTICAL_INSET - (CGFloat)(i + 1) * INFO_ROW_HEIGHT - gaps * INFO_SEPARATOR_HEIGHT;
    NSRect label = infoLabels[i].frame;
    infoLabels[i].frame = NSMakeRect(INFO_INSET, y + floor((INFO_ROW_HEIGHT - NSHeight(label))/2.0), NSWidth(label), NSHeight(label));
    NSRect value = infoValues[i].frame;
    infoValues[i].frame = NSMakeRect(width - INFO_INSET - valueWidth, y + floor((INFO_ROW_HEIGHT - NSHeight(value))/2.0), valueWidth, NSHeight(value));
  }

  // each a line through the middle of the gap above its section's first row, inset as the rows' text
  __block NSUInteger separator = 0;
  [infoSeparatorRows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL* stop) {
    CGFloat line = height - INFO_VERTICAL_INSET - (CGFloat)row * INFO_ROW_HEIGHT - ((CGFloat)separator + 0.5) * INFO_SEPARATOR_HEIGHT;
    infoSeparators[separator].frame = NSMakeRect(INFO_INSET, floor(line), width - 2.0 * INFO_INSET, 1.0);
    separator++;
  }];

  NSRect menuFrame = infoMenuWindow.frame;
  NSScreen* screen = infoMenuWindow.screen ?: [NSScreen mainScreen];
  NSRect visible = screen.visibleFrame;
  if (!infoSideDecided)
  {
    infoSideDecided = true;
    bool leftFits = (NSMinX(menuFrame) - ROW_TIP_GAP - width) >= NSMinX(visible);
    bool rightFits = (NSMaxX(menuFrame) + ROW_TIP_GAP + width) <= NSMaxX(visible);
    // neither: left, clamped onto the screen below
    infoOnLeft = leftFits || !rightFits;
  }
  NSRect frame = NSMakeRect(0, 0, width, height);
  frame.origin.x = infoOnLeft ? (NSMinX(menuFrame) - ROW_TIP_GAP - width) : (NSMaxX(menuFrame) + ROW_TIP_GAP);
  frame.origin.y = NSMaxY(menuFrame) - height;
  frame.origin.x = MIN(MAX(frame.origin.x, NSMinX(visible)), NSMaxX(visible) - width);
  frame.origin.y = MIN(MAX(frame.origin.y, NSMinY(visible)), NSMaxY(visible) - height);
  [infoPanel setFrame:frame display:YES];
  infoGlass.contentView.frame = infoGlass.bounds;

  if (widened && (rowTipMenuWindow != nil) && rowTip.isVisible)
  {
    [self placeRowTip];
  }
}

- (void)hideInfoPanel
{
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(showInfoPanel) object:nil];
  [infoTimer invalidate];
  infoTimer = nil;
  infoGeneration++;
  infoPlaced = false;
  infoMenuWindow = nil;
  [infoPanel orderOut:nil];
}

// how full the startup volume is, from its free space as Finder shows it (purgeable space included), read off the
// main thread: one read takes tens of milliseconds. One read at a time; a read for an earlier opening is kept but not
// shown.
- (void)readDisk
{
  if (diskReadInFlight)
  {
    return;
  }
  diskReadInFlight = true;
  lastDiskRead = [[NSProcessInfo processInfo] systemUptime];
  lastDiskAttempt = lastDiskRead;
  NSUInteger generation = infoGeneration;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    // a new URL each time: an NSURL keeps the resource values it has read
    NSURL* root = [NSURL fileURLWithPath:@"/" isDirectory:YES];
    NSDictionary<NSURLResourceKey, id>* volume = [root resourceValuesForKeys:@[NSURLVolumeAvailableCapacityForImportantUsageKey, NSURLVolumeTotalCapacityKey] error:NULL];
    NSNumber* available = volume[NSURLVolumeAvailableCapacityForImportantUsageKey];
    NSNumber* total = volume[NSURLVolumeTotalCapacityKey];
    dispatch_async(dispatch_get_main_queue(), ^{
      diskReadInFlight = false;
      if ((available == nil) || (total == nil))
      {
        lastDiskRead = 0.0; // the next tick tries again
        static bool logged = false;
        if (!logged)
        {
          logged = true;
          NSLog(@"the startup volume's free space could not be read: the disk row keeps its last value");
        }
        return;
      }
      NSLocale* locale = [NSLocale currentLocale];
      uint64_t wholeBytes = total.unsignedLongLongValue;
      uint64_t freeBytes = available.unsignedLongLongValue;
      diskTitle = TotalTitle(GBText(wholeBytes, locale), @"Disk usage:");
      diskText = PercentText((wholeBytes > freeBytes) ? (wholeBytes - freeBytes) : 0, wholeBytes, locale);
      diskFraction = (wholeBytes > 0) ? ((double)((wholeBytes > freeBytes) ? (wholeBytes - freeBytes) : 0) / (double)wholeBytes) : -1.0;
      if (generation == infoGeneration)
      {
        [self applyInfoValues];
      }
    });
  });
}

@end
