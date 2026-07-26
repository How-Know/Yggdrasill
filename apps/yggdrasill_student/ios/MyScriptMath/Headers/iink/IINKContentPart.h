// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class IINKContentPackage;
@class IINKParameterSet;

/**
 * A part stores one content item. It is structured into several blocks that
 * consist of semantically meaningful sub sections of content. A part can be
 * interpreted as a hierarchy of blocks.
 *
 * @see IINKContentPackage.
 */
@interface IINKContentPart : NSObject
{

}

//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The package that contains this part.
 */
@property (nonatomic, readonly, nonnull) IINKContentPackage *package;

/**
 * The identifier of this part.
 */
@property (nonatomic, readonly, nonnull) NSString *identifier;

/**
 * The type of this part.
 */
@property (nonatomic, readonly, nonnull) NSString *type;

/**
 * The view box, the rectangle that represents the viewable area of
 * this part's content (document coordinates in mm).
 */
@property (nonatomic, readonly) CGRect viewBox;

/**
 * The part's metadata as a parameter set.
 */
@property (nonatomic, nullable) IINKParameterSet *metadata;

/**
 * Returns the part's fixed-size, if defined, otherwise `{0.f, 0.f}` (document coordinates in mm).
 *
 * @since 4.1
 */
@property (atomic, readonly) CGSize fixedSize;

//==============================================================================
#pragma mark - Language
//==============================================================================

/**
 * Returns the language of this part.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when part does not support text recognition (i.e. for types Math and Drawing).
 * @return the part language locale identifier, empty if not set yet (will be set by {@link IINKEditor#setPart}).
 */
- (NSString* _Nullable)getLanguageWithError:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(language());

@end
