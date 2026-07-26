// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/services/IINKChangesetOperation.h>


/**
 * A HistoryManager allows managing changesets for undo/redo.
 * It is associated with an offscreen editor.
 *
 * @since 3.0
 */
@interface IINKHistoryManager : NSObject
{

}


//==============================================================================
#pragma mark - History Management
//==============================================================================

/**
 * Undo the last changeset on part.
 *
 * @note this function will wait for pending gestures recognition.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when undo operations failed.
 */
- (BOOL)undo:(NSError * _Nullable * _Nullable)error
             NS_SWIFT_NAME(undo());


/**
 * Redo the last changeset reverted by `undo` on part.
 *
 * @note this function will wait for pending gestures recognition.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when redo operations failed.
 */
- (BOOL)redo:(NSError * _Nullable * _Nullable)error
             NS_SWIFT_NAME(redo());

/**
 * Returns the number of changesets performed on the part, since content part
 * was opened.
 *
 * @note this function will wait for pending gestures recognition.
 * @note the undo stack is partially purged from time to time to control
 *   memory consumption. The number of possible undo changesets at a given
 *   time is provided by `getPossibleUndoCount()`, while the total number of
 *   changesets since content part was opened is provided by
 *   `getUndoStackIndex()`.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the number of changesets performed on the part.
 */
-(nullable NSNumber *) undoRedoStackIndex:(NSError * _Nullable * _Nullable)error
                                NS_SWIFT_NAME(undoRedoStackIndex());


/**
 * Returns the number of changesets that can be undone (<= `getUndoStackIndex()`).
 *
 * @note this function will wait for pending gestures recognition.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the number of changesets that can be undone.
 */
-(nullable NSNumber *) possibleUndoCount:(NSError * _Nullable * _Nullable)error
                               NS_SWIFT_NAME(possibleUndoCount());

/**
 * Returns the number of changesets that can be redone.
 *
 * @note this function will wait for pending gestures recognition.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the number of changesets that can be redone.
 */
-(nullable NSNumber *) possibleRedoCount:(NSError * _Nullable * _Nullable)error
                               NS_SWIFT_NAME(possibleRedoCount());
/**
 * Returns the id associated with an undo/redo stack index.
 * Valid stack index values range from (current stack index - possible undo count) to (current stack index + possible redo count - 1).
 *
 * @note this function will wait for pending gestures recognition.
 *
 * @param stackIndex the index in the undo/redo stack.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *   * IINKErrorRuntime when `stackIndex` is invalid.
 * @return the id associated with the undo/redo stack index.
 */
-(nullable NSString *) undoRedoIdAt:(NSInteger)stackIndex
                              error:(NSError * _Nullable * _Nullable)error
                                    NS_SWIFT_NAME(undoRedoId(at:));

/**
 * Returns the changeset corresponding to an undo to the given id.
 *
 * @param id the id in the undo/redo stack.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the changeset if it exists, otherwise empty.
 */
-(nullable NSArray<IINKChangesetOperation *> *)undoChangesetTo:(nonnull NSString *)id
                                                        error:(NSError * _Nullable * _Nullable)error
                                                              NS_SWIFT_NAME(undoChangesetTo(id:));

/**
 * Returns the changeset corresponding to a redo from the given id.
 *
 * @param id the id in the undo/redo stack.
 * @param error the recipient for the error description object
 *   * IINKErrorRuntime when associated editor has been destroyed.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the changeset if it exists, otherwise empty.
 */
-(nullable NSArray<IINKChangesetOperation *> *)redoChangesetFrom:(nonnull NSString *)id
                                                          error:(NSError * _Nullable * _Nullable)error
                                                                NS_SWIFT_NAME(redoChangesetFrom(id:));

@end
