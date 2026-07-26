// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>

/**
 * Wrapper object for an `CGRect` value.
 */
@interface IINKRect : NSObject

@property (nonatomic, assign) CGRect value;

/**
 * Create a new `IINKRect` instance.
 * @param value the CGRect value.
 */
- (nullable instancetype)initWithValue:(CGRect)value;

/**
 * Builds a new `IINKRect` instance.
 * @param value the CGRect value.
 */
+ (nonnull IINKRect *)valueWithCGRect:(CGRect)value;

@end
