// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>


@class IINKRenderer;

/**
 * The delegate interface for receiving renderer events.
 *
 * @see IINKRenderer
 */
@protocol IINKRendererDelegate <NSObject>

@required

//==============================================================================
#pragma mark - Required Methods
//==============================================================================

/**
 * Invoked when the view transform has changed.
 *
 * @param renderer the renderer.
 */
- (void)viewTransformChanged:(nonnull IINKRenderer*)renderer;

@end
