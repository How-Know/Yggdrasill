// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/services/IINKHistoryManager.h>
#import <iink/services/IINKOffscreenEditorDelegate.h>
#import <iink/IINKEditor.h>
#import <iink/IINKError.h>
#import <iink/IINKMimeType.h>
#import <iink/IINKParameterSet.h>
#import <iink/IINKPointerEvent.h>


@class IINKContentPart;
@class IINKEngine;
@class IINKConfiguration;
@protocol IINKOffscreenGestureDelegate;

/**
 * The OffscreenEditor is a service allowing offscreen interactivity.
 * It is the entry point to edit an associated part and receive change notifications.
 *
 * @since 2.1
 */
@interface IINKOffscreenEditor : NSObject
{

}


//==============================================================================
#pragma mark - Delegate
//==============================================================================

/**
 * Adds a delegate to this offscreen editor without changing the `delegate` property.
 * @param delegate the delegate to add.
 */
- (void)addDelegate:(nonnull id<IINKOffscreenEditorDelegate>)delegate;

/**
 * Removes a delegate added by `addDelegate:`
 * @param delegate the delegate to remove.
 */
- (void)removeDelegate:(nonnull id<IINKOffscreenEditorDelegate>)delegate;


//==============================================================================
#pragma mark - Gesture Delegate
//==============================================================================

/**
 * The delegate that will receive offscreen gesture handler events.
 */
@property (weak, nonatomic, nullable) id<IINKOffscreenGestureDelegate> gestureDelegate;


//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The `Engine` to which this offscreen editor is attached.
 */
@property (nonatomic, readonly, nonnull) IINKEngine *engine;

/**
 * The configuration associated with this offscreen editor.
 */
@property (nonatomic, readonly, nonnull) IINKConfiguration *configuration;

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
 * The part managed by this offscreen editor.
 */
@property (strong, nonatomic, nullable) IINKContentPart *part;

/**
 * Sets the part managed by this offscreen editor.
 *
 * @param part the part.
 * @param error the recipient for the error description object
 *
 *   * IINKErrorRuntime  when no `IFontMetricProvider` has been set,
 *   via `setFontMetricsProvider()`.
 *   * IINKErrorRuntime  when `part` is already bound.
 *   * IINKErrorRuntime  when this offscreen editor cannot be configured.
*/
- (BOOL)setPart:(nullable IINKContentPart*)part
          error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(part:));

/**
 * Sets the part managed by this offscreen editor.
 *
 * @param part the part.
 * @param forceReconfigure tells whether to force the reconfiguration or not.
 *   This call may trigger a complete reprocess of the `part`, interactivity
 *   will be limited until that processing is over.
 * @param error the recipient for the error description object
 *
 *   * IINKErrorRuntime  when no `IFontMetricProvider` has been set,
 *   via `setFontMetricsProvider()`.
 *   * IINKErrorRuntime  when `part` is already bound.
 *   * IINKErrorRuntime  when this offscreen editor cannot be configured.
 *
 * @since 4.5
*/
- (BOOL)setPart:(nullable IINKContentPart*)part
  forceReconfigure:(BOOL)forceReconfigure
             error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(part:forceReconfigure:));

/**
 * The block id at the root of the current part, empty if none.
 */
@property (nonatomic, strong, readonly, nullable) NSString *rootBlockId;

/**
 * The `HistoryManager` to which this offscreen editor is attached, if any.
 *
 * @since 3.0
 */
@property (strong, nonatomic, readonly) IINKHistoryManager * _Nullable historyManager;

/**
 * The `MathSolverController` associated with this offscreen editor.
 *
 * @since 4.0
 */
@property (nonatomic, readonly, nullable) IINKMathSolverController *mathSolverController;


//==============================================================================
#pragma mark - Content Management
//==============================================================================

/**
 * Removes all content from the part.
 */
- (void)clear;


//==============================================================================
#pragma mark - Concurrency
//==============================================================================

/**
 * Whether part modification operations are over.
 */
@property (nonatomic, readonly) BOOL idle;

/**
 * Waits until part modification operations are over.
 */
-(void)waitForIdle;


//==============================================================================
#pragma mark - Item Management
//==============================================================================

/**
 * Adds strokes.
 *
 * @param events the strokes pointer events (with coordinates in input units).
 * @param count the event count.
 * @param processGestures tells whether to process gestures or not.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when count is inferior or equal to zero.
 *   * IINKErrorInvalidArgument when a pointer event contains incorrect data.
 *   * IINKErrorInvalidArgument when a stroke has too many points.
 *   * IINKErrorInvalidArgument when events contain more than `20` strokes and processGestures is `true`.
 *   * IINKErrorPointerSequence when event sequence is not allowed.
 * @return the new item ids on success, otherwise `nil`.
 */
- (nullable NSArray<NSString*> *)addStrokes:(nonnull IINKPointerEvent *)events
                                      count:(NSInteger)count
                          doProcessGestures:(BOOL)processGestures
                                      error:(NSError * _Nullable * _Nullable)error;

/**
 * Replaces strokes.
 *
 * @param itemIds the item ids to replace. Unknown ids are ignored.
 * @param events the strokes pointer events (with coordinates in input units).
 * @param count the event count.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when itemIds is empty.
 *   * IINKErrorInvalidArgument when count is inferior or equal to zero.
 *   * IINKErrorInvalidArgument when pointerType is invalid.
 *   * IINKErrorInvalidArgument when a pointer event contains incorrect data.
 *   * IINKErrorInvalidArgument when a stroke has too many points.
 *   * IINKErrorPointerSequence when event sequence is not allowed.
 * @return the replacing item ids, otherwise `nil`.
 */
- (nullable NSArray<NSString*> *)replaceStrokes:(nonnull NSArray<NSString*> *)itemIds
                                         events:(nonnull IINKPointerEvent *)events
                                          count:(NSInteger)count
                                          error:(NSError * _Nullable * _Nullable)error;

/**
 * Erases the specified items. Unknown ids are ignored.
 *
 * @param itemIds the item ids to erase.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when offscreen editor is not associated with a part.
 */
- (BOOL)erase:(nonnull NSArray<NSString*> *)itemIds
        error:(NSError * _Nullable * _Nullable)error;


//==============================================================================
#pragma mark - Content Manipulation
//==============================================================================

/**
 * Checks if a transformation is allowed on the specified items.
 *
 * @param transform the transformation to check.
 * @param itemIds the item ids on which to check the transformation.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when offscreen editor is not associated with a part.
 *   * IINKErrorInvalidArgument when item ids are not valid.
 * @return an IINKTransformErrorValue object containing error code from enum `IINKTransformError`.
 *
 */
- (nullable IINKTransformErrorValue*)getTransformStatus:(CGAffineTransform)transform
                                                itemIds:(nonnull NSArray<NSString*> *)itemIds
                                                  error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(transformStatus(forTransform:itemIds:));

/**
 * Transforms the specified items.
 *
 * @param transform the transformation to apply.
 * @param itemIds the item ids on which to apply the transformation.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when offscreen editor is not associated with a part.
 *   * IINKErrorRuntime when the transform is not allowed on the item ids.
 *   * IINKErrorInvalidArgument when transform is not valid for this operation.
 *   * IINKErrorInvalidArgument when item ids are not valid.
 */
- (BOOL)applyTransform:(CGAffineTransform)transform
               itemIds:(nonnull NSArray<NSString*> *)itemIds
                 error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(applyTransform(forTransform:itemIds:));

/**
 * Returns the available types for the specified items.
 *
 * @note this function will wait for pending gesture recognition before returning available types.
 *
 * @param itemIds the item ids to request types for.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when offscreen editor is not associated with a part.
 *   * IINKErrorInvalidArgument when item ids are not valid.
 * @return an array of the available types.
 *
 * @since 3.1
 */
- (nullable NSArray<NSString*> *)getAvailableItemsTypes:(nonnull NSArray<NSString*> *)itemIds
                                                  error:(NSError * _Nullable * _Nullable)error
                                     NS_SWIFT_NAME(availableTypes(forItems:));

/**
 * Sets the classification of the specified items to a given type.
 *
 * @note this function will wait for pending gesture recognition before changing items type.
 *
 * @param itemIds the item ids to classify.
 * @param type the content type to set. See {@link #getAvailableItemsTypes()}.
 * @param forceSingleBlock `true` to force converting the items to a single block, otherwise `false`.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when item ids are not valid.
 *   * IINKErrorRuntime when offscreen editor is not associated with a part.
 *   * IINKErrorInvalidArgument when items are not compatible with the type.
 *
 * @since 3.1
 */
- (BOOL)setItemsType:(nonnull NSString*)type
               items:(nonnull NSArray<NSString*> *)itemIds
    forceSingleBlock:(BOOL)forceSingleBlock
               error:(NSError * _Nullable * _Nullable)error
        NS_SWIFT_NAME(set(type:forItems:forceSingleBlock:));

//==============================================================================
#pragma mark - Export
//==============================================================================

/**
 * Returns the supported export formats for the specified items.
 *
 * @param itemIds the item ids to request export mime types for, empty means full part.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when item ids are not valid.
 * @return an array of the supported mime types, empty if not associated with a part.
 */
- (nullable NSArray<IINKMimeTypeValue *> *)getSupportedExportMimeTypes:(nonnull NSArray<NSString*> *)itemIds
                                                                 error:(NSError * _Nullable * _Nullable)error
                                           NS_SWIFT_NAME(supportedExportMimeTypes(forItemIds:));

/**
 * Exports the specified items.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param itemIds the item ids to export, empty means full part.
 * @param mimeType the mime type that specifies the output format.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when offscreen editor is not associated with a part.
 *   * IINKErrorInvalidArgument when item ids are not valid.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 * @return the exported content on success, otherwise `nil`.
 */
- (nullable NSString *)export_:(nonnull NSArray<NSString*> *)itemIds
                      mimeType:(IINKMimeType)mimeType
                         error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(export(itemIds:mimeType:));

/**
 * Exports the specified items.
 *
 * @note the method is named `export_` because the C++ standard defines
 * `export` as a keyword.
 *
 * @param itemIds the item ids to export, empty means full part.
 * @param mimeType the mime type that specifies the output format.
 * @param overrideConfiguration the extra configuration used when exporting.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when offscreen editor is not associated with a part.
 *   * IINKErrorInvalidArgument when item ids are not valid.
 *   * IINKErrorRuntime when the specified mime type is not supported.
 *   * IINKErrorRuntime when an I/O operation fails.
 *   * IINKErrorRuntime when there are some ongoing operations on the part
 *   that prevent export, see `idle`.
 *   * IINKErrorInvalidArgument when there is nothing to export.
 *   * IINKErrorInvalidArgument when `overrideConfiguration` is invalid.
 * @return the exported content on success, otherwise `nil`.
 */
- (nullable NSString *)export_:(nonnull NSArray<NSString*> *)itemIds
                      mimeType:(IINKMimeType)mimeType
         overrideConfiguration:(nonnull IINKParameterSet *)overrideConfiguration
                         error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(export(itemIds:mimeType:overrideConfiguration:));

@end
