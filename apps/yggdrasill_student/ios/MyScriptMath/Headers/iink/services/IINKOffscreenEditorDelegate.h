// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <iink/IINKEditorDelegate.h>


@class IINKOffscreenEditor;

/**
 * The delegate interface for receiving offscreen editor events.
 *
 * @see IINKOffscreenEditor
 * @since 2.1
 */
@protocol IINKOffscreenEditorDelegate <NSObject>

@required

//==============================================================================
#pragma mark - Required Methods
//==============================================================================

/**
 * Invoked when the part associated with the listened offscreen editor has changed.
 *
 * @param editor the offscreen editor.
 * @see IINKOffscreenEditor#setPart:(IINKContentPart)
 */
- (void)partChanged:(nonnull IINKOffscreenEditor*)editor;

/**
 * Invoked when the content has changed.
 *
 * @param editor the offscreen editor.
 * @param blockIds an array of block ids that have changed.
 */
- (void)contentChanged:(nonnull IINKOffscreenEditor*)editor blockIds:(nonnull NSArray<NSString *> *)blockIds;

/**
 * Invoked when an error has occurred.
 *
 * @param editor the offscreen editor.
 * @param blockId the block id on which this error has occurred.
 * @param message the error message.
 */
- (void)onError:(nonnull IINKOffscreenEditor*)editor
        blockId:(nonnull NSString*)blockId
        message:(nonnull NSString*)message;

@optional

//==============================================================================
#pragma mark - Optional Methods
//==============================================================================

/**
 * Invoked when the content has changed, with detailed information.
 *
 * @param editor the editor.
 * @param addedBlockIds the identifiers of the added blocks.
 * @param removedBlockIds the identifiers of the removed blocks.
 * @param updatedBlockIds the identifiers of the updated blocks.
 *
 * @since 4.2
 */
- (void)contentChanged2:(nonnull IINKOffscreenEditor*)editor
           addedBlockIds:(nonnull NSArray<NSString *> *)addedBlockIds
         removedBlockIds:(nonnull NSArray<NSString *> *)removedBlockIds
         updatedBlockIds:(nonnull NSArray<NSString *> *)updatedBlockIds;

/**
 * Invoked when an error has occurred.
 *
 * @param editor the offscreen editor.
 * @param blockId the block id on which this error has occurred.
 * @param code the error code.
 * @param message the error message.
 */
- (void)onError:(nonnull IINKOffscreenEditor*)editor
        blockId:(nonnull NSString*)blockId
           code:(IINKEditorError)code
        message:(nonnull NSString*)message;

@end
