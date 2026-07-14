#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <math.h>

static double batteryCutoffC = 40.0;
static const double minimumConfigurableCutoffC = 35.0;
static const double maximumConfigurableCutoffC = 50.0;
static double pollSeconds = 15.0;
static BOOL runOnce = NO;
static BOOL dryRun = NO;
static BOOL noSleep = NO;
static BOOL ignoreTripLatch = NO;
static BOOL commandLineCutoffSpecified = NO;
static NSInteger simulatedThermalState = -1;
static NSURL *tripLatch;
static NSUserDefaults *settings;
static NSString *const settingsDomain = @"com.lackofcheese.amphetamine-thermal-watchdog";
static NSString *const batteryCutoffKey = @"BatteryCutoffC";
static NSStatusItem *statusItem;
static NSMenuItem *thermalMenuItem;
static NSMenuItem *batteryMenuItem;
static NSMenuItem *cutoffMenuItem;
static NSMenuItem *latchMenuItem;
static NSString *latestThermalName = @"starting";
static NSString *latestBatteryText = @"checking…";

@interface GuardMenuController : NSObject
- (void)openLog:(id)sender;
- (void)resetLatch:(id)sender;
- (void)setPresetCutoff:(NSMenuItem *)sender;
- (void)setCustomCutoff:(id)sender;
@end

static GuardMenuController *menuController;

static void Log(NSString *message) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ formatter = [[NSISO8601DateFormatter alloc] init]; });
    printf("%s %s\n", [[formatter stringFromDate:[NSDate date]] UTF8String], [message UTF8String]);
    fflush(stdout);
}

static NSString *RunCommand(NSString *executable, NSArray<NSString *> *arguments, NSError **error) {
    NSTask *task = [[NSTask alloc] init];
    NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    task.standardOutput = pipe;
    task.standardError = pipe;
    if (![task launchAndReturnError:error]) return nil;
    [task waitUntilExit];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    output = [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (task.terminationStatus != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"AmphetamineThermalGuard"
                                         code:task.terminationStatus
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"%@ failed with status %d: %@",
                                          executable, task.terminationStatus, output]}];
        }
        return nil;
    }
    return output;
}

static NSString *ThermalStateName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal: return @"nominal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return [NSString stringWithFormat:@"unknown(%ld)", (long)state];
}

static BOOL IsConfigurableCutoff(double value) {
    return isfinite(value) && value >= minimumConfigurableCutoffC && value <= maximumConfigurableCutoffC;
}

static void UpdateCutoffMenu(void) {
    cutoffMenuItem.title = [NSString stringWithFormat:@"Battery cutoff: %.1f°C", batteryCutoffC];
    for (NSMenuItem *item in cutoffMenuItem.submenu.itemArray) {
        NSNumber *preset = item.representedObject;
        item.state = preset && fabs(preset.doubleValue - batteryCutoffC) < 0.01 ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

static void StoreCutoff(double value, NSString *source) {
    batteryCutoffC = value;
    [settings setDouble:value forKey:batteryCutoffKey];
    [settings synchronize];
    Log([NSString stringWithFormat:@"Battery cutoff changed to %.1fC via %@", value, source]);
    UpdateCutoffMenu();
}

static void ReloadStoredCutoff(void) {
    if (commandLineCutoffSpecified) return;
    NSNumber *stored = [settings objectForKey:batteryCutoffKey];
    if (stored && IsConfigurableCutoff(stored.doubleValue)) {
        batteryCutoffC = stored.doubleValue;
    }
}

static void UpdateMenuBar(NSProcessInfoThermalState state, NSNumber *batteryC) {
    latestThermalName = ThermalStateName(state);
    latestBatteryText = batteryC ? [NSString stringWithFormat:@"%.1f°C", batteryC.doubleValue] : @"unavailable";
    NSString *symbol = @"thermometer.medium";
    NSColor *tint = nil;
    if (state == NSProcessInfoThermalStateNominal) {
        symbol = @"thermometer.low";
    } else if (state == NSProcessInfoThermalStateFair) {
        symbol = @"thermometer.medium";
        tint = [NSColor systemOrangeColor];
    } else {
        symbol = @"thermometer.high";
        tint = [NSColor systemRedColor];
    }
    if (batteryC && batteryC.doubleValue >= 35.0 && state == NSProcessInfoThermalStateNominal) {
        tint = [NSColor systemOrangeColor];
    }
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Thermal watchdog"];
    statusItem.button.image = image;
    statusItem.button.contentTintColor = tint;
    statusItem.button.toolTip = [NSString stringWithFormat:@"Thermal watchdog: %@, battery %@", latestThermalName, latestBatteryText];
    thermalMenuItem.title = [NSString stringWithFormat:@"System thermal state: %@", latestThermalName];
    batteryMenuItem.title = [NSString stringWithFormat:@"Battery temperature: %@", latestBatteryText];
    UpdateCutoffMenu();
    BOOL latched = [[NSFileManager defaultManager] fileExistsAtPath:tripLatch.path];
    latchMenuItem.title = latched ? @"Reset thermal trip latch" : @"Trip latch: armed";
    latchMenuItem.enabled = latched;
}

@implementation GuardMenuController
- (void)openLog:(id)sender {
    NSURL *logURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/AmphetamineThermalGuard.log"]];
    [[NSWorkspace sharedWorkspace] openURL:logURL];
}

- (void)resetLatch:(id)sender {
    NSError *error = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:tripLatch.path]) {
        [[NSFileManager defaultManager] removeItemAtURL:tripLatch error:&error];
    }
    if (error) {
        Log([NSString stringWithFormat:@"WARNING: could not reset trip latch: %@", error.localizedDescription]);
    } else {
        Log(@"Trip latch reset from menu bar");
    }
    latchMenuItem.title = @"Trip latch: armed";
    latchMenuItem.enabled = NO;
}

- (void)setPresetCutoff:(NSMenuItem *)sender {
    NSNumber *preset = sender.representedObject;
    StoreCutoff(preset.doubleValue, @"menu preset");
}

- (void)setCustomCutoff:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Set battery temperature cutoff";
    alert.informativeText = @"Enter a value from 35°C to 50°C. Values above 45°C are not recommended because Apple does not publish an acceptable internal battery-temperature limit.";
    [alert addButtonWithTitle:@"Set Cutoff"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 24)];
    field.stringValue = [NSString stringWithFormat:@"%.1f", batteryCutoffC];
    alert.accessoryView = field;
    [alert.window setInitialFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    double value = field.doubleValue;
    if (!IsConfigurableCutoff(value)) {
        NSAlert *invalid = [[NSAlert alloc] init];
        invalid.messageText = @"Invalid cutoff";
        invalid.informativeText = @"Choose a temperature between 35°C and 50°C.";
        [invalid runModal];
        return;
    }
    if (value > 45.0) {
        NSAlert *warning = [[NSAlert alloc] init];
        warning.alertStyle = NSAlertStyleCritical;
        warning.messageText = @"Use a cutoff above 45°C?";
        warning.informativeText = @"This is a deliberately permissive setting. Apple warns that heat and charging temperature accelerate battery aging, but does not publish a safe internal battery-temperature limit.";
        [warning addButtonWithTitle:@"Use This Value"];
        [warning addButtonWithTitle:@"Cancel"];
        if ([warning runModal] != NSAlertFirstButtonReturn) return;
    }
    StoreCutoff(value, @"custom menu setting");
}
@end

static void SetupMenuBar(void) {
    menuController = [[GuardMenuController alloc] init];
    statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    statusItem.button.image = [NSImage imageWithSystemSymbolName:@"thermometer.medium" accessibilityDescription:@"Thermal watchdog"];
    statusItem.button.toolTip = @"Thermal watchdog starting…";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Thermal Watchdog"];
    NSMenuItem *heading = [[NSMenuItem alloc] initWithTitle:@"Amphetamine Thermal Watchdog" action:nil keyEquivalent:@""];
    heading.enabled = NO;
    [menu addItem:heading];
    [menu addItem:[NSMenuItem separatorItem]];
    thermalMenuItem = [[NSMenuItem alloc] initWithTitle:@"System thermal state: starting" action:nil keyEquivalent:@""];
    thermalMenuItem.enabled = NO;
    [menu addItem:thermalMenuItem];
    batteryMenuItem = [[NSMenuItem alloc] initWithTitle:@"Battery temperature: checking…" action:nil keyEquivalent:@""];
    batteryMenuItem.enabled = NO;
    [menu addItem:batteryMenuItem];
    cutoffMenuItem = [[NSMenuItem alloc] initWithTitle:@"Battery cutoff: 40.0°C" action:nil keyEquivalent:@""];
    NSMenu *cutoffMenu = [[NSMenu alloc] initWithTitle:@"Battery cutoff"];
    for (NSNumber *preset in @[@40.0, @42.0, @45.0]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%.0f°C", preset.doubleValue]
                                                      action:@selector(setPresetCutoff:)
                                               keyEquivalent:@""];
        item.target = menuController;
        item.representedObject = preset;
        [cutoffMenu addItem:item];
    }
    [cutoffMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *custom = [[NSMenuItem alloc] initWithTitle:@"Custom…" action:@selector(setCustomCutoff:) keyEquivalent:@""];
    custom.target = menuController;
    [cutoffMenu addItem:custom];
    cutoffMenuItem.submenu = cutoffMenu;
    [menu addItem:cutoffMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    latchMenuItem = [[NSMenuItem alloc] initWithTitle:@"Trip latch: armed" action:@selector(resetLatch:) keyEquivalent:@""];
    latchMenuItem.target = menuController;
    latchMenuItem.enabled = NO;
    [menu addItem:latchMenuItem];
    NSMenuItem *logs = [[NSMenuItem alloc] initWithTitle:@"Open watchdog log" action:@selector(openLog:) keyEquivalent:@""];
    logs.target = menuController;
    [menu addItem:logs];
    statusItem.menu = menu;
    UpdateCutoffMenu();
}

static NSNumber *BatteryTemperatureC(void) {
    NSError *error = nil;
    NSString *output = RunCommand(@"/usr/sbin/ioreg", @[@"-r", @"-c", @"AppleSmartBattery", @"-l"], &error);
    if (!output) {
        Log([NSString stringWithFormat:@"WARNING: battery temperature unavailable: %@", error.localizedDescription]);
        return nil;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\\"Temperature\\\"\\s*=\\s*(\\d+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];
    if (!match) return nil;
    double raw = [[output substringWithRange:[match rangeAtIndex:1]] doubleValue];
    double celsius = raw / 10.0 - 273.15;
    if (celsius < -20.0 || celsius > 100.0) {
        Log([NSString stringWithFormat:@"Ignoring implausible battery temperature: raw=%.0f converted=%.1fC", raw, celsius]);
        return nil;
    }
    return @(celsius);
}

static void WriteTripLatch(NSString *reason) {
    NSError *error = nil;
    NSURL *directory = [tripLatch URLByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        Log([NSString stringWithFormat:@"WARNING: could not create state directory: %@", error.localizedDescription]);
        return;
    }
    NSString *contents = [NSString stringWithFormat:@"%@ %@\n", [[NSDate date] description], reason];
    if (![contents writeToURL:tripLatch atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        Log([NSString stringWithFormat:@"WARNING: could not write trip latch: %@", error.localizedDescription]);
    }
}

__attribute__((noreturn)) static void Trip(NSString *reason) {
    Log([NSString stringWithFormat:@"TRIP: %@", reason]);
    if (dryRun) {
        Log(@"Dry run: would end Amphetamine session and request system sleep");
        exit(EXIT_SUCCESS);
    }

    WriteTripLatch(reason);
    NSError *error = nil;
    NSString *output = RunCommand(@"/usr/bin/osascript", @[@"-e", @"tell application \"Amphetamine\" to end session"], &error);
    if (output) {
        Log(output.length ? [NSString stringWithFormat:@"Amphetamine session ended: %@", output] : @"Amphetamine session ended");
    } else {
        Log([NSString stringWithFormat:@"WARNING: could not end Amphetamine session: %@", error.localizedDescription]);
    }

    if (noSleep) {
        Log(@"No-sleep test mode: skipping system sleep request");
    } else {
        error = nil;
        output = RunCommand(@"/usr/bin/pmset", @[@"sleepnow"], &error);
        if (output) {
            Log(output.length ? [NSString stringWithFormat:@"System sleep requested: %@", output] : @"System sleep requested");
        } else {
            Log([NSString stringWithFormat:@"WARNING: could not request system sleep: %@", error.localizedDescription]);
        }
    }
    exit(EXIT_SUCCESS);
}

static NSProcessInfoThermalState ParseThermalState(NSString *value) {
    if ([value isEqualToString:@"nominal"]) return NSProcessInfoThermalStateNominal;
    if ([value isEqualToString:@"fair"]) return NSProcessInfoThermalStateFair;
    if ([value isEqualToString:@"serious"]) return NSProcessInfoThermalStateSerious;
    if ([value isEqualToString:@"critical"]) return NSProcessInfoThermalStateCritical;
    fprintf(stderr, "Invalid thermal state: %s\n", value.UTF8String);
    exit(EXIT_FAILURE);
}

static void CheckSensors(void) {
    @autoreleasepool {
        ReloadStoredCutoff();
        NSProcessInfoThermalState state = simulatedThermalState >= 0
            ? (NSProcessInfoThermalState)simulatedThermalState
            : [NSProcessInfo processInfo].thermalState;
        NSNumber *batteryC = BatteryTemperatureC();
        Log([NSString stringWithFormat:@"Sample: thermal=%@ battery=%@", ThermalStateName(state), batteryC ? [NSString stringWithFormat:@"%.1fC", batteryC.doubleValue] : @"unavailable"]);
        if (!runOnce) {
            dispatch_async(dispatch_get_main_queue(), ^{ UpdateMenuBar(state, batteryC); });
        }
        if (state == NSProcessInfoThermalStateSerious || state == NSProcessInfoThermalStateCritical) {
            Trip([NSString stringWithFormat:@"system thermal state is %@", ThermalStateName(state)]);
        }
        if (batteryC && batteryC.doubleValue >= batteryCutoffC) {
            Trip([NSString stringWithFormat:@"battery temperature %.1fC reached cutoff %.1fC", batteryC.doubleValue, batteryCutoffC]);
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray<NSString *> *arguments = [[NSProcessInfo processInfo] arguments];
        for (NSUInteger index = 1; index < arguments.count; index++) {
            NSString *argument = arguments[index];
            if ([argument isEqualToString:@"--battery-cutoff-c"] && ++index < arguments.count) {
                batteryCutoffC = [arguments[index] doubleValue];
                commandLineCutoffSpecified = YES;
            } else if ([argument isEqualToString:@"--poll-seconds"] && ++index < arguments.count) {
                pollSeconds = [arguments[index] doubleValue];
            } else if ([argument isEqualToString:@"--once"]) {
                runOnce = YES;
            } else if ([argument isEqualToString:@"--dry-run"]) {
                dryRun = YES;
            } else if ([argument isEqualToString:@"--no-sleep"]) {
                noSleep = YES;
            } else if ([argument isEqualToString:@"--ignore-trip-latch"]) {
                ignoreTripLatch = YES;
            } else if ([argument isEqualToString:@"--simulate-thermal"] && ++index < arguments.count) {
                simulatedThermalState = ParseThermalState(arguments[index]);
            } else {
                fprintf(stderr, "Unknown or incomplete argument: %s\n", argument.UTF8String);
                return EXIT_FAILURE;
            }
        }

        NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
        settings = [[NSUserDefaults alloc] initWithSuiteName:settingsDomain];
        ReloadStoredCutoff();
        tripLatch = [home URLByAppendingPathComponent:@"Library/Application Support/AmphetamineThermalGuard/tripped"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tripLatch.path] && !ignoreTripLatch) {
            Log([NSString stringWithFormat:@"Trip latch exists at %@; guard remains stopped until reset", tripLatch.path]);
            return EXIT_SUCCESS;
        }

        Log([NSString stringWithFormat:@"Starting guard: battery cutoff=%.1fC poll=%.0fs dryRun=%@", batteryCutoffC, pollSeconds, dryRun ? @"yes" : @"no"]);
        if (runOnce) {
            CheckSensors();
            return EXIT_SUCCESS;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        SetupMenuBar();
        dispatch_queue_t sensorQueue = dispatch_queue_create("com.lackofcheese.amphetamine-thermal-watchdog.sensors", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sensorQueue);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, (uint64_t)(pollSeconds * NSEC_PER_SEC), NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ CheckSensors(); });
        dispatch_resume(timer);
        [NSApp run];
        return EXIT_SUCCESS;
    }
}
