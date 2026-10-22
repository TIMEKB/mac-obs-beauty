#pragma once
#import <Foundation/Foundation.h>

// Runtime libraries/models are external dependencies, never plugin payloads.
static inline NSString *LBResourceRoot(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/obs-live-beauty/engine-resources"];
}

static inline NSString *LBResolveResourceRoot(NSString *configured)
{
    if (!configured.length) return LBResourceRoot();
    // Earlier local builds bundled the runtime. Migrate only that obsolete default;
    // deliberately selected custom resource directories remain the user's choice.
    if ([configured hasSuffix:@"obs-live-beauty.plugin/Contents/Resources/engine-resources"] &&
        ![[NSFileManager defaultManager] fileExistsAtPath:
            [configured stringByAppendingPathComponent:@"manifest.json"]])
        return LBResourceRoot();
    return configured;
}
