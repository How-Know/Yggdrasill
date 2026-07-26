// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/graphics/IINKICanvas.h>

/**
 * Style information for the rendering of strokes and text.
 */
@interface IINKStyle : NSObject
{

}

//==============================================================================
#pragma mark - Stroke Styling Properties
//==============================================================================

/**
 * The stroke color.
 */
@property (nonatomic) uint32_t strokeColor;

/**
 * The stroke width.
 */
@property (nonatomic) float strokeWidth;

/**
 * The stroke line cap.
 */
@property (nonatomic) IINKLineCap strokeLineCap;

/**
 * The stroke line join.
 */
@property (nonatomic) IINKLineJoin strokeLineJoin;

/**
 * The stroke miter limit.
 */
@property (nonatomic) float strokeMiterLimit;

/**
 * The stroke dash array.
 */
@property (nonatomic) NSArray<NSNumber *> *strokeDashArray;

/**
 * The stroke dash offset.
 */
@property (nonatomic) float strokeDashOffset;


//==============================================================================
#pragma mark - General Styling Properties
//==============================================================================

/**
 * The fill color.
 */
@property (nonatomic) uint32_t fillColor;

/**
 * The fill rule.
 */
@property (nonatomic) IINKFillRule fillRule;


//==============================================================================
#pragma mark - Font Styling Properties
//==============================================================================

/**
 * The font family.
 */
@property (nonatomic) NSString *fontFamily;

/**
 * The font line height.
 */
@property (nonatomic) float fontLineHeight;

/**
 * The font size.
 */
@property (nonatomic) float fontSize;

/**
 * The font style.
 */
@property (nonatomic) NSString *fontStyle;

/**
 * The font variant.
 */
@property (nonatomic) NSString *fontVariant;

/**
 * The font weight.
 */
@property (nonatomic) NSInteger fontWeight;


//==============================================================================
#pragma mark - Drop Shadow Properties
//==============================================================================

/**
 * The drop shadow horizontal offset.
 */
@property (nonatomic) float dropShadowXOffset;

/**
 * The drop shadow vertical offset.
 */
@property (nonatomic) float dropShadowYOffset;

/**
 * The drop shadow blur radius.
 */
@property (nonatomic) float dropShadowRadius;

/**
 * The drop shadow color
 */
@property (nonatomic) uint32_t dropShadowColor;


//==============================================================================
#pragma mark - Update managment
//==============================================================================

- (void)clearChangeFlags;

- (void)setAllChangeFlags;

- (void)applyTo:(id<IINKICanvas>)canvas;


@end
