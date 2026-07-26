// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import <iink/IINKIContentSelection.h>


@class IINKContentPart;


/**
 * Represents a block of content. The tree of content blocks provides the
 * hierarchical structure of a content part into semantic units.
 */
@interface IINKContentBlock : NSObject <IINKIContentSelection>
{

}

//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The type of this block.
 */
@property (nonatomic, readonly, nonnull) NSString *type;

/**
 * The identifier of this block.
 */
@property (nonatomic, readonly, nonnull) NSString *identifier;

/**
 * An identifier that can be used to match corresponding calls to
 * {@link IINKICanvas#startGroup}.
 */
@property (nonatomic, readonly, nonnull) NSString *renderingIdentifier;

/**
 * The children of this block. The returned array is a copy of the
 * list of child blocks, which makes it safe against concurrent changes.
 */
@property (nonatomic, readonly, nonnull) NSArray<IINKContentBlock *> *children;

/**
 * The block's attributes as a JSON string.
 *
 * @since 1.1
 */
@property (nonatomic, readonly, nonnull) NSString *attributes;

/**
 * The parent of this block, or `nil` if this block is the root block.
 *
 * @since 1.4
 */
@property (nonatomic, readonly, nullable) IINKContentBlock *parent;

/**
 * The box that represents the position of this block (document coordinates in mm).
 */
@property (nonatomic, readonly) CGRect box;

/**
 * An array of NSValue holding 4 CGPoint: the four points of the oriented box of this block : top-left,
 * top-right, bottom-right, bottom-left points after rotation (document coordinates in mm).
 *
 * @since 4.2
 */
@property (nonatomic, readonly, nullable) NSArray<NSValue*> *orientedBox;

/**
 * The current conversion state of this block as a bitwise or combination
 * IINKConversionState values.
 */
@property (nonatomic, readonly) IINKConversionState conversionState;

@end
