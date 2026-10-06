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
#import <ctype.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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
#define TOP_TOOL_ROWS               (2*TOP_COUNT) // headroom: 2x the rows shown

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

// macOS 27 hides menu item images unless an item asks for them
static void ShowMenuItemImage(NSMenuItem* item)
{
  if (@available(macOS 27.0, *))
  {
    item.preferredImageVisibility = NSMenuItemImageVisibilityVisible;
  }
}

#pragma mark - /usr/bin/top reader

// One /usr/bin/top run per menu opening. Its lines are parsed on the file handle's background queue;
// only complete blocks of (pid, cpu) rows reach the main thread.
@interface TopToolSession : NSObject
{
@public
  NSUInteger generation;
  NSTask* task;
  NSMutableData* pending;       // bytes after the last newline
  int blocks;                   // "PID" header lines seen; block 1 is all zeros and is dropped
  bool inBlock;
  int rows;
  pid_t pids[TOP_TOOL_ROWS];
  double cpus[TOP_TOOL_ROWS];
  bool loggedExit;
  bool loggedEmpty;
}
@end

@implementation TopToolSession
@end

// a row is exactly: spaces, pid, spaces, cpu (digits with an optional fraction), spaces
static bool ParseTopRow(const char* s, pid_t* pid, double* cpu)
{
  while (isspace((unsigned char)*s)) s++;
  if (!isdigit((unsigned char)*s)) return false;
  long long p = 0;
  while (isdigit((unsigned char)*s))
  {
    p = (p * 10) + (*s++ - '0');
    if (p > INT_MAX) return false;
  }
  if (!isspace((unsigned char)*s)) return false;
  while (isspace((unsigned char)*s)) s++;
  if (!isdigit((unsigned char)*s)) return false;
  double value = 0.0;
  while (isdigit((unsigned char)*s))
  {
    value = (value * 10.0) + (*s++ - '0');
  }
  if (*s == '.')
  {
    s++;
    if (!isdigit((unsigned char)*s)) return false;
    double scale = 0.1;
    while (isdigit((unsigned char)*s))
    {
      value += (*s++ - '0') * scale;
      scale /= 10.0;
    }
  }
  while (isspace((unsigned char)*s)) s++;
  if (*s != '\0') return false;
  *pid = (pid_t)p;
  *cpu = value;
  return true;
}

// feeds one line to the parser; calls block() for every complete block after the first
static void TopToolParseLine(TopToolSession* session, const char* line, void (^block)(NSData* pids, NSData* cpus), void (^empty)(void))
{
  pid_t pid;
  double cpu;
  if (strncmp(line, "PID", 3) == 0)
  {
    session->blocks++;
    session->inBlock = true;
    session->rows = 0;
  }
  else if (strncmp(line, "Processes:", 10) == 0)
  {
    if (session->inBlock && (session->blocks > 1))
    {
      if (session->rows > 0)
      {
        block([NSData dataWithBytes:session->pids length:session->rows * sizeof(pid_t)], [NSData dataWithBytes:session->cpus length:session->rows * sizeof(double)]);
      }
      else
      {
        empty();
      }
    }
    session->inBlock = false;
  }
  else if (session->inBlock && ParseTopRow(line, &pid, &cpu))
  {
    session->pids[session->rows] = pid;
    session->cpus[session->rows] = cpu;
    session->rows++;
    if (session->rows == TOP_TOOL_ROWS)
    {
      if (session->blocks > 1)
      {
        block([NSData dataWithBytes:session->pids length:session->rows * sizeof(pid_t)], [NSData dataWithBytes:session->cpus length:session->rows * sizeof(double)]);
      }
      session->inBlock = false;
    }
  }
}

static void TopToolConsume(TopToolSession* session, NSData* data, void (^block)(NSData* pids, NSData* cpus), void (^empty)(void))
{
  [session->pending appendData:data];
  const char* bytes = (const char*)[session->pending bytes];
  NSUInteger length = [session->pending length];
  NSUInteger start = 0;
  for (NSUInteger i=0; i<length; i++)
  {
    if (bytes[i] == '\n')
    {
      char line[256];
      NSUInteger n = MIN(i - start, sizeof(line) - 1);
      memcpy(line, &bytes[start], n);
      line[n] = '\0';
      TopToolParseLine(session, line, block, empty);
      start = i + 1;
    }
  }
  [session->pending replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
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

// decoded like the menu row decodes it ("%s"), which never fails: the kernel cuts names at a byte
// limit, so a name can end in half a UTF-8 character
static NSString* SampleText(const char* name)
{
  return [NSString stringWithFormat:@"%s", name];
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
static bool topListValid = false;
static int topCount = 0;
static NSTimeInterval lastTopSample = 0.0;
#define TOP_MIN_INTERVAL (0.25)

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

// The inspector's tools (man, lsof, nm, sample) run on a background queue. Every selection bumps
// inspectGeneration, and a result that belongs to an older selection is dropped. The *Job values
// hold the generation of a tool still running for that tab (0 = none). Main thread only.
static NSUInteger inspectGeneration = 0;
static NSUInteger lsofJob = 0;
static NSUInteger nmJob = 0;
static NSUInteger threadsJob = 0;
static NSUInteger threadsRun = 0;
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
  NSString* shownName = [NSString stringWithFormat:@"%@%s", (decision.helper ? @"↳ " : @""), name];
  NSString* stringName = [self getStringForName:shownName width:target];
  NSString* stringCpu = [self getStringForCpu:cpu width:CPU_STR_SPACE_TARGET];
  [item setTitle: [NSString stringWithFormat:@"%@ %@", stringName, stringCpu]];
  
  NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:[item title] attributes:attributesGrey];
  [title setAttributes:attributesWhite range:NSMakeRange([stringName length], [stringCpu length]+1)];

  
  [item setAttributedTitle:title];
  [item setImage:decision.menuImage];
  [item setToolTip:decision.tooltip];
  
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
      ShowMenuItemImage(topMenus[i]);
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
    ShowMenuItemImage(item);
  }

  [menu addItem:[NSMenuItem separatorItem]];

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
      BOOL written = [pngData writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Downloads/img.png"] options:NSDataWritingAtomic error:&error];
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

// Samples on every tick, with the menu closed too (about 1-2 ms), so that the CPU% always covers the
// last interval and the list is current the moment the menu opens.
- (void)updateTop:(id)sender
{
  TopSample();
  lastTopSample = [[NSProcessInfo processInfo] systemUptime];
  topListValid = true;
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
    // other users' processes are ranked only while /usr/bin/top supplies their CPU (menu open)
    if (psample->cpu_known != 0)
    {
      topProcceses[counter++] = *psample;
    }
    psample = TopIterate();
  }
  topCount = counter;
}

#pragma mark - /usr/bin/top while the menu is open

static TopToolSession* topToolSession = nil;
static NSUInteger topToolGeneration = 0;

- (void)startTopTool
{
  [self stopTopTool];

  TopToolSession* session = [[TopToolSession alloc] init];
  session->generation = ++topToolGeneration;
  session->pending = [NSMutableData data];

  NSTask* task = [[NSTask alloc] init];
  [task setExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/top"]];
  [task setArguments:@[@"-l", @"0", @"-s", @"1", @"-o", @"cpu", @"-stats", @"pid,cpu", @"-n", [NSString stringWithFormat:@"%d", TOP_TOOL_ROWS]]];
  // the decimal separator is '.' whatever the user's locale
  NSMutableDictionary* environment = [NSMutableDictionary dictionaryWithObject:@"C" forKey:@"LC_ALL"];
  NSString* path = [[[NSProcessInfo processInfo] environment] objectForKey:@"PATH"];
  if (path != nil)
  {
    environment[@"PATH"] = path;
  }
  [task setEnvironment:environment];
  NSPipe* pipe = [NSPipe pipe];
  [task setStandardOutput:pipe];
  [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];

  NSUInteger generation = session->generation;
  [task setTerminationHandler:^(NSTask* t) {
    int status = [t terminationStatus];
    long reason = (long)[t terminationReason];
    dispatch_async(dispatch_get_main_queue(), ^{
      if ((topToolSession != nil) && (topToolSession->generation == generation) && !topToolSession->loggedExit)
      {
        topToolSession->loggedExit = true;
        NSLog(@"/usr/bin/top exited while the menu was open: status %d, reason %ld", status, reason);
      }
    });
  }];

  NSError* error = nil;
  if (![task launchAndReturnError:&error])
  {
    NSLog(@"could not launch /usr/bin/top: %@", error);
    return;
  }
  session->task = task;
  topToolSession = session;

  __weak AppDelegate* weakSelf = self;
  [[pipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle* handle) {
    NSData* data = [handle availableData];
    if ([data length] == 0)
    {
      // end of file: a handler left set would be called again and again
      [handle setReadabilityHandler:nil];
      return;
    }
    TopToolConsume(session, data, ^(NSData* pids, NSData* cpus) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf applyTopTool:session pids:pids cpus:cpus];
      });
    }, ^{
      dispatch_async(dispatch_get_main_queue(), ^{
        if ((topToolSession == session) && !session->loggedEmpty)
        {
          session->loggedEmpty = true;
          NSLog(@"/usr/bin/top printed a sample with no readable rows");
        }
      });
    });
  }];
}

- (void)applyTopTool:(TopToolSession*)session pids:(NSData*)pids cpus:(NSData*)cpus
{
  if ((topToolSession != session) || (session->generation != topToolGeneration))
  {
    return;
  }
  TopSetOthersCpu((const pid_t*)[pids bytes], (const double*)[cpus bytes], (int)([pids length] / sizeof(pid_t)));
  [self collectTopList];
  if (refreshTop)
  {
    [self updateMenuTop];
  }
}

- (void)stopTopTool
{
  topToolGeneration++;
  TopToolSession* session = topToolSession;
  topToolSession = nil;
  if (session != nil)
  {
    NSTask* task = session->task;
    [[[task standardOutput] fileHandleForReading] setReadabilityHandler:nil];
    [task setTerminationHandler:nil];
    // terminate on a task that never launched throws
    if ([task isRunning])
    {
      [task terminate];
    }
  }
  TopSetOthersCpu(NULL, NULL, 0);
  [self collectTopList];
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
  if ((pid_number == nil) || (lsofJob == inspectGeneration))
  {
    return;
  }
  NSUInteger generation = inspectGeneration;
  lsofJob = generation;

  [self runTool:@"/usr/sbin/lsof" arguments:@[@"-p", [pid_number stringValue]] withStderr:YES done:^(NSString* output) {
    if (lsofJob == generation)
    {
      lsofJob = 0;
    }
    [self.procLsofTextView setString:(output != nil) ? output : @"N/A (error)"];
  }];
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
  if ([path length] == 0)
  {
    // no executable path (kernel_task): nothing to run nm on
    [self.procNmTextView setString:@"N/A"];
    return;
  }
  if (nmJob == inspectGeneration)
  {
    return;
  }
  NSUInteger generation = inspectGeneration;
  nmJob = generation;

  // "--": a path starting with '-' must not be read as an option
  [self runTool:@"/usr/bin/nm" arguments:@[@"--", path] withStderr:YES done:^(NSString* output) {
    if (nmJob == generation)
    {
      nmJob = 0;
    }
    [self.procNmTextView setString:(output != nil) ? output : @"N/A (error)"];
  }];
}

- (void)fillThreadsForProcess:(NSNumber*)pid_number
{
  if ((pid_number == nil) || (threadsJob == inspectGeneration))
  {
    return;
  }
  NSUInteger generation = inspectGeneration;
  threadsJob = generation;
  NSUInteger run = ++threadsRun;

  // sample runs for 10 seconds by default: count down until its report arrives
  for (int i=0; i<=10; i++)
  {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)i * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if ((threadsRun == run) && (threadsJob == generation) && (inspectGeneration == generation))
      {
        [self.procThreadsTextView setString:[NSString stringWithFormat:@"\nsampling ends in %d seconds ...", (10-i)]];
      }
    });
  }

  [self runTool:@"/usr/bin/sample" arguments:@[[pid_number stringValue]] withStderr:YES done:^(NSString* output) {
    if (threadsJob == generation)
    {
      threadsJob = 0;
    }
    [self.procThreadsTextView setString:(output != nil) ? output : @"N/A (error)"];
  }];
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
    
    CpuRenderInit();
    CpuSamplerInit(&cpu_info);
    CpuSamplerSineDemoInit(&cpu_sine_demo_info);
    CpuSamplerSineDemoInit(&cpu_flat_demo_info);
    TopInit(); // takes the first sample: the CPU baseline
    lastTopSample = [[NSProcessInfo processInfo] systemUptime];

    [self setupPreferences];
    [self setupStatusItem];
    [self setupMenus];
    [self setupTimers];

    // room for the inspector's "Helper of:" line
    [self.procAppName setUsesSingleLineMode:NO];
    [self.procAppName setMaximumNumberOfLines:2];
  }
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
  [self stopTopTool];
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

  inspectGeneration++;
  [self stopInspectorTools];
  current_process_pid = [NSNumber numberWithInt:pid];

  ProcessIconDecision* decision = [self decisionForPid:pid];
  NSImage *icon = [decision.image copy];
  [icon setSize:NSMakeSize(TOP_ICON_SIZE, TOP_ICON_SIZE)];
  [self.procAppIcon setImage:icon];

  TopProcessInfo_t* info = TopGetArgs(pid);
  // KERN_PROCARGS2 (info->command) fails for other users' processes; proc_pidpath fails only for kernel_task
  current_process_path = ProcessPath(pid);
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

  NSString* line = [NSString stringWithFormat:@"%s, pid:%d, ppid:%d, prio:%d, stat:%d (%s), flags:%d (%s)",
                    sample->name, sample->pid, sample->ppid, sample->tprio, sample->status, status_str, sample->flags, bits_str];
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

  [self.procDescTextView setString:@"\npreparing..."];
  [self.procArgsEnvTextView setString:@"\npreparing..."];
  [self.procLsofTextView setString:@"\npreparing..."];
  [self.procNmTextView setString:@"\npreparing..."];
  [self.procThreadsTextView setString:@"\npreparing..."];

  //if ([self.top isVisible] == NO)
  {
    [NSApp activateIgnoringOtherApps:YES];
    [self.top center];
    [self.top orderFrontRegardless];
    [self.top makeKeyWindow];
  }
  
  [self.procAppView selectFirstTabViewItem:self];

  [self fillArgsEnvForProcess:info];
  [self fillDescForProcess:name tab:descriptionTab];
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
  // other users' processes join when top's second sample arrives, about a second later
  [self startTopTool];

  refreshTop = true;

  // take a fresh sample, unless the timer has just taken one: a very short interval gives noisy CPU%
  if (!topListValid || (([[NSProcessInfo processInfo] systemUptime] - lastTopSample) >= TOP_MIN_INTERVAL))
  {
    [self updateTop:nil];
    [timerTop setFireDate:[NSDate dateWithTimeIntervalSinceNow:TOP_REFRESH_RATE]];
  }
  else
  {
    [self updateMenuTop];
  }
}

- (void)menuDidClose:(NSMenu *)menu
{
  refreshTop = false;
  [self stopTopTool];
}

- (void)tabView:(NSTabView *)tabView didSelectTabViewItem:(nullable NSTabViewItem *)tabViewItem
{
  
  switch ([[tabViewItem identifier] intValue])
  {
    case 3:
    {
      [self fillLsofForProcess:current_process_pid];
      break;
    }
    case 4:
    {
      [self fillNmForProcess:current_process_path];
      break;
    }
    case 5:
    {
      [self fillThreadsForProcess:current_process_pid];
      break;
    }
    default:
      break;
  }
}

@end
