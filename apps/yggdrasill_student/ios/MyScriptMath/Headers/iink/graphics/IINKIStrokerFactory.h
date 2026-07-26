// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/graphics/IINKIStroker.h>


/**
 * The stroker factory interface, to create `IINKIStroker` instances.
 */
@protocol IINKIStrokerFactory <NSObject>

@required

//==============================================================================
#pragma mark - Required Methods
//==============================================================================

/**
 * Creates a new stroker instance.
 *
 * @return the newly created stroker.
 */
- (nonnull id<IINKIStroker>)createStroker;

@end
