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
#import <cxxabi.h>

#import "AppDelegate.h"

#import "CpuSampler.h"
#import "CpuRenderer.h"
#import "Top.h"

#pragma mark Constants

//#define GENERATE_THEME_IMAGE
#ifdef GENERATE_THEME_IMAGE
  #warning "GENERATE_THEME_IMAGE !"
#endif

#define TOP_COUNT                   (15)
#define TOP_REFRESH_RATE            (2.5)

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
static NSString* LaunchOnStartupKey = @"LaunchOnStartupKey";

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

static void imageFree(CFAllocatorRef allocator, const void *value)
{
  NSImage* image = (__bridge NSImage*)value;
  CFBridgingRelease((__bridge CFTypeRef _Nullable)(image));
}

static const void* imageRetain(CFAllocatorRef allocator, const void *value)
{
  NSImage* string = (__bridge NSImage*)value;
  return CFBridgingRetain(string);
}

static Boolean imageEqual(const void *value1, const void *value2)
{
  NSImage* image1 = (__bridge NSImage*)value1;
  NSImage* image2 = (__bridge NSImage*)value2;
  return [image1 isEqualTo:image2];
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
static CFMutableDictionaryRef topNameHashTable;
static CFMutableDictionaryRef topCpuHashTable;
static CFMutableDictionaryRef topIconHashTable;

static bool refreshTop = false;

static CGFloat tickHeight = 16.0;
static CGFloat tickWidth = 3.0;
static CGFloat tickSpaceWidth = 1.0;
static CGFloat tickTotalWidth = 0.0;
static CGFloat imageWidth = 0.0;

static int granularity = 0;

static bool bar = true;

static bool stripped = true;

static bool colored = false;
static int theme = THEME_YELLOW;

static float speed = 1.0f;

static bool launch = false;

static NSDictionary* attributesStandard = nil;
static NSDictionary* attributesGrey = nil;
static NSDictionary* attributesWhite = nil;

static double spaceWidth = 0.0;

static NSNumber *current_process_pid = nil;
static NSString *current_process_path = nil;

volatile static BOOL fillLsofForProcessInProgress = NO;
volatile static BOOL fillNmForProcessInProgress = NO;
volatile static BOOL fillThreadsForProcessInProgress = NO;

- (NSFileHandle*)launch:(NSTask *)task
{
  NSPipe *oPipe = [NSPipe pipe];
  [task setStandardOutput:oPipe];

  //[task setStandardError:ePipe];
  //NSPipe *ePipe = [[NSPipe alloc] init];

  //NSError *error = nil;
  if ([task launchAndReturnError:nil])
  {
    return [oPipe fileHandleForReading];
  }
  else
  {
    return nil;
  }
}

- (void)launchAppAt:(NSString*)path with:(NSArray<NSString *> *)arguments
{
#if 1
  [[NSWorkspace sharedWorkspace] launchApplication:path];
#else
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
    else
    {
      //NSLog(@"launchAppAt OK");
    }
  }];
#endif
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
  imageWidth = count * tickTotalWidth;
  if (bar == NO)
  {
    imageWidth += 1.0;
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

- (NSString*)getStringForName:(char*)name pid:(pid_t)pid width:(CGFloat)target
{
  const void* key = (const void *)(uintptr_t)pid;
  if (key == NULL)
  {
    key = (const void*)0xffffffff;
  }
  if (!CFDictionaryContainsKey(topNameHashTable, key))
  {
    NSMutableString* string = [NSMutableString stringWithFormat:@"%s", name];
    int count = [self getSpacesCountFor:string width:target];
    if (count <= 0)
    {
      [string deleteCharactersInRange:NSMakeRange([string length]-SIZE_DOTS, SIZE_DOTS)];
      [string insertString:[NSString stringWithCharacters:&dots[0] length:SIZE_DOTS] atIndex:[string length]];
      while (count <= 0)
      {
        [string deleteCharactersInRange:NSMakeRange([string length]-SIZE_DOTS, 1)];
        count = [self getSpacesCountFor:string width:target];
      }
    }

    size_t length = [string length];
    if (length > SIZE_SPACES)
    {
      length = SIZE_SPACES;
    }
    [string insertString:[NSString stringWithCharacters:&spaces[0] length:count] atIndex:length];

    CFDictionarySetValue(topNameHashTable, key, (__bridge const void *)(string));
  }
  return (NSString*)CFDictionaryGetValue(topNameHashTable, key);
  //return [NSString stringWithFormat:@"%--s %*c %6.1f%%", name, spaces, SPACE_THIN, cpu];
}

- (NSImage*)getIconForPid:(pid_t)pid size:(NSSize)size
{
  const void* key = (const void *)(uintptr_t)pid;
  if (key == NULL)
  {
    key = (const void*)0xffffffff;
  }
  if (!CFDictionaryContainsKey(topIconHashTable, key))
  {
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSImage* appIcon = [app icon];
    if (appIcon == nil)
    {
      //NSImage* appIcon = [[NSWorkspace sharedWorkspace] iconForFile:[NSString stringWithFormat:@"%s", path]];
      static NSImage* defaultIcon = nil;
      if (defaultIcon == nil)
      {
#if 0
        char buffer[4096+1];
        snprintf(&buffer[0], 4096, "%s/%s", SYSTEM_ICONS_RSRC, PROCESS_DEFAULT_ICON_NAME);
        defaultIcon = [[NSImage alloc] initWithContentsOfFile:[NSString stringWithFormat:@"%s", buffer]];
#else
        defaultIcon = [[NSImage alloc] initWithSize:size];
#endif
      }
      appIcon = defaultIcon;
    }
    
    if (appIcon != nil)
    {
      [appIcon setSize:size];

      CFDictionarySetValue(topIconHashTable, key, (__bridge const void *)(appIcon));
    }
  }
  return (NSImage*)CFDictionaryGetValue(topIconHashTable, key);
}

- (void)updateMenuTopFor:(NSMenuItem*)item name:(char*)name pid:(pid_t)pid path:(char*)path cpu:(double)cpu width:(CGFloat)target
{
  NSString* stringName = [self getStringForName:name pid:pid width:target];
  NSString* stringCpu = [self getStringForCpu:cpu width:CPU_STR_SPACE_TARGET];
  [item setTitle: [NSString stringWithFormat:@"%@ %@", stringName, stringCpu]];
  
  NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:[item title] attributes:attributesGrey];
  [title setAttributes:attributesWhite range:NSMakeRange([stringName length], [stringCpu length]+1)];

  
  [item setAttributedTitle:title];
  [item setImage:[self getIconForPid:pid size:NSMakeSize(MENU_ICON_SIZE, MENU_ICON_SIZE)]];
  
  //NSSize size = [[item title] sizeWithAttributes:attributesGrey];
  //return size.width;
}

- (void)updateMenuTop
{
  for (int i=0; i<TOP_COUNT; i++)
  {
    //NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    //NSString *fullPath = [ws fullPathForApplication:[path lastPathComponent]];
    //NSImage *appIcon = [ws iconForFileType:NSFileTypeForHFSTypeCode(kGenericApplicationIcon)];
    
    TopProcessSample_t* sample = &topProcceses[i];
    [self updateMenuTopFor:topMenus[i] name:sample->name pid:sample->pid path:NULL cpu:sample->cpu width:NAME_STR_SPACE_TARGET];
    [topMenus[i] setTag:sample->pid];
  }
  
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
    item = [menu addItemWithTitle:@"TOP CPU PROCESSES" action:nil keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandardCenter]];
    for (int i=0; i<TOP_COUNT; i++)
    {
      topMenus[i] = [menu addItemWithTitle:@"" action:@selector(selectPid:) keyEquivalent:@""];
    }
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
  }

  [menu addItem:[NSMenuItem separatorItem]];

  {
    NSMenuItem* item = [menu addItemWithTitle:@"Open upMonitor Preferences..." action:@selector(openPreferences:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
    //NSImage* appIcon = [NSImage imageNamed:@"AppIcon"];
    NSImage* appIcon = [NSImage imageNamed:@"NSPreferencesGeneral"];
    [appIcon setSize:NSMakeSize(MENU_ICON_SIZE+2.0, MENU_ICON_SIZE+2.0)];
    [item setImage:appIcon];
  }
  
  [menu addItem:[NSMenuItem separatorItem]];
  
  {
    NSMenuItem* item = [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@""];
    [item setAttributedTitle:[[NSAttributedString alloc] initWithString:[item title] attributes:attributesStandard]];
  }
  
  self.statusItem.menu = menu;
}

- (bool)isLight
{
  static NSAppearance* darkAppearance = nil;
  if (darkAppearance == nil)
  {
    darkAppearance = [NSAppearance appearanceNamed:@"NSAppearanceNameDarkAqua"];
  }

  NSAppearance* appearance = [NSApp effectiveAppearance];
  if (appearance == darkAppearance)
  {
    return false;
  }
  else
  {
    return true;
  }
}

- (void)renderMenubarWithLight:(BOOL)light
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
      CpuRender(&cpu_info, ctx, light, granularity, bar, stripped, colored, tickWidth, tickTotalWidth, imageWidth, theme);
    }
    [image unlockFocus];
  }
  self.statusItem.button.image = image;
}

- (void)renderPrefsRealWithLight:(BOOL)light
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
      CpuRender(&cpu_info, ctx, light, granularity, bar, stripped, colored, tickWidth, tickTotalWidth, imageWidth, theme);
    }
    [image unlockFocus];
  }
  self.realDemoView.image = image;
}

- (void)renderPrefsSinWithLight:(BOOL)light
{
  CpuSamplerSineDemoUpdate(&cpu_sine_demo_info, speed);

  [self.sineDemoView setBoundsSize:NSMakeSize(imageWidth, tickHeight)];
  [self.sineDemoView setFrameSize:NSMakeSize(imageWidth, tickHeight)];
  NSRect imgFrame = [self.sineDemoView frame];
  [self.sineDemoView setFrameOrigin:NSMakePoint((int)(([self.window frame].size.width-imageWidth)/2.0), imgFrame.origin.y)];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, tickHeight)];
    }
//    else
//    {
//      image = self.sineDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_sine_demo_info, ctx, light, granularity, bar, stripped, colored, tickWidth, tickTotalWidth, imageWidth, theme);
    }
    [image unlockFocus];
  }
  self.sineDemoView.image = image;
}

- (void)renderPrefsFlatWithLight:(BOOL)light
{
  CpuSamplerFlatDemoUpdate(&cpu_flat_demo_info, speed);
  
  [self.flatDemoView setBoundsSize:NSMakeSize(imageWidth, tickHeight)];
  [self.flatDemoView setFrameSize:NSMakeSize(imageWidth, tickHeight)];
  NSRect imgFrame = [self.flatDemoView frame];
  [self.flatDemoView setFrameOrigin:NSMakePoint((int)((([self.window frame].size.width-imageWidth)/2.0)+125.0), imgFrame.origin.y)];
  static NSImage* image = nil;
  {
//    if (image == nil)
    {
      image = [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, tickHeight)];
    }
//    else
//    {
//      image = self.flatDemoView.image;
//    }
    
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRender(&cpu_flat_demo_info, ctx, light, granularity, bar, stripped, colored, tickWidth, tickTotalWidth, imageWidth, theme);
    }
    [image unlockFocus];
  }
  self.flatDemoView.image = image;
}

- (void)updateCPU:(id)sender
{
  bool light = [self isLight];
  [self updateRendererParameters];
  
  [self renderMenubarWithLight:light];
  if ([self.window isVisible])
  {
    [self renderPrefsRealWithLight:light];
    [self renderPrefsSinWithLight:light];
    [self renderPrefsFlatWithLight:light];
  }
  
#ifdef GENERATE_THEME_IMAGE
  static BOOL doit = YES;
  if (doit)
  {
    int width = 64, height = 256;
    image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image lockFocus];
    {
      CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
      CpuRenderDemo(ctx, width, height, 0);
    }
    [image unlockFocus];
    {
      CGImageRef cgRef = [image CGImageForProposedRect:NULL context:nil hints:nil];
      NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
      [newRep setSize:[image size]];
      NSData *pngData = [newRep representationUsingType:NSBitmapImageFileTypePNG properties:@{NSImageCompressionFactor:@1.0}];
      NSError* error = nil;
      BOOL written = [pngData writeToFile:@"/Users/gerard/Downloads/img.png" options:NSDataWritingAtomic error:&error];
      if (!written)
      {
        NSLog(@"%@", error);
      }
    }
    doit = NO;
  }
#endif
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

- (void)updateTop:(id)sender
{
  if (refreshTop)
  {
    TopSample();
    int counter = 0;
    const TopProcessSample_t *psample = TopIterate();
    while (psample != NULL)
    {
      //if (psample->pid > 1)
      {
        topProcceses[counter] = *psample;
        //printf("   %6d %30s %5.1f%% %20s\n", psample->pid, psample->name, psample->cpu, TopGetUsername(psample->uid));
        if (++counter >= TOP_COUNT)
        {
          break;
        }
      }
      psample = TopIterate();
    }
    //printf("\n");
    [self performSelectorOnMainThread:@selector(updateMenuTop) withObject:nil waitUntilDone:YES];
  }
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

- (void)setupPreferences
{
#if 0
  [self removeUserDefaults];
#endif
  
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{GranularityKey:@2}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{RefreshKey:@0.1}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{StyleKey:@1}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{TickLineKey:@1}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{TickWidthKey:@3.0}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{AppearanceKey:@1}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{ThemeKey:@2}];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{LaunchOnStartupKey:@0}];

  granularity = (int)[[NSUserDefaults standardUserDefaults] integerForKey:GranularityKey];
  speed = 10.0 * [[NSUserDefaults standardUserDefaults] doubleForKey:RefreshKey];
  bar = [[NSUserDefaults standardUserDefaults] boolForKey:StyleKey];
  stripped = [[NSUserDefaults standardUserDefaults] boolForKey:TickLineKey];
  tickWidth = [[NSUserDefaults standardUserDefaults] doubleForKey:TickWidthKey];
  colored = [[NSUserDefaults standardUserDefaults] boolForKey:AppearanceKey];
  theme = (int)[[NSUserDefaults standardUserDefaults] integerForKey:ThemeKey];
  launch = [[NSUserDefaults standardUserDefaults] boolForKey:LaunchOnStartupKey];

  [self updateRendererParameters];
  [self updateUI];
}

- (void)setupTimers
{
  [timerCPU invalidate];
  timerCPU = nil;
  timerCPU = [NSTimer scheduledTimerWithTimeInterval:[[NSUserDefaults standardUserDefaults] doubleForKey:RefreshKey] target:self selector:@selector(updateCPU:) userInfo:nil repeats:YES];
  [[NSRunLoop currentRunLoop] addTimer:timerCPU forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:timerCPU forMode:NSModalPanelRunLoopMode];

  [timerTop invalidate];
  timerTop = nil;
  timerTop = [NSTimer scheduledTimerWithTimeInterval:TOP_REFRESH_RATE target:self selector:@selector(updateTop:) userInfo:nil repeats:YES];
  [[NSRunLoop currentRunLoop] addTimer:timerTop forMode:NSEventTrackingRunLoopMode];
  [[NSRunLoop currentRunLoop] addTimer:timerTop forMode:NSModalPanelRunLoopMode];
}

- (BOOL)fillDescForProcess:(NSString*)name
{
  BOOL found = NO;
  {
    // https://developer.apple.com/documentation/foundation/nstask
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/man"];
    [task setArguments:[NSArray arrayWithObjects:@"-P", @"col -bx", name, nil]];
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task launch];
    if ([task isRunning])
    {
      [task waitUntilExit];
    }
    NSData *data = [[pipe fileHandleForReading] availableData];
    if ([data length] > 0)
    {
      NSString *output = [NSString stringWithFormat:@"\n%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
      [self.procDescTextView setString:output];
      found = YES;
    }
  }
  return found;
}

- (BOOL)fillArgsEnvForProcess:(TopProcessInfo_t*) info
{
  BOOL found = NO;

  if (info->args_count > 0)
  {
    NSString *output = [NSString stringWithFormat:@"\nCOMMAND:\n\n%s\n\n\nARGUMENTS: (%d)\n\n%s\n\nENVIRONMENT: (%d)\n\n%s\n",
                        info->command, info->args_count, info->args_info, info->envs_count, info->envs_info];
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

- (void)fillLsofForProcess:(NSNumber*)pid_number
{
//  if (fillLsofForProcessInProgress)
//  {
//    return;
//  }
  fillLsofForProcessInProgress = YES;

  NSString *appPath = @"/usr/sbin/lsof";
  pid_t pid = [pid_number intValue];
  NSArray<NSString *> *arguments = [NSArray arrayWithObjects:@"-p", [NSString stringWithFormat:@"%d", pid], nil];
  //NSArray<NSString *> *arguments = @[];

  {
    // https://developer.apple.com/documentation/foundation/nstask
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:appPath];
    [task setArguments:arguments];
    
    NSFileHandle *outputFileHandle = [self launch:task];
    if (outputFileHandle != nil)
    {
      if ([task isRunning])
      {
        [task waitUntilExit];
      }
      NSData *outputData = [outputFileHandle readDataToEndOfFile];
      NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
      [self.procLsofTextView performSelectorOnMainThread:@selector(setString:) withObject:output waitUntilDone:NO];
    }
    else
    {
      [self.procLsofTextView performSelectorOnMainThread:@selector(setString:) withObject:@"N/A (error)" waitUntilDone:NO];
    }
    
    [task terminate];
  }
  
  fillLsofForProcessInProgress = NO;
}

- (void)demangleString:(NSString*)string
{
#if 0
  //NSLog(@"demangleString: %@", string);
  NSString* sofar = @"";
  
  NSArray *lines = [string componentsSeparatedByString:@"\n"];
  for (int i=0; i<[lines count]; i++)
  {
    NSString* line = [lines objectAtIndex:i];
    NSArray* tokens = [line componentsSeparatedByString:@" "];
    int count = (int)[tokens count];
    if (count > 1)
    {
      NSString* mangled = [tokens objectAtIndex:(count-1)];
      int offset = (int)[line length] - (int)[mangled length];
      
      int status = 0;
      const char* mangled_cstr = [mangled UTF8String];

      static char* unmangled_cstr = NULL;
      if (unmangled_cstr == NULL)
      {
        unmangled_cstr = (char*)realloc(unmangled_cstr, 128);
      }
      abi::__cxa_demangle(mangled_cstr, unmangled_cstr, NULL, &status);
      if (status == 0)
      {
        sofar = [sofar stringByAppendingString:[NSString stringWithFormat:@"%@%s\n", [line substringToIndex:offset], unmangled_cstr]];
      }
      else
      {
        if (mangled_cstr[0] == '_')
        {
          sofar = [sofar stringByAppendingString:[NSString stringWithFormat:@"%@%s\n", [line substringToIndex:offset], &mangled_cstr[1]]];
        }
        else
        {
          sofar = [sofar stringByAppendingString:[NSString stringWithFormat:@"%@\n", line]];
        }
      }
    }
    else
    {
      sofar = [sofar stringByAppendingString:@"\n"];
    }
  }
  [self.procNmTextView setString:sofar];
#else
  NSTextStorage *textStorage = [self.procNmTextView textStorage];
  [textStorage beginEditing];
  [self.procNmTextView setString:string];
  [textStorage endEditing];
#endif
}

- (void)fillNmForProcess:(NSString*)path
{
  if (fillNmForProcessInProgress)
  {
    return;
  }
  fillNmForProcessInProgress = YES;

  NSString *appPath = @"/usr/bin/nm";
  NSArray<NSString *> *arguments = [NSArray arrayWithObjects:path, nil];
  //NSArray<NSString *> *arguments = @[];

  {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:appPath];
    [task setArguments:arguments];
    
    NSFileHandle *outputFileHandle = [self launch:task];
    if (outputFileHandle != nil)
    {
      if ([task isRunning])
      {
        [task waitUntilExit];
      }
      NSData *outputData = [outputFileHandle readDataToEndOfFile];
      NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
      [self.procNmTextView performSelectorOnMainThread:@selector(setString:) withObject:output waitUntilDone:NO];
      //[self performSelectorOnMainThread:@selector(demangleString:) withObject:output waitUntilDone:NO];
    }
    else
    {
      [self.procNmTextView performSelectorOnMainThread:@selector(setString:) withObject:@"N/A (error)" waitUntilDone:NO];
    }

    [task terminate];
  }
  
  fillNmForProcessInProgress = NO;
}

- (void)fillThreadsForProcess:(NSNumber*)pid_number
{
  if (fillThreadsForProcessInProgress)
  {
    return;
  }
  fillThreadsForProcessInProgress = YES;
  
  NSString *appPath = @"/usr/bin/sample";
  pid_t pid = [pid_number intValue];
  NSArray<NSString *> *arguments = [NSArray arrayWithObjects:[NSString stringWithFormat:@"%d", pid], nil];
  //NSArray<NSString *> *arguments = @[];

  {
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:appPath];
    [task setArguments:arguments];
    
    NSFileHandle *outputFileHandle = [self launch:task];
    if (outputFileHandle != nil)
    {
      int wait = 10;
      for (int i=0; i<=wait; i++)
      {
        [NSThread sleepForTimeInterval:1];
        NSString *string = [NSString stringWithFormat:@"\nsampling ends in %d seconds ...", (10-i)];
        [self.procThreadsTextView performSelectorOnMainThread:@selector(setString:) withObject:string waitUntilDone:NO];
      }
      
//      while ([task isRunning])
//      {
//        [NSThread sleepForTimeInterval:1];
//        NSString *string = [NSString stringWithFormat:@"\nstill sampling ..."];
//        [self.procThreadsTextView performSelectorOnMainThread:@selector(setString:) withObject:string waitUntilDone:NO];
//      }
      
      NSData *outputData = [outputFileHandle readDataToEndOfFile];
      NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
      [self.procThreadsTextView performSelectorOnMainThread:@selector(setString:) withObject:output waitUntilDone:NO];
    }
    else
    {
      [self.procThreadsTextView performSelectorOnMainThread:@selector(setString:) withObject:@"N/A (error)" waitUntilDone:NO];
    }
    
    [task terminate];
  }
  
  fillThreadsForProcessInProgress = NO;
}

#pragma mark - Public APIs

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
  srandom((int)time(NULL)^getpid());
  
  {
    {
      CFDictionaryValueCallBacks tableCallbacks = { 0, stringRetain, stringFree, NULL, stringEqual };
      topNameHashTable = CFDictionaryCreateMutable(NULL, 0, NULL, &tableCallbacks);
      topCpuHashTable = CFDictionaryCreateMutable(NULL, 0, NULL, &tableCallbacks);
    }
    
    {
      CFDictionaryValueCallBacks tableCallbacks = { 0, imageRetain, imageFree, NULL, imageEqual };
      topIconHashTable = CFDictionaryCreateMutable(NULL, 0, NULL, &tableCallbacks);
    }
    
    CpuRenderInit();
    CpuSamplerInit(&cpu_info);
    CpuSamplerSineDemoInit(&cpu_sine_demo_info);
    CpuSamplerSineDemoInit(&cpu_flat_demo_info);
    TopInit();
    
    [self setupPreferences];
    [self setupStatusItem];
    [self setupMenus];
    [self setupTimers];
    
    refreshTop = true;
    {
      [timerTop fire];
    }
    refreshTop = false;
  }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
  //[[NSUserDefaults standardUserDefaults] synchronize];
}

- (IBAction)openPreferences:(id)sender
{
  [NSApp activateIgnoringOtherApps:YES];
  
  [self.window center];
  [self.window orderFrontRegardless];
  [self.window makeKeyWindow];
}

- (void)processExplorer:(id)sender
{
  NSLog(@"processExplorer");
}

+ (void)runBlock:(void (^)())block
{
    block();
}

+ (void)runAfterDelay:(CGFloat)delay block:(void (^)())block
{
    void (^block_)() = [block copy];
    [self performSelector:@selector(runBlock:) withObject:block_ afterDelay:delay];
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
  current_process_pid = [NSNumber numberWithInt:pid];
    
  NSImage *icon = [[NSImage alloc] initWithData:[[self getIconForPid:pid size:NSMakeSize(MENU_ICON_SIZE, MENU_ICON_SIZE)] TIFFRepresentation]];
  [icon setSize:NSMakeSize(TOP_ICON_SIZE, TOP_ICON_SIZE)];
  [self.procAppIcon setImage:icon];
  
  TopProcessInfo_t* info = TopGetArgs(pid);
  TopProcessSample_t* sample = TopGetSample(pid);
  current_process_path = [NSString stringWithFormat:@"%s", info->command];
  NSString* name = [NSString stringWithFormat:@"%s", info->name];
  
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

  [self.procAppName setStringValue:[NSString stringWithFormat:@"%s, pid:%d, ppid:%d, prio:%d, stat:%d (%s), flags:%d (%s)",
                                    sample->name, sample->pid, sample->ppid, sample->tprio, sample->status, status_str, sample->flags, bits_str]];

  [self.procDescTextView performSelectorOnMainThread:@selector(setString:) withObject:@"\npreparing..." waitUntilDone:NO];
  [self.procArgsEnvTextView performSelectorOnMainThread:@selector(setString:) withObject:@"\npreparing..." waitUntilDone:NO];
  [self.procLsofTextView performSelectorOnMainThread:@selector(setString:) withObject:@"\npreparing..." waitUntilDone:NO];
  [self.procNmTextView performSelectorOnMainThread:@selector(setString:) withObject:@"\npreparing..." waitUntilDone:NO];
  [self.procThreadsTextView performSelectorOnMainThread:@selector(setString:) withObject:@"\npreparing..." waitUntilDone:NO];

  //if ([self.top isVisible] == NO)
  {
    [NSApp activateIgnoringOtherApps:YES];
    [self.top center];
    [self.top orderFrontRegardless];
    [self.top makeKeyWindow];
  }
  
  [self.procAppView selectFirstTabViewItem:self];
  
  [AppDelegate runAfterDelay:1 block:^{
    [self fillArgsEnvForProcess:info];
    if ([self fillDescForProcess:name])
    {
      [self.procAppView removeTabViewItem:descriptionTab];
      [self.procAppView insertTabViewItem:descriptionTab atIndex:0];
      //[self.procAppView selectTabViewItem:descriptionTab];
    }
    else
    {
      [self.procAppView removeTabViewItem:descriptionTab];
    }
  }];
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
  [self setupTimers];
}

- (IBAction)normalButtonClicked:(id)sender
{
  speed = 2.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.2 forKey:RefreshKey];

  [self updateUI];
  [self setupTimers];
}

- (IBAction)slowButtonClicked:(id)sender
{
  speed = 5.0f;

  [[NSUserDefaults standardUserDefaults] setDouble:0.5 forKey:RefreshKey];

  [self updateUI];
  [self setupTimers];
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
  tickWidth = 3.0;
  [[NSUserDefaults standardUserDefaults] setBool:bar forKey:StyleKey];
  [[NSUserDefaults standardUserDefaults] setDouble:tickWidth forKey:TickWidthKey];

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

- (IBAction)kofi:(id)sender
{
  NSURL *url = [NSURL URLWithString:@"https://ko-fi.com/halfmarble"];
  [[NSWorkspace sharedWorkspace] openURL:url];
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
  refreshTop = true;
}

- (void)menuDidClose:(NSMenu *)menu
{
  refreshTop = false;
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(nullable NSTabViewItem *)tabViewItem
{
  
  switch ([[tabViewItem identifier] intValue])
  {
    case 3:
    {
      [self performSelectorInBackground:@selector(fillLsofForProcess:) withObject:current_process_pid];
      break;
    }
    case 4:
    {
      [self performSelectorInBackground:@selector(fillNmForProcess:) withObject:current_process_path];
      break;
    }
    case 5:
    {
      [self performSelectorInBackground:@selector(fillThreadsForProcess:) withObject:current_process_pid];
      break;
    }
    default:
      break;
  }
}

@end
