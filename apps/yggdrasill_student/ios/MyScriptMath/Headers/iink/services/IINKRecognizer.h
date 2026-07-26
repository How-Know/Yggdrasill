// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/services/IINKRecognizerDelegate.h>
#import <iink/IINKError.h>
#import <iink/IINKMimeType.h>
#import "iink/IINKConfiguration.h"
#import "iink/IINKPointerEvent.h"

@class IINKEngine;
@class IINKConfiguration;

/**
 * The Recognizer runs background handwriting recognition on ink.
 *
 * @since 2.1
 */
@interface IINKRecognizer : NSObject
{

}

//==============================================================================
#pragma mark - Delegate
//==============================================================================

/**
 * Adds a delegate to this recognizer.
 * @param delegate the delegate to add.
 */
- (void)addDelegate:(nonnull id<IINKRecognizerDelegate>)delegate;

/**
 * Removes a delegate added by `addDelegate:`
 * @param delegate the delegate to remove.
 */
- (void)removeDelegate:(nonnull id<IINKRecognizerDelegate>)delegate;


//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The `Engine` to which this recognizer is attached.
 */
@property (nonatomic, readonly, nonnull) IINKEngine *engine;

/**
 * The scale to convert input horizontal coordinates unit into mm,
 * such that (X coordinate unit * scaleX = mm).
 */
@property (nonatomic, readonly) float scaleX;

/**
 * The scale to convert input vertical coordinates unit into mm,
 * such that (Y coordinate unit * scaleY = mm).
 */
@property (nonatomic, readonly) float scaleY;

/**
 * The configuration associated with this recognizer.
 */
@property (nonatomic, readonly, nonnull) IINKConfiguration *configuration;

/**
 * Lists the result formats supported by this recognizer.
 *
 * @return the list of supported mime types.
 */
@property (nonatomic, readonly, nonnull) NSArray<IINKMimeTypeValue *> *supportedResultMimeTypes;


//==============================================================================
#pragma mark - Content Manipulation
//==============================================================================

/**
 * Applies the configuration changes to this recognizer.
 * For example, if you changed the language of the recognizer, call this API
 * to ensure the recognizer will take the change into account
 *
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when there is an ongoing pointer trace.
 *   * IINKErrorRuntime when there are some ongoing operations, see `idle`.
 *   * IINKErrorRuntime when the configuration cannot be applied to this recognizer.
 */
- (BOOL)applyConfigurationWithError:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(applyConfiguration());

/**
 * Removes all content from the recognizer.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorPointerSequence when there is an ongoing pointer trace.
 */
- (BOOL)clearWithError:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(clear());

/**
 * Returns the result of the recognition since the last call to `clear()`.
 *
 * @param mimeType the mime type that specifies the output format.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when the specified mime type is not supported.
 *   * IINKErrorRuntime when there are some ongoing operations, see `idle`.
 * @return the result on success, otherwise `nil`.
 */
- (nullable NSString *)getResult:(IINKMimeType)mimeType
                           error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(result(mimeType:));


//==============================================================================
#pragma mark - Pointer Events
//==============================================================================

/**
 * Registers a pointer down event.
 *
 * @param point pointer event coordinates.
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorPointerSequence when `pointerDown()` has already been called.
 * @return the item identifier of the starting stroke if any, otherwise
 *   an empty string.
 */
- (nullable NSString *)pointerDown:(CGPoint)point
                                at:(int64_t)t
                             force:(float)f
                             error:(NSError * _Nullable * _Nullable)error
                      NS_SWIFT_NAME(pointerDown(point:timestamp:force:));

/**
 * Registers a pointer move event.
 *
 * @param point pointer event coordinates.
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorPointerSequence when `pointerDown()` has not been called before.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerMove:(CGPoint)point
                 at:(int64_t)t
              force:(float)f
              error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerMove(point:timestamp:force:));

/**
 * Registers a pointer up event.
 *
 * @param point pointer event coordinates.
 * @param t pointer event timestamp, in ms since Unix EPOCH.
 * @param f normalized pressure, in [0,1].
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when x or y is not a number.
 *   * IINKErrorInvalidArgument when t exceeds year 9999.
 *   * IINKErrorInvalidArgument when f is not a number or is negative.
 *   * IINKErrorPointerSequence when `pointerDown()` has not been called before.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerUp:(CGPoint)point
               at:(int64_t)t
            force:(float)f
            error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerUp(point:timestamp:force:));

/**
 * Cancels an ongoing pointer trace.
 *
 * @param error the recipient for the error description object
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerCancelWithError:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerCancel());

/**
 * Sends a series of pointer events.
 *
 * @param events the list of events.
 * @param count the event count.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when a pointer event contains incorrect data.
 *   * IINKErrorPointerSequence when event sequence is not allowed.
 * @return `YES` on success, otherwise `NO`.
 */
- (BOOL)pointerEvents:(nonnull IINKPointerEvent *)events
                count:(NSInteger)count
                error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(pointerEvents(_:count:));


//==============================================================================
#pragma mark - Concurrency
//==============================================================================

/**
 * Whether ongoing modification operations are over.
 */
@property (nonatomic, readonly) BOOL idle;

/**
 * Waits until ongoing operations are over.
 */
- (void)waitForIdle;

@end
