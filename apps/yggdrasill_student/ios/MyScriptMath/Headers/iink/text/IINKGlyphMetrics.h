// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/graphics/IINKStyle.h>


/**
 * Describes glyphs spans in a label.
 */
@interface IINKGlyphMetrics : NSObject
{

}

/**
 * Create a new `IINKGlyphMetrics` instance.
 * @param bounds the glyph bounds.
 * @param lsb the left side bearings.
 * @param rsb the right side bearings.
 */
- (instancetype)initWithBounds:(CGRect)bounds leftSideBearings:(CGFloat)lsb rightSideBearings:(CGFloat)rsb;

/**
 * The glyph bounding box.
 */
@property (nonatomic) CGRect boundingBox;

/**
 * The glyph left side bearing.
 */
@property (nonatomic) CGFloat leftSideBearing;

/**
 * The glyph right side bearing.
 */
@property (nonatomic) CGFloat rightSideBearing;

@end
