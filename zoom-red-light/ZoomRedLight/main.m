#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

typedef NS_ENUM(NSInteger, ZoomMicState) {
    ZoomMicStateUnmuted,
    ZoomMicStateMuted,
    ZoomMicStateNotRunning,
    ZoomMicStatePermissionRequired,
    ZoomMicStateUnknown
};

typedef NS_ENUM(NSInteger, IndicatorStyle) {
    IndicatorStyleSolidCircle,
    IndicatorStyleRing,
    IndicatorStyleRoundedSquare,
    IndicatorStyleMicrophone,
    IndicatorStyleLiveBadge,
    IndicatorStyleCount
};

typedef NS_ENUM(NSInteger, IndicatorSize) {
    IndicatorSizeStandard,
    IndicatorSizeLarge,
    IndicatorSizeCount
};

static NSString *const IndicatorStyleDefaultsKey = @"IndicatorStyle";
static NSString *const IndicatorSizeDefaultsKey = @"IndicatorSize";
static NSString *const BannerVisibleDefaultsKey = @"BannerVisible";
static NSString *const HotBannerTextDefaultsKey = @"HotBannerText";
static NSString *const MutedBannerTextDefaultsKey = @"MutedBannerText";
static NSString *const DefaultHotBannerText = @"MIC HOT";
static NSString *const DefaultMutedBannerText = @"MIC MUTED";

@interface IndicatorBannerView : NSView
@property(nonatomic) ZoomMicState state;
@property(nonatomic, copy) NSString *hotText;
@property(nonatomic, copy) NSString *mutedText;
@end

@implementation IndicatorBannerView

- (void)setState:(ZoomMicState)state {
    _state = state;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSColor *color = self.state == ZoomMicStateUnmuted
        ? NSColor.systemRedColor
        : NSColor.systemGrayColor;
    NSRect bannerRect = NSInsetRect(self.bounds, 1.0, 2.0);
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bannerRect xRadius:5.0 yRadius:5.0] fill];

    NSString *label;
    switch (self.state) {
        case ZoomMicStateUnmuted: label = self.hotText ?: DefaultHotBannerText; break;
        case ZoomMicStateMuted: label = self.mutedText ?: DefaultMutedBannerText; break;
        case ZoomMicStateNotRunning: label = @"ZOOM NOT RUNNING"; break;
        case ZoomMicStatePermissionRequired: label = @"ACCESSIBILITY REQUIRED"; break;
        default: label = @"MICROPHONE STATUS UNAVAILABLE"; break;
    }
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:13.0],
        NSForegroundColorAttributeName: NSColor.whiteColor,
        NSKernAttributeName: @4.0
    };
    NSSize labelSize = [label sizeWithAttributes:attributes];
    NSPoint origin = NSMakePoint(NSMidX(self.bounds) - labelSize.width / 2.0,
                                 NSMidY(self.bounds) - labelSize.height / 2.0);
    [label drawAtPoint:origin withAttributes:attributes];
}

@end

@interface ZoomMicMonitor : NSObject
@property(nonatomic) CGRect audioButtonRect;
@property(nonatomic) BOOL hasAudioButtonRect;
- (ZoomMicState)currentState;
- (BOOL)audioButtonContainsPoint:(CGPoint)point;
- (void)requestAccessibilityPermission;
@end

@implementation ZoomMicMonitor

- (ZoomMicState)currentState {
    if (!AXIsProcessTrusted()) {
        @synchronized (self) {
            self.hasAudioButtonRect = NO;
        }
        return ZoomMicStatePermissionRequired;
    }

    NSRunningApplication *zoom = nil;
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        NSString *identifier = application.bundleIdentifier;
        if ([identifier isEqualToString:@"us.zoom.xos"] || [identifier hasPrefix:@"us.zoom.xos."]) {
            zoom = application;
            break;
        }
    }
    if (zoom == nil) {
        @synchronized (self) {
            self.hasAudioButtonRect = NO;
        }
        return ZoomMicStateNotRunning;
    }

    AXUIElementRef root = AXUIElementCreateApplication(zoom.processIdentifier);
    ZoomMicState state = ZoomMicStateUnknown;

    // Prefer the in-meeting window. Its Mute/Unmute button changes immediately,
    // whereas Zoom updates the equivalent application-menu command lazily.
    CFTypeRef windowsValue = [self copyAttribute:kAXWindowsAttribute element:root];
    if (windowsValue != NULL && CFGetTypeID(windowsValue) == CFArrayGetTypeID()) {
        for (id window in (__bridge NSArray *)windowsValue) {
            state = [self micStateInTree:(__bridge AXUIElementRef)window];
            if (state != ZoomMicStateUnknown) {
                break;
            }
        }
    }
    if (windowsValue != NULL) {
        CFRelease(windowsValue);
    }

    // Fall back to the menu bar when Zoom's meeting controls are unavailable.
    if (state == ZoomMicStateUnknown) {
        CFTypeRef menuBar = [self copyAttribute:kAXMenuBarAttribute element:root];
        if (menuBar != NULL && CFGetTypeID(menuBar) == AXUIElementGetTypeID()) {
            state = [self micStateInTree:(AXUIElementRef)menuBar];
        }
        if (menuBar != NULL) {
            CFRelease(menuBar);
        }
    }
    CFRelease(root);
    return state;
}

- (void)requestAccessibilityPermission {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

- (ZoomMicState)micStateInTree:(AXUIElementRef)root {
    NSMutableArray *queue = [NSMutableArray arrayWithObject:(__bridge id)root];
    NSUInteger index = 0;
    const NSUInteger maximumElements = 3000;

    while (index < queue.count && index < maximumElements) {
        AXUIElementRef element = (__bridge AXUIElementRef)queue[index++];
        if ([self elementIsEnabled:element]) {
            ZoomMicState state = [self micStateForElement:element];
            if (state != ZoomMicStateUnknown) {
                NSString *identifier = [self stringAttribute:kAXIdentifierAttribute element:element] ?: @"?";
                if ([identifier isEqualToString:@"audio"]) {
                    [self updateAudioButtonRectFromElement:element];
                }
                return state;
            }
        }

        CFTypeRef childrenValue = [self copyAttribute:kAXChildrenAttribute element:element];
        if (childrenValue != NULL) {
            if (CFGetTypeID(childrenValue) == CFArrayGetTypeID()) {
                [queue addObjectsFromArray:(__bridge NSArray *)childrenValue];
            }
            CFRelease(childrenValue);
        }
    }
    return ZoomMicStateUnknown;
}

- (void)updateAudioButtonRectFromElement:(AXUIElementRef)element {
    CFTypeRef positionValue = [self copyAttribute:kAXPositionAttribute element:element];
    CFTypeRef sizeValue = [self copyAttribute:kAXSizeAttribute element:element];
    CGPoint position;
    CGSize size;
    BOOL valid = positionValue != NULL && sizeValue != NULL &&
        CFGetTypeID(positionValue) == AXValueGetTypeID() &&
        CFGetTypeID(sizeValue) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &position) &&
        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
    if (valid) {
        @synchronized (self) {
            self.audioButtonRect = CGRectMake(position.x, position.y, size.width, size.height);
            self.hasAudioButtonRect = YES;
        }
    }
    if (positionValue != NULL) {
        CFRelease(positionValue);
    }
    if (sizeValue != NULL) {
        CFRelease(sizeValue);
    }
}

- (BOOL)audioButtonContainsPoint:(CGPoint)point {
    @synchronized (self) {
        return self.hasAudioButtonRect && CGRectContainsPoint(self.audioButtonRect, point);
    }
}

- (ZoomMicState)micStateForElement:(AXUIElementRef)element {
    NSString *role = [self stringAttribute:kAXRoleAttribute element:element];
    NSSet *searchableRoles = [NSSet setWithObjects:
        (__bridge NSString *)kAXButtonRole,
        (__bridge NSString *)kAXMenuItemRole,
        (__bridge NSString *)kAXCheckBoxRole,
        nil
    ];
    if (![searchableRoles containsObject:role]) {
        return ZoomMicStateUnknown;
    }

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *attribute in @[
        (__bridge NSString *)kAXTitleAttribute,
        (__bridge NSString *)kAXDescriptionAttribute,
        (__bridge NSString *)kAXHelpAttribute,
        (__bridge NSString *)kAXValueAttribute
    ]) {
        NSString *value = [self stringAttribute:(__bridge CFStringRef)attribute element:element];
        if (value.length > 0) {
            [parts addObject:value];
        }
    }
    NSString *text = [[parts componentsJoinedByString:@" "] lowercaseString];

    // The label describes the action: "Unmute" means currently muted, while
    // "Mute" means the microphone is currently live.
    if ([text containsString:@"unmute audio"] ||
        [text containsString:@"unmute my audio"] ||
        [text isEqualToString:@"unmute"]) {
        return ZoomMicStateMuted;
    }
    if ([text containsString:@"mute audio"] ||
        [text containsString:@"mute my audio"] ||
        [text isEqualToString:@"mute"]) {
        return ZoomMicStateUnmuted;
    }
    return ZoomMicStateUnknown;
}

- (BOOL)elementIsEnabled:(AXUIElementRef)element {
    CFTypeRef value = [self copyAttribute:kAXEnabledAttribute element:element];
    if (value == NULL) {
        return YES;
    }
    BOOL enabled = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue(value);
    }
    CFRelease(value);
    return enabled;
}

- (NSString *)stringAttribute:(CFStringRef)attribute element:(AXUIElementRef)element {
    CFTypeRef value = [self copyAttribute:attribute element:element];
    if (value == NULL) {
        return nil;
    }
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [(__bridge NSString *)value copy];
    }
    CFRelease(value);
    return result;
}

- (CFTypeRef)copyAttribute:(CFStringRef)attribute element:(AXUIElementRef)element CF_RETURNS_RETAINED {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, attribute, &value);
    return error == kAXErrorSuccess ? value : NULL;
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) ZoomMicMonitor *monitor;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *stateMenuItem;
@property(nonatomic, strong) NSMenu *indicatorStyleMenu;
@property(nonatomic, strong) NSMenu *indicatorSizeMenu;
@property(nonatomic, strong) NSMenu *bannerMenu;
@property(nonatomic, strong) NSPanel *bannerPanel;
@property(nonatomic, strong) IndicatorBannerView *bannerView;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) id globalEventMonitor;
@property(nonatomic) CFMachPortRef eventTap;
@property(nonatomic) CFRunLoopSourceRef eventTapSource;
@property(nonatomic) dispatch_queue_t monitorQueue;
@property(nonatomic) BOOL refreshInFlight;
@property(nonatomic) ZoomMicState lastState;
@property(nonatomic) ZoomMicState optimisticState;
@property(nonatomic) CFAbsoluteTime optimisticUntil;
@property(nonatomic) BOOL temporaryUnmuteActive;
@property(nonatomic) unsigned short zoomMuteKeyCode;
@property(nonatomic) NSEventModifierFlags zoomMuteModifiers;
@property(nonatomic) BOOL hasZoomMuteShortcut;
@property(nonatomic) BOOL zoomMuteShortcutIsGlobal;
@property(nonatomic) CFAbsoluteTime nextShortcutRefresh;
@property(nonatomic) IndicatorStyle indicatorStyle;
@property(nonatomic) IndicatorSize indicatorSize;
@property(nonatomic) BOOL bannerVisible;
@property(nonatomic, copy) NSString *hotBannerText;
@property(nonatomic, copy) NSString *mutedBannerText;
- (void)handleGlobalEvent:(NSEvent *)event;
- (void)applyReportedState:(ZoomMicState)reportedState;
@end

static CGEventRef ZoomRedLightEventTapCallback(CGEventTapProxy proxy,
                                                CGEventType type,
                                                CGEventRef event,
                                                void *userInfo) {
    (void)proxy;
    AppDelegate *delegate = (__bridge AppDelegate *)userInfo;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (delegate.eventTap != NULL) {
            CGEventTapEnable(delegate.eventTap, true);
        }
        return event;
    }

    if (type == kCGEventKeyDown || type == kCGEventKeyUp || type == kCGEventLeftMouseDown) {
        CGEventRef eventCopy = CGEventCreateCopy(event);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSEvent *nsEvent = [NSEvent eventWithCGEvent:eventCopy];
            if (nsEvent != nil) {
                [delegate handleGlobalEvent:nsEvent];
            }
            CFRelease(eventCopy);
        });
    }
    return event;
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.monitor = [[ZoomMicMonitor alloc] init];
    self.monitorQueue = dispatch_queue_create("com.local.ZoomRedLight.monitor", DISPATCH_QUEUE_SERIAL);
    self.lastState = -1;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id storedSize = [defaults objectForKey:IndicatorSizeDefaultsKey];
    BOOL migrateTopBanner = storedSize != nil && [storedSize integerValue] == 2 &&
        [defaults objectForKey:BannerVisibleDefaultsKey] == nil;
    [defaults registerDefaults:@{
        IndicatorStyleDefaultsKey: @0,
        IndicatorSizeDefaultsKey: @0,
        BannerVisibleDefaultsKey: @NO,
        HotBannerTextDefaultsKey: DefaultHotBannerText,
        MutedBannerTextDefaultsKey: DefaultMutedBannerText
    }];
    NSInteger savedStyle = [defaults integerForKey:IndicatorStyleDefaultsKey];
    self.indicatorStyle = savedStyle >= 0 && savedStyle < IndicatorStyleCount
        ? savedStyle
        : IndicatorStyleSolidCircle;
    NSInteger savedSize = [defaults integerForKey:IndicatorSizeDefaultsKey];
    self.indicatorSize = savedSize >= 0 && savedSize < IndicatorSizeCount
        ? savedSize
        : IndicatorSizeStandard;
    self.bannerVisible = migrateTopBanner || [defaults boolForKey:BannerVisibleDefaultsKey];
    self.hotBannerText = [defaults stringForKey:HotBannerTextDefaultsKey];
    self.mutedBannerText = [defaults stringForKey:MutedBannerTextDefaultsKey];
    if (migrateTopBanner) {
        [defaults setInteger:IndicatorSizeStandard forKey:IndicatorSizeDefaultsKey];
        [defaults setBool:YES forKey:BannerVisibleDefaultsKey];
    }
    [self loadZoomMuteShortcut];
    [self configureStatusItem];
    [NSNotificationCenter.defaultCenter addObserver:self
                                            selector:@selector(screenParametersDidChange:)
                                                name:NSApplicationDidChangeScreenParametersNotification
                                              object:nil];
    [self configureGlobalEventMonitor];
    [self refresh];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                  target:self
                                                selector:@selector(refresh)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)loadZoomMuteShortcut {
    NSString *path = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Preferences/us.zoom.xos.Hotkey.plist"];
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:path];
    NSDictionary *shortcut = preferences[@"[HK@combo]-HotkeyOnOffAudio"];
    NSNumber *keyCode = shortcut[@"hot key code"];
    NSNumber *modifiers = shortcut[@"hot key modifier"];

    self.hasZoomMuteShortcut = keyCode != nil && modifiers != nil;
    if (self.hasZoomMuteShortcut) {
        self.zoomMuteKeyCode = keyCode.unsignedShortValue;
        self.zoomMuteModifiers = modifiers.unsignedLongLongValue;
        self.zoomMuteShortcutIsGlobal = [preferences[@"[gHK@state]-HotkeyOnOffAudio"] boolValue];
    }
    self.nextShortcutRefresh = CFAbsoluteTimeGetCurrent() + 2.0;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.timer invalidate];
    if (self.eventTapSource != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.eventTapSource, kCFRunLoopCommonModes);
        CFRelease(self.eventTapSource);
        self.eventTapSource = NULL;
    }
    if (self.eventTap != NULL) {
        CFMachPortInvalidate(self.eventTap);
        CFRelease(self.eventTap);
        self.eventTap = NULL;
    }
    if (self.globalEventMonitor != nil) {
        [NSEvent removeMonitor:self.globalEventMonitor];
    }
}

- (void)configureGlobalEventMonitor {
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp);
    self.eventTap = CGEventTapCreate(kCGSessionEventTap,
                                     kCGHeadInsertEventTap,
                                     kCGEventTapOptionListenOnly,
                                     mask,
                                     ZoomRedLightEventTapCallback,
                                     (__bridge void *)self);
    if (self.eventTap != NULL) {
        self.eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                            self.eventTap,
                                                            0);
        CFRunLoopAddSource(CFRunLoopGetMain(), self.eventTapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(self.eventTap, true);
        return;
    }

    // Fall back to AppKit monitoring if macOS does not allow an event tap.
    __weak AppDelegate *weakSelf = self;
    self.globalEventMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown |
                                               NSEventMaskKeyDown |
                                               NSEventMaskKeyUp)
        handler:^(NSEvent *event) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf handleGlobalEvent:event];
            });
        }];
}

- (void)handleGlobalEvent:(NSEvent *)event {
    if (event.type == NSEventTypeLeftMouseDown) {
        CGPoint click = CGEventGetLocation(event.CGEvent);
        if ([self.monitor audioButtonContainsPoint:click]) {
            [self predictToggle];
        }
        return;
    }

    if (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp) {
        NSString *frontmostIdentifier = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
        BOOL isZoom = [frontmostIdentifier isEqualToString:@"us.zoom.xos"] ||
            [frontmostIdentifier hasPrefix:@"us.zoom.xos."];

        NSEventModifierFlags shortcutMask = NSEventModifierFlagCommand |
            NSEventModifierFlagOption |
            NSEventModifierFlagControl |
            NSEventModifierFlagShift |
            NSEventModifierFlagFunction;
        NSEventModifierFlags eventModifiers = event.modifierFlags & shortcutMask;
        NSEventModifierFlags configuredModifiers = self.zoomMuteModifiers & shortcutMask;

        // Zoom's press-and-hold Space behavior is a momentary state, not a
        // toggle: key-down unmutes and key-up restores mute. Ignore editable
        // controls so typing a space in Zoom chat does not flash the icon red.
        BOOL isPlainSpace = event.keyCode == 49 && eventModifiers == 0;
        if (isPlainSpace && event.type == NSEventTypeKeyUp && self.temporaryUnmuteActive) {
            self.temporaryUnmuteActive = NO;
            [self predictState:ZoomMicStateMuted];
            return;
        }
        if (isZoom && isPlainSpace) {
            if (event.type == NSEventTypeKeyDown && !event.isARepeat &&
                self.lastState == ZoomMicStateMuted && ![self focusedElementIsEditable]) {
                self.temporaryUnmuteActive = YES;
                [self predictState:ZoomMicStateUnmuted];
            }
            return;
        }

        if (event.type != NSEventTypeKeyDown) {
            return;
        }

        BOOL configuredShortcutMatches = self.hasZoomMuteShortcut &&
            event.keyCode == self.zoomMuteKeyCode &&
            eventModifiers == configuredModifiers &&
            (self.zoomMuteShortcutIsGlobal || isZoom);

        // Zoom's factory default is Command-Shift-A. Use it only when Zoom has
        // not saved a custom mute shortcut.
        BOOL defaultShortcutMatches = !self.hasZoomMuteShortcut && isZoom &&
            eventModifiers == (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
            [[event.charactersIgnoringModifiers lowercaseString] isEqualToString:@"a"];

        if (configuredShortcutMatches || defaultShortcutMatches) {
            [self predictToggle];
        }
    }
}

- (void)predictToggle {
    if (self.lastState != ZoomMicStateMuted && self.lastState != ZoomMicStateUnmuted) {
        return;
    }
    ZoomMicState state = self.lastState == ZoomMicStateMuted
        ? ZoomMicStateUnmuted
        : ZoomMicStateMuted;
    [self predictState:state];
}

- (void)predictState:(ZoomMicState)state {
    self.optimisticState = state;
    self.optimisticUntil = CFAbsoluteTimeGetCurrent() + 1.5;
    [self applyState:self.optimisticState];
}

- (BOOL)focusedElementIsEditable {
    if (!AXIsProcessTrusted()) {
        return NO;
    }
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    CFTypeRef focusedValue = NULL;
    AXError error = AXUIElementCopyAttributeValue(systemWide,
                                                   kAXFocusedUIElementAttribute,
                                                   &focusedValue);
    CFRelease(systemWide);
    if (error != kAXErrorSuccess || focusedValue == NULL ||
        CFGetTypeID(focusedValue) != AXUIElementGetTypeID()) {
        if (focusedValue != NULL) {
            CFRelease(focusedValue);
        }
        return NO;
    }

    AXUIElementRef focused = (AXUIElementRef)focusedValue;
    CFTypeRef roleValue = NULL;
    AXUIElementCopyAttributeValue(focused, kAXRoleAttribute, &roleValue);
    NSString *role = roleValue != NULL && CFGetTypeID(roleValue) == CFStringGetTypeID()
        ? (__bridge NSString *)roleValue
        : nil;
    BOOL editable = [role isEqualToString:(__bridge NSString *)kAXTextFieldRole] ||
        [role isEqualToString:(__bridge NSString *)kAXTextAreaRole] ||
        [role isEqualToString:(__bridge NSString *)kAXComboBoxRole];
    if (roleValue != NULL) {
        CFRelease(roleValue);
    }
    CFRelease(focusedValue);
    return editable;
}

- (void)configureStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [self indicatorImageWithColor:NSColor.systemGrayColor];
    self.statusItem.button.imagePosition = NSImageOnly;

    NSMenu *menu = [[NSMenu alloc] init];
    self.stateMenuItem = [[NSMenuItem alloc] initWithTitle:@"Starting…" action:nil keyEquivalent:@""];
    self.stateMenuItem.enabled = NO;
    [menu addItem:self.stateMenuItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *styleItem = [[NSMenuItem alloc]
        initWithTitle:@"Icon Style"
        action:nil
        keyEquivalent:@""];
    self.indicatorStyleMenu = [[NSMenu alloc] initWithTitle:@"Icon Style"];
    NSArray<NSString *> *styleTitles = @[
        @"Solid Circle",
        @"Outlined Circle",
        @"Rounded Square",
        @"Microphone",
        @"LIVE Badge"
    ];
    [styleTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:title
            action:@selector(selectIndicatorStyle:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = index;
        [self.indicatorStyleMenu addItem:item];
    }];
    styleItem.submenu = self.indicatorStyleMenu;
    [menu addItem:styleItem];
    [self updateIndicatorStyleMenu];

    NSMenuItem *sizeItem = [[NSMenuItem alloc]
        initWithTitle:@"Icon Size"
        action:nil
        keyEquivalent:@""];
    self.indicatorSizeMenu = [[NSMenu alloc] initWithTitle:@"Icon Size"];
    NSArray<NSString *> *sizeTitles = @[
        @"Standard",
        @"Large"
    ];
    [sizeTitles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:title
            action:@selector(selectIndicatorSize:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = index;
        [self.indicatorSizeMenu addItem:item];
    }];
    sizeItem.submenu = self.indicatorSizeMenu;
    [menu addItem:sizeItem];
    [self updateIndicatorSizeMenu];

    NSMenuItem *bannerItem = [[NSMenuItem alloc]
        initWithTitle:@"Banner"
        action:nil
        keyEquivalent:@""];
    self.bannerMenu = [[NSMenu alloc] initWithTitle:@"Banner"];
    for (NSDictionary *option in @[
        @{@"title": @"Show", @"value": @YES},
        @{@"title": @"Hide", @"value": @NO}
    ]) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:option[@"title"]
            action:@selector(selectBannerVisibility:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = [option[@"value"] boolValue];
        [self.bannerMenu addItem:item];
    }
    bannerItem.submenu = self.bannerMenu;
    [menu addItem:bannerItem];
    [self updateBannerMenu];

    NSMenuItem *advancedItem = [[NSMenuItem alloc]
        initWithTitle:@"Advanced"
        action:nil
        keyEquivalent:@""];
    NSMenu *advancedMenu = [[NSMenu alloc] initWithTitle:@"Advanced"];
    NSMenuItem *customTextItem = [[NSMenuItem alloc]
        initWithTitle:@"Custom Banner Text…"
        action:@selector(customizeBannerText)
        keyEquivalent:@""];
    customTextItem.target = self;
    [advancedMenu addItem:customTextItem];
    advancedItem.submenu = advancedMenu;
    [menu addItem:advancedItem];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *permissionItem = [[NSMenuItem alloc]
        initWithTitle:@"Open Accessibility Settings…"
        action:@selector(openAccessibilitySettings)
        keyEquivalent:@""];
    permissionItem.target = self;
    [menu addItem:permissionItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc]
        initWithTitle:@"Quit Zoom Red Light"
        action:@selector(quit)
        keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
    self.statusItem.menu = menu;
    [self updateBannerForState:ZoomMicStateUnknown];
}

- (void)refresh {
    if (CFAbsoluteTimeGetCurrent() >= self.nextShortcutRefresh) {
        [self loadZoomMuteShortcut];
    }
    if (self.refreshInFlight) {
        return;
    }

    self.refreshInFlight = YES;
    __weak AppDelegate *weakSelf = self;
    dispatch_async(self.monitorQueue, ^{
        AppDelegate *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        ZoomMicState reportedState = [strongSelf.monitor currentState];
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *mainSelf = weakSelf;
            if (mainSelf == nil) {
                return;
            }
            mainSelf.refreshInFlight = NO;
            [mainSelf applyReportedState:reportedState];
        });
    });
}

- (void)applyReportedState:(ZoomMicState)reportedState {
    ZoomMicState state = reportedState;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.optimisticUntil > now) {
        if (reportedState == self.optimisticState) {
            self.optimisticUntil = 0;
        } else {
            state = self.optimisticState;
        }
    } else {
        self.optimisticUntil = 0;
    }

    [self applyState:state];

    if (reportedState == ZoomMicStatePermissionRequired) {
        [self.monitor requestAccessibilityPermission];
    }
}

- (void)applyState:(ZoomMicState)state {
    if (state == self.lastState) {
        return;
    }
    self.lastState = state;

    NSString *text;
    switch (state) {
        case ZoomMicStateUnmuted: text = @"Zoom microphone is live"; break;
        case ZoomMicStateMuted: text = @"Zoom microphone is muted"; break;
        case ZoomMicStateNotRunning: text = @"Zoom is not running"; break;
        case ZoomMicStatePermissionRequired: text = @"Accessibility permission required"; break;
        default: text = @"Zoom microphone state is unavailable"; break;
    }
    self.stateMenuItem.title = text;
    self.statusItem.button.toolTip = text;
    NSColor *color = state == ZoomMicStateUnmuted
        ? NSColor.systemRedColor
        : NSColor.systemGrayColor;
    self.statusItem.button.image = [self indicatorImageWithColor:color];
    [self updateBannerForState:state];
}

- (NSImage *)indicatorImageWithColor:(NSColor *)color {
    BOOL large = self.indicatorSize == IndicatorSizeLarge;
    NSSize size;
    if (self.indicatorStyle == IndicatorStyleLiveBadge) {
        size = large ? NSMakeSize(46.0, 20.0) : NSMakeSize(31.0, 14.0);
    } else {
        size = large ? NSMakeSize(21.0, 21.0) : NSMakeSize(15.0, 15.0);
    }
    IndicatorStyle style = self.indicatorStyle;
    NSImage *image = [NSImage imageWithSize:size
                                   flipped:NO
                            drawingHandler:^BOOL(NSRect destinationRect) {
        NSRect iconRect = NSInsetRect(destinationRect, 1.5, 1.5);
        switch (style) {
            case IndicatorStyleRing: {
                [color setStroke];
                NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(iconRect, 1.0, 1.0)];
                ring.lineWidth = 2.0;
                [ring stroke];
                break;
            }
            case IndicatorStyleRoundedSquare: {
                [color setFill];
                [[NSBezierPath bezierPathWithRoundedRect:iconRect xRadius:2.5 yRadius:2.5] fill];
                break;
            }
            case IndicatorStyleMicrophone: {
                NSImageSymbolConfiguration *configuration =
                    [NSImageSymbolConfiguration configurationWithPointSize:12.0
                                                                    weight:NSFontWeightSemibold];
                NSImageSymbolConfiguration *colorConfiguration =
                    [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]];
                configuration = [configuration configurationByApplyingConfiguration:colorConfiguration];
                NSImage *symbol = [[NSImage imageWithSystemSymbolName:@"mic.fill"
                                             accessibilityDescription:@"Zoom microphone status"]
                    imageWithSymbolConfiguration:configuration];
                [symbol drawInRect:destinationRect];
                break;
            }
            case IndicatorStyleLiveBadge: {
                [color setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(destinationRect, 0.5, 1.0)
                                                  xRadius:4.0
                                                  yRadius:4.0] fill];
                NSDictionary *attributes = @{
                    NSFontAttributeName: [NSFont boldSystemFontOfSize:8.0],
                    NSForegroundColorAttributeName: NSColor.whiteColor
                };
                NSString *label = @"LIVE";
                NSSize labelSize = [label sizeWithAttributes:attributes];
                NSPoint origin = NSMakePoint(NSMidX(destinationRect) - labelSize.width / 2.0,
                                             NSMidY(destinationRect) - labelSize.height / 2.0);
                [label drawAtPoint:origin withAttributes:attributes];
                break;
            }
            case IndicatorStyleSolidCircle:
            default:
                [color setFill];
                [[NSBezierPath bezierPathWithOvalInRect:iconRect] fill];
                break;
        }
        return YES;
    }];
    // Status-bar buttons render template images in black. This is intentionally
    // a full-color image so the live/muted state remains visible.
    image.template = NO;
    image.accessibilityDescription = @"Zoom microphone status";
    return image;
}

- (void)selectIndicatorStyle:(NSMenuItem *)sender {
    if (sender.tag < 0 || sender.tag >= IndicatorStyleCount) {
        return;
    }
    self.indicatorStyle = sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.indicatorStyle
                                             forKey:IndicatorStyleDefaultsKey];
    [self updateIndicatorStyleMenu];

    NSColor *color = self.lastState == ZoomMicStateUnmuted
        ? NSColor.systemRedColor
        : NSColor.systemGrayColor;
    self.statusItem.button.image = [self indicatorImageWithColor:color];
}

- (void)updateIndicatorStyleMenu {
    for (NSMenuItem *item in self.indicatorStyleMenu.itemArray) {
        item.state = item.tag == self.indicatorStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)selectIndicatorSize:(NSMenuItem *)sender {
    if (sender.tag < 0 || sender.tag >= IndicatorSizeCount) {
        return;
    }
    self.indicatorSize = sender.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.indicatorSize
                                             forKey:IndicatorSizeDefaultsKey];
    [self updateIndicatorSizeMenu];

    NSColor *color = self.lastState == ZoomMicStateUnmuted
        ? NSColor.systemRedColor
        : NSColor.systemGrayColor;
    self.statusItem.button.image = [self indicatorImageWithColor:color];
    [self updateBannerForState:self.lastState];
}

- (void)updateIndicatorSizeMenu {
    for (NSMenuItem *item in self.indicatorSizeMenu.itemArray) {
        item.state = item.tag == self.indicatorSize ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)updateBannerForState:(ZoomMicState)state {
    BOOL meetingIsActive = state == ZoomMicStateMuted || state == ZoomMicStateUnmuted;
    if (!self.bannerVisible || !meetingIsActive) {
        [self.bannerPanel orderOut:nil];
        return;
    }

    if (self.bannerPanel == nil) {
        self.bannerPanel = [[NSPanel alloc]
            initWithContentRect:NSZeroRect
                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered
                          defer:NO];
        self.bannerPanel.opaque = NO;
        self.bannerPanel.backgroundColor = NSColor.clearColor;
        self.bannerPanel.hasShadow = NO;
        self.bannerPanel.ignoresMouseEvents = YES;
        self.bannerPanel.level = NSStatusWindowLevel;
        self.bannerPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorStationary |
            NSWindowCollectionBehaviorFullScreenAuxiliary |
            NSWindowCollectionBehaviorIgnoresCycle;
        self.bannerView = [[IndicatorBannerView alloc] initWithFrame:NSZeroRect];
        self.bannerView.hotText = self.hotBannerText;
        self.bannerView.mutedText = self.mutedBannerText;
        self.bannerPanel.contentView = self.bannerView;
    }

    NSScreen *screen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
    if (screen == nil) {
        return;
    }
    NSRect screenFrame = screen.frame;
    CGFloat menuBarHeight = NSMaxY(screenFrame) - NSMaxY(screen.visibleFrame);
    if (menuBarHeight < 18.0) {
        menuBarHeight = 24.0;
    }
    CGFloat bannerWidth = floor(NSWidth(screenFrame) / 3.0);
    NSRect bannerFrame = NSMakeRect(NSMidX(screenFrame) - bannerWidth / 2.0,
                                    NSMaxY(screenFrame) - menuBarHeight,
                                    bannerWidth,
                                    menuBarHeight);
    [self.bannerPanel setFrame:bannerFrame display:YES];
    self.bannerView.state = state;
    [self.bannerPanel orderFrontRegardless];
}

- (void)screenParametersDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateBannerForState:self.lastState];
}

- (void)selectBannerVisibility:(NSMenuItem *)sender {
    self.bannerVisible = sender.tag != 0;
    [NSUserDefaults.standardUserDefaults setBool:self.bannerVisible
                                          forKey:BannerVisibleDefaultsKey];
    [self updateBannerMenu];
    [self updateBannerForState:self.lastState];
}

- (void)updateBannerMenu {
    for (NSMenuItem *item in self.bannerMenu.itemArray) {
        item.state = (item.tag != 0) == self.bannerVisible
            ? NSControlStateValueOn
            : NSControlStateValueOff;
    }
}

- (void)customizeBannerText {
    [NSApp activateIgnoringOtherApps:YES];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Custom Banner Text";
    alert.informativeText = @"Set the text shown for each microphone state.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"Restore Defaults"];

    NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 380.0, 72.0)];
    NSTextField *mutedLabel = [NSTextField labelWithString:@"Mic muted:"];
    mutedLabel.frame = NSMakeRect(0.0, 44.0, 100.0, 20.0);
    NSTextField *mutedField = [[NSTextField alloc] initWithFrame:NSMakeRect(105.0, 40.0, 275.0, 24.0)];
    mutedField.stringValue = self.mutedBannerText ?: DefaultMutedBannerText;
    mutedField.placeholderString = DefaultMutedBannerText;

    NSTextField *hotLabel = [NSTextField labelWithString:@"Mic hot:"];
    hotLabel.frame = NSMakeRect(0.0, 10.0, 100.0, 20.0);
    NSTextField *hotField = [[NSTextField alloc] initWithFrame:NSMakeRect(105.0, 6.0, 275.0, 24.0)];
    hotField.stringValue = self.hotBannerText ?: DefaultHotBannerText;
    hotField.placeholderString = DefaultHotBannerText;

    [form addSubview:mutedLabel];
    [form addSubview:mutedField];
    [form addSubview:hotLabel];
    [form addSubview:hotField];
    alert.accessoryView = form;
    alert.window.initialFirstResponder = mutedField;

    NSModalResponse response = [alert runModal];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (response == NSAlertFirstButtonReturn) {
        NSString *mutedText = [mutedField.stringValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *hotText = [hotField.stringValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        self.mutedBannerText = mutedText.length > 0 ? mutedText : DefaultMutedBannerText;
        self.hotBannerText = hotText.length > 0 ? hotText : DefaultHotBannerText;
        [defaults setObject:self.mutedBannerText forKey:MutedBannerTextDefaultsKey];
        [defaults setObject:self.hotBannerText forKey:HotBannerTextDefaultsKey];
        [self updateBannerText];
    } else if (response == NSAlertThirdButtonReturn) {
        [defaults removeObjectForKey:MutedBannerTextDefaultsKey];
        [defaults removeObjectForKey:HotBannerTextDefaultsKey];
        self.mutedBannerText = DefaultMutedBannerText;
        self.hotBannerText = DefaultHotBannerText;
        [self updateBannerText];
    }
}

- (void)updateBannerText {
    self.bannerView.mutedText = self.mutedBannerText;
    self.bannerView.hotText = self.hotBannerText;
    [self.bannerView setNeedsDisplay:YES];
}

- (void)openAccessibilitySettings {
    [self.monitor requestAccessibilityPermission];
    NSURL *url = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)quit {
    [NSApp terminate:nil];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [[AppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [application run];
    }
    return 0;
}
