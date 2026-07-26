// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>


@class IINKConfiguration;

/**
 * The delegate interface for receiving configuration change events.
 *
 * @see IINKConfiguration:delegate
 */
@protocol IINKConfigurationDelegate <NSObject>

@required

//==============================================================================
#pragma mark - Required Methods
//==============================================================================

/**
 * Invoked when the configuration has changed.
 *
 * @param configuration the configuration that has changed.
 */
- (void)configurationChanged:(nonnull IINKConfiguration *)configuration;

@end
