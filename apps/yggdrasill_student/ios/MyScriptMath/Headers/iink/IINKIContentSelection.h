// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/IINKContentPart.h>


/**
 * Describes the state of the content for a given block.
 */
typedef NS_OPTIONS(NSUInteger, IINKConversionState)
{
  /** Handwritten content (ink). */
  IINKConversionStateHandwriting = 1 << 0,
  /** Digital content, suitable for publication (adaptative font size, fitted graphics). */
  IINKConversionStateDigitalPublish = 1 << 1,
  /** Digital content, suitable for edition (normalized font size, expanded graphics). */
  IINKConversionStateDigitalEdit = 1 << 2
};

/**
 * Wrapper object for an `IINKConversionState` value.
 */
@interface IINKConversionStateValue : NSObject
{

}

@property (nonatomic) IINKConversionState value;

/**
 * Create a new `ConversionStateValue` instance.
 * @param value the conversion state value.
 */
- (nullable instancetype)initWithValue:(IINKConversionState)value;

/**
 * Builds a new `ConversionStateValue` instance.
 * @param value the conversion state value.
 */
+ (nonnull IINKConversionStateValue *)valueWithConversionState:(IINKConversionState)value;

@end


/**
 * Protocol implemented by selection.
 *
 * @see IINKContentSelection
 * @see IINKContentBlock
 * @since 2.0
 */
@protocol IINKIContentSelection

@required

/**
 * The part that contains this selection.
 */
@property (nonatomic, readonly, nonnull) IINKContentPart *part;

/**
 * Whether this selection is still valid. A block becomes invalid when it is
 * removed or when the currently edited part changes (see
 * {@link IINKEditorDelegate#partChanged}).
 */
@property (nonatomic, readonly) BOOL valid;

@end
