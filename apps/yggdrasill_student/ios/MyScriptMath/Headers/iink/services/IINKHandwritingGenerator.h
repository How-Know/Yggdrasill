// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKMimeType.h>
#import <iink/IINKParameterSet.h>
#import <iink/IINKPointerEvent.h>


@class IINKEngine;
@class IINKHandwritingProfile;
@class IINKHandwritingProfileBuilder;
@class IINKHandwritingResult;

@protocol IINKHandwritingGeneratorDelegate;

/**
 * Represents a handwriting generator that provides a way to generate
 * handwritten content from source parameters (label, writing profile and formatting).
 *
 * @since 4.1
 */
@interface IINKHandwritingGenerator : NSObject
{

}


//==============================================================================
#pragma mark - Delegate
//==============================================================================

/**
 * Sets the specified listener to this handwriting generator.
 */
@property (weak, nonatomic, nullable) id<IINKHandwritingGeneratorDelegate> generatorDelegate;


//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The `Engine` to which this handwriting generator is attached.
 */
@property (nonatomic, readonly, nonnull) IINKEngine *engine;

/**
 * The handwriting profile builder associated with this handwriting generator.
 */
@property (nonatomic, readonly, nonnull) IINKHandwritingProfileBuilder *handwritingProfileBuilder;


//==============================================================================
#pragma mark - Concurrency
//==============================================================================

/**
 * Whether handwriting generation is over.
 */
@property (nonatomic, readonly) BOOL idle;

/**
 * Waits until handwriting generation is over.
 */
-(void)waitForIdle;

/**
 * Cancels the ongoing handwriting generation if any.
 */
- (void)cancel;

//==============================================================================
#pragma mark - Handwriting Generation Session Management
//==============================================================================

/**
 * Returns the types of content that can be generated.
 *
 * @return an array of the supported content types.
 */
- (nullable NSArray<NSString*> *)getSupportedContentTypes
                                 NS_SWIFT_NAME(supportedContentTypes());

/**
 * Returns the input formats supported by the handwriting generation for the given content type.
 *
 * @param type the type of the generated handwritten content.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `type` is not a supported content type.
 * @return an array of the supported mime types.
 */
- (nullable NSArray<IINKMimeTypeValue *> *)getSupportedMimeTypes:(nonnull NSString *)type
                                                         error:(NSError * _Nullable * _Nullable)error
                                               NS_SWIFT_NAME(supportedMimeTypes(forType:));

/**
 * Starts a handwriting generation using the specified writing profile.
 *
 * @param type the type of the generated handwritten content.
 * @param profile the handwriting profile used to generate the handwritten content.
 * @param overrideConfiguration the extra configuration used for this handwriting generation.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `type` is not a supported content type.
 *   * IINKErrorRuntime when this handwriting generator is not idle (see `isIdle()`).
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 */
- (BOOL)start:(nonnull NSString *)type
                profile:(nonnull IINKHandwritingProfile *)profile
  overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                  error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(start(_:profile:overrideConfiguration:));

/**
 * Adds text in the current handwriting generation.
 *
 * @param label the input label that the generated handwritten content must match.
 * @param type the mime type describing the format of the `label`.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `type` is not supported by this handwriting generator.
 *   * IINKErrorRuntime when a handwriting generation has not been started (see `start()`).
 */
- (BOOL)add:(nonnull NSString *)label
        type:(IINKMimeType)type
       error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(add(_:type:));

/**
 * Tells the handwriting generation to not wait for more text to add.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when a handwriting generation has not been started (see `start()` and `add()`).
 */
- (BOOL)end:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(end());

/**
 * Returns the handwriting result of the current handwriting generation.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when a handwriting generation has not been started (see `start()` and `add()`).
 * @return the handwriting result of the current handwriting generation.
 */
- (nullable IINKHandwritingResult *)getResult:(NSError * _Nullable * _Nullable)error
                                    NS_SWIFT_NAME(result());


/**
 * Loads the resource synchronously.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when the resource file cannot be loaded.
 *
 * @since 4.2
 */
- (BOOL)loadResource:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(loadResource());


/**
 * Normalizes a handwriting generation input.
 *
 * @param contentType the type of the generated handwritten content.
 * @param label the input label to normalize.
 * @param mimeType the mime type describing the format of the `label`.
 * @param overrideConfiguration the extra configuration used for this normalization.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when `contentType` is not a supported content type.
 *   * IINKErrorInvalidArgument when `type` is not supported by this handwriting generator.
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 *   * IINKErrorRuntime when the handwriting generator resource is not found in the search path of the configuration manager (\"configuration-manager.search-path\").
 *
 * @return the normalized label described in the same mimetype as the label.
 *
 * @since 4.3
 */
- (nullable NSString*)normalize:(nonnull NSString *)label
                    contentType:(nonnull NSString *)contentType
                       mimeType:(IINKMimeType)mimeType
          overrideConfiguration:(nullable IINKParameterSet *)overrideConfiguration
                          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(normalize(_:contentType:mimeType:overrideConfiguration:));

@end
