// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/**
 * Helper to wrap and ease CGTransform manipulation.
 *
 * @since 3.1
 */
@interface IINKTransform : NSObject

@property (nonatomic, assign) CGAffineTransform value;

/**
 * Create a new `IINKTransform` instance.
 * @param value the CGAffineTransform value.
 */
- (nullable instancetype)initWithValue:(CGAffineTransform)value;

/**
 * Builds a new `IINKTransform` instance.
 * @param value the CGAffineTransform value.
 */
+ (nonnull IINKTransform *)valueWithCGAffineTransform:(CGAffineTransform)value;

/**
 * Gets the transform to transform a rectangle into another.
 *
 * @param fromRect the source rectangle.
 * @param toRect the destination rectangle.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when a rectangle is invalid.
 * @return the transform that transforms `fromRect` into `toRect`.
 */
+ (nullable IINKTransform *)getTransformFromRect:(CGRect)fromRect
                                          toRect:(CGRect)toRect
                                           error:(NSError * _Nullable * _Nullable)error
                                                 NS_SWIFT_NAME(transform(fromRect:toRect:));

@end
