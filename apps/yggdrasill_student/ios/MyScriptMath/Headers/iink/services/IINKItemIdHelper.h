// Copyright @ MyScript. All rights reserved.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <iink/IINKError.h>
#import <iink/IINKPointerEvent.h>
#import <iink/graphics/IINKRect.h>

@class IINKEngine;

/**
 * Describes the combination modifiers.
 *
 * @since 2.1
 */
typedef NS_ENUM(NSUInteger, IINKItemIdCombinationModifier)
{
  /** Combines the union. */
  IINKItemIdCombinationModifierUnion,
  /** Combines the difference. */
  IINKItemIdCombinationModifierDifference,
  /** Combines the intersection. */
  IINKItemIdCombinationModifierIntersection,
};


/**
 * An ItemIdHelper allows working with item ids (e.g. strokes, glyphs, primitives, objects).
 * It is associated with an offscreen editor.
 *
 * @since 2.1
 */
@interface IINKItemIdHelper : NSObject
{

}


//==============================================================================
#pragma mark - Properties
//==============================================================================

/**
 * The `Engine` to which this offscreen editor is attached.
 */
@property (nonatomic, readonly, nonnull) IINKEngine *engine;


//==============================================================================
#pragma mark - Content Manipulation
//==============================================================================

/**
 * Checks whether a block is empty.
 *
 * @param blockId the block id to check.
 * @return `true` if block is empty or invalid or editor is not associated
 *   with a part, otherwise `false`.
 */
- (BOOL)isEmpty:(nonnull NSString *)blockId
        NS_SWIFT_NAME(isEmpty(blockId:));

/**
 * Returns the type of a block.
 *
 * @param blockId the identifier of the block.
 *
 * @return the block type associated with `blockId` or empty if there is no
 *   such block in the current part.
 *
 * @since 3.0
 */
- (nonnull NSString *)getBlockType:(nonnull NSString *)blockId
                       NS_SWIFT_NAME(getBlockType(blockId:));

/**
 * Returns the bounding box of a block.
 *
 * @param blockId the identifier of the block.
 *
 * @return the bounding box (with coordinates in input units) associated with `blockId`
 *   or empty if there is no such block in the current part.
 *
 * @since 3.0
 */
- (nullable IINKRect*)getBlockBox:(nonnull NSString *)blockId
          NS_SWIFT_NAME(getBlockBox(blockId:));

/**
 * Returns the four points of the oriented box of a block.
 *
 * @param blockId the identifier of the block.
 *
 * @return An array of NSValue holding 4 CGPoint: the original top-left, top-right, bottom-right,
 * bottom-left points after rotation (with coordinates in input units) or four zeros points if there is
 * no such block in the current part.
 *
 * @since 4.2
 */
- (nonnull NSArray<NSValue*> *)getBlockOrientedBox:(nonnull NSString *)blockId
                                   NS_SWIFT_NAME(getBlockOrientedBox(blockId:));

/**
 * Returns the bounding box of an item ids list.
 *
 * @param itemIds the item ids list.
 *
 * @return the bounding box (with coordinates in input units) associated with `itemIds`.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when an item id is invalid.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *
 * @since 3.0
 */
- (nullable IINKRect*)getItemsBox:(nonnull NSArray<NSString*> *)itemIds
                            error:(NSError * _Nullable * _Nullable)error
          NS_SWIFT_NAME(getItemsBox(itemIds:));

/**
 * Returns the children block ids of a block.
 *
 * @param blockId the identifier of the block.
 *
 * @return an array of the children block ids associated with `blockId` or empty
 *   if there is no such block in the current part.
 *
 * @since 3.0
 */
- (nonnull NSArray<NSString*> *)getBlockChildrenIds:(nonnull NSString *)blockId
                                NS_SWIFT_NAME(getBlockChildrenIds(blockId:));

/**
 * Returns the parent block id of a block.
 *
 * @param blockId the identifier of the block.
 *
 * @return the parent block id associated with `blockId` or empty if block is root
 *   or if there is no such block in the current part.
 *
 * @since 3.0
 */
- (nonnull NSString*)getBlockParentId:(nonnull NSString *)blockId
                      NS_SWIFT_NAME(getBlockParentId(blockId:));

/**
 * Returns the parent block id of an item.
 *
 * @param itemId the identifier of the item.
 *
 * @return the parent block id associated with `itemId`.
 *
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when item id is invalid.
 *   * IINKErrorRuntime when editor is not associated with a part.
 *
 * @since 3.0
 */
- (nullable NSString *)getItemParentId:(nonnull NSString *)itemId
                                 error:(NSError * _Nullable * _Nullable)error
                       NS_SWIFT_NAME(getItemParentId(itemId:));

/**
 * Returns the item ids associated with a given `blockId`.
 *
 * @param blockId the identifier of the block.
 *
 * @return the item ids associated with `blockId` on success, empty if there is no
 *   such block in the current part, `nil` otherwise.
 */
- (nonnull NSArray<NSString*> *)getItemsByBlockId:(nonnull NSString *)blockId;

/**
 * Combines two item ids lists.
 *
 * @param itemIds1 the first item ids list to combine.
 * @param itemIds2 the second item ids list to combine.
 * @param mode the modifier specifying the combination mode.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when when an item id is invalid.
 *   * IINKErrorInvalidArgument when mode is not a valid ItemIdCombinationModifier value.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the combined list of item ids.
 */
- (nullable NSArray<NSString*> *)combine:(nonnull NSArray<NSString*> *)itemIds1
                                itemIds2:(nonnull NSArray<NSString*> *)itemIds2
                                    mode:(IINKItemIdCombinationModifier)mode
                                   error:(NSError * _Nullable * _Nullable)error;

/**
 * Checks if an item is partial.
 *
 * @param itemId the item id to check.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when item id is invalid.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return an NSNumber wrapping a boolean: `true` if item is partial, `false` otherwise.
 */
- (nullable NSNumber*)isPartialItem:(nonnull NSString *)itemId
                error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the full item id associated with a partial item id.
 *
 * @param partialItemId the partial item id.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when partial item id is invalid.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the full item id.
 */
- (nullable NSString *)getFullItemId:(nonnull NSString *)partialItemId
                               error:(NSError * _Nullable * _Nullable)error;

/**
 * Returns the pointer events of an item.
 *
 * @param itemId the item id.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when item id is invalid.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the pointer events of the item (with coordinates in input units).
 */
- (nullable NSArray<IINKPointerEventValue*> *)getPointsForItemId:(nonnull NSString *)itemId
                                                           error:(NSError * _Nullable * _Nullable)error;

/**
 * Converts an item ids list to its canonical form.
 *
 * @param itemIds the item ids list.
 * @param error the recipient for the error description object
 *   * IINKErrorInvalidArgument when an item id is invalid.
 *   * IINKErrorRuntime when editor is not associated with a part.
 * @return the canonical form of the item ids list.
 */
- (nullable NSArray<NSString*> *)toCanonicalItemIds:(nonnull NSArray<NSString*> *)itemIds
                                              error:(NSError * _Nullable * _Nullable)error;

@end
