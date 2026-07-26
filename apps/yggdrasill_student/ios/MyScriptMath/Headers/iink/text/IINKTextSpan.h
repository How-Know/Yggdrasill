// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/graphics/IINKStyle.h>


/**
 * Describes glyphs spans in a label.
 */
@interface IINKTextSpan : NSObject
{

}

/**
 * The begin position in a label of this span, in glyph (i.e. grapheme
 * cluster) count.
 */
@property (nonatomic, readonly) NSInteger beginPosition;

/**
 * The end position in a label of this span, in glyph (i.e. grapheme
 * cluster) count.
 */
@property (nonatomic, readonly) NSInteger endPosition;

/**
 * The style associated with this span.
 */
@property (nonatomic, readonly) IINKStyle *style;

@end
